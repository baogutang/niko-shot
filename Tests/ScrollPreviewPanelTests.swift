// Exercises native scroll-preview placement, bounded-image drawing, observation, following, and release without TCC.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class ScrollPreviewPanelTests: XCTestCase {
    func testPlacementPrefersClearRightThenLeftAndAvoidsControlBar() {
        let screen = CGRect(x: -1200, y: 80, width: 1200, height: 800)
        let size = CGSize(width: 260, height: 420)
        let target = CGRect(x: -850, y: 210, width: 300, height: 440)
        let right = ScrollPreviewPanelController.placement(near: target, avoiding: nil, in: screen, size: size)
        XCTAssertEqual(right.minX, target.maxX + 12)
        XCTAssertTrue(screen.contains(right)); XCTAssertFalse(right.intersects(target))
        let blockedRight = CGRect(x: right.minX - 2, y: screen.minY, width: right.width + 4, height: screen.height)
        let left = ScrollPreviewPanelController.placement(near: target, avoiding: blockedRight, in: screen, size: size)
        XCTAssertEqual(left.maxX, target.minX - 12)
        XCTAssertFalse(left.intersects(target)); XCTAssertFalse(left.intersects(blockedRight))
        let narrow = CGRect(x: 0, y: 0, width: 500, height: 460)
        let fallback = ScrollPreviewPanelController.placement(near: narrow.insetBy(dx: 20, dy: 20),
            avoiding: CGRect(x: 0, y: 0, width: 500, height: 60), in: narrow, size: size)
        XCTAssertTrue(narrow.contains(fallback))
        XCTAssertTrue(fallback.minX == narrow.minX || fallback.maxX == narrow.maxX)
    }

    func testShowNeverTakesFocusAndCloseReleasesImageAndObservers() async throws {
        let state = ScrollControlState()
        state.preview = try await snapshot(height: 900, frames: 3)
        state.frames = 3; state.height = 9000
        let existingKey = NSApplication.shared.keyWindow
        var controller: ScrollPreviewPanelController? = ScrollPreviewPanelController(state: state)
        weak let weakController = controller
        controller?.show(near: target())
        let panel = try shownPanel(), view = try imageView(in: panel)
        XCTAssertEqual(controller?.windowCount, 1)
        XCTAssertEqual(controller?.diagnostics.observerCount, 3)
        XCTAssertEqual(controller?.diagnostics.imageSize, CGSize(width: 120, height: 900))
        XCTAssertEqual(controller?.diagnostics.sourceSize, CGSize(width: 1200, height: 9000))
        XCTAssertEqual(controller?.diagnostics.frames, 3)
        XCTAssertEqual(controller?.diagnostics.imageCount, 1)
        XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(controller?.panelFrame, panel.frame)
        XCTAssertFalse(panel.frame.intersects(target()))
        if let visible = panel.screen?.visibleFrame { XCTAssertTrue(visible.contains(panel.frame)) }
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(NSApplication.shared.keyWindow === existingKey)
        controller?.show(near: target()); controller?.reposition(near: target())
        XCTAssertEqual(controller?.windowCount, 1)
        controller?.close(); controller?.close()
        XCTAssertEqual(controller?.windowCount, 0); XCTAssertNil(controller?.panelFrame)
        XCTAssertEqual(controller?.diagnostics.imageCount, 0); XCTAssertEqual(controller?.diagnostics.observerCount, 0)
        XCTAssertFalse(view.hasImage, "Closing must release the direct CGImage reference even if a view is inspected")
        XCTAssertNil(panel.contentView); XCTAssertFalse(panel.isVisible)
        controller = nil
        XCTAssertNil(weakController)
    }

    func testDroppingShownControllerClearsNativeImageAndPanel() async throws {
        let state = ScrollControlState()
        state.preview = try await snapshot(height: 600, frames: 1)
        var controller: ScrollPreviewPanelController? = ScrollPreviewPanelController(state: state)
        weak let weakController = controller
        controller?.show(near: target())
        let panel = try shownPanel(), image = try imageView(in: panel)
        XCTAssertTrue(image.hasImage)
        controller = nil
        XCTAssertNil(weakController)
        XCTAssertFalse(panel.isVisible); XCTAssertNil(panel.contentView)
        XCTAssertFalse(image.hasImage)
        XCTAssertNotNil(state.preview, "Closing preview alone must preserve the capture coordinator's accepted snapshot")
    }

    func testAcceptedUpdatesFollowTailUntilUserBrowsesAndLatestRestoresFollowing() async throws {
        let state = ScrollControlState(), controller = ScrollPreviewPanelController(state: state)
        defer { controller.close() }
        controller.show(near: target())
        state.preview = try await snapshot(height: 700, frames: 1)
        state.frames = 1; state.height = 7000
        try await waitUntil { controller.diagnostics.frames == 1 }
        XCTAssertGreaterThan(controller.diagnostics.maximumScrollOffset, 0)
        XCTAssertEqual(controller.diagnostics.scrollOffset, controller.diagnostics.maximumScrollOffset, accuracy: 1)
        let panel = try shownPanel(), scroll = try scrollView(in: panel)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 90))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertFalse(controller.diagnostics.isFollowingTail)
        let browsingOffset = controller.diagnostics.scrollOffset
        state.preview = try await snapshot(height: 1000, frames: 2)
        state.frames = 2; state.height = 10000
        try await waitUntil { controller.diagnostics.frames == 2 }
        XCTAssertEqual(controller.diagnostics.scrollOffset, browsingOffset, accuracy: 1,
                       "A new segment must not jump someone browsing an earlier portion back to the tail")
        let latest = try XCTUnwrap(allViews(in: try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "回到长截图最新内容" })
        XCTAssertFalse(latest.isHidden)
        latest.performClick(nil)
        XCTAssertTrue(controller.diagnostics.isFollowingTail)
        XCTAssertEqual(controller.diagnostics.scrollOffset, controller.diagnostics.maximumScrollOffset, accuracy: 1)
        let updates = controller.diagnostics.updateCount
        state.status = "正在确认底部"; state.isPaused = true
        try await waitUntil { allText(in: panel).contains("正在确认底部") }
        XCTAssertEqual(controller.diagnostics.updateCount, updates, "Status and duplicate samples must not replace the accepted image")
        XCTAssertEqual(controller.diagnostics.scrollOffset, controller.diagnostics.maximumScrollOffset, accuracy: 1)
    }

    func testWholeImageShowsBothEndsOfRealThumbnailWithoutChangingFocus() async throws {
        let state = ScrollControlState()
        state.preview = try await snapshot(height: 900, frames: 4)
        state.frames = 4; state.height = 9000
        let controller = ScrollPreviewPanelController(state: state)
        defer { controller.close() }
        controller.show(near: target())
        let panel = try shownPanel(), key = NSApplication.shared.keyWindow
        let mode = try XCTUnwrap(allViews(in: try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSSegmentedControl }.first)
        mode.selectedSegment = 0; XCTAssertTrue(mode.sendAction(mode.action, to: mode.target))
        XCTAssertTrue(controller.diagnostics.isShowingWholeImage)
        XCTAssertEqual(controller.diagnostics.maximumScrollOffset, 0, accuracy: 1)
        let image = try imageView(in: panel)
        let bitmap = try XCTUnwrap(image.bitmapImageRepForCachingDisplay(in: image.bounds))
        image.cacheDisplay(in: image.bounds, to: bitmap)
        let center = bitmap.pixelsWide / 2
        let colors = (0..<bitmap.pixelsHigh).compactMap { bitmap.colorAt(x: center, y: $0)?.usingColorSpace(.deviceRGB) }
        XCTAssertTrue(colors.prefix(colors.count / 3).contains { $0.redComponent > 0.8 && $0.blueComponent < 0.2 },
                      "The complete preview must retain the first red band at the top")
        XCTAssertTrue(colors.suffix(colors.count / 3).contains { $0.blueComponent > 0.8 && $0.redComponent < 0.2 },
                      "The complete preview must retain the accepted blue bottom band")
        XCTAssertTrue(NSApplication.shared.keyWindow === key)
        XCTAssertTrue(allText(in: panel).contains { $0.contains("已拼接 4 段") })
    }

    func testUnavailablePreviewAndClosedObservationNeverReopenPanel() async throws {
        let state = ScrollControlState(), controller = ScrollPreviewPanelController(state: state)
        controller.show(near: target())
        let panel = try shownPanel()
        XCTAssertTrue(allText(in: panel).contains("正在准备首张画面…"))
        state.frames = 2; state.height = 5000
        try await waitUntil { allText(in: panel).contains("预览暂时不可用\n已捕获内容仍可完成") }
        XCTAssertEqual(controller.diagnostics.imageCount, 0)
        state.status = "仅更新状态"
        controller.close()
        state.preview = try await snapshot(height: 1000, frames: 3)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.windowCount, 0); XCTAssertEqual(controller.diagnostics.observerCount, 0)
        XCTAssertEqual(controller.diagnostics.imageCount, 0)
        controller.show(near: target())
        XCTAssertEqual(controller.diagnostics.frames, 3)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(controller.windowCount, 0, "Screen topology changes must clean up this panel and its observer")
        XCTAssertEqual(controller.diagnostics.observerCount, 0)
    }

    func testOnlyExplicitUserCloseNotifiesAndReopeningRetainsCallback() throws {
        let controller = ScrollPreviewPanelController(state: ScrollControlState())
        defer { controller.close() }
        var userClosures = 0
        controller.onUserClose = {
            XCTAssertEqual(controller.windowCount, 0, "The callback sees an already released panel")
            userClosures += 1
        }
        defer { controller.onUserClose = nil }
        controller.show(near: target()); controller.close()
        XCTAssertEqual(userClosures, 0)
        controller.show(near: target())
        let panel = try shownPanel()
        let close = try XCTUnwrap(panel.contentView.flatMap { allViews(in: $0).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "关闭长截图预览" } })
        close.performClick(nil)
        XCTAssertEqual(userClosures, 1); XCTAssertEqual(controller.windowCount, 0)
        controller.show(near: target())
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(userClosures, 1); XCTAssertEqual(controller.windowCount, 0)
    }

    private func target() -> CGRect {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return CGRect(x: screen.midX - 180, y: screen.midY - 170, width: 360, height: 340)
    }
    private func shownPanel() throws -> NSWindow {
        try XCTUnwrap(NSApplication.shared.windows.first { $0.isVisible && $0.accessibilityLabel() == "长截图实时预览" })
    }
    private func allViews(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { allViews(in: $0) } }
    private func allText(in panel: NSWindow) -> [String] {
        panel.contentView.map { allViews(in: $0).compactMap { ($0 as? NSTextField)?.stringValue } } ?? []
    }
    private func imageView(in panel: NSWindow) throws -> ScrollPreviewImageView {
        try XCTUnwrap(panel.contentView.flatMap { allViews(in: $0).compactMap { $0 as? ScrollPreviewImageView }.first })
    }
    private func scrollView(in panel: NSWindow) throws -> NSScrollView {
        try XCTUnwrap(panel.contentView.flatMap { allViews(in: $0).compactMap { $0 as? NSScrollView }.first })
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Native observation must update without a timer")
    }
    private func snapshot(height: Int, frames: Int) async throws -> ScrollPreviewSnapshot {
        try await Task.detached {
            guard let context = CGContext(data: nil, width: 120, height: height, bitsPerComponent: 8, bytesPerRow: 480,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw NSError(domain: "ScrollPreviewFixture", code: 1)
            }
            context.setFillColor(CGColor(gray: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: height))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: height - 60, width: 120, height: 60))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
            guard let image = context.makeImage() else { throw NSError(domain: "ScrollPreviewFixture", code: 2) }
            return ScrollPreviewSnapshot(image: image, sourceWidth: 1200, sourceHeight: height * 10, frames: frames)
        }.value
    }
}
