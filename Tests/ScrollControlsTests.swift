// Verifies scroll-HUD reuse, recovery expansion and teardown without capture or Accessibility operations.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class ScrollControlsTests: XCTestCase {
    func testRepeatedShowAndRecoveryCloseReleaseTheController() throws {
        let state = ScrollControlState()
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        var controller: ScrollControlBarController? = ScrollControlBarController(
            state: state, onFinish: {}, onCancel: {}, onRetry: {}, onManualOverlap: { _ in }, onManualMode: {}
        )
        weak let weakController = controller
        weak var shownPanel: NSWindow?
        defer { controller?.close() }

        controller?.show(near: CGRect(x: 200, y: 200, width: 300, height: 400))
        controller?.show()
        XCTAssertEqual(controller?.windowCount, 1)
        try autoreleasepool {
            let panel = try XCTUnwrap(NSApplication.shared.windows.first {
                !existing.contains(ObjectIdentifier($0)) && $0.accessibilityLabel() == "长截图控制条"
            })
            shownPanel = panel
            XCTAssertTrue(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            let initialHeight = panel.frame.height
            state.isPaused = true
            state.isMatching = true
            state.correlation = 0.82
            state.maximumOverlap = 299
            controller?.show()
            XCTAssertEqual(controller?.windowCount, 1, "Recovery must reuse the existing panel")
            XCTAssertGreaterThan(panel.frame.height, initialHeight, "Seam confirmation needs room for editable overlap controls")
            if let visible = panel.screen?.visibleFrame { XCTAssertTrue(visible.contains(panel.frame)) }
        }

        controller?.close()
        controller?.close()
        XCTAssertEqual(controller?.windowCount, 0)
        XCTAssertFalse(shownPanel?.isVisible ?? false)
        controller = nil
        XCTAssertNil(weakController)
    }

    func testDroppingIdleControllerClosesItsPanel() throws {
        let state = ScrollControlState()
        state.mode = .manual
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        var controller: ScrollControlBarController? = ScrollControlBarController(
            state: state, onFinish: {}, onCancel: {}, onRetry: {}, onManualOverlap: { _ in }, onManualMode: {}
        )
        weak let weakController = controller
        weak var shownPanel: NSWindow?
        controller?.show()
        XCTAssertEqual(controller?.windowCount, 1)
        try autoreleasepool {
            shownPanel = try XCTUnwrap(NSApplication.shared.windows.first {
                !existing.contains(ObjectIdentifier($0)) && $0.accessibilityLabel() == "长截图控制条"
            })
        }

        controller = nil
        XCTAssertNil(weakController, "View callbacks must not retain an abandoned controller")
        XCTAssertFalse(shownPanel?.isVisible ?? false, "Fallback deinitialization must hide the native panel")
        XCTAssertEqual(state.frames, 0)
        XCTAssertEqual(state.height, 0)
    }
}
