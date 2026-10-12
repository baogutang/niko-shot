// Checks lazy creation, idempotent cancellation, native encoder teardown and protection of pre-existing files.
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
}
