// 不请求权限：验证两种 WindowServer 模式、点/像素边界以及多屏选择。
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class WindowFrameGrabberTests: XCTestCase {
    func testWindowAndBelowOverlayUseDistinctOptionsAndPreservePointCoordinates() async throws {
        let image = try await ScrollImageFixture().solid(width: 40, height: 60)
        let log = RequestLog()
        let grabber = WindowFrameGrabber { rect, option, id in log.record(rect, option, id); return image }
        let rect = CGRect(x: -500, y: -200, width: 20, height: 30)
        let window = try await grabber.captureWindow(windowID: 31, rect: rect)
        let below = try await grabber.captureRegionBelowOwnWindow(ownWindowID: 72, rect: rect)
        XCTAssertTrue(window === image); XCTAssertTrue(below === image)
        let requests = log.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].rect, rect); XCTAssertEqual(requests[0].option, .optionIncludingWindow); XCTAssertEqual(requests[0].id, 31)
        XCTAssertEqual(requests[1].rect, rect); XCTAssertEqual(requests[1].option, .optionOnScreenBelowWindow); XCTAssertEqual(requests[1].id, 72)
        XCTAssertFalse(requests.contains { $0.onMain }, "the synchronous compositor grab must not block the main thread")
    }

    func testInvalidGeometryNeverCallsTheWindowServer() async throws {
        let log = RequestLog()
        let grabber = WindowFrameGrabber { rect, option, id in log.record(rect, option, id); return nil }
        let zeroID = try await grabber.captureWindow(windowID: 0, rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        let infinite = try await grabber.captureWindow(windowID: 2, rect: .infinite)
        let empty = try await grabber.captureRegionBelowOwnWindow(ownWindowID: 2, rect: .zero)
        XCTAssertNil(zeroID); XCTAssertNil(infinite); XCTAssertNil(empty)
        XCTAssertEqual(log.requests.count, 0)
    }

    /// Nominal-resolution grabs are normalized in the same off-main hop.
    func testScaledGrabNormalizesOffTheMainThread() async throws {
        let nominal = try await ScrollImageFixture().solid(width: 20, height: 30)
        let log = RequestLog()
        let grabber = WindowFrameGrabber { rect, option, id in log.record(rect, option, id); return nominal }
        let image = try await grabber.captureWindow(windowID: 9, rect: CGRect(x: 0, y: 0, width: 20, height: 30), scale: 2)
        XCTAssertEqual(image?.width, 40); XCTAssertEqual(image?.height, 60)
        XCTAssertEqual(log.requests.map(\.onMain), [false])
    }

    /// One compositor check per frame: the check after each grab supplies the next grab's geometry.
    /// A window that moved since the last check is grabbed again at its new position.
    func testSnapshotChecksGeometryOncePerFrameAndRegrabsAfterAMove() async throws {
        let image = try await ScrollImageFixture().solid(width: 20, height: 20)
        let screen = ScreenGeometry(id: 5, frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2)
        let probe = SnapshotProbe(CaptureContext(screen: screen, localRect: CGRect(x: 10, y: 10, width: 100, height: 100), kind: "window"))
        let snapshot = RegionSnapshot(capture: { target in probe.grabbed.append(target?.localRect ?? .null); return image },
                                      validate: { probe.checks += 1; return probe.current })
        _ = try await snapshot.capture()
        XCTAssertEqual(probe.checks, 2, "first frame: initial geometry, then the post-grab check")
        _ = try await snapshot.capture(); _ = try await snapshot.capture()
        XCTAssertEqual(probe.checks, 4)
        XCTAssertEqual(probe.grabbed.count, 3)
        // The window moves between frames: the stale grab is discarded and repeated at the new rect.
        let moved = CGRect(x: 60, y: 40, width: 100, height: 100)
        probe.current = CaptureContext(screen: screen, localRect: moved, kind: "window")
        _ = try await snapshot.capture()
        XCTAssertEqual(Array(probe.grabbed.suffix(2)), [CGRect(x: 10, y: 10, width: 100, height: 100), moved])
        XCTAssertEqual(snapshot.context?.localRect, moved)
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

@MainActor
private final class SnapshotProbe {
    var current: CaptureContext
    var checks = 0
    var grabbed: [CGRect] = []
    init(_ current: CaptureContext) { self.current = current }
}

/// Records compositor requests from whatever thread the grabber runs them on.
private final class RequestLog: @unchecked Sendable {
    struct Request { let rect: CGRect; let option: CGWindowListOption; let id: CGWindowID; let onMain: Bool }
    private let lock = NSLock()
    private var entries: [Request] = []
    var requests: [Request] { lock.withLock { entries } }
    func record(_ rect: CGRect, _ option: CGWindowListOption, _ id: CGWindowID) {
        let entry = Request(rect: rect, option: option, id: id, onMain: Thread.isMainThread)
        lock.withLock { entries.append(entry) }
    }
}
