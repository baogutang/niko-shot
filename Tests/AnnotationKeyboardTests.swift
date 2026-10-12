// Exercises native key events, real modal text input, accessibility and rendered pixel output without CGEvents.
import AppKit
import CoreGraphics
import ImageIO
import XCTest
@testable import NikoShot

@MainActor
final class AnnotationKeyboardTests: XCTestCase {
    func testBracketKeysCycleEveryToolAndRetainNumberShortcuts() async throws {
        let canvas = try await makeCanvas()
        defer { canvas.prepareForFinish() }
        var changes: [AnnotationTool] = []
        canvas.onToolChange = { changes.append($0) }
        for expected in Array(AnnotationTool.allCases.dropFirst()) + [.rectangle] {
            try send("]", code: 30, to: canvas)
            XCTAssertEqual(canvas.tool, expected)
        }
        XCTAssertEqual(Set(changes), Set(AnnotationTool.allCases))
        try send("[", code: 33, to: canvas)
        XCTAssertEqual(canvas.tool, .magnifier)
        try send("6", code: 22, to: canvas)
        XCTAssertEqual(canvas.tool, .text)
        try send("9", code: 25, to: canvas)
        XCTAssertEqual(canvas.tool, .highlight)
        try send("]", code: 30, to: canvas)
        XCTAssertEqual(canvas.tool, .step)
        XCTAssertEqual(canvas.accessibilityRole(), .group)
        XCTAssertTrue((canvas.accessibilityHelp() ?? "").contains("原图像素"))
        XCTAssertTrue((canvas.accessibilityValue() as? String ?? "").contains("序号"))
    }

