// Confines all media buffers, writer inputs, microphone mixing, and camera compositing to one queue.
@preconcurrency import AVFoundation // Legacy media delegates are confined to their explicitly supplied callback queue.
@preconcurrency import ScreenCaptureKit // SCStreamOutput does not express callback-queue isolation in its declaration.
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Framework callbacks and commands share this queue; no CMSampleBuffer/CVPixelBuffer crosses an actor.
/// The Sendable conformance covers the queue-owning controller, never an unchecked media-buffer wrapper.
final class RecordingPipeline: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate,
                               AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "com.n1ko.niko-shot.recording.writer", qos: .userInitiated)
    private let options: RecordingOptions
    private let width: Int, height: Int
    private let output: URL
    private let events: AsyncStream<RecordingEvent>.Continuation
    // All mutable members below are exclusively accessed on queue.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audio: AudioRouter?
    private var cameraSession: AVCaptureSession?
    private var cameraOutput: AVCaptureVideoDataOutput?
    private var cameraImage: CVPixelBuffer?
    private var screenImage: CVPixelBuffer?
    private var encodedImage: CVPixelBuffer?
    private var imageContext: CIContext?
    private var clockTimer: DispatchSourceTimer?
    private var finishingTimer: DispatchSourceTimer?
    private var timeline = RecordingTimeline()
    private var lastVideoTime: Double?
    private var acceptsSamples = false
    private var ownsOutput = false
    private var finishing: CheckedContinuation<RecordingResult, any Error>?
    private var finishingDuration = 0.0
    private var videoFinished = false
    private var audioFinished = false
    private var writerFinishing = false

    init(options: RecordingOptions, width: Int, height: Int, output: URL,
         events: AsyncStream<RecordingEvent>.Continuation) {
        self.options = options; self.width = width; self.height = height
        self.output = output; self.events = events
    }

    func configure() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do { try self.configureOnQueue(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func pause(at time: Double) {
        queue.async {
            guard self.acceptsSamples, self.timeline.pausedAt == nil else { return }
            let duration = self.timeline.elapsed(at: time)
            do { try self.audio?.flushConverters() }
            catch { self.failOnQueue(error.localizedDescription); return }
            self.flushAudio(until: Int(duration * AudioRouter.sampleRate))
            self.timeline.pause(at: time)
            self.events.yield(.duration(duration))
        }
    }

    func resume(at time: Double) { queue.async { if self.acceptsSamples { self.timeline.resume(at: time) } } }

    func setCameraEnabled(_ enabled: Bool) async throws -> AVCaptureSession? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.acceptsSamples else { continuation.resume(throwing: RecordingError.cancelled); return }
                do {
                    if enabled, self.cameraSession == nil { try self.startCameraOnQueue() }
                    else if !enabled { self.stopCameraOnQueue() }
                    continuation.resume(returning: self.cameraSession)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func finish(at hostTime: Double) async throws -> RecordingResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.finishOnQueue(continuation, at: hostTime) }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.acceptsSamples = false
                self.stopInputsOnQueue()
                if let writer = self.writer, writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
                if self.ownsOutput { try? FileManager.default.removeItem(at: self.output); self.ownsOutput = false }
                self.finishing?.resume(throwing: RecordingError.cancelled); self.finishing = nil
                self.releaseWriterOnQueue()
                self.events.finish(); continuation.resume()
            }
        }
    }

    /// Reads confinement diagnostics without exposing a native media buffer to another executor.
    func resourceCounts() async -> [String: Int] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: ["writer": self.writer == nil ? 0 : 1,
                    "video": self.videoInput == nil ? 0 : 1, "audio": self.audioInput == nil ? 0 : 1,
                    "adaptor": self.adaptor == nil ? 0 : 1, "mixer": self.audio == nil ? 0 : 1,
                    "microphone": self.audio?.isMicrophoneRunning == true ? 1 : 0,
                    "camera": self.cameraSession == nil ? 0 : 1, "screenBuffer": self.screenImage == nil ? 0 : 1,
                    "cameraBuffer": self.cameraImage == nil ? 0 : 1, "encodedBuffer": self.encodedImage == nil ? 0 : 1,
                    "gpu": self.imageContext == nil ? 0 : 1, "timer": self.clockTimer == nil ? 0 : 1,
                    "finishingTimeout": self.finishingTimer == nil ? 0 : 1,
                    "finishing": self.finishing == nil ? 0 : 1])
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard acceptsSamples, timeline.pausedAt == nil,
              CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch outputType {
        case .screen:
            guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            if let entries = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let raw = entries.first?[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard time.isFinite else { return }
            if timeline.origin == nil {
                timeline.begin(at: time)
                writer?.startSession(atSourceTime: .zero)
            }
            screenImage = image
            appendVideo(image, sourceTime: time)
        case .audio:
            guard let frame = AudioRouter.copySystemPCM(sampleBuffer) else { return }
            receivePCM(frame, source: .system)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let message = error.localizedDescription
        queue.async { if self.acceptsSamples { self.failOnQueue(message) } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard acceptsSamples, cameraSession != nil, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        cameraImage = image
        // A static desktop must still record a moving camera inset even though our own windows are excluded.
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if let background = screenImage, let presentation = timeline.presentationTime(for: time),
           presentation - (lastVideoTime ?? -1) >= 1 / Double(options.fps) {
            appendVideo(background, sourceTime: time)
        }
    }

    private func configureOnQueue() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard writer == nil else { throw RecordingError.encoder("录制器已经初始化。") }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw RecordingError.encoder("输出文件已经存在，请选择新的文件名。")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let assetWriter = try AVAssetWriter(outputURL: output, fileType: .mp4)
        ownsOutput = true
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: options.bitRate(width: width, height: height),
            AVVideoExpectedSourceFrameRateKey: options.fps, AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: options.codec == "h264" ? AVVideoProfileLevelH264HighAutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel as String
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: options.codec == "h264" ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
                                             kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true; input.mediaTimeScale = 60_000
        guard assetWriter.canAdd(input) else { throw RecordingError.encoder("当前设备不支持所选视频编码。") }
        assetWriter.add(input)
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        writer = assetWriter; videoInput = input; adaptor = pixels
        if options.systemAudio || options.microphone {
            let router = try AudioRouter(systemAudio: options.systemAudio, microphone: options.microphone)
            let audioTrack = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioRouter.sampleRate,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
            ])
            audioTrack.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(audioTrack) else { throw RecordingError.encoder("AAC 音频编码不可用。") }
            assetWriter.add(audioTrack); audioInput = audioTrack; audio = router
        }
        guard assetWriter.startWriting() else { throw RecordingError.encoder(assetWriter.error?.localizedDescription ?? "无法开始 MP4 编码。") }
        acceptsSamples = true
        if options.microphone {
            try audio?.startMicrophone { [weak self] frame in
                guard let self else { return }
                self.queue.async { self.receivePCM(frame, source: .microphone) }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let self, self.acceptsSamples else { return }
            self.events.yield(.duration(self.timeline.elapsed(at: Self.hostTime)))
        }
        clockTimer = timer; timer.resume()
    }

    private func receivePCM(_ frame: RecordingPCMFrame, source: RecordingAudioSource) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard acceptsSamples, let presentation = timeline.presentationTime(for: frame.sourceTime), let audio else { return }
        do { try audio.append(frame, at: presentation, source: source); flushAudio(until: audio.readyThroughFrame) }
        catch { failOnQueue(error.localizedDescription) }
    }

    private func flushAudio(until endFrame: Int) {
        guard let audio, let input = audioInput, writer?.status == .writing, timeline.origin != nil else { return }
        while input.isReadyForMoreMediaData, let mixed = audio.consume(until: endFrame) {
            do {
                let buffer = try audio.sampleBuffer(for: mixed)
                if !input.append(buffer) { failOnQueue(writer?.error?.localizedDescription ?? "混合音频写入失败。"); return }
            } catch { failOnQueue(error.localizedDescription); return }
        }
    }

    private func appendVideo(_ source: CVPixelBuffer, sourceTime: Double) {
        guard let presentation = timeline.presentationTime(for: sourceTime),
              presentation > (lastVideoTime ?? -1), let input = videoInput, input.isReadyForMoreMediaData,
              let adaptor, writer?.status == .writing else { return }
        do {
            let image = try cameraImage.map { try composite(background: source, camera: $0) } ?? source
            let time = CMTime(seconds: presentation, preferredTimescale: 60_000)
            guard adaptor.append(image, withPresentationTime: time) else {
                failOnQueue(writer?.error?.localizedDescription ?? "视频帧写入失败。"); return
            }
            lastVideoTime = presentation; encodedImage = image
        } catch { failOnQueue(error.localizedDescription) }
    }

    private func composite(background: CVPixelBuffer, camera: CVPixelBuffer) throws -> CVPixelBuffer {
        guard let pool = adaptor?.pixelBufferPool else { throw RecordingError.encoder("摄像头合成缓冲池不可用。") }
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
        guard status == kCVReturnSuccess, let destination else { throw RecordingError.encoder("摄像头合成缓冲区分配失败 (\(status))。") }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let insetWidth = CGFloat(width) * 0.22, insetHeight = min(CGFloat(height) * 0.3, insetWidth * 9 / 16)
        let margin = max(8, CGFloat(width) * 0.018)
        let target = CGRect(x: CGFloat(width) - insetWidth - margin, y: margin, width: insetWidth, height: insetHeight)
        let cameraImage = CIImage(cvPixelBuffer: camera)
        let factor = max(target.width / cameraImage.extent.width, target.height / cameraImage.extent.height)
        let resized = cameraImage.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let positioned = resized.transformed(by: CGAffineTransform(translationX: target.midX - resized.extent.midX,
                                                                  y: target.midY - resized.extent.midY)).cropped(to: target)
        let result = positioned.composited(over: CIImage(cvPixelBuffer: background)).cropped(to: bounds)
        let context: CIContext
        if let cached = imageContext { context = cached }
        else { context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false]); imageContext = context }
        context.render(result, to: destination, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return destination
    }

    private func startCameraOnQueue() throws {
        guard let device = AVCaptureDevice.default(for: .video) else { throw RecordingError.capture("没有可用的摄像头。") }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration(); throw RecordingError.capture("摄像头画中画不可用。")
        }
        session.addInput(input); session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = true
        }
        session.commitConfiguration()
        cameraOutput = output; cameraSession = session
        session.startRunning()
        guard session.isRunning else { stopCameraOnQueue(); throw RecordingError.capture("摄像头未能开始采集。") }
    }

    private func stopCameraOnQueue() {
        cameraOutput?.setSampleBufferDelegate(nil, queue: nil)
        cameraSession?.stopRunning()
        cameraSession = nil; cameraOutput = nil; cameraImage = nil; imageContext = nil
    }

    private func finishOnQueue(_ continuation: CheckedContinuation<RecordingResult, any Error>, at hostTime: Double) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard finishing == nil, let writer, writer.status == .writing else {
            continuation.resume(throwing: RecordingError.encoder(self.writer?.error?.localizedDescription ?? "录制器已停止。")); return
        }
        acceptsSamples = false; stopInputsOnQueue()
        do { try audio?.flushConverters() }
        catch { writer.cancelWriting(); continuation.resume(throwing: error); return }
        guard timeline.origin != nil, lastVideoTime != nil else {
            writer.cancelWriting()
            if ownsOutput { try? FileManager.default.removeItem(at: output); ownsOutput = false }
            releaseWriterOnQueue(); events.finish(); continuation.resume(throwing: RecordingError.empty); return
        }
        let end = max(timeline.elapsed(at: hostTime), (lastVideoTime ?? 0) + 1 / Double(options.fps))
        events.yield(.duration(end)); finishing = continuation; finishingDuration = end
        audioFinished = audioInput == nil; videoFinished = false; writerFinishing = false
        // Backpressure must not drop the final static-screen frame or the last mixed audio block.
        videoInput?.requestMediaDataWhenReady(on: queue) { [weak self] in self?.finishVideoOnQueue() }
        audioInput?.requestMediaDataWhenReady(on: queue) { [weak self] in self?.finishAudioOnQueue() }
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.schedule(deadline: .now() + .seconds(15), leeway: .milliseconds(100))
        timeout.setEventHandler { [weak self] in
            guard let self, self.finishing != nil else { return }
            self.abortFinishOnQueue("编码器完成超时，请检查可用磁盘空间。")
        }
        finishingTimer = timeout; timeout.resume()
    }

    private func finishVideoOnQueue() {
        guard finishing != nil, !videoFinished, let input = videoInput else { return }
        if writer?.status == .failed { abortFinishOnQueue(writer?.error?.localizedDescription ?? "视频编码失败。"); return }
        guard input.isReadyForMoreMediaData else { return }
        // A final repeated frame gives an unchanged desktop its full recorded duration.
        if let image = encodedImage, finishingDuration > (lastVideoTime ?? -1),
           adaptor?.append(image, withPresentationTime: CMTime(seconds: finishingDuration, preferredTimescale: 60_000)) != true {
            abortFinishOnQueue(writer?.error?.localizedDescription ?? "最后一帧写入失败。"); return
        }
        input.markAsFinished(); videoFinished = true; finishWriterIfReadyOnQueue()
    }

    private func finishAudioOnQueue() {
        guard finishing != nil, !audioFinished, let input = audioInput, let audio else { return }
        if writer?.status == .failed { abortFinishOnQueue(writer?.error?.localizedDescription ?? "音频编码失败。"); return }
        let endFrame = Int(finishingDuration * AudioRouter.sampleRate)
        while input.isReadyForMoreMediaData, let mixed = audio.consume(until: endFrame) {
            do {
                guard input.append(try audio.sampleBuffer(for: mixed)) else {
                    abortFinishOnQueue(writer?.error?.localizedDescription ?? "最后一段音频写入失败。"); return
                }
            } catch { abortFinishOnQueue(error.localizedDescription); return }
        }
        guard audio.mixer.nextFrame >= endFrame else { return }
        input.markAsFinished(); audioFinished = true; finishWriterIfReadyOnQueue()
    }

    private func finishWriterIfReadyOnQueue() {
        guard finishing != nil, videoFinished, audioFinished, !writerFinishing, let writer else { return }
        writerFinishing = true
        writer.endSession(atSourceTime: CMTime(seconds: finishingDuration, preferredTimescale: 60_000))
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard let pending = self.finishing else { return }
                self.finishing = nil
                if self.writer?.status == .completed {
                    let result = RecordingResult(url: self.output, duration: self.finishingDuration)
                    self.ownsOutput = false; self.releaseWriterOnQueue(); self.events.finish(); pending.resume(returning: result)
                } else {
                    let message = self.writer?.error?.localizedDescription ?? "MP4 文件未能完成。"
                    if self.ownsOutput { try? FileManager.default.removeItem(at: self.output); self.ownsOutput = false }
                    self.releaseWriterOnQueue(); self.events.finish(); pending.resume(throwing: RecordingError.encoder(message))
                }
            }
        }
    }

    private func abortFinishOnQueue(_ message: String) {
        guard let pending = finishing else { return }
        finishing = nil
        if writer?.status == .writing { writer?.cancelWriting() }
        if ownsOutput { try? FileManager.default.removeItem(at: output); ownsOutput = false }
        releaseWriterOnQueue(); events.finish(); pending.resume(throwing: RecordingError.encoder(message))
    }

    private func failOnQueue(_ message: String) {
        guard acceptsSamples else { return }
        acceptsSamples = false; stopInputsOnQueue(); events.yield(.failure(message))
    }

    private func stopInputsOnQueue() {
        clockTimer?.setEventHandler {}; clockTimer?.cancel(); clockTimer = nil
        audio?.stopMicrophone(); stopCameraOnQueue()
    }

    private func releaseWriterOnQueue() {
        finishingTimer?.setEventHandler {}; finishingTimer?.cancel(); finishingTimer = nil
        writer = nil; videoInput = nil; audioInput = nil; adaptor = nil; audio = nil
        screenImage = nil; encodedImage = nil; lastVideoTime = nil; timeline = RecordingTimeline()
    }

    static var hostTime: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}
