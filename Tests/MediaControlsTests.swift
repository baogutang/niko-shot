// Verifies native media-panel teardown using idle sessions without starting capture or requesting consent.
import AppKit
import AVFoundation
import XCTest
@testable import NikoShot

@MainActor
final class MediaControlsTests: XCTestCase {
    func testIdleRecordingHUDClosesAndReleasesController() throws {
        let session = RecordingSession()
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        var controller: RecordingControlBarController? = RecordingControlBarController(
            session: session, onStop: {}, onCancel: {}, onCamera: { _ in }
        )
        weak let weakController = controller
        weak var shownPanel: NSWindow?
        defer { controller?.close() }

        controller?.show()
        controller?.show()
        XCTAssertEqual(controller?.windowCount, 1, "Repeated show must reuse the panel")
        try autoreleasepool {
            let panel = try XCTUnwrap(NSApplication.shared.windows.first {
                !existingWindows.contains(ObjectIdentifier($0)) && $0.accessibilityLabel() == "录屏控制条"
            })
            shownPanel = panel
            XCTAssertTrue(panel.canBecomeKey, "Controls must accept keyboard focus after user interaction")
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        }
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.cameraSession)

        controller?.close()
        controller?.close()
        XCTAssertEqual(controller?.windowCount, 0)
        XCTAssertFalse(shownPanel?.isVisible ?? false)
        controller = nil
        XCTAssertNil(weakController, "Closed HUD must not retain its controller through view callbacks")
        XCTAssertEqual(session.state, .idle)
    }

    func testShortOrInactiveRecordingCancelsWithoutConfirmation() {
        var cancels = 0
        let controller = RecordingControlBarController(session: RecordingSession(), onStop: {}, onCancel: { cancels += 1 }, onCamera: { _ in })
        controller.requestCancel()
        XCTAssertEqual(cancels, 1, "Only recordings longer than five seconds ask before discarding")
        controller.close()
    }

    func testEmptyCameraPreviewClosesAndReleasesControllerWithoutStartingSession() throws {
        let session = AVCaptureSession()
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        var controller: CameraPiPController? = CameraPiPController()
        weak let weakController = controller
        weak var shownPanel: NSWindow?
        defer { controller?.close() }

        controller?.show(session: session)
        controller?.show(session: session)
        XCTAssertEqual(controller?.windowCount, 1, "Repeated show must reuse the preview")
        try autoreleasepool {
            let panel = try XCTUnwrap(NSApplication.shared.windows.first {
                !existingWindows.contains(ObjectIdentifier($0)) && $0.accessibilityLabel() == "摄像头画中画预览，拖动移动，双指缩放"
            })
            shownPanel = panel
            XCTAssertTrue(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            let closeButton = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSButton }.first)
            XCTAssertEqual(closeButton.keyEquivalent, "\u{1b}")
            XCTAssertTrue(closeButton.keyEquivalentModifierMask.isEmpty)
        }
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.inputs.isEmpty)
        XCTAssertTrue(session.outputs.isEmpty)

        controller?.close()
        controller?.close()
        XCTAssertEqual(controller?.windowCount, 0)
        XCTAssertFalse(shownPanel?.isVisible ?? false)
        controller = nil
        XCTAssertNil(weakController, "Closed preview must release its controller")
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.inputs.isEmpty)
        XCTAssertTrue(session.outputs.isEmpty)
    }
}
