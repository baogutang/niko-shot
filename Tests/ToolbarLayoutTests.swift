// Exercises the real AppKit HUD's compact completion, disclosure, screen placement and transient-control lifecycle.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class ToolbarLayoutTests: XCTestCase {
    func testCompactBarHasOneRightmostCompletionAndDiscoverableScroll() throws {
        var actions: [ToolbarAction] = []
        let hud = HUDContentView(onTool: { _ in }, onAction: { actions.append($0) }, onColor: { _ in }, onWidth: { _ in })
        defer { hud.closeAuxiliaryControls() }
        layout(hud, width: 704)
        let buttons = allButtons(in: hud)
        XCTAssertEqual(buttons.count, 7)
        XCTAssertEqual(hud.frame.height, 58)
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
        try assertHitTargets(in: hud, expectedCount: 7)
        completion.performClick(nil)
        XCTAssertEqual(actions, [.copy])
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
        try button("标注工具", in: hud).performClick(nil)
        XCTAssertTrue(controller.isAnnotationExpanded)
        XCTAssertGreaterThan(panel.frame.height, compactHeight)
        XCTAssertFalse(panel.frame.intersects(selection))
        try assertHitTargets(in: hud, expectedCount: 24)
        XCTAssertTrue(try button(ToolbarAction.undo.title, in: hud).isEnabled)
        XCTAssertFalse(try button(ToolbarAction.redo.title, in: hud).isEnabled)
        try button(AnnotationTool.rectangle.title, in: hud).performClick(nil)
        XCTAssertEqual(try button(AnnotationTool.rectangle.title, in: hud).accessibilityValue() as? String, "已选择")
        try button("标注工具", in: hud).performClick(nil)
        XCTAssertFalse(controller.isAnnotationExpanded)
        XCTAssertEqual(panel.frame.height, compactHeight, "Identical available width must not retain the expanded height")
        XCTAssertNil(allButtons(in: hud).first { $0.accessibilityLabel() == AnnotationTool.rectangle.title })
        controller.setSelectedTool(.pen)
        XCTAssertTrue(controller.isAnnotationExpanded, "Keyboard tool selection must disclose its matching pointer controls")
        XCTAssertEqual(try button(AnnotationTool.pen.title, in: hud).accessibilityValue() as? String, "已选择")
        XCTAssertEqual(try button(AnnotationTool.rectangle.title, in: hud).accessibilityValue() as? String, "")
        try assertHitTargets(in: hud, expectedCount: 24)
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
                try assertHitTargets(in: hud, expectedCount: expanded ? 24 : 7)
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
        try button("标注工具", in: hud).performClick(nil)
        XCTAssertTrue(controller.isAnnotationExpanded)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(panel.frame))
        XCTAssertFalse(panel.frame.intersects(selection), "A free side should be used before covering the selected pixels")
        XCTAssertGreaterThan(panel.frame.minX, selection.maxX)
        try assertHitTargets(in: hud, expectedCount: 24)
        try button("标注工具", in: hud).performClick(nil)
        XCTAssertEqual(panel.frame.height, 58)
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
            layout(hud, width: 400)
            XCTAssertFalse(hud.isAnnotationExpanded)
            try assertHitTargets(in: hud, expectedCount: 2)
            XCTAssertEqual(Set(allButtons(in: hud).compactMap { $0.accessibilityLabel() }), [title, ToolbarAction.close.title])
            let confirm = try button(title, in: hud)
            XCTAssertEqual(confirm.title, title)
            XCTAssertEqual(confirm.toolTip, "\(title) · Enter")
            confirm.performClick(nil)
            XCTAssertEqual(actions, [.copy], "The selection coordinator owns the confirmation behavior")
        }
    }

    func testStylePopoversCloseOnCollapseAndSessionTeardown() throws {
        var controller: ToolbarController? = ToolbarController(onTool: { _ in }, onAction: { _ in }, onColor: { _ in }, onWidth: { _ in })
        weak let weakController = controller
        defer { controller?.close() }
        controller?.show(near: CGRect(x: 180, y: 300, width: 420, height: 250),
                         screenFrame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let hud = try XCTUnwrap(try shownPanel().contentView as? HUDContentView)
        controller?.setSelectedTool(.rectangle)
        try button("标注颜色：红色", in: hud).performClick(nil)
        XCTAssertEqual(controller?.auxiliaryControlCount, 1)
        try button("标注工具", in: hud).performClick(nil)
        XCTAssertEqual(controller?.auxiliaryControlCount, 0)
        controller?.setSelectedTool(.pen)
        try button("标注线宽：3 pt", in: hud).performClick(nil)
        XCTAssertEqual(controller?.auxiliaryControlCount, 1)
        controller?.close()
        XCTAssertEqual(controller?.auxiliaryControlCount, 0)
        XCTAssertEqual(hud.auxiliaryControlCount, 0)
        XCTAssertEqual(controller?.windowCount, 0)
        controller = nil
        XCTAssertNil(weakController, "Closed native controls must not retain the session controller")
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

    private func assertHitTargets(in hud: HUDContentView, expectedCount: Int) throws {
        hud.layoutSubtreeIfNeeded()
        let buttons = allButtons(in: hud)
        XCTAssertEqual(buttons.count, expectedCount)
        for button in buttons {
            let frame = button.convert(button.bounds, to: hud)
            let title = button.accessibilityLabel() ?? "unnamed control"
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor, title)
            XCTAssertGreaterThanOrEqual(frame.width, 44, title)
            XCTAssertGreaterThanOrEqual(frame.height, 44, title)
            XCTAssertTrue(hud.bounds.contains(frame), "\(title) \(frame) must fit inside \(hud.bounds)")
        }
    }
}
