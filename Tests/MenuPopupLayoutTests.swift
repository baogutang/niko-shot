import AppKit
import SwiftUI
import XCTest
@testable import NikoShot

@MainActor
final class MenuPopupLayoutTests: XCTestCase {
    func testExternalDisplaysAboveBelowAndLeftKeepTheEntirePopoverInsideTheirOwnVisibleArea() {
        for origin in [CGPoint(x: 1440, y: 0), CGPoint(x: -1280, y: 180), CGPoint(x: 0, y: 900), CGPoint(x: 0, y: -720)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1280, height: 720))
            let visible = CGRect(x: screen.minX, y: screen.minY + 48, width: 1280, height: 648)
            let safe = MenuPopupLayout.safeFrame(screen: screen, visible: visible, safeTop: 0)
            let size = MenuPopupLayout.contentSize(in: safe)
            // 含 AppKit 原生箭头/边框，初始 frame 模拟副屏错误定位到屏幕上方。
            let requested = CGRect(x: screen.maxX - 110, y: screen.maxY - 160,
                width: size.width + 12, height: size.height + 24)
            let placed = MenuPopupLayout.clampedFrame(requested, within: safe)
            XCTAssertTrue(safe.contains(placed))
            XCTAssertLessThanOrEqual(placed.maxY, visible.maxY - 8)
        }
    }

    func testSmallScaledDisplayAndNotchReserveChromeAndAllowTheContentToScroll() {
        let screen = CGRect(x: 0, y: 0, width: 1024, height: 600)
        let safe = MenuPopupLayout.safeFrame(screen: screen, visible: CGRect(x: 0, y: 36, width: 1024, height: 540), safeTop: 38)
        let size = MenuPopupLayout.contentSize(in: safe)
        XCTAssertLessThan(size.height, 512)
        XCTAssertLessThanOrEqual(size.height + 24, safe.height)
        XCTAssertLessThanOrEqual(size.width + 12, safe.width)
        XCTAssertLessThanOrEqual(safe.maxY, screen.maxY - 38 - 8)
    }

    func testRecentCaptureUpdatesCannotChangeTheHostingSizeOrHideHeaderAndFooter() async throws {
        let model = MenuModel()
        let size = CGSize(width: 344, height: 340)
        let host = NSHostingView(rootView: MenuContent(model: model, hotkeys: nil, action: { _ in }, settings: {}, presentationSize: size))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for count in [0, 3, 0] {
            model.recents = (0..<count).map { index in
                HistoryRecord(id: UUID(), createdAt: .now, path: "/tmp/niko-menu-fixture-\(index).png", thumbnail: Data(),
                    width: 1200, height: 800, appBundleID: "", captureKind: "region")
            }
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.frame.size, size)
            XCTAssertEqual(host.fittingSize.width, size.width, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, size.height, accuracy: 1)
        }
    }

    func testNativePopoverArrowAndHostingViewBothFitAtTheTopRightOfTheScreen() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let safe = MenuPopupLayout.safeFrame(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top)
        let size = MenuPopupLayout.contentSize(in: safe)
        let anchor = NSWindow(contentRect: CGRect(x: safe.maxX - 24, y: safe.maxY - 24, width: 24, height: 24),
            styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        let button = NSButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        anchor.contentView = button
        let popup = NSPopover()
        popup.animates = false
        popup.behavior = .transient
        let controller = NSHostingController(rootView: MenuContent(model: MenuModel(), hotkeys: nil,
            action: { _ in }, settings: {}, presentationSize: size))
        controller.sizingOptions = []
        controller.preferredContentSize = size
        popup.contentViewController = controller
        popup.contentSize = size
        defer {
            popup.close(); popup.contentViewController = nil; anchor.contentView = nil; anchor.close()
            NSApp.activate(ignoringOtherApps: true)
        }
        anchor.orderFront(nil)
        popup.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        try await Task.sleep(for: .milliseconds(50))
        let window = try XCTUnwrap(controller.view.window)
        window.setFrameOrigin(MenuPopupLayout.clampedFrame(window.frame, within: safe).origin)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(safe.contains(window.frame), "The native arrow/chrome must also remain visible")
        let content = window.convertToScreen(controller.view.convert(controller.view.bounds, to: nil))
        XCTAssertTrue(window.frame.contains(content), "The hosting root must not be cropped by its own popup")
        XCTAssertEqual(controller.view.bounds.height, size.height, accuracy: 1)
        popup.close(); popup.contentViewController = nil; anchor.contentView = nil; anchor.close()
        NSApp.activate(ignoringOtherApps: true)
        // AppKit 在下一轮事件分发才交还 popover 的键盘会话；不能把它留给后续输入测试。
        try await Task.sleep(for: .milliseconds(150))
    }
}
