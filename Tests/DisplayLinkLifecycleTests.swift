// Uses synthetic images and dormant windows to test native display-link teardown, not actual refresh-rate performance.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class DisplayLinkLifecycleTests: XCTestCase {
    func testDormantDriverAndWeakSelectorOwnerReleaseWithoutCallbacks() {
        _ = NSApplication.shared
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        var driver: ActiveDisplayLink? = ActiveDisplayLink { XCTFail("A hidden test window must not produce rendering evidence") }
        weak let weakDriver = driver
        driver?.start(in: view)
        XCTAssertFalse(driver?.isActive ?? true, "Detached views must not allocate a display link")

        window.contentView = view
        driver?.start(in: view)
        driver?.start(in: view)
        XCTAssertTrue(driver?.isActive ?? false)
        XCTAssertLessThanOrEqual(driver?.statistics.maximumFPS ?? Int.max, min(120, window.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60))
        XCTAssertEqual(driver?.statistics.frameCount, 0)
        XCTAssertEqual(driver?.statistics.averageFPS, 0)
        driver?.invalidate()
        driver?.invalidate()
        XCTAssertFalse(driver?.isActive ?? true)
        driver?.start(in: view)
        driver = nil
        XCTAssertNil(weakDriver, "The native display link's selector proxy must hold its owner weakly")
    }

    func testSelectionDetachAndFinishOwnNoDisplayLinks() throws {
        let context = try ImageUtilities.context(width: 40, height: 40)
        let image = try XCTUnwrap(context.makeImage())
        let frame = FrozenFrame(screen: ScreenGeometry(id: 1, frame: CGRect(x: 80, y: 80, width: 20, height: 20), scale: 2), image: image)
        var session: SelectionSession? = SelectionSession()
        weak let weakSession = session
        defer { session?.finish() }
        session?.start(frames: [frame]) { _, _ in XCTFail("Synthetic teardown must not output a screenshot") }
        XCTAssertEqual(session?.displayLinkCount, 1)
        try autoreleasepool {
            let window = try XCTUnwrap(session?.windows.first)
            let view = try XCTUnwrap(window.contentView as? SelectionView)
            view.selection = CGRect(x: 2, y: 3, width: 6, height: 7)
            XCTAssertEqual(view.selection.width, 6, "Selection data must update before the display callback")
            window.contentView = nil
            XCTAssertEqual(view.displayLinkCount, 0, "Detaching must unschedule the view's native link synchronously")
        }
        session?.finish()
        session?.start(frames: [frame]) { _, _ in XCTFail("Synthetic teardown must not output a screenshot") }
        XCTAssertEqual(session?.displayLinkCount, 1)
        session?.finish()
        XCTAssertEqual(session?.displayLinkCount, 0)
        XCTAssertEqual(session?.windowCount, 0)
        XCTAssertEqual(session?.monitorCount, 0)
        XCTAssertEqual(session?.frameCount, 0)
        XCTAssertEqual(session?.displayLinkStatistics.count, 1, "Finish must preserve the timing snapshot without retaining the link")
        session = nil
        XCTAssertNil(weakSession)
    }
}
