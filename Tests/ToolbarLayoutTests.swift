// Verifies native toolbar actions, adaptive layout, contextual styles and text focus through real AppKit controls.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class ToolbarLayoutTests: XCTestCase {
    func testDrawnAnnotationsCanBeUndoneAndRedoneFromVisibleButtons() throws {
        let pixels = try ImageUtilities.context(width: 400, height: 320)
        let session = SelectionSession()
        session.edit(image: try XCTUnwrap(pixels.makeImage()), pointSize: CGSize(width: 200, height: 160)) { _, _ in }
        defer { session.finish() }
        let hud = try stack()
        let canvas = try XCTUnwrap(NSApp.windows.compactMap(\.contentView).flatMap { allViews(in: $0) }
            .compactMap { $0 as? AnnotationCanvasView }.first)
        let undo = try button(ToolbarAction.undo.title, in: hud), redo = try button(ToolbarAction.redo.title, in: hud)
        XCTAssertFalse(undo.isEnabled); XCTAssertFalse(redo.isEnabled)
        for (index, tool) in [AnnotationTool.line, .arrow, .rectangle].enumerated() {
            try button(tool.title, in: hud).performClick(nil)
            try draw(in: canvas, from: CGPoint(x: 20, y: 15 + index * 40), to: CGPoint(x: 120, y: 35 + index * 40))
            XCTAssertEqual(canvas.document.commands.count, index + 1)
            XCTAssertTrue(undo.isEnabled); XCTAssertFalse(redo.isEnabled)
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
        try draw(in: canvas, from: CGPoint(x: 160, y: 120), to: CGPoint(x: 180, y: 140))
        XCTAssertFalse(redo.isEnabled, "Drawing after undo must discard the old redo branch")
    }

    func testMainBarExposesEveryToolAndOneRightmostCompletion() throws {
        var actions: [ToolbarAction] = []
        let controller = ToolbarController(onTool: { _ in }, onAction: { actions.append($0) })
        defer { controller.close() }
        show(controller)
        let hud = try stack()
        XCTAssertEqual(allButtons(in: hud).count, 19)
        XCTAssertFalse(controller.isPropertyBarVisible)
        for tool in AnnotationTool.toolbarTools { XCTAssertNotNil(controller.button(for: tool)) }
        for action in ToolbarAction.allCases where action != .selection { XCTAssertNotNil(controller.button(for: action)) }
        let completion = try XCTUnwrap(controller.button(for: ToolbarAction.copy))
        let completionFrame = completion.convert(completion.bounds, to: hud)
        XCTAssertEqual(completionFrame.maxX, try XCTUnwrap(allButtons(in: hud).map { $0.convert($0.bounds, to: hud).maxX }.max()), accuracy: 0.5)
        XCTAssertEqual(allButtons(in: hud).filter { $0.accessibilityLabel() == ToolbarAction.copy.title }.count, 1)
        XCTAssertTrue((completion.toolTip ?? "").contains("↩"))
        try assertHitTargets(in: hud)
        controller.button(for: ToolbarAction.translate)?.performClick(nil)
        completion.performClick(nil)
        XCTAssertEqual(actions, [.translate, .copy])
    }

    func testSelectingToolsRevealsOnlyRelevantPropertiesAndMirrorsVariants() throws {
        let controller = ToolbarController(onTool: { _ in }, onAction: { _ in })
        defer { controller.close() }
        show(controller)
        let panel = try shownPanel(), hud = try stack()
        let compactHeight = panel.frame.height
        controller.button(for: AnnotationTool.rectangle)?.performClick(nil)
        XCTAssertTrue(controller.isPropertyBarVisible)
        XCTAssertGreaterThan(panel.frame.height, compactHeight)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertNotNil(controller.propertyButtons.first { $0.accessibilityLabel() == "填充" })
        controller.setSelectedTool(.blur)
        XCTAssertEqual(controller.button(for: AnnotationTool.mosaic)?.accessibilityValue() as? String, "已选择")
        XCTAssertNotNil(controller.propertyButtons.first { $0.accessibilityLabel() == "模糊" })
        XCTAssertFalse(controller.propertyButtons.contains { ($0.accessibilityLabel() ?? "").contains("蓝色") })
        controller.setSelectedTool(.note)
        XCTAssertEqual(controller.button(for: AnnotationTool.text)?.accessibilityValue() as? String, "已选择")
        XCTAssertNotNil(controller.propertyButtons.first { $0.accessibilityLabel() == "便签底色" })
        try assertHitTargets(in: hud)
        controller.setSelectedTool(nil)
        XCTAssertFalse(controller.isPropertyBarVisible)
        XCTAssertEqual(panel.frame.height, compactHeight)
    }

    func testNarrowScreensKeepAllToolsAndStyleControlsInsideThePanel() throws {
        let controller = ToolbarController(onTool: { _ in }, onAction: { _ in })
        defer { controller.close() }
        for width: CGFloat in [640, 320, 240] {
            let screen = CGRect(x: 0, y: 0, width: width, height: 700)
            controller.show(near: CGRect(x: 20, y: 350, width: width - 40, height: 200), screenFrame: screen)
            controller.setSelectedTool(.rectangle)
            let panel = try shownPanel(), hud = try stack()
            XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(panel.frame))
            XCTAssertEqual(allButtons(in: hud.main).count, 19)
            try assertHitTargets(in: hud)
        }
    }

    func testToolbarUsesFreeSpaceAboveOrBelowBeforeCoveringSelection() throws {
        let size = CGSize(width: 650, height: 86), screen = CGRect(x: 8, y: 8, width: 884, height: 684)
        for selection in [CGRect(x: 180, y: 300, width: 420, height: 250), CGRect(x: 180, y: 10, width: 420, height: 250)] {
            let (frame, _) = ToolbarController.frame(for: size, near: selection, screen: screen)
            XCTAssertTrue(screen.contains(frame)); XCTAssertFalse(frame.intersects(selection))
        }
    }

    func testConfirmationOnlyOffersCancelAndTheNamedCompletion() throws {
        for title in ["开始录制", "开始长截图"] {
            var actions: [ToolbarAction] = []
            let controller = ToolbarController(onTool: { _ in XCTFail("Confirmation cannot select a tool") },
                onAction: { actions.append($0) }, confirmationTitle: title)
            defer { controller.close() }
            show(controller)
            let ignoredResult = NSView()
            controller.setSelectedTool(.rectangle)
            controller.setTextResultView(ignoredResult)
            XCTAssertFalse(controller.isPropertyBarVisible)
            XCTAssertNil(ignoredResult.superview)
            XCTAssertEqual(allButtons(in: try stack()).count, 2)
            try XCTUnwrap(controller.button(for: ToolbarAction.copy)).performClick(nil)
            XCTAssertEqual(actions, [.copy])
            XCTAssertFalse(try shownPanel().canBecomeKey)
        }
    }

    func testInlineStyleChangesAreDeliveredAndCloseReleasesController() throws {
        var styles: [AnnotationStyle] = []
        var controller: ToolbarController? = ToolbarController(onTool: { _ in }, onAction: { _ in }, onStyle: { styles.append($0) })
        weak let weakController = controller
        show(try XCTUnwrap(controller))
        controller?.setSelectedTool(.rectangle)
        let hud = try stack()
        try button("蓝色", in: hud, contains: true).performClick(nil)
        XCTAssertEqual(styles.last?.color, AnnotationColor.palette[4].color)
        try button("粗", in: hud).performClick(nil)
        XCTAssertEqual(styles.last?.width, 8)
        try button("填充", in: hud).performClick(nil)
        XCTAssertEqual(styles.last?.filled, true)
        controller?.close()
        XCTAssertEqual(controller?.auxiliaryControlCount, 0)
        XCTAssertEqual(controller?.windowCount, 0)
        controller = nil
        XCTAssertNil(weakController)
    }

    func testInlineTextKeepsIMECompositionAndAttachmentWhenPropertiesChange() throws {
        let controller = ToolbarController(onTool: { _ in }, onAction: { _ in })
        defer { controller.close() }
        show(controller)
        let panel = try shownPanel(), hud = try stack()
        let compactHeight = panel.frame.height
        let result = ToolbarResultFixtureView()
        let editor = NSTextView(frame: .zero)
        editor.string = "English 与中文"; editor.autoresizingMask = [.width, .height]
        result.addSubview(editor)
        controller.setTextResultView(result, preferredHeight: 180)
        XCTAssertTrue(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(result.window === panel)
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.makeFirstResponder(editor))
        editor.setMarkedText("日本語", selectedRange: NSRange(location: 0, length: 3),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let detachments = result.detachments
        controller.setSelectedTool(.rectangle)
        controller.setSelectedTool(.text)
        XCTAssertTrue(panel.firstResponder === editor)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(result.detachments, detachments)
        XCTAssertTrue(hud.bounds.contains(result.convert(result.bounds, to: hud)))
        controller.setTextResultView(nil)
        controller.setSelectedTool(nil)
        XCTAssertFalse(panel.canBecomeKey); XCTAssertNil(result.window)
        XCTAssertEqual(panel.frame.height, compactHeight)
    }

    func testTextCardFitsShortScreensWithoutClippingTools() throws {
        let controller = ToolbarController(onTool: { _ in }, onAction: { _ in })
        defer { controller.close() }
        controller.show(near: CGRect(x: 20, y: 120, width: 250, height: 150),
                        screenFrame: CGRect(x: 0, y: 0, width: 320, height: 350))
        controller.setSelectedTool(.rectangle)
        let result = NSView()
        controller.setTextResultView(result, preferredHeight: 280)
        let hud = try stack()
        XCTAssertLessThanOrEqual(hud.bounds.height, 334)
        XCTAssertGreaterThan(result.frame.height, 0)
        XCTAssertTrue(hud.bounds.contains(result.convert(result.bounds, to: hud)))
        try assertHitTargets(in: hud)
    }

    private func show(_ controller: ToolbarController) {
        controller.show(near: CGRect(x: 180, y: 360, width: 420, height: 230), screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    }

    private func shownPanel() throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "截图工具栏" })
    }

    private func stack() throws -> ToolbarStackView { try XCTUnwrap(try shownPanel().contentView as? ToolbarStackView) }

    private func button(_ label: String, in view: NSView, contains: Bool = false) throws -> NSButton {
        try XCTUnwrap(allButtons(in: view).first { contains ? ($0.accessibilityLabel() ?? "").contains(label) : $0.accessibilityLabel() == label }, label)
    }

    private func allButtons(in view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { allButtons(in: $0) } }
    private func allViews(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { allViews(in: $0) } }

    private func draw(in canvas: AnnotationCanvasView, from: CGPoint, to: CGPoint) throws {
        for (type, point) in [(NSEvent.EventType.leftMouseDown, from), (.leftMouseDragged, to), (.leftMouseUp, to)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type { case .leftMouseDown: canvas.mouseDown(with: event); case .leftMouseDragged: canvas.mouseDragged(with: event); default: canvas.mouseUp(with: event) }
        }
    }

    private func assertHitTargets(in hud: ToolbarStackView) throws {
        hud.layoutSubtreeIfNeeded()
        for button in allButtons(in: hud) {
            let frame = button.convert(button.bounds, to: hud)
            let label = button.accessibilityLabel() ?? "control"
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor, label)
            XCTAssertGreaterThanOrEqual(frame.width, 24, label)
            XCTAssertGreaterThanOrEqual(frame.height, 24, label)
            XCTAssertTrue(hud.bounds.contains(frame), "\(label) \(frame) must fit inside \(hud.bounds)")
        }
    }
}

@MainActor
private final class ToolbarResultFixtureView: NSView {
    var detachments = 0
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { detachments += 1 } }
}
