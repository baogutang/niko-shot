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

    func testDraggingTheIconDragsTheAppNotTheGuidePanel() throws {
        let icon = AppIconDragView(frame: CGRect(x: 0, y: 0, width: 76, height: 76))
        XCTAssertFalse(icon.mouseDownCanMoveWindow, "A movable-by-background panel would otherwise move instead of dragging")
        let bundle = URL(fileURLWithPath: "/Applications/niko-shot.app", isDirectory: true)
        let item = icon.makeDraggingItem(bundleURL: bundle)
        let writer = try XCTUnwrap(item.item as? NSURL)
        XCTAssertEqual(writer as URL, bundle)
        let types = writer.writableTypes(for: NSPasteboard(name: NSPasteboard.Name("niko-shot-drag-\(UUID().uuidString)")))
        XCTAssertTrue(types.contains(.fileURL), "Privacy lists accept a dropped application file")
    }

    func testIconInsideTheGuidePanelIsTheDragSourceUnderThePointer() throws {
        let opener = PermissionGuide.shared.openSettings
        PermissionGuide.shared.openSettings = { _ in }
        PermissionGuide.shared.present(.accessibility)
        defer { PermissionGuide.shared.dismiss(); PermissionGuide.shared.openSettings = opener }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.accessibilityLabel() == "权限授权引导" && $0.isVisible })
        XCTAssertTrue(panel.isMovableByWindowBackground)
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let icon = try XCTUnwrap(Self.views(in: content).compactMap { $0 as? AppIconDragView }.first)
        let center = icon.convert(CGPoint(x: icon.bounds.midX, y: icon.bounds.midY), to: nil)
        // hitTest takes a point in the receiver's superview, as NSWindow uses it for a real click.
        let frameView = try XCTUnwrap(content.superview)
        let hit = frameView.hitTest(frameView.convert(center, from: nil))
        XCTAssertTrue(hit === icon, "The icon, not the panel background, receives the drag")
        XCTAssertFalse(hit?.mouseDownCanMoveWindow ?? true)
    }

    func testScreenRecordingGrantIsNoticedBeforeARelaunch() {
        let other: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: 4242), kCGWindowLayer as String: NSNumber(value: 0),
                                    kCGWindowOwnerName as String: "系统设置", kCGWindowName as String: "隐私与安全性"]
        XCTAssertTrue(ScreenRecordingProbe.otherWindowTitlesAreReadable([other], ownPID: 1))
        var hidden = other; hidden.removeValue(forKey: kCGWindowName as String)
        XCTAssertFalse(ScreenRecordingProbe.otherWindowTitlesAreReadable([hidden], ownPID: 1), "Titles are hidden without consent")
        XCTAssertFalse(ScreenRecordingProbe.otherWindowTitlesAreReadable([other], ownPID: 4242), "Our own windows prove nothing")
        var dock = other; dock[kCGWindowOwnerName as String] = "Dock"
        XCTAssertFalse(ScreenRecordingProbe.otherWindowTitlesAreReadable([dock], ownPID: 1))
        var menu = other; menu[kCGWindowLayer as String] = NSNumber(value: 25)
        XCTAssertFalse(ScreenRecordingProbe.otherWindowTitlesAreReadable([menu], ownPID: 1))
    }

    private static func views(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views(in: $0) } }

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
