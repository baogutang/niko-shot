// Checks lazy creation, idempotent cancellation, native encoder teardown and protection of pre-existing files.
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import NikoShot

@MainActor
final class RecordingLifecycleTests: XCTestCase {
    func testIdleSessionAndRepeatedCancelHaveNoResources() async {
        let session = RecordingSession()
        XCTAssertEqual(session.resourceCounts.values.reduce(0, +), 0)
        await session.cancel(); await session.cancel()
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.resourceCounts.values.reduce(0, +), 0)
        XCTAssertNil(session.cameraSession)
    }

    func testConfiguredNativeWriterCancelRemovesOnlyItsPartialFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("niko-recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("partial.mp4")
        let (_, events) = AsyncStream<RecordingEvent>.makeStream()
        let pipeline = RecordingPipeline(options: RecordingOptions(systemAudio: false), width: 320, height: 180, output: output, events: events)
        try await pipeline.configure()
        await pipeline.cancel(); await pipeline.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let counts = await pipeline.resourceCounts()
        XCTAssertEqual(counts.values.reduce(0, +), 0)
        let original = Data("existing file".utf8)
        try original.write(to: output)
        let (_, secondEvents) = AsyncStream<RecordingEvent>.makeStream()
        let second = RecordingPipeline(options: RecordingOptions(systemAudio: false), width: 320, height: 180, output: output, events: secondEvents)
        do { try await second.configure(); XCTFail("A pre-existing recording must be protected") } catch {}
        await second.cancel()
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testCaptureStopKeepsAHealthyWriterAndFinishesAtTheStopFrame() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("niko-recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("interrupted.mp4")
        let (events, continuation) = AsyncStream<RecordingEvent>.makeStream()
        let pipeline = RecordingPipeline(options: RecordingOptions(systemAudio: false), width: 320, height: 180, output: output, events: continuation)
        try await pipeline.configure()
        // ScreenCaptureKit stamps frames on the host clock; mirror that so the stop time maps onto the same timeline.
        let start = RecordingPipeline.hostTime - 0.5
        for index in 0..<15 {
            let sample = try screenSample(at: start + Double(index) / 30)
            pipeline.queue.sync { pipeline.receive(sample, of: .screen) }
        }
        pipeline.captureStopped("The user stopped the stream.")
        var interruption: String?
        for await event in events {
            if case .interrupted(let message) = event { interruption = message; break }
            if case .failure(let message) = event { XCTFail("A healthy writer must not fail: \(message)"); break }
        }
        XCTAssertEqual(interruption, "The user stopped the stream.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "Menu-bar Stop must not delete the recording")
        // A late Stop must not stretch the last frame past the moment capture actually ended.
        let result = try await pipeline.finish(at: RecordingPipeline.hostTime + 5)
        XCTAssertEqual(result.url, output)
        XCTAssertGreaterThan(result.duration, 0.45); XCTAssertLessThan(result.duration, 2)
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video), length = try await asset.load(.duration).seconds
        XCTAssertEqual(tracks.count, 1); XCTAssertEqual(length, result.duration, accuracy: 0.1)
        let counts = await pipeline.resourceCounts()
        XCTAssertEqual(counts.values.reduce(0, +), 0)
    }

    private func screenSample(at seconds: Double) throws -> CMSampleBuffer {
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created) == kCVReturnSuccess,
              let pixels = created else { throw RecordingError.empty }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) { memset(base, 0x80, CVPixelBufferGetDataSize(pixels)) }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                           formatDescriptionOut: &format) == noErr, let format else { throw RecordingError.empty }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { throw RecordingError.empty }
        return sample
    }
}
