// Exposes an observable native recording lifecycle while media state remains on its callback queue.
@preconcurrency import AVFoundation // AVCaptureSession is a native preview handle; media buffers stay inside RecordingPipeline.
@preconcurrency import ScreenCaptureKit // Legacy framework callbacks use the pipeline's explicitly supplied serial queue.
import CoreGraphics
import Foundation
import Observation

/// Coordinates ScreenCaptureKit, microphone consent, camera preview, and a queue-confined MP4 encoder.
@MainActor @Observable
public final class RecordingSession {
    /// Current lifecycle observed by the floating controls.
    public private(set) var state: RecordingState = .idle
    /// Pause-free elapsed time, retained after Stop for the GIF size estimate.
    public private(set) var duration: Double = 0
    /// The latest actionable capture/encoding error.
    public private(set) var errorMessage: String?
    /// A native preview handle, present only while camera capture is enabled.
    public private(set) var cameraSession: AVCaptureSession?
    /// Actual even-pixel encoded dimensions, retained after Stop.
    public private(set) var lastOutputSize: CGSize = .zero
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var pipeline: RecordingPipeline?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cameraRequest = UUID()

    /// Creates a lazy recording session with no active stream, camera, microphone, or timers.
    public init() {}

    /// Diagnostic counts used to verify that idle/cancelled sessions own no native capture resources.
    var resourceCounts: [String: Int] {
        ["stream": stream == nil ? 0 : 1, "pipeline": pipeline == nil ? 0 : 1,
         "events": eventTask == nil ? 0 : 1, "camera": cameraSession == nil ? 0 : 1,
         "cleanup": cleanupTask == nil ? 0 : 1]
    }

