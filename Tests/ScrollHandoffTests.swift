// Verifies toolbar discovery and real screenshot-to-scroll ownership transitions without ScreenCaptureKit consent.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class ScrollHandoffTests: XCTestCase {
    func testToolbarShowsLongCaptureTextAndExplainsDisabledAction() throws {
        var actions: [ToolbarAction] = []
        let hud = HUDContentView(onTool: { _ in }, onAction: { actions.append($0) }, onColor: { _ in }, onWidth: { _ in })
        defer { hud.closeAuxiliaryControls() }
        hud.frame.size = hud.configure(maximumWidth: 704)
        hud.layoutSubtreeIfNeeded()
        let buttons = allButtons(in: hud)
        let button = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "长截图" })
        XCTAssertEqual(button.title, "长截图", "The primary action must be discoverable without hovering")
        XCTAssertNotNil(button.image)
        XCTAssertGreaterThanOrEqual(button.frame.width, 44)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        for tool in AnnotationTool.allCases {
            XCTAssertNotNil(buttons.first { $0.accessibilityLabel() == tool.title })
        }
        let redo = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == ToolbarAction.redo.title })
        let selection = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == ToolbarAction.selection.title })
        let redoFrame = redo.convert(redo.bounds, to: hud)
        let selectionFrame = selection.convert(selection.bounds, to: hud)
        XCTAssertEqual(selectionFrame.minX - redoFrame.maxX, 13, accuracy: 1,
                       "The output row must not stretch groups into empty space")
        button.performClick(nil)
        XCTAssertEqual(actions, [.scroll])
        let reason = "选区高度不足 240 像素，请增大选区。"
        hud.setScrollAvailability(enabled: false, explanation: reason)
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.accessibilityHelp(), reason)
        XCTAssertTrue((button.toolTip ?? "").contains(reason))
        hud.frame.size = hud.configure(maximumWidth: 100)
        hud.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.title, "长截图")
        XCTAssertGreaterThanOrEqual(button.frame.width, 44)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
    }

    func testLiveHandoffClosesOverlaysBeforeCallbackAndRetainsMixedDisplayWindowIdentity() async throws {
        let image = try await fixture(width: 640, height: 480)
        let target = viewport()
        let selection = SelectionSession()
        defer { selection.onScrollCapture = nil; selection.finish() }
        var outputs = 0, finishes: [Bool] = [], received: [CaptureContext?] = []
        selection.onScrollCapture = { context in
            XCTAssertEqual(selection.state, .idle)
            XCTAssertEqual(selection.windowCount, 0)
            XCTAssertEqual(selection.monitorCount, 0)
            XCTAssertEqual(selection.frameCount, 0)
            received.append(context)
        }
        selection.start(frames: [FrozenFrame(screen: target.screen, image: image)], kind: "window",
                        initial: target, autoConfirm: false) { _, _ in outputs += 1 }
        selection.onFinish = { finishes.append($0) }
        selection.requestScrollCapture()
        selection.requestScrollCapture()
        await selection.drainPendingOperations()
        let delivered = try XCTUnwrap(received.first.flatMap { $0 })
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(finishes, [true])
        XCTAssertEqual(outputs, 0, "Scrolling must not render or export the annotated frozen screenshot")
        assertViewport(delivered, equals: target)
        XCTAssertEqual(selection.resourceCounts.values.reduce(0, +), 0)
    }

    func testAnnotationSelectionRoundTripRetainsWindowIdentityAfterKeyboardNudge() async throws {
        let image = try await fixture(width: 640, height: 480)
        let target = viewport()
        let candidate = WindowCandidate(id: 42, frame: target.globalRect, title: "Fixture window", appBundleID: target.appBundleID)
        let selection = SelectionSession()
        defer { selection.onScrollCapture = nil; selection.finish() }
        var received: CaptureContext?
        selection.onScrollCapture = { received = $0 }
        selection.start(frames: [FrozenFrame(screen: target.screen, image: image)], candidates: [candidate],
                        kind: "window", initial: target, autoConfirm: false) { _, _ in XCTFail("Scroll exported an image") }
        selection.beginAnnotation(tool: .rectangle)
        try await waitUntil {
            selection.windows.contains { window in window.contentView?.subviews.contains { $0 is AnnotationCanvasView } == true }
        }
        let canvas = try XCTUnwrap(selection.windows.flatMap { $0.contentView?.subviews ?? [] }.compactMap { $0 as? AnnotationCanvasView }.first)
        try key("\t", code: 48, to: canvas)
        try await waitUntil { selection.state == .selected }
        let selector = try XCTUnwrap(selection.windows.compactMap { $0.contentView as? SelectionView }.first)
        try key("", code: 124, to: selector)
        selection.requestScrollCapture()
        await selection.drainPendingOperations()
        let delivered = try XCTUnwrap(received)
        XCTAssertEqual(delivered.windowID, 42)
        XCTAssertEqual(delivered.appBundleID, target.appBundleID)
        XCTAssertEqual(delivered.screen.id, target.screen.id)
        XCTAssertEqual(delivered.localRect.minX, target.localRect.minX + 0.5)
        XCTAssertEqual(delivered.localRect.size, target.localRect.size)
        XCTAssertEqual(selection.resourceCounts.values.reduce(0, +), 0)
    }

    func testImportedImageRequestsReselectionInsteadOfInventingScreenCoordinates() async throws {
        let image = try await fixture(width: 640, height: 480)
        let selection = SelectionSession()
        defer { selection.onScrollCapture = nil; selection.finish() }
        var received: [CaptureContext?] = []
        selection.onScrollCapture = { received.append($0) }
        selection.edit(image: image, pointSize: CGSize(width: 320, height: 240)) { _, _ in XCTFail("Scroll exported imported pixels") }
        selection.requestScrollCapture()
        await selection.drainPendingOperations()
        XCTAssertEqual(received.count, 1)
        XCTAssertNil(received[0])
        XCTAssertEqual(selection.windowCount, 0)
        XCTAssertEqual(selection.monitorCount, 0)
        XCTAssertEqual(selection.resourceCounts.values.reduce(0, +), 0)
    }

    func testLivePreviewWaitsForCancelledArchiveWorkerAndReusesViewportWithoutReselection() async throws {
        let image = try await fixture(width: 640, height: 480)
        let fresh = try await fixture(width: 400, height: 300)
        let target = viewport(), gate = ScrollHandoffGate()
        let selection = SelectionSession(afterImageOperation: { await gate.pause() })
        var previews: [CaptureContext] = []
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in XCTFail("Showing setup must not produce capture output") }, capturePreview: { context in
                XCTAssertEqual(selection.windowCount, 0)
                XCTAssertEqual(selection.monitorCount, 0)
                XCTAssertEqual(selection.resourceCounts.values.reduce(0, +), 0)
                previews.append(context)
                return fresh
            })
        selection.onScrollCapture = { [weak coordinator] in coordinator?.continueFromSelection(context: $0) }
        defer { selection.onScrollCapture = nil; selection.finish() }
        selection.start(frames: [FrozenFrame(screen: target.screen, image: image)], initial: target, autoConfirm: false) { _, _ in XCTFail("Scroll exported frozen pixels") }
        selection.beginAnnotation(tool: .arrow)
        await gate.waitUntilEntered()
        selection.requestScrollCapture()
        await Task.yield()
        XCTAssertTrue(coordinator.isBusy)
        XCTAssertEqual(coordinator.resourceCounts["operation"], 1)
        XCTAssertTrue(previews.isEmpty, "The live request must await the old archive/render worker")
        await gate.release()
        try await waitUntil { coordinator.resourceCounts["setup"] == 1 }
        XCTAssertEqual(previews.count, 1)
        assertViewport(try XCTUnwrap(previews.first), equals: target)
        assertViewport(try XCTUnwrap(coordinator.selectedViewport), equals: target)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
        XCTAssertEqual(selection.resourceCounts.values.reduce(0, +), 0)
    }

    func testCancellingHandoffBeforeArchiveDrainNeverStartsLiveCaptureOrLateSetup() async throws {
        let image = try await fixture(width: 640, height: 480)
        let target = viewport(), gate = ScrollHandoffGate()
        let selection = SelectionSession(afterImageOperation: { await gate.pause() })
        var previews = 0
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in XCTFail("Cancelled handoff produced output") }, capturePreview: { _ in
                previews += 1; return image
            })
        selection.onScrollCapture = { [weak coordinator] in coordinator?.continueFromSelection(context: $0) }
        defer { selection.onScrollCapture = nil; selection.finish() }
        selection.start(frames: [FrozenFrame(screen: target.screen, image: image)], initial: target, autoConfirm: false) { _, _ in XCTFail("Scroll exported frozen pixels") }
        selection.beginAnnotation(tool: .arrow)
        await gate.waitUntilEntered()
        selection.requestScrollCapture()
        let cancellation = Task { await coordinator.cancel() }
        try await waitUntil { coordinator.resourceCounts["cleanup"] == 1 }
        XCTAssertEqual(previews, 0)
        await gate.release()
        await cancellation.value
        XCTAssertEqual(previews, 0)
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
        XCTAssertEqual(selection.resourceCounts.values.reduce(0, +), 0)
        XCTAssertEqual(selection.windowCount, 0)
    }

    func testReselectionPromptCancellationReleasesNativeAlertWithoutScreenCapture() async throws {
        let selection = SelectionSession()
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
                                            onCapture: { _, _ in XCTFail("Cancelled reselection produced output") })
        coordinator.continueFromSelection(context: nil)
        XCTAssertEqual(coordinator.resourceCounts["reselectionAlert"], 1)
        XCTAssertEqual(coordinator.resourceCounts["reselectionActions"], 1)
        XCTAssertNil(NSApp.modalWindow, "Reselection must return to the main run loop for async cancellation")
        let cancellation = Task { await coordinator.cancel() }
        await cancellation.value
        await coordinator.cancel()
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
        XCTAssertEqual(selection.windowCount, 0)
    }

    private func viewport() -> CaptureContext {
        CaptureContext(screen: ScreenGeometry(id: 99, frame: CGRect(x: -400, y: 600, width: 320, height: 240), scale: 2),
                       localRect: CGRect(x: 20, y: 30, width: 200, height: 150), kind: "window", appBundleID: "com.example.fixture", windowID: 42)
    }

    private func assertViewport(_ actual: CaptureContext, equals expected: CaptureContext) {
        XCTAssertEqual(actual.screen.id, expected.screen.id)
        XCTAssertEqual(actual.screen.frame, expected.screen.frame)
        XCTAssertEqual(actual.screen.scale, expected.screen.scale)
        XCTAssertEqual(actual.localRect, expected.localRect)
        XCTAssertEqual(actual.globalRect, expected.globalRect)
        XCTAssertEqual(actual.windowID, expected.windowID)
        XCTAssertEqual(actual.appBundleID, expected.appBundleID)
        XCTAssertTrue(actual.hasLiveScreenRegion)
    }

    private func allButtons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { allButtons(in: $0) }
    }

    private func fixture(width: Int, height: Int) async throws -> CGImage {
        try await Task.detached {
            let context = try ImageUtilities.context(width: width, height: height)
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else { throw AppError.imageCreation }
            return image
        }.value
    }

    private func key(_ characters: String, code: UInt16, to view: NSView) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        view.keyDown(with: event)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Native transition did not finish within the fixture deadline")
    }
}

private actor ScrollHandoffGate {
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
