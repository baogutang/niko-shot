// Exercises the real AppKit HUD's compact completion, disclosure, screen placement and transient-control lifecycle.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class ToolbarLayoutTests: XCTestCase {
    func testDrawnLineArrowAndRectangleCanBeUndoneAndRedoneFromVisibleButtons() throws {
        let pixels = try ImageUtilities.context(width: 400, height: 320)
        let session = SelectionSession()
        session.edit(image: try XCTUnwrap(pixels.makeImage()), pointSize: CGSize(width: 200, height: 160)) { _, _ in }
        defer { session.finish() }
        let hud = try XCTUnwrap(try shownPanel().contentView as? HUDContentView)
        let canvas = try XCTUnwrap(NSApp.windows.compactMap(\.contentView).flatMap { allViews(in: $0) }
            .compactMap { $0 as? AnnotationCanvasView }.first)
        let undo = try button(ToolbarAction.undo.title, in: hud), redo = try button(ToolbarAction.redo.title, in: hud)
        XCTAssertFalse(undo.isEnabled); XCTAssertFalse(redo.isEnabled)
        for (index, tool) in [AnnotationTool.line, .arrow, .rectangle].enumerated() {
            try button(tool.title, in: hud).performClick(nil)
            for (type, point) in [(NSEvent.EventType.leftMouseDown, CGPoint(x: 20, y: 20)),
                                  (.leftMouseDragged, CGPoint(x: 120, y: 90)), (.leftMouseUp, CGPoint(x: 120, y: 90))] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                switch type {
                case .leftMouseDown: canvas.mouseDown(with: event)
                case .leftMouseDragged: canvas.mouseDragged(with: event)
                default: canvas.mouseUp(with: event)
                }
            }
            XCTAssertEqual(canvas.document.commands.count, index + 1)
            XCTAssertTrue(undo.isEnabled)
            XCTAssertFalse(redo.isEnabled)
        }
        for count in stride(from: 2, through: 0, by: -1) {
            undo.performClick(nil)
            XCTAssertEqual(canvas.document.commands.count, count)
            XCTAssertTrue(redo.isEnabled)
            XCTAssertEqual(undo.isEnabled, count > 0)
        }
        for count in 1...3 {
            redo.performClick(nil)
            XCTAssertEqual(canvas.document.commands.count, count)
            XCTAssertTrue(undo.isEnabled)
            XCTAssertEqual(redo.isEnabled, count < 3)
        }
        undo.performClick(nil)
        try button(AnnotationTool.pen.title, in: hud).performClick(nil)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49))
        canvas.keyDown(with: key)
        let move = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 124))
        canvas.keyDown(with: move); canvas.keyDown(with: key)
        XCTAssertFalse(redo.isEnabled, "A new drawing invalidates the old redo branch")
    }

    func testCompactBarHasOneRightmostCompletionAndDiscoverableScroll() throws {
        var actions: [ToolbarAction] = []
        let hud = HUDContentView(onTool: { _ in }, onAction: { actions.append($0) }, onColor: { _ in }, onWidth: { _ in })
        defer { hud.closeAuxiliaryControls() }
        layout(hud, width: 704)
        let buttons = allButtons(in: hud)
        XCTAssertEqual(buttons.count, 19)
        XCTAssertEqual(hud.frame.height, 80)
        XCTAssertGreaterThanOrEqual(hud.frame.width, 400)
        XCTAssertLessThanOrEqual(hud.frame.width, 520)
        for tool in [AnnotationTool.rectangle, .ellipse, .line, .arrow, .pen, .text, .mosaic] {
            XCTAssertNotNil(try button(tool.title, in: hud))
        }
        XCTAssertFalse(hud.isAnnotationExpanded)
        XCTAssertEqual(buttons.filter { $0.accessibilityLabel() == "完成并复制" }.count, 1)
        XCTAssertFalse(buttons.contains { $0.accessibilityLabel() == "复制" })
        let completion = try button("完成并复制", in: hud)
        XCTAssertEqual(ToolbarAction.copy.symbol, "checkmark")
        XCTAssertNotNil(completion.image)
        XCTAssertEqual(completion.toolTip, "完成并复制 · Enter")
        let completionFrame = completion.convert(completion.bounds, to: hud)
        XCTAssertEqual(completionFrame.maxX, try XCTUnwrap(buttons.map { $0.convert($0.bounds, to: hud).maxX }.max()), accuracy: 0.5)
        let scroll = try button("长截图", in: hud)
        XCTAssertEqual(scroll.title, "长截图")
        XCTAssertEqual(scroll.imagePosition, .imageLeading)
        for action in [ToolbarAction.undo, .redo, .ocr, .translate] {
            let labeled = try button(action.title, in: hud)
            XCTAssertEqual(labeled.title, action.title)
            XCTAssertEqual(labeled.imagePosition, .imageLeading)
        }
        let undo = try button(ToolbarAction.undo.title, in: hud)
        XCTAssertEqual(undo.convert(undo.bounds, to: hud).midY,
                       try button(AnnotationTool.arrow.title, in: hud).convert(undo.bounds, to: hud).midY, accuracy: 0.5)
        XCTAssertNotEqual(undo.convert(undo.bounds, to: hud).midY, completionFrame.midY)
        try assertHitTargets(in: hud, expectedCount: 19)
        try button(ToolbarAction.translate.title, in: hud).performClick(nil)
        XCTAssertEqual(actions, [.translate])
        completion.performClick(nil)
        XCTAssertEqual(actions, [.translate, .copy])
    }

    func testDisclosureResizesRealPanelAndKeyboardSelectionReopensTools() throws {
        let controller = ToolbarController(onTool: { _ in }, onAction: { _ in }, onColor: { _ in }, onWidth: { _ in })
        defer { controller.close() }
        let screen = CGRect(x: 0, y: 0, width: 900, height: 700)
        let selection = CGRect(x: 180, y: 300, width: 420, height: 250)
        controller.setUndoAvailability(canUndo: true, canRedo: false)
        controller.show(near: selection, screenFrame: screen)
        let panel = try shownPanel()
        let hud = try XCTUnwrap(panel.contentView as? HUDContentView)
        let compactHeight = panel.frame.height
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.screenSaver.rawValue)
        try button(AnnotationTool.rectangle.title, in: hud).performClick(nil)
        XCTAssertFalse(controller.isAnnotationExpanded, "Common tools must draw directly without opening an inspector")
        XCTAssertEqual(panel.frame.height, compactHeight)
        try button("更多标注工具", in: hud).performClick(nil)
        XCTAssertTrue(controller.isAnnotationExpanded)
        XCTAssertGreaterThan(panel.frame.height, compactHeight)
        XCTAssertFalse(panel.frame.intersects(selection))
        try assertHitTargets(in: hud, expectedCount: 25)
        XCTAssertTrue(try button(ToolbarAction.undo.title, in: hud).isEnabled)
        XCTAssertFalse(try button(ToolbarAction.redo.title, in: hud).isEnabled)
        try button(AnnotationTool.blur.title, in: hud).performClick(nil)
        XCTAssertEqual(try button(AnnotationTool.blur.title, in: hud).accessibilityValue() as? String, "已选择")
        try button("更多标注工具", in: hud).performClick(nil)
        XCTAssertFalse(controller.isAnnotationExpanded)
        XCTAssertEqual(panel.frame.height, compactHeight, "Identical available width must not retain the expanded height")
        XCTAssertNil(allButtons(in: hud).first { $0.accessibilityLabel() == AnnotationTool.blur.title })
        XCTAssertEqual(try button("更多标注工具", in: hud).accessibilityValue() as? String, "当前工具：模糊")
        controller.setSelectedTool(.pen)
        XCTAssertFalse(controller.isAnnotationExpanded, "Keyboard entry to a common tool must keep the toolbar compact")
        XCTAssertEqual(try button(AnnotationTool.pen.title, in: hud).accessibilityValue() as? String, "已选择")
        XCTAssertEqual(try button(AnnotationTool.rectangle.title, in: hud).accessibilityValue() as? String, "")
        controller.setSelectedTool(.highlight)
        XCTAssertTrue(controller.isAnnotationExpanded, "Keyboard entry to an advanced tool must reveal its selected control")
        XCTAssertEqual(try button(AnnotationTool.highlight.title, in: hud).accessibilityValue() as? String, "已选择")
        try assertHitTargets(in: hud, expectedCount: 25)
        try button("更多标注工具", in: hud).performClick(nil)
        controller.show(near: selection, screenFrame: screen)
        XCTAssertFalse(controller.isAnnotationExpanded, "Repositioning must preserve an explicitly collapsed inspector")
        XCTAssertTrue((try button("更多标注工具", in: hud).toolTip ?? "").contains(AnnotationTool.highlight.title))
        controller.close()
        XCTAssertEqual(controller.windowCount, 0)
        XCTAssertEqual(controller.auxiliaryControlCount, 0)
    }

    func testNarrowRowsKeepEveryToolAndActionInsideHUD() throws {
        let hud = HUDContentView(onTool: { _ in }, onAction: { _ in }, onColor: { _ in }, onWidth: { _ in })
        defer { hud.closeAuxiliaryControls() }
        for width: CGFloat in [240, 100] {
            for expanded in [false, true] {
                hud.setAnnotationExpanded(expanded)
                layout(hud, width: width)
                XCTAssertLessThanOrEqual(hud.frame.width, width)
                try assertHitTargets(in: hud, expectedCount: expanded ? 25 : 19)
                XCTAssertEqual(try button("长截图", in: hud).title, "长截图")
                if expanded {
                    for tool in AnnotationTool.allCases { XCTAssertNotNil(try button(tool.title, in: hud)) }
                }
            }
        }
    }

    func testExpandedInspectorWrapsBesideTallSelection() throws {
        let controller = ToolbarController(onTool: { _ in }, onAction: { _ in }, onColor: { _ in }, onWidth: { _ in })
        defer { controller.close() }
        let screen = CGRect(x: 0, y: 0, width: 640, height: 480)
        let selection = CGRect(x: 20, y: 40, width: 320, height: 360)
        controller.show(near: selection, screenFrame: screen)
        let panel = try shownPanel()
        let hud = try XCTUnwrap(panel.contentView as? HUDContentView)
        let compactHeight = panel.frame.height
        try button("更多标注工具", in: hud).performClick(nil)
        XCTAssertTrue(controller.isAnnotationExpanded)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(panel.frame))
        XCTAssertFalse(panel.frame.intersects(selection), "A free side should be used before covering the selected pixels")
        XCTAssertGreaterThan(panel.frame.minX, selection.maxX)
        try assertHitTargets(in: hud, expectedCount: 25)
        try button("更多标注工具", in: hud).performClick(nil)
        XCTAssertEqual(panel.frame.height, compactHeight)
        XCTAssertFalse(panel.frame.intersects(selection))
    }

    func testConfirmationModeContainsOnlyConfirmAndCancel() throws {
        for title in ["开始录制", "开始长截图"] {
            var actions: [ToolbarAction] = []
            let hud = HUDContentView(onTool: { _ in XCTFail("Confirmation must not select an annotation tool") },
                                     onAction: { actions.append($0) }, onColor: { _ in }, onWidth: { _ in }, confirmationTitle: title)
            defer { hud.closeAuxiliaryControls() }
            layout(hud, width: 400)
            hud.setAnnotationExpanded(true)
            let ignoredResult = NSView()
            hud.setTextResultView(ignoredResult)
            layout(hud, width: 400)
            XCTAssertFalse(hud.isAnnotationExpanded)
            XCTAssertNil(ignoredResult.superview, "Confirmation modes must not acquire text or annotation UI")
            try assertHitTargets(in: hud, expectedCount: 2)
            XCTAssertEqual(Set(allButtons(in: hud).compactMap { $0.accessibilityLabel() }), [title, ToolbarAction.close.title])
            let confirm = try button(title, in: hud)
            XCTAssertEqual(confirm.title, title)
            XCTAssertEqual(confirm.toolTip, "\(title) · Enter")
            confirm.performClick(nil)
            XCTAssertEqual(actions, [.copy], "The selection coordinator owns the confirmation behavior")
        }
    }

    func testStylePopoversCloseOnCollapseAndSessionTeardown() async throws {
        var colors: [NSColor] = [], widths: [CGFloat] = []
        var controller: ToolbarController? = ToolbarController(onTool: { _ in }, onAction: { _ in },
                                                               onColor: { colors.append($0) }, onWidth: { widths.append($0) })
        weak let weakController = controller
        defer { controller?.close() }
        controller?.show(near: CGRect(x: 180, y: 300, width: 420, height: 250),
                         screenFrame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let hud = try XCTUnwrap(try shownPanel().contentView as? HUDContentView)
        XCTAssertFalse(hud.isAnnotationExpanded)
        try button("标注颜色：红色", in: hud).performClick(nil)
        XCTAssertEqual(controller?.auxiliaryControlCount, 1)
        let blue = try XCTUnwrap(NSApplication.shared.windows.flatMap { $0.contentView.map { allButtons(in: $0) } ?? [] }
            .first { $0.accessibilityLabel() == "标注颜色：蓝色" })
        blue.performClick(nil)
        try await waitUntil { controller?.auxiliaryControlCount == 0 }
        XCTAssertEqual(colors.count, 1, "A style can be chosen before any drawing tool")
        XCTAssertFalse(hud.isAnnotationExpanded)
        try button("标注线宽：3 pt", in: hud).performClick(nil)
        let slider = try XCTUnwrap(NSApplication.shared.windows.flatMap { $0.contentView.map { allViews(in: $0) } ?? [] }
            .compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "标注线宽" })
        slider.doubleValue = 9
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        XCTAssertEqual(widths, [9])
        XCTAssertNotNil(try button("标注线宽：9 pt", in: hud))
        try button("更多标注工具", in: hud).performClick(nil)
        XCTAssertEqual(controller?.auxiliaryControlCount, 0)
        controller?.setSelectedTool(.pen)
        try button("标注线宽：9 pt", in: hud).performClick(nil)
        XCTAssertEqual(controller?.auxiliaryControlCount, 1)
        controller?.close()
        XCTAssertEqual(controller?.auxiliaryControlCount, 0)
        XCTAssertEqual(hud.auxiliaryControlCount, 0)
        XCTAssertEqual(controller?.windowCount, 0)
        controller = nil
        XCTAssertNil(weakController, "Closed native controls must not retain the session controller")
    }

    func testInlineTextPreservesFocusCompositionAndAttachmentAcrossReflow() throws {
        let controller = ToolbarController(onTool: { _ in }, onAction: { _ in }, onColor: { _ in }, onWidth: { _ in })
        defer { controller.close() }
        controller.show(near: CGRect(x: 180, y: 360, width: 420, height: 230),
                        screenFrame: CGRect(x: 0, y: 0, width: 900, height: 800))
        let panel = try shownPanel(), hud = try XCTUnwrap(panel.contentView as? HUDContentView)
        let compactHeight = panel.frame.height
        let result = ToolbarResultFixtureView()
        let editor = NSTextView(frame: .zero)
        editor.string = "English 与中文"
        editor.autoresizingMask = [.width, .height]
        result.addSubview(editor)
        controller.setTextResultView(result, preferredHeight: 180)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.frame.height, compactHeight + 190)
        XCTAssertTrue(result.window === panel)
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        editor.setMarkedText("日本語", selectedRange: NSRange(location: 0, length: 3),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let detachments = result.detachments
        try button("更多标注工具", in: hud).performClick(nil)
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertTrue(editor.hasMarkedText(), "Button relayout must not cancel native IME composition")
        XCTAssertEqual(result.detachments, detachments)
        XCTAssertTrue(result.window === panel)
        XCTAssertTrue(hud.bounds.contains(result.convert(result.bounds, to: hud)))
        try assertHitTargets(in: hud, expectedCount: 25)
        controller.setTextResultView(nil)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertNil(result.window)
        XCTAssertEqual(controller.auxiliaryControlCount, 0)
        try button("更多标注工具", in: hud).performClick(nil)
        XCTAssertEqual(panel.frame.height, compactHeight)
    }

    func testInlineTextFitsLimitedHeightWithoutHidingButtons() throws {
        let hud = HUDContentView(onTool: { _ in }, onAction: { _ in }, onColor: { _ in }, onWidth: { _ in })
        defer { hud.closeAuxiliaryControls(); hud.setTextResultView(nil) }
        let result = NSView()
        hud.setTextResultView(result, preferredHeight: 280)
        hud.frame.size = hud.configure(maximumWidth: 240, maximumHeight: 300)
        hud.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(hud.frame.height, 300)
        XCTAssertLessThan(result.frame.height, 280)
        XCTAssertGreaterThan(result.frame.height, 0)
        XCTAssertTrue(hud.bounds.contains(result.convert(result.bounds, to: hud)))
        try assertHitTargets(in: hud, expectedCount: 19)
    }

    private func layout(_ hud: HUDContentView, width: CGFloat) {
        hud.frame.size = hud.configure(maximumWidth: width)
        hud.layoutSubtreeIfNeeded()
    }

    private func shownPanel() throws -> NSWindow {
        try XCTUnwrap(NSApplication.shared.windows.first { $0.isVisible && $0.accessibilityLabel() == "截图标注工具条" })
    }

    private func button(_ label: String, in hud: HUDContentView) throws -> NSButton {
        try XCTUnwrap(allButtons(in: hud).first { $0.accessibilityLabel() == label }, label)
    }

    private func allButtons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { allButtons(in: $0) }
    }

    private func allViews(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { allViews(in: $0) } }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Native style popover must finish closing")
    }

    private func assertHitTargets(in hud: HUDContentView, expectedCount: Int) throws {
        hud.layoutSubtreeIfNeeded()
        let buttons = allButtons(in: hud)
        XCTAssertEqual(buttons.count, expectedCount)
        for button in buttons {
            let frame = button.convert(button.bounds, to: hud)
            let title = button.accessibilityLabel() ?? "unnamed control"
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor, title)
            XCTAssertGreaterThanOrEqual(frame.width, 32, title)
            XCTAssertGreaterThanOrEqual(frame.height, 32, title)
            XCTAssertTrue(hud.bounds.contains(frame), "\(title) \(frame) must fit inside \(hud.bounds)")
        }
    }
}

@MainActor
private final class ToolbarResultFixtureView: NSView {
    var detachments = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detachments += 1 }
    }
}
