// Checks guide docking geometry and that only an explicit "开始使用" completes onboarding.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class PermissionGuideTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1_512, height: 944)
    private let size = CGSize(width: 460, height: 172)

    func testGuideDocksBelowSettingsNearTheListPane() {
        let settings = CGRect(x: 300, y: 300, width: 780, height: 560)
        let frame = PermissionGuide.placement(size: size, settings: settings, visible: visible)
        XCTAssertEqual(frame.maxY, settings.minY - 12)
        XCTAssertGreaterThan(frame.midX, settings.midX, "The privacy list sits in the right-hand pane")
        XCTAssertTrue(visible.contains(frame))
    }

    func testGuideMovesBesideSettingsWhenThereIsNoRoomBelow() {
        let settings = CGRect(x: 120, y: 40, width: 760, height: 840)
        let frame = PermissionGuide.placement(size: size, settings: settings, visible: visible)
        XCTAssertEqual(frame.minX, settings.maxX + 12)
        XCTAssertTrue(visible.contains(frame))
    }

    func testGuideFallsBackToTheScreenWhenSettingsIsNotOpenYet() {
        let frame = PermissionGuide.placement(size: size, settings: nil, visible: visible)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 1)
        XCTAssertTrue(visible.contains(frame))
    }

    func testPermissionNamesMapToGuides() {
        XCTAssertEqual(PermissionKind.matching("屏幕录制"), .screenRecording)
        XCTAssertEqual(PermissionKind.matching("屏幕与系统音频录制"), .screenRecording)
        XCTAssertEqual(PermissionKind.matching("辅助功能"), .accessibility)
        XCTAssertNil(PermissionKind.matching("麦克风"))
        XCTAssertTrue(PermissionKind.screenRecording.needsRelaunchAfterGrant)
        XCTAssertFalse(PermissionKind.accessibility.needsRelaunchAfterGrant)
    }

    func testClosingWelcomeKeepsOnboardingIncomplete() throws {
        let suite = "niko-shot.welcome-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var completions = 0
        var controller: WelcomeWindowController? = WelcomeWindowController(onDemo: {}, onComplete: { completions += 1 },
            defaults: defaults, shortcuts: [("区域截图", "⇧⌘A")])
        weak let weakController = controller
        controller?.show(); controller?.show()
        XCTAssertEqual(controller?.windowCount, 1)
        controller?.close()
        XCTAssertEqual(controller?.windowCount, 0)
        XCTAssertFalse(defaults.bool(forKey: WelcomeWindowController.completionKey))
        XCTAssertEqual(completions, 0)
        controller = nil
        XCTAssertNil(weakController)
    }
}
