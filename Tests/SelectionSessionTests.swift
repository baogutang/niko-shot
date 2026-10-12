// Verifies session teardown on synthetic screens without requesting recording permissions.
import XCTest
@testable import NikoShot

@MainActor
final class SelectionSessionTests: XCTestCase {
    func testFinishRemovesWindowsListenersAndFrozenFrames() throws {
        let context = try ImageUtilities.context(width: 20, height: 20)
        let image = try XCTUnwrap(context.makeImage())
        var session: SelectionSession? = SelectionSession()
        weak let weakSession = session
        session?.start(frames: [FrozenFrame(screen: ScreenGeometry(id: 1, frame: CGRect(x: -100, y: -100, width: 10, height: 10), scale: 2), image: image)]) { _, _ in }
        XCTAssertEqual(session?.windowCount, 1)
        XCTAssertEqual(session?.monitorCount, 1)
        session?.finish()
        XCTAssertEqual(session?.windowCount, 0)
        XCTAssertEqual(session?.monitorCount, 0)
        XCTAssertEqual(session?.frameCount, 0)
        XCTAssertEqual(session?.state, .idle)
        session = nil
        XCTAssertNil(weakSession)
    }
    func testImageEditorTearsDownItsWindowAndToolbar() throws {
        let context = try ImageUtilities.context(width: 64, height: 128)
        let image = try XCTUnwrap(context.makeImage())
        var session: SelectionSession? = SelectionSession()
        weak let weakSession = session
        session?.edit(image: image, pointSize: CGSize(width: 32, height: 64)) { _, _ in }
        XCTAssertEqual(session?.state, .annotating)
        XCTAssertEqual(session?.windowCount, 2)
        XCTAssertEqual(session?.monitorCount, 1)
        session?.finish()
        XCTAssertEqual(session?.windowCount, 0)
        XCTAssertEqual(session?.monitorCount, 0)
        session = nil
        XCTAssertNil(weakSession)
    }

    func testRecordingSelectionCancelIsReportedOnceAndLeavesNoResources() throws {
        let context = try ImageUtilities.context(width: 64, height: 64)
        let image = try XCTUnwrap(context.makeImage())
        let geometry = ScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 32, height: 32), scale: 2)
        let session = SelectionSession()
        session.start(frames: [FrozenFrame(screen: geometry, image: image)],
                      initial: CaptureContext(screen: geometry, localRect: CGRect(x: 2, y: 2, width: 20, height: 20)),
                      autoConfirm: false, confirmationTitle: "开始录制") { _, _ in XCTFail("Cancellation produced capture output") }
        var completions: [Bool] = []
        session.onFinish = { completions.append($0) }
        session.beginAnnotation(tool: .rectangle)
        XCTAssertEqual(session.state, .selected)
        session.finish(); session.finish()
        XCTAssertEqual(completions, [false])
        XCTAssertEqual(session.windowCount, 0)
        XCTAssertEqual(session.monitorCount, 0)
        XCTAssertEqual(session.frameCount, 0)
    }

    func testHistoryEditorFitsWidthAndExportsAllOriginalPixels() async throws {
        let context = try ImageUtilities.context(width: 2800, height: 1896)
        let image = try XCTUnwrap(context.makeImage())
        let session = SelectionSession()
        defer { session.finish() }
        var captured: (CGImage, CaptureContext)?
        session.edit(image: image, pointSize: CGSize(width: image.width, height: image.height)) {
            captured = ($0, $1)
        }
        session.confirm()
        let deadline = ContinuousClock.now + .seconds(5)
        while captured == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let result = try XCTUnwrap(captured)
        XCTAssertLessThanOrEqual(result.1.localRect.width, 884)
        XCTAssertEqual(result.0.width, 2800)
        XCTAssertEqual(result.0.height, 1896)
        XCTAssertEqual(result.1.localRect.width * result.1.screen.scale, 2800, accuracy: 0.001)
        XCTAssertEqual(result.1.localRect.height * result.1.screen.scale, 1896, accuracy: 0.001)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.windowCount, 0)
        XCTAssertEqual(session.monitorCount, 0)
    }

    func testCancellationWaitsForRealExportAndNeverCallsCompletion() async throws {
        let context = try ImageUtilities.context(width: 128, height: 96)
        let image = try XCTUnwrap(context.makeImage())
        let gate = SelectionImageGate()
        var session: SelectionSession? = SelectionSession(afterImageOperation: { await gate.pause() })
        weak let weakSession = session
        var outputs = 0
        session?.edit(image: image, pointSize: CGSize(width: 64, height: 48)) { _, _ in outputs += 1 }
        session?.confirm()
        await gate.waitUntilEntered()
        session?.finish()
        let finishing = Task { [weak session] in await session?.finishAndDrain() }
        await Task.yield()
        XCTAssertEqual(session?.resourceCounts["selectionTasks"], 1, "Completed rendering still awaits native work release")
        XCTAssertEqual(session?.windowCount, 0)
        XCTAssertEqual(session?.monitorCount, 0)
        await gate.release()
        await finishing.value
        XCTAssertEqual(outputs, 0)
        XCTAssertEqual(session?.resourceCounts.values.reduce(0, +), 0)
        session = nil
        XCTAssertNil(weakSession)
    }

}

private actor SelectionImageGate {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; arrival?.resume(); arrival = nil
        await withCheckedContinuation { completion = $0 }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() { completion?.resume(); completion = nil }
}