    /// Starts a region, individual window, or display, requesting only the sources that were selected.
    public func start(target: RecordingTarget, options: RecordingOptions, output: URL) async throws {
        let options = RecordingOptions(fps: options.fps, codec: options.codec, quality: options.quality,
            systemAudio: options.systemAudio, microphone: options.microphone, showsCursor: options.showsCursor, camera: options.camera)
        guard (state == .idle || state == .failed), cleanupTask == nil else { throw RecordingError.capture("已有录制正在进行。") }
        let token = UUID(); generation = token
        state = .preparing; duration = 0; errorMessage = nil; lastOutputSize = .zero
        var localPipeline: RecordingPipeline?, localStream: SCStream?
        do {
            guard CGPreflightScreenCaptureAccess() else {
                throw RecordingError.permission("屏幕与系统音频录制")
            }
            if options.microphone { try await requireAccess(to: .audio, named: "麦克风") }
            if options.camera { try await requireAccess(to: .video, named: "摄像头") }
            try checkGeneration(token)
            let (filter, configuration, size) = try await captureConfiguration(for: target, options: options)
            try checkGeneration(token)
            lastOutputSize = size
            let (events, continuation) = AsyncStream<RecordingEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
            let encoder = RecordingPipeline(options: options, width: Int(size.width), height: Int(size.height),
                                            output: output, events: continuation)
            localPipeline = encoder; pipeline = encoder
            eventTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled, let self, self.generation == token else { break }
                    self.receive(event, generation: token)
                }
            }
            try await encoder.configure()
            try checkGeneration(token)
            if options.camera {
                let preview = try await encoder.setCameraEnabled(true)
                try checkGeneration(token); cameraSession = preview
            }
            let capture = SCStream(filter: filter, configuration: configuration, delegate: encoder)
            localStream = capture; stream = capture
            try capture.addStreamOutput(encoder, type: .screen, sampleHandlerQueue: encoder.queue)
            if options.systemAudio { try capture.addStreamOutput(encoder, type: .audio, sampleHandlerQueue: encoder.queue) }
            try await capture.startCapture()
            try checkGeneration(token)
            state = .recording
        } catch {
            try? await localStream?.stopCapture()
            await localPipeline?.cancel()
            if generation == token {
                stream = nil; pipeline = nil; cameraSession = nil
                eventTask?.cancel(); eventTask = nil
                if error is CancellationError { state = .idle }
                else { state = .failed; errorMessage = error.localizedDescription }
            }
            throw error
        }
    }

    /// Pauses both tracks, preserving the exact host-clock boundary for Resume.
    public func pause() {
        guard state == .recording else { return }
        state = .paused; pipeline?.pause(at: RecordingPipeline.hostTime)
    }

    /// Resumes video and mixed audio on the same timeline, without recording the paused interval.
    public func resume() {
        guard state == .paused else { return }
        pipeline?.resume(at: RecordingPipeline.hostTime); state = .recording
    }

    /// Finalizes a playable MP4 and retains its duration/dimensions for optional GIF export.
    public func stop() async throws -> URL {
        guard state == .recording || state == .paused, let encoder = pipeline else { throw RecordingError.notRecording }
        let token = generation
        state = .finishing
        let stopTime = RecordingPipeline.hostTime
        encoder.pause(at: stopTime)
        if let stream { try? await stream.stopCapture() }
        self.stream = nil; cameraSession = nil
        do {
            let result = try await encoder.finish(at: stopTime)
            try checkGeneration(token)
            pipeline = nil; eventTask?.cancel(); eventTask = nil; state = .idle; duration = result.duration
            return result.url
        } catch {
            await encoder.cancel()
            if generation == token {
                pipeline = nil; eventTask?.cancel(); eventTask = nil
                state = .failed; errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    /// Cancels capture and deletes only the partial output actually created by this session.
    public func cancel() async {
        if let cleanupTask { await cleanupTask.value }
        generation = UUID(); cameraRequest = UUID()
        let token = generation
        let oldStream = stream, oldPipeline = pipeline
        stream = nil; pipeline = nil; cameraSession = nil
        eventTask?.cancel(); eventTask = nil
        guard oldStream != nil || oldPipeline != nil else {
            cleanupTask = nil; state = .idle; duration = 0; errorMessage = nil; return
        }
        // Keep the session busy until the old native resources have been stopped.
        state = .finishing
        let cleanup = Task {
            try? await oldStream?.stopCapture()
            await oldPipeline?.cancel()
        }
        cleanupTask = cleanup
        await cleanup.value
        if generation == token { cleanupTask = nil; state = .idle; duration = 0; errorMessage = nil }
    }

    /// Toggles both the native PiP preview and the inset encoded into the saved video.
    public func setCameraEnabled(_ enabled: Bool) async throws {
        guard [.preparing, .recording, .paused].contains(state), let encoder = pipeline else { throw RecordingError.notRecording }
        let token = generation, request = UUID(); cameraRequest = request
        if enabled { try await requireAccess(to: .video, named: "摄像头") }
        try checkGeneration(token)
        guard cameraRequest == request else { return }
        let preview = try await encoder.setCameraEnabled(enabled)
        try checkGeneration(token)
        guard cameraRequest == request else { return }
        cameraSession = preview
    }

    private func requireAccess(to type: AVMediaType, named name: String) async throws {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: type) else { throw RecordingError.permission(name) }
        default: throw RecordingError.permission(name)
        }
    }

    private func checkGeneration(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func receive(_ event: RecordingEvent, generation token: UUID) {
        switch event {
        case .duration(let value): duration = value
        case .failure(let message):
            guard state != .idle, state != .finishing, state != .failed else { return }
            errorMessage = message; state = .failed
            let oldStream = stream, encoder = pipeline
            stream = nil; pipeline = nil; cameraSession = nil
            cleanupTask = Task { [weak self] in
                try? await oldStream?.stopCapture(); await encoder?.cancel()
                guard let self, self.generation == token else { return }
                self.eventTask?.cancel(); self.eventTask = nil; self.cleanupTask = nil
            }
        }
    }

    private func captureConfiguration(for target: RecordingTarget, options: RecordingOptions) async throws
        -> (SCContentFilter, SCStreamConfiguration, CGSize) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter: SCContentFilter, logicalSize: CGSize, scale: CGFloat
        var crop: CGRect?
        switch target {
        case .region(let id, let rect, let factor):
            guard let display = content.displays.first(where: { $0.displayID == id }),
                  factor.isFinite, factor > 0 else { throw RecordingError.invalidTarget }
            filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            let available = CGRect(origin: .zero, size: filter.contentRect.size)
            let clipped = rect.standardized.intersection(available)
            guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { throw RecordingError.invalidTarget }
            crop = clipped; logicalSize = clipped.size; scale = factor
        case .display(let id, let factor):
            guard let display = content.displays.first(where: { $0.displayID == id }),
                  factor.isFinite, factor > 0 else { throw RecordingError.invalidTarget }
            filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            logicalSize = filter.contentRect.size; scale = factor
        case .window(let id, let factor):
            guard let window = content.windows.first(where: { $0.windowID == id }),
                  window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier,
                  factor.isFinite, factor > 0 else { throw RecordingError.invalidTarget }
            filter = SCContentFilter(desktopIndependentWindow: window)
            logicalSize = filter.contentRect.size; scale = factor
        }
        let rawWidth = Double(logicalSize.width * scale), rawHeight = Double(logicalSize.height * scale)
        guard rawWidth.isFinite, rawHeight.isFinite, rawWidth >= 2, rawHeight >= 2,
              rawWidth <= 16_384, rawHeight <= 16_384 else { throw RecordingError.invalidTarget }
        let width = max(2, Int(rawWidth.rounded(.up)) / 2 * 2), height = max(2, Int(rawHeight.rounded(.up)) / 2 * 2)
        let configuration = SCStreamConfiguration()
        configuration.width = width; configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        configuration.queueDepth = 3; configuration.showsCursor = options.showsCursor
        configuration.pixelFormat = kCVPixelFormatType_32BGRA; configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.capturesAudio = options.systemAudio; configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000; configuration.channelCount = 2
        if let crop { configuration.sourceRect = crop }
        return (filter, configuration, CGSize(width: width, height: height))
    }
}
