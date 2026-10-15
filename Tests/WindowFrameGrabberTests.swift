// 不请求权限：验证两种 WindowServer 模式、点/像素边界以及多屏选择。
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class WindowFrameGrabberTests: XCTestCase {
    func testWindowAndBelowOverlayUseDistinctOptionsAndPreservePointCoordinates() async throws {
        let image = try await ScrollImageFixture().solid(width: 40, height: 60)
        var requests: [(CGRect, CGWindowListOption, CGWindowID)] = []
        let grabber = WindowFrameGrabber { rect, option, id in requests.append((rect, option, id)); return image }
        let rect = CGRect(x: -500, y: -200, width: 20, height: 30)
        XCTAssertTrue(grabber.captureWindow(windowID: 31, rect: rect) === image)
        XCTAssertTrue(grabber.captureRegionBelowOwnWindow(ownWindowID: 72, rect: rect) === image)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].0, rect); XCTAssertEqual(requests[0].1, .optionIncludingWindow); XCTAssertEqual(requests[0].2, 31)
        XCTAssertEqual(requests[1].0, rect); XCTAssertEqual(requests[1].1, .optionOnScreenBelowWindow); XCTAssertEqual(requests[1].2, 72)
    }

    func testInvalidGeometryNeverCallsTheWindowServer() {
        var calls = 0
        let grabber = WindowFrameGrabber { _, _, _ in calls += 1; return nil }
        XCTAssertNil(grabber.captureWindow(windowID: 0, rect: CGRect(x: 0, y: 0, width: 20, height: 20)))
        XCTAssertNil(grabber.captureWindow(windowID: 2, rect: .infinite))
        XCTAssertNil(grabber.captureRegionBelowOwnWindow(ownWindowID: 2, rect: .zero))
        XCTAssertEqual(calls, 0)
    }

    func testMixedDisplayGeometryUsesMouseScreenScaleAndPrimaryTopOnlyForYFlip() async throws {
        let primary = ScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1_440, height: 900), scale: 2, safeTop: 32)
        let secondary = ScreenGeometry(id: 2, frame: CGRect(x: -1_920, y: 240, width: 1_920, height: 1_080), scale: 1)
        XCTAssertEqual(WindowFrameGrabber.screenForMouse(at: CGPoint(x: -700, y: 1_100), screens: [primary, secondary]), secondary)
        let context = CaptureContext(screen: secondary, localRect: CGRect(x: 30, y: 80, width: 320, height: 240))
        XCTAssertEqual(WindowFrameGrabber.windowServerRect(context, primaryTop: 900), CGRect(x: -1_890, y: -340, width: 320, height: 240))
        let nominal = try await ScrollImageFixture().solid(width: 20, height: 30)
        let retina = try WindowFrameGrabber.normalized(nominal, rect: CGRect(x: 0, y: 0, width: 20, height: 30), scale: 2)
        XCTAssertEqual(retina.width, 40); XCTAssertEqual(retina.height, 60)
        let native = try WindowFrameGrabber.normalized(retina, rect: CGRect(x: 0, y: 0, width: 20, height: 30), scale: 2)
        XCTAssertTrue(native === retina)
    }

    func testAutomaticScrollChecksTheInputWindowAndIgnoresClickThroughChrome() async throws {
        let frame = CGRect(x: 220, y: 300, width: 320, height: 240)
        let target = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let blocker = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false; blocker.isReleasedWhenClosed = false
        blocker.level = .floating
        defer { blocker.close(); target.close() }
        target.orderFrontRegardless()
        let point = CGPoint(x: frame.midX, y: frame.midY), id = CGWindowID(target.windowNumber)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNoThrow(try CaptureEngine.checkScrollDestination(windowID: id, point: point))
        blocker.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertThrowsError(try CaptureEngine.checkScrollDestination(windowID: id, point: point))
        blocker.ignoresMouseEvents = true
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNoThrow(try CaptureEngine.checkScrollDestination(windowID: id, point: point))
    }

    func testMovingWindowPastDisplayEdgeDoesNotChangeItsViewportDimensions() {
        let screen = ScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1_440, height: 900), scale: 2)
        let context = CaptureContext(screen: screen, localRect: CGRect(x: -100, y: 80, width: 320, height: 240), kind: "window")
        XCTAssertEqual(WindowFrameGrabber.windowServerRect(context, primaryTop: 900), CGRect(x: -100, y: 80, width: 320, height: 240))
    }
}
