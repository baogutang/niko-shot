// Verifies that capture toolbar hints open above the toolbar's own screen-saver-level window.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class HUDTooltipTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run {
            HUDTooltip.shared.hide()
            HUDTooltip.shared.restingDelay = .milliseconds(380)
        }
        try await super.tearDown()
    }

    private func spin(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }

    private func hoverEvent(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             trackingNumber: 0, userData: nil))
    }

    func testHoveringAToolShowsItsNameAndKeyAboveTheCaptureOverlay() throws {
        HUDTooltip.shared.restingDelay = .zero
        let controller = ToolbarController(onTool: { _ in }, onAction: { _ in })
        defer { controller.close() }
        let screen = try XCTUnwrap(NSScreen.main)
        controller.show(near: CGRect(x: screen.frame.midX - 200, y: screen.frame.midY, width: 400, height: 200), screenFrame: screen.frame)
        let rectangle = try XCTUnwrap(controller.button(for: AnnotationTool.rectangle))
        let window = try XCTUnwrap(rectangle.window)
        XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.screenSaver.rawValue, "The toolbar rides above the frozen screen")

        rectangle.mouseEntered(with: try hoverEvent(.mouseEntered, in: window))
        spin(0.15)
        XCTAssertTrue(HUDTooltip.shared.isVisible)
        XCTAssertEqual(HUDTooltip.shared.text, "矩形   1")
        let tip = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.ignoresMouseEvents && $0.level.rawValue == window.level.rawValue + 1 })
        let button = window.convertToScreen(rectangle.convert(rectangle.bounds, to: nil))
        XCTAssertGreaterThanOrEqual(tip.frame.minY, button.maxY, "The hint sits above the button, not on it")

        // Moving along the bar swaps the hint without waiting again.
        HUDTooltip.shared.restingDelay = .seconds(5)
        let done = try XCTUnwrap(controller.button(for: ToolbarAction.copy))
        rectangle.mouseExited(with: try hoverEvent(.mouseExited, in: window))
        done.mouseEntered(with: try hoverEvent(.mouseEntered, in: window))
        spin(0.15)
        XCTAssertTrue(HUDTooltip.shared.isVisible)
        XCTAssertTrue(HUDTooltip.shared.text.hasPrefix("完成并复制"))
        XCTAssertTrue(HUDTooltip.shared.text.contains("↩"))

        done.mouseExited(with: try hoverEvent(.mouseExited, in: window))
        XCTAssertFalse(HUDTooltip.shared.isVisible)
    }

    func testClosingTheToolbarTakesItsHintAway() throws {
        HUDTooltip.shared.restingDelay = .zero
        let controller = ToolbarController(onTool: { _ in }, onAction: { _ in })
        let screen = try XCTUnwrap(NSScreen.main)
        controller.show(near: CGRect(x: screen.frame.midX - 200, y: screen.frame.midY, width: 400, height: 200), screenFrame: screen.frame)
        let undo = try XCTUnwrap(controller.button(for: ToolbarAction.undo))
        undo.mouseEntered(with: try hoverEvent(.mouseEntered, in: try XCTUnwrap(undo.window)))
        spin(0.15)
        XCTAssertTrue(HUDTooltip.shared.isVisible, "Disabled buttons still explain themselves")
        controller.close()
        XCTAssertFalse(HUDTooltip.shared.isVisible)
    }

    func testHintStaysOnScreenAndDropsBelowNearTheTop() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 700), size = CGSize(width: 120, height: 26)
        let middle = HUDTooltip.frame(size: size, anchor: CGRect(x: 400, y: 300, width: 30, height: 30), visible: visible)
        XCTAssertEqual(middle, CGRect(x: 355, y: 336, width: 120, height: 26))
        let top = HUDTooltip.frame(size: size, anchor: CGRect(x: 400, y: 680, width: 30, height: 20), visible: visible)
        XCTAssertEqual(top.maxY, 674, "Below the button when there is no room above")
        let edge = HUDTooltip.frame(size: size, anchor: CGRect(x: 985, y: 300, width: 15, height: 30), visible: visible)
        XCTAssertEqual(edge.maxX, 996)
    }
}
