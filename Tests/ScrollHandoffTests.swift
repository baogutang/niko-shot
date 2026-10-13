// Verifies toolbar discovery and real screenshot-to-scroll ownership transitions without ScreenCaptureKit consent.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class ScrollHandoffTests: XCTestCase {
    func testMouseDragShowsEveryToolbarControlAndRoutesOCROutput() async throws {
        let image = try await fixture(width: 640, height: 480)
        let screen = ScreenGeometry(id: 61, frame: CGRect(x: 80, y: 80, width: 640, height: 480), scale: 1)
        let suite = "niko-shot.toolbar-ocr-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.automaticTranslation = false
        let textController = ScreenshotTextController(settings: settings, recognition: { image, _, _ in
            XCTAssertEqual(image.width, 340)
            XCTAssertEqual(image.height, 280)
            return [OCRBlock(text: "OCR toolbar result", boundingBox: .zero, confidence: 1)]
        })
        let selection = SelectionSession(makeTextController: { textController })
        defer { selection.finish() }
        var captured: (CGImage, CaptureContext)?
        var recognizedText: String?
        selection.onRecognizedText = { recognizedText = $0 }
        selection.start(frames: [FrozenFrame(screen: screen, image: image)]) { captured = ($0, $1) }
        XCTAssertEqual(selection.state, .selecting)
        let view = try XCTUnwrap(selection.windows.first?.contentView as? SelectionView)
        try mouse(.leftMouseDown, point: CGPoint(x: 60, y: 50), to: view)
        try mouse(.leftMouseDragged, point: CGPoint(x: 300, y: 200), to: view)
        try mouse(.leftMouseDragged, point: CGPoint(x: 400, y: 330), to: view)
        try mouse(.leftMouseUp, point: CGPoint(x: 400, y: 330), to: view)
        XCTAssertEqual(selection.state, .selected)
        XCTAssertEqual(selection.windowCount, 2)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "截图标注工具条" })
        let hud = try XCTUnwrap(panel.contentView as? HUDContentView)
        hud.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(panel.level.rawValue, try XCTUnwrap(view.window).level.rawValue)
        XCTAssertFalse(panel.canBecomeKey, "Pointer use must keep the selection's keyboard responder")
        try await waitUntil { panel.alphaValue >= 0.95 }
        let compactButtons = allButtons(in: hud)
        XCTAssertFalse(hud.isAnnotationExpanded)
        XCTAssertEqual(compactButtons.count, 18, "Selection must begin with directly available common tools")
        XCTAssertEqual(compactButtons.filter { $0.accessibilityLabel() == ToolbarAction.copy.title }.count, 1)
        XCTAssertFalse(compactButtons.contains { $0.accessibilityLabel() == "复制" })
        for tool in [AnnotationTool.rectangle, .ellipse, .arrow, .pen, .text, .mosaic] {
            XCTAssertTrue(compactButtons.contains { $0.accessibilityLabel() == tool.title })
        }
        XCTAssertFalse(compactButtons.contains { $0.accessibilityLabel() == AnnotationTool.blur.title })
        let completion = try XCTUnwrap(compactButtons.first { $0.accessibilityLabel() == ToolbarAction.copy.title })
        let cancel = try XCTUnwrap(compactButtons.first { $0.accessibilityLabel() == ToolbarAction.close.title })
        XCTAssertGreaterThan(completion.convert(completion.bounds, to: hud).minX,
                             cancel.convert(cancel.bounds, to: hud).minX)
        try XCTUnwrap(compactButtons.first { $0.accessibilityLabel() == "更多标注工具" }).performClick(nil)
        XCTAssertTrue(hud.isAnnotationExpanded)
        hud.layoutSubtreeIfNeeded()
        let buttons = allButtons(in: hud)
        for title in AnnotationTool.allCases.map(\.title) + ToolbarAction.allCases.map(\.title) {
            let button = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == title }, title)
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor, title)
            let frame = button.convert(button.bounds, to: hud)
            XCTAssertGreaterThanOrEqual(frame.width, 32, title)
            XCTAssertGreaterThanOrEqual(frame.height, 32, title)
            XCTAssertTrue(hud.bounds.contains(frame), "\(title) must be fully inside the visible panel: \(frame)")
        }
        let ocr = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == ToolbarAction.ocr.title })
        XCTAssertTrue(ocr.isEnabled)
        ocr.performClick(nil)
        try await waitUntil { recognizedText != nil }
        XCTAssertEqual(recognizedText, "OCR toolbar result")
        XCTAssertEqual(selection.state, .selected, "OCR must remain below the screenshot without exporting it")
        XCTAssertNil(captured)
        XCTAssertTrue(panel.canBecomeKey)
        completion.performClick(nil)
        try await waitUntil { captured != nil }
        let result = try XCTUnwrap(captured)
        XCTAssertEqual(selection.outputAction, .copy)
        XCTAssertEqual(result.0.width, 340)
        XCTAssertEqual(result.0.height, 280)
        XCTAssertEqual(result.1.localRect, CGRect(x: 60, y: 50, width: 340, height: 280))
        await selection.drainPendingOperations()
        XCTAssertEqual(selection.windowCount, 0)
        XCTAssertEqual(selection.monitorCount, 0)
        XCTAssertEqual(selection.resourceCounts.values.reduce(0, +), 0)
    }

    func testMouseSelectedToolbarStartsAnnotationThenHandsOriginalViewportToScroll() async throws {
        let image = try await fixture(width: 1280, height: 960)
        let screen = ScreenGeometry(id: 62, frame: CGRect(x: 80, y: 80, width: 640, height: 480), scale: 2)
        let candidate = WindowCandidate(id: 42, frame: screen.frame, title: "Fixture window", appBundleID: "com.example.fixture")
        let selection = SelectionSession()
        defer { selection.onScrollCapture = nil; selection.finish() }
        var captured: CaptureContext?
        selection.onScrollCapture = { captured = $0 }
        selection.start(frames: [FrozenFrame(screen: screen, image: image)], candidates: [candidate]) { _, _ in
            XCTFail("Scroll must not export annotated frozen pixels")
        }
        let view = try XCTUnwrap(selection.windows.first?.contentView as? SelectionView)
        try mouse(.leftMouseDown, point: CGPoint(x: 60, y: 50), to: view)
        try mouse(.leftMouseDragged, point: CGPoint(x: 400, y: 330), to: view)
        try mouse(.leftMouseUp, point: CGPoint(x: 400, y: 330), to: view)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "截图标注工具条" })
        let hud = try XCTUnwrap(panel.contentView as? HUDContentView)
        XCTAssertFalse(hud.isAnnotationExpanded)
        let rectangle = try XCTUnwrap(allButtons(in: hud).first { $0.accessibilityLabel() == AnnotationTool.rectangle.title })
        rectangle.performClick(nil)
        XCTAssertFalse(hud.isAnnotationExpanded, "A directly available tool must not expand the advanced row")
        try await waitUntil {
            selection.windows.contains { $0.contentView?.subviews.contains { $0 is AnnotationCanvasView } == true }
        }
        let canvas = try XCTUnwrap(selection.windows.flatMap { $0.contentView?.subviews ?? [] }.compactMap { $0 as? AnnotationCanvasView }.first)
        try key(" ", code: 49, to: canvas)
        try key("", code: 124, to: canvas)
        try key("", code: 125, to: canvas)
        try key(" ", code: 49, to: canvas)
        XCTAssertEqual(canvas.document.commands.count, 1)
        let scroll = try XCTUnwrap(allButtons(in: hud).first { $0.accessibilityLabel() == ToolbarAction.scroll.title })
        XCTAssertTrue(scroll.isEnabled)
        scroll.performClick(nil)
        let result = try XCTUnwrap(captured)
        XCTAssertEqual(result.screen, screen)
        XCTAssertEqual(result.localRect, CGRect(x: 60, y: 50, width: 340, height: 280))
        XCTAssertEqual(result.windowID, candidate.id)
        XCTAssertEqual(result.appBundleID, candidate.appBundleID)
        await selection.drainPendingOperations()
        XCTAssertEqual(selection.state, .idle)
        XCTAssertEqual(selection.windowCount, 0)
        XCTAssertEqual(selection.resourceCounts.values.reduce(0, +), 0)
    }

    func testToolbarShowsLongCaptureTextAndExplainsDisabledAction() throws {
        var actions: [ToolbarAction] = []
        let hud = HUDContentView(onTool: { _ in }, onAction: { actions.append($0) }, onColor: { _ in }, onWidth: { _ in })
        defer { hud.closeAuxiliaryControls() }
        hud.frame.size = hud.configure(maximumWidth: 704)
        hud.layoutSubtreeIfNeeded()
        let compactButtons = allButtons(in: hud)
        XCTAssertEqual(compactButtons.count, 18)
        let button = try XCTUnwrap(compactButtons.first { $0.accessibilityLabel() == "长截图" })
        XCTAssertEqual(button.title, "长截图", "The primary action must be discoverable without hovering")
        XCTAssertNotNil(button.image)
        XCTAssertGreaterThanOrEqual(button.frame.width, 32)
        XCTAssertGreaterThanOrEqual(button.frame.height, 32)
        try XCTUnwrap(compactButtons.first { $0.accessibilityLabel() == "更多标注工具" }).performClick(nil)
        hud.frame.size = hud.configure(maximumWidth: 704)
        hud.layoutSubtreeIfNeeded()
        let buttons = allButtons(in: hud)
        for tool in AnnotationTool.allCases {
            XCTAssertNotNil(buttons.first { $0.accessibilityLabel() == tool.title })
        }
        let width = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "标注线宽：3 pt" })
        let undo = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == ToolbarAction.undo.title })
        let widthFrame = width.convert(width.bounds, to: hud)
        let undoFrame = undo.convert(undo.bounds, to: hud)
        XCTAssertEqual(undoFrame.minX - widthFrame.maxX, 9, accuracy: 1,
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
        XCTAssertGreaterThanOrEqual(button.frame.width, 32)
        XCTAssertGreaterThanOrEqual(button.frame.height, 32)
    }

    func testDirectRectanglePenAndArrowDrawAndReturnCopiesAnnotatedPixels() async throws {
        let image = try await fixture(width: 640, height: 480)
        let screen = ScreenGeometry(id: 64, frame: CGRect(x: 80, y: 80, width: 640, height: 480), scale: 1)
        let target = CaptureContext(screen: screen, localRect: CGRect(x: 60, y: 50, width: 340, height: 280),
                                    kind: "region", appBundleID: "com.example.fixture")
        let selection = SelectionSession()
        defer { selection.finish() }
        var output: CGImage?
        selection.start(frames: [FrozenFrame(screen: screen, image: image)], initial: target,
                        autoConfirm: false) { output = $0; _ = $1 }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "截图标注工具条" })
        let hud = try XCTUnwrap(panel.contentView as? HUDContentView)
        var canvas: AnnotationCanvasView?
        for tool in [AnnotationTool.rectangle, .pen, .arrow] {
            try XCTUnwrap(allButtons(in: hud).first { $0.accessibilityLabel() == tool.title }).performClick(nil)
            try await waitUntil {
                selection.windows.contains { $0.contentView?.subviews.contains { $0 is AnnotationCanvasView } == true }
            }
            canvas = selection.windows.flatMap { $0.contentView?.subviews ?? [] }.compactMap { $0 as? AnnotationCanvasView }.first
            let editor = try XCTUnwrap(canvas)
            try mouse(.leftMouseDown, point: CGPoint(x: 30, y: 40), to: editor)
            try mouse(.leftMouseDragged, point: CGPoint(x: 150, y: 130), to: editor)
            try mouse(.leftMouseUp, point: CGPoint(x: 210, y: 160), to: editor)
            XCTAssertEqual(editor.document.commands.last?.tool, tool)
            XCTAssertFalse(hud.isAnnotationExpanded)
        }
        let editor = try XCTUnwrap(canvas)
        XCTAssertEqual(editor.document.commands.count, 3)
        try XCTUnwrap(allButtons(in: hud).first { $0.accessibilityLabel() == ToolbarAction.undo.title }).performClick(nil)
        XCTAssertEqual(editor.document.commands.count, 2)
        try XCTUnwrap(allButtons(in: hud).first { $0.accessibilityLabel() == ToolbarAction.redo.title }).performClick(nil)
        XCTAssertEqual(editor.document.commands.count, 3)
        try key("\r", code: 36, to: editor)
        try await waitUntil { output != nil }
        let rendered = try XCTUnwrap(output)
        XCTAssertEqual(selection.outputAction, .copy)
        XCTAssertEqual(rendered.width, 340)
        XCTAssertEqual(rendered.height, 280)
        let original = try XCTUnwrap(image.cropping(to: target.localRect))
        let changedPixels = try await Task.detached {
            let first = try ImageUtilities.context(width: 340, height: 280)
            let second = try ImageUtilities.context(width: 340, height: 280)
            let bounds = CGRect(x: 0, y: 0, width: 340, height: 280)
            first.draw(original, in: bounds); second.draw(rendered, in: bounds)
            guard let before = first.data, let after = second.data else { throw AppError.imageCreation }
            return memcmp(before, after, first.bytesPerRow * first.height) != 0
        }.value
        XCTAssertTrue(changedPixels, "Native mouse drawing must change the copied image, not only tool selection state")
        await selection.drainPendingOperations()
        XCTAssertEqual(selection.resourceCounts.values.reduce(0, +), 0)
    }

    func testDefaultCompletionButtonAndReturnBothCopySelectedPixels() async throws {
        let image = try await fixture(width: 640, height: 480)
        let screen = ScreenGeometry(id: 63, frame: CGRect(x: 80, y: 80, width: 640, height: 480), scale: 1)
        let target = CaptureContext(screen: screen, localRect: CGRect(x: 60, y: 50, width: 340, height: 280),
                                    kind: "region", appBundleID: "com.example.fixture")
        for keyboard in [false, true] {
            let selection = SelectionSession()
            defer { selection.finish() }
            var captured: (CGImage, CaptureContext)?
            selection.start(frames: [FrozenFrame(screen: screen, image: image)], initial: target,
                            autoConfirm: false) { captured = ($0, $1) }
            let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "截图标注工具条" })
            let hud = try XCTUnwrap(panel.contentView as? HUDContentView)
            XCTAssertFalse(hud.isAnnotationExpanded)
            if keyboard {
                let selector = try XCTUnwrap(selection.windows.first?.contentView as? SelectionView)
                try key("\r", code: 36, to: selector)
            } else {
                try XCTUnwrap(allButtons(in: hud).first { $0.accessibilityLabel() == "完成并复制" }).performClick(nil)
            }
            try await waitUntil { captured != nil }
            let result = try XCTUnwrap(captured)
            XCTAssertEqual(selection.outputAction, .copy)
            XCTAssertEqual(result.0.width, 340)
            XCTAssertEqual(result.0.height, 280)
            XCTAssertEqual(result.1.localRect, target.localRect)
            await selection.drainPendingOperations()
            XCTAssertEqual(selection.resourceCounts.values.reduce(0, +), 0)
        }
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
            onCapture: { _, _ in XCTFail("Starting the follow controls must wait for an explicit finish before output") }, capturePreview: { context in
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
        try await waitUntil {
            coordinator.resourceCounts["controls"] == 1 && coordinator.controlProgress.frames == 1 &&
            !coordinator.controlProgress.isWorking
        }
        XCTAssertEqual(coordinator.resourceCounts["setup"], 0, "A selected viewport starts following without another confirmation window")
        XCTAssertEqual(coordinator.controlProgress.mode, .manual)
        XCTAssertEqual(coordinator.controlProgress.height, fresh.height)
        XCTAssertFalse(coordinator.controlProgress.isPaused)
        XCTAssertFalse(coordinator.controlProgress.isMatching)
        XCTAssertEqual(previews.count, 1)
        assertViewport(try XCTUnwrap(previews.first), equals: target)
        assertViewport(try XCTUnwrap(coordinator.selectedViewport), equals: target)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(coordinator.resourceCounts["controls"], 1, "A stationary page must remain ready for the user to scroll")
        XCTAssertEqual(coordinator.controlProgress.frames, 1)
        XCTAssertTrue(coordinator.isBusy)
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
        XCTAssertEqual(coordinator.resourceCounts["controls"], 0)
        XCTAssertEqual(coordinator.resourceCounts["setup"], 0)
        XCTAssertEqual(coordinator.controlProgress.frames, 0)
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

    private func mouse(_ type: NSEvent.EventType, point: CGPoint, to view: NSView) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: XCTFail("Unsupported fixture mouse event")
        }
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
