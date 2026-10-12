// Exercises native hardware MP4/AAC encoding, AVAssetReader GIF export, shared palettes and cancellation safety.
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import VideoToolbox
import XCTest
import os
@testable import NikoShot

@MainActor
final class GifExporterTests: XCTestCase {
    func testDifferentColoredFramesHaveOne256ColorGlobalPaletteAndPTSDelays() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = try await RecordingMediaFixture().images(count: 3)
        let destination = directory.appendingPathComponent("colors.gif")
        try await GifExporter().exportFrames(images: images, timestamps: [0, 0.13, 0.28], destination: destination,
                                             options: GifOptions(width: 16, fps: 15))
        let result = try await RecordingMediaFixture().inspect(destination)
        XCTAssertEqual(result.frames, 3); XCTAssertEqual(result.globalColors, 256)
        XCTAssertEqual(result.localColors, [0, 0, 0], "Frames must share one global palette")
        XCTAssertEqual(result.loopCount, 0); XCTAssertEqual(result.width, 16); XCTAssertEqual(result.height, 16)
        XCTAssertEqual(result.delays[0], 0.13, accuracy: 0.001)
        XCTAssertEqual(result.delays[1], 0.15, accuracy: 0.001)
        XCTAssertGreaterThan(result.firstRed, 240); XCTAssertLessThan(result.lastRed, 10)
    }

    func testCentisecondRoundingKeepsThirtyFPSTotalDuration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = try await RecordingMediaFixture().images(count: 30)
        let destination = directory.appendingPathComponent("clock.gif")
        try await GifExporter().exportFrames(images: images, timestamps: (0..<30).map { Double($0) / 30 },
                                             destination: destination, options: GifOptions(width: 16, fps: 30))
        let result = try await RecordingMediaFixture().inspect(destination)
        XCTAssertEqual(result.frames, 30)
        XCTAssertEqual(result.delays.reduce(0, +), 1, accuracy: 0.001)
        XCTAssertTrue(result.delays.contains(0.04)); XCTAssertTrue(result.delays.contains(0.03))
    }

    func testRealHEVCAndMixedAACVideoExportsThroughAssetReader() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = RecordingMediaFixture()
        let video = directory.appendingPathComponent("native.mp4")
        try await fixture.writeVideo(to: video)
        let sound = try await fixture.inspectMixedAudio(video)
        XCTAssertEqual(sound.trackCount, 1)
        XCTAssertGreaterThan(sound.systemAmplitude, 0.1, "440 Hz system tone must survive the single AAC track")
        XCTAssertGreaterThan(sound.microphoneAmplitude, 0.1, "880 Hz microphone tone must survive the same AAC track")
        let destination = directory.appendingPathComponent("native.gif")
        try await GifExporter.export(video: video, destination: destination, options: GifOptions(width: 160, fps: 15))
        let result = try await fixture.inspect(destination)
        XCTAssertEqual(result.frames, 15); XCTAssertEqual(result.width, 160); XCTAssertEqual(result.height, 90)
        XCTAssertEqual(result.globalColors, 256); XCTAssertTrue(result.localColors.allSatisfy { $0 == 0 })
        XCTAssertEqual(result.loopCount, 0)
        XCTAssertEqual(result.delays.reduce(0, +), 1, accuracy: 0.02)
        XCTAssertGreaterThan(result.lastRed, result.firstRed + 100)
    }

    func testCancellationDuringDecodePreservesExistingDestinationAndRemovesStages() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("native.mp4")
        try await RecordingMediaFixture().writeVideo(to: video)
        let destination = directory.appendingPathComponent("existing.gif")
        let original = Data("previous user file".utf8); try original.write(to: destination)
        let originalNames = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        let holder = OSAllocatedUnfairLock<Task<Void, any Error>?>(initialState: nil)
        let task = Task {
            try await GifExporter.export(video: video, destination: destination, options: GifOptions(width: 160, fps: 15)) { progress in
                if progress > 0.3 { holder.withLock { $0?.cancel() } }
            }
        }
        holder.withLock { $0 = task }
        do { try await task.value; XCTFail("The active export must observe cancellation") }
        catch is CancellationError {} catch { throw error }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), originalNames)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niko-media-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct GIFInspection: Sendable {
    let frames: Int, width: Int, height: Int, globalColors: Int, loopCount: Int
    let localColors: [Int], delays: [Double]
    let firstRed: Int, lastRed: Int
}

private struct AudioInspection: Sendable { let trackCount: Int; let systemAmplitude: Double; let microphoneAmplitude: Double }

