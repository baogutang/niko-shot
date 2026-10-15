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
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "截图工具栏" })
        let hud = try XCTUnwrap(panel.contentView as? ToolbarStackView)
        hud.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(panel.level.rawValue, try XCTUnwrap(view.window).level.rawValue)
        XCTAssertFalse(panel.canBecomeKey, "Pointer use must keep the selection's keyboard responder")
        try await waitUntil { panel.alphaValue >= 0.95 }
        let buttons = allButtons(in: hud)
        XCTAssertEqual(buttons.count, 19, "Every tool and action is directly available in one row")
        XCTAssertEqual(buttons.filter { $0.accessibilityLabel() == ToolbarAction.copy.title }.count, 1)
        for title in AnnotationTool.toolbarTools.map(\.title) + ToolbarAction.allCases.filter({ $0 != .selection }).map(\.title) {
            let button = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == title }, title)
            let frame = button.convert(button.bounds, to: hud)
            XCTAssertGreaterThanOrEqual(frame.width, 28, title)
            XCTAssertGreaterThanOrEqual(frame.height, 28, title)
            XCTAssertTrue(hud.bounds.contains(frame), "\(title) must be fully inside the visible panel: \(frame)")
        }
        XCTAssertFalse(buttons.contains { $0.accessibilityLabel() == AnnotationTool.blur.title })
        let completion = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == ToolbarAction.copy.title })
        let cancel = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == ToolbarAction.close.title })
        let completionFrame = completion.convert(completion.bounds, to: hud), cancelFrame = cancel.convert(cancel.bounds, to: hud)
        if abs(completionFrame.midY - cancelFrame.midY) < 1 {
            XCTAssertGreaterThan(completionFrame.minX, cancelFrame.minX)
        } else {
            XCTAssertGreaterThan(completionFrame.minY, cancelFrame.minY, "On narrow screens completion follows cancel on the next row")
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
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "截图工具栏" })
        let hud = try XCTUnwrap(panel.contentView as? ToolbarStackView)
        let rectangle = try XCTUnwrap(allButtons(in: hud).first { $0.accessibilityLabel() == AnnotationTool.rectangle.title })
        rectangle.performClick(nil)
        XCTAssertNotNil(hud.properties, "Choosing a tool reveals its style bar")
        try await waitUntil {
            selection.windows.contains { $0.contentView?.subviews.contains { $0 is AnnotationCanvasView } == true }
        }
        let canvas = try XCTUnwrap(selection.windows.flatMap { $0.contentView?.subviews ?? [] }.compactMap { $0 as? AnnotationCanvasView }.first)
        try mouse(.leftMouseDown, point: CGPoint(x: 20, y: 20), to: canvas)
        try mouse(.leftMouseDragged, point: CGPoint(x: 120, y: 90), to: canvas)
        try mouse(.leftMouseUp, point: CGPoint(x: 120, y: 90), to: canvas)
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

    func testToolbarShowsLongCaptureAndExplainsDisabledAction() throws {
        var actions: [ToolbarAction] = []
        let controller = ToolbarController(onTool: { _ in }, onAction: { actions.append($0) })
        defer { controller.close() }
        controller.show(near: CGRect(x: 200, y: 300, width: 600, height: 300), screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900))
        let button = try XCTUnwrap(controller.button(for: .scroll))
        XCTAssertEqual(button.accessibilityLabel(), "长截图")
        XCTAssertGreaterThanOrEqual(button.frame.width, 28)
        button.performClick(nil)
        XCTAssertEqual(actions, [.scroll])
        let reason = "选区高度不足 240 像素，请增大选区。"
        controller.setScrollAvailability(enabled: false, explanation: reason)
        XCTAssertFalse(button.isEnabled)
        XCTAssertEqual(button.accessibilityHelp(), reason)
        XCTAssertTrue((button.toolTip ?? "").contains(reason))
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
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "截图工具栏" })
        let hud = try XCTUnwrap(panel.contentView as? ToolbarStackView)
        var canvas: AnnotationCanvasView?
        for (index, tool) in [AnnotationTool.rectangle, .pen, .arrow].enumerated() {
            try XCTUnwrap(allButtons(in: hud).first { $0.accessibilityLabel() == tool.title }).performClick(nil)
            try await waitUntil {
                selection.windows.contains { $0.contentView?.subviews.contains { $0 is AnnotationCanvasView } == true }
            }
            canvas = selection.windows.flatMap { $0.contentView?.subviews ?? [] }.compactMap { $0 as? AnnotationCanvasView }.first
            let editor = try XCTUnwrap(canvas)
            let offset = CGFloat(index) * 80
            try mouse(.leftMouseDown, point: CGPoint(x: 20 + offset, y: 30), to: editor)
            try mouse(.leftMouseDragged, point: CGPoint(x: 60 + offset, y: 120), to: editor)
            try mouse(.leftMouseUp, point: CGPoint(x: 80 + offset, y: 200), to: editor)
            XCTAssertEqual(editor.document.commands.last?.tool, tool)
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
            let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "截图工具栏" })
            let hud = try XCTUnwrap(panel.contentView as? ToolbarStackView)
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