    func testKeyboardGestureMovesOneOriginalPixelAndExportsAtRetinaResolution() async throws {
        let canvas = try await makeCanvas()
        defer { canvas.prepareForFinish() }
        try send(" ", code: 49, to: canvas)
        try send("", code: 124, to: canvas)
        try send("", code: 124, modifiers: .shift, to: canvas)
        try send("", code: 125, to: canvas)
        try send("", code: 125, modifiers: .shift, to: canvas)
        try send(" ", code: 49, to: canvas)
        let item = try XCTUnwrap(canvas.document.commands.first)
        XCTAssertEqual(item.tool, .rectangle)
        XCTAssertEqual(item.points.first, CGPoint(x: 100, y: 80))
        XCTAssertEqual(item.points.last, CGPoint(x: 105.5, y: 85.5))
        XCTAssertEqual(item.rect.size, CGSize(width: 5.5, height: 5.5))
        XCTAssertTrue((canvas.accessibilityValue() as? String ?? "").contains("1 条"))
        let base = canvas.base, snapshot = canvas.document
        let result = try await Task.detached {
            let rendered = try AnnotationRenderer.render(base: base, document: snapshot, scale: 2)
            let png = try ImageUtilities.png(rendered)
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let output = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppError.imageCreation }
            let context = try ImageUtilities.context(width: output.width, height: output.height)
            context.draw(output, in: CGRect(x: 0, y: 0, width: output.width, height: output.height))
            guard let data = context.data else { throw AppError.imageCreation }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            let offset = 160 * context.bytesPerRow + 205 * 4
            return (width: output.width, height: output.height,
                red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2])
        }.value
        XCTAssertEqual(result.width, 400); XCTAssertEqual(result.height, 320)
        XCTAssertGreaterThan(result.red, 230); XCTAssertLessThan(result.green, 140); XCTAssertLessThan(result.blue, 140)
    }

    func testChangingToolsDiscardsGestureAndStepIsImmediatelyUndoable() async throws {
        let canvas = try await makeCanvas()
        defer { canvas.prepareForFinish() }
        try send(" ", code: 49, to: canvas)
        try send("", code: 124, modifiers: .shift, to: canvas)
        try send("]", code: 30, to: canvas)
        XCTAssertEqual(canvas.resourceCounts["pendingGesture"], 0)
        XCTAssertTrue(canvas.document.commands.isEmpty)
        canvas.tool = .step
        try send(" ", code: 49, to: canvas); try send(" ", code: 49, to: canvas)
        XCTAssertEqual(canvas.document.commands.map(\.number), [1, 2])
        try send("z", code: 6, modifiers: .command, to: canvas)
        XCTAssertEqual(canvas.document.commands.count, 1)
        try send("z", code: 6, modifiers: [.command, .shift], to: canvas)
        XCTAssertEqual(canvas.document.commands.count, 2)
    }

    func testSaveCopyTabAndEscapePreserveNativeRoutes() async throws {
        let canvas = try await makeCanvas()
        defer { canvas.prepareForFinish() }
        var actions: [ToolbarAction] = []
        canvas.onAction = { actions.append($0) }
        try send(" ", code: 49, to: canvas)
        try send("", code: 124, modifiers: .shift, to: canvas)
        try send("", code: 125, modifiers: .shift, to: canvas)
        try send("s", code: 1, modifiers: .command, to: canvas)
        XCTAssertEqual(canvas.document.commands.count, 1, "Saving must include the current keyboard gesture")
        try send("\r", code: 36, to: canvas)
        try send(" ", code: 49, to: canvas)
        try send("\t", code: 48, to: canvas)
        XCTAssertEqual(canvas.resourceCounts["pendingGesture"], 0)
        try send(" ", code: 49, to: canvas)
        try send("", code: 53, to: canvas)
        XCTAssertEqual(actions, [.save, .copy, .selection, .close])
        XCTAssertEqual(canvas.document.commands.count, 1, "Escape and Tab discard uncommitted marks")
        XCTAssertEqual(canvas.resourceCounts["pendingGesture"], 0)
    }

    func testKeyboardPenAccumulatesPointsAndCannotLeaveOriginalImageBounds() async throws {
        let canvas = try await makeCanvas()
        defer { canvas.prepareForFinish() }
        canvas.tool = .pen
        try send(" ", code: 49, to: canvas)
        try send("", code: 124, to: canvas)
        try send("", code: 125, to: canvas)
        for _ in 0..<30 { try send("", code: 123, modifiers: .shift, to: canvas) }
        try send(" ", code: 49, to: canvas)
        let item = try XCTUnwrap(canvas.document.commands.first)
        XCTAssertEqual(item.tool, .pen)
        XCTAssertEqual(Array(item.points.prefix(3)), [CGPoint(x: 100, y: 80), CGPoint(x: 100.5, y: 80), CGPoint(x: 100.5, y: 80.5)])
        XCTAssertEqual(item.points.last?.x, 0)
        XCTAssertTrue(item.points.allSatisfy { canvas.bounds.contains($0) || $0.x == canvas.bounds.maxX || $0.y == canvas.bounds.maxY })
    }

    func testSpaceUsesNativeTextModalAndPreservesTheFontSnapshot() async throws {
        _ = NSApplication.shared
        for tool in [AnnotationTool.text, .note] {
            let canvas = try await makeCanvas()
            defer { canvas.prepareForFinish() }
            canvas.tool = tool
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard let window = NSApp.modalWindow, let content = window.contentView,
                          let input = Self.findText(in: content), let add = Self.findButton("添加", in: content) else {
                        XCTFail("Space must present the regular native text modal"); NSApp.abortModal(); return
                    }
                    input.string = "键盘添加\nnative text"
                    input.font = NSFont(name: "Helvetica", size: 24)
                    add.performClick(nil)
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            try send(" ", code: 49, to: canvas)
            let item = try XCTUnwrap(canvas.document.commands.first)
            XCTAssertEqual(item.tool, tool); XCTAssertEqual(item.text, "键盘添加\nnative text")
            XCTAssertEqual(item.font.postScriptName, "Helvetica"); XCTAssertEqual(item.font.pointSize, 24)
            XCTAssertEqual(canvas.resourceCounts["textAlert"], 0)
        }
    }

    func testSessionFinishAbortsNativeTextModalAndCannotAppendAfterReturn() async throws {
        _ = NSApplication.shared
        let canvas = try await makeCanvas()
        canvas.tool = .text
        var modalWasVisible = false
        let closeCanvas: @MainActor @Sendable () -> Void = {
            modalWasVisible = NSApp.modalWindow?.isVisible == true
            canvas.prepareForFinish()
        }
        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated { closeCanvas() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate(); canvas.prepareForFinish() }
        try send(" ", code: 49, to: canvas)
        XCTAssertTrue(modalWasVisible)
        XCTAssertTrue(canvas.document.commands.isEmpty)
        XCTAssertEqual(canvas.resourceCounts.values.reduce(0, +), 0)
        XCTAssertNil(NSApp.modalWindow)
        try send(" ", code: 49, to: canvas)
        XCTAssertTrue(canvas.document.commands.isEmpty)
        XCTAssertEqual(canvas.resourceCounts.values.reduce(0, +), 0)
    }

    func testFinishDrainsSupersededPreviewsAndPreventsLaterInput() async throws {
        let canvas = try await makeCanvas()
        canvas.tool = .step
        for _ in 0..<12 { try send(" ", code: 49, to: canvas) }
        XCTAssertEqual(canvas.resourceCounts["preview"], 12, "Superseded workers remain owned until they return")
        canvas.prepareForFinish()
        await canvas.finishAndDrain()
        XCTAssertEqual(canvas.resourceCounts.values.reduce(0, +), 0)
        XCTAssertTrue((canvas.accessibilityValue() as? String ?? "").contains("已结束"))
        let count = canvas.document.commands.count
        try send(" ", code: 49, to: canvas)
        canvas.refresh()
        XCTAssertEqual(canvas.document.commands.count, count)
        XCTAssertEqual(canvas.resourceCounts.values.reduce(0, +), 0)
    }

    private func makeCanvas() async throws -> AnnotationCanvasView {
        let image = try await Task.detached { () -> CGImage in
            let context = try ImageUtilities.context(width: 400, height: 320)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 320))
            guard let image = context.makeImage() else { throw AppError.imageCreation }
            return image
        }.value
        return AnnotationCanvasView(image: image, size: CGSize(width: 200, height: 160))
    }

    private func send(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], to canvas: AnnotationCanvasView) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        canvas.keyDown(with: event)
    }

    private static func findText(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let result = findText(in: child) { return result } }
        return nil
    }
    private static func findButton(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews { if let result = findButton(title, in: child) { return result } }
        return nil
    }
}