/// All fixture rasterization, media buffers and native decoding remain on this worker executor.
private actor RecordingMediaFixture {
    func images(count: Int) throws -> [CGImage] {
        guard let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw GifExportError.image
        }
        return try (0..<count).map { index in
            let color: CGColor
            switch index % 3 {
            case 0: color = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
            case 1: color = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
            default: color = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
            }
            context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            guard let image = context.makeImage() else { throw GifExportError.image }; return image
        }
    }

    func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 600_000, AVVideoAllowFrameReorderingKey: false],
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        guard writer.canAdd(video), writer.canAdd(audio) else { throw GifExportError.video("Fixture encoding unavailable") }
        writer.add(video); writer.add(audio)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.startWriting() else { throw GifExportError.video(writer.error?.localizedDescription ?? "Fixture start failed") }
        writer.startSession(atSourceTime: .zero)
        let router = try AudioRouter(systemAudio: true, microphone: true)
        for index in 0..<30 {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard let pool = adaptor.pixelBufferPool else { throw GifExportError.image }
            var created: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created) == kCVReturnSuccess,
                  let buffer = created else { throw GifExportError.image }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 180,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
                CVPixelBufferUnlockBaseAddress(buffer, []); throw GifExportError.image
            }
            let fraction = CGFloat(index) / 29
            context.setFillColor(CGColor(red: fraction, green: 0.2, blue: 1 - fraction, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw GifExportError.video(writer.error?.localizedDescription ?? "Fixture video append failed")
            }
            for (source, frequency) in [(RecordingAudioSource.system, 440.0), (.microphone, 880.0)] {
                var samples = [Float](repeating: 0, count: 3_200)
                for frame in 0..<1_600 {
                    let value = Float(sin(Double(index * 1_600 + frame) * frequency * 2 * .pi / 48_000) * 0.2)
                    samples[frame * 2] = value; samples[frame * 2 + 1] = value
                }
                try router.append(RecordingPCMFrame(sourceTime: Double(index) / 30, sampleRate: 48_000, channels: 2, samples: samples),
                                  at: Double(index) / 30, source: source)
            }
            try await drainAudio(router, input: audio, until: router.readyThroughFrame, writer: writer)
        }
        try await drainAudio(router, input: audio, until: 48_000, writer: writer)
        video.markAsFinished(); audio.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw GifExportError.video(writer.error?.localizedDescription ?? "Fixture finish failed") }
    }

    private func drainAudio(_ router: AudioRouter, input: AVAssetWriterInput, until frame: Int, writer: AVAssetWriter) async throws {
        while router.mixer.nextFrame < frame {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw GifExportError.video(writer.error?.localizedDescription ?? "Fixture audio stalled") }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard let block = router.consume(until: frame) else { break }
            guard input.append(try router.sampleBuffer(for: block)) else { throw GifExportError.video(writer.error?.localizedDescription ?? "Fixture audio append failed") }
        }
    }

    func inspectMixedAudio(_ url: URL) async throws -> AudioInspection {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw GifExportError.video("Fixture has no mixed track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw GifExportError.video("Fixture audio decoder failed") }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            if let frame = AudioRouter.copySystemPCM(buffer) { samples.append(contentsOf: frame.samples) }
        }
        let count = min(48_000, samples.count / 2)
        guard count > 0 else { throw GifExportError.video("Fixture mixed track is empty") }
        func amplitude(_ frequency: Double) -> Double {
            var sine = 0.0, cosine = 0.0
            for frame in 0..<count {
                let angle = Double(frame) * frequency * 2 * .pi / 48_000, value = Double(samples[frame * 2])
                sine += value * sin(angle); cosine += value * cos(angle)
            }
            return hypot(sine, cosine) * 2 / Double(count)
        }
        return AudioInspection(trackCount: tracks.count, systemAmplitude: amplitude(440), microphoneAmplitude: amplitude(880))
    }

    func inspect(_ url: URL) throws -> GIFInspection {
        let data = try Data(contentsOf: url)
        guard data.count >= 13, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw GifExportError.image }
        let colors = data[10] & 0x80 != 0 ? 1 << (Int(data[10] & 7) + 1) : 0
        var position = 13 + colors * 3, localColors: [Int] = []
        while position < data.count {
            switch data[position] {
            case 0x3b: position = data.count; continue
            case 0x21: position += 2
            case 0x2c:
                guard position + 10 <= data.count else { throw GifExportError.image }
                let packed = data[position + 9], count = packed & 0x80 != 0 ? 1 << (Int(packed & 7) + 1) : 0
                localColors.append(count); position += 10 + count * 3 + 1
            default: throw GifExportError.image
            }
            while position < data.count {
                let count = Int(data[position]); position += 1
                if count == 0 { break }; position += count
            }
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let first = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let last = CGImageSourceCreateImageAtIndex(source, count - 1, nil) else { throw GifExportError.image }
        let properties = CGImageSourceCopyProperties(source, nil) as? [String: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        let delays = (0..<count).map { index -> Double in
            let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
            let dictionary = frame?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            return (dictionary?[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue ?? 0
        }
        return GIFInspection(frames: count, width: first.width, height: first.height, globalColors: colors,
            loopCount: (gif?[kCGImagePropertyGIFLoopCount as String] as? NSNumber)?.intValue ?? -1,
            localColors: localColors, delays: delays, firstRed: try red(first), lastRed: try red(last))
    }

    private func red(_ image: CGImage) throws -> Int {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw GifExportError.image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return Int(bytes[0])
    }
}
