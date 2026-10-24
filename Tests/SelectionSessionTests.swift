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

/// The 0.5.2 lag came from relayout work on every drag event; these pin the cheap path.
@MainActor
final class SelectionDragTests: XCTestCase {
    private func makeSession() throws -> (SelectionSession, SelectionView, NSWindow) {
        let context = try ImageUtilities.context(width: 800, height: 600)
        let image = try XCTUnwrap(context.makeImage())
        let session = SelectionSession()
        let screen = ScreenGeometry(id: 7, frame: CGRect(x: -6000, y: -6000, width: 400, height: 300), scale: 2)
        session.start(frames: [FrozenFrame(screen: screen, image: image)]) { _, _ in }
        let window = try XCTUnwrap(session.windows.first)
        return (session, try XCTUnwrap(window.contentView as? SelectionView), window)
    }

    private func event(_ type: NSEvent.EventType, _ point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testToolbarStaysHiddenWhileDraggingAndAppearsOnMouseUp() throws {
        let (session, view, window) = try makeSession()
        defer { session.finish() }
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 40, y: 40), in: window))
        for step in 1...12 {
            view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 40 + step * 15, y: 40 + step * 10), in: window))
            XCTAssertTrue(view.isTrackingMouse)
            XCTAssertFalse(session.isToolbarVisible, "No toolbar layout while the selection is still moving")
            XCTAssertEqual(session.state, .selected)
        }
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 220, y: 160), in: window))
        XCTAssertFalse(view.isTrackingMouse)
        XCTAssertTrue(session.isToolbarVisible)
    }

    func testDimStripsTileTheScreenAroundTheSelection() throws {
        let (session, view, _) = try makeSession()
        defer { session.finish() }
        view.selection = CGRect(x: 50, y: 60, width: 120, height: 80)
        let selection = view.visibleSelection
        let strips = view.dimLayers.map(\.frame).filter { !$0.isEmpty }
        XCTAssertEqual(strips.count, 4)
        let area = strips.reduce(0) { $0 + $1.width * $1.height } + selection.width * selection.height
        XCTAssertEqual(area, view.bounds.width * view.bounds.height, accuracy: 0.5)
        for strip in strips { XCTAssertFalse(strip.intersects(selection.insetBy(dx: 0.5, dy: 0.5))) }
    }
}
