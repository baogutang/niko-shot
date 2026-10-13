// Exercises real compositor metadata without screen recording or Accessibility consent.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class WindowServerGeometryTests: XCTestCase {
    func testVisibleNativeWindowHasCorrectIdentityAndGeometry() async throws {
        let window = makeWindow()
        defer { window.orderOut(nil); window.close() }
        let id = try XCTUnwrap(UInt32(exactly: window.windowNumber))
        try await waitUntil { if case .visible = ScrollWindowServer.lookup(id: id) { true } else { false } }
        let geometry = try XCTUnwrap(CaptureEngine.windowGeometry(id: id))
        XCTAssertTrue(geometry.isOnScreen, "A genuinely visible native window must not report closed")
        XCTAssertEqual(geometry.id, id)
        XCTAssertEqual(geometry.ownerPID, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(geometry.frame.minX, window.frame.minX, accuracy: 1)
        XCTAssertEqual(geometry.frame.minY, window.frame.minY, accuracy: 1)
        XCTAssertEqual(geometry.frame.width, window.frame.width, accuracy: 1)
        XCTAssertEqual(geometry.frame.height, window.frame.height, accuracy: 1)
    }

    func testOrderedOutWindowIsRejectedAndCanBecomeVisibleAgain() async throws {
        let window = makeWindow()
        defer { window.orderOut(nil); window.close() }
        let id = try XCTUnwrap(UInt32(exactly: window.windowNumber))
        try await waitUntil { if case .visible = ScrollWindowServer.lookup(id: id) { true } else { false } }
        window.orderOut(nil)
        try await waitUntil { if case .notVisible = ScrollWindowServer.lookup(id: id) { true } else { false } }
        XCTAssertFalse(try XCTUnwrap(CaptureEngine.windowGeometry(id: id)).isOnScreen)
        window.orderFrontRegardless()
        try await waitUntil { if case .visible = ScrollWindowServer.lookup(id: id) { true } else { false } }
        XCTAssertTrue(try XCTUnwrap(CaptureEngine.windowGeometry(id: id)).isOnScreen)
    }

    func testMinimizedAndClosedNativeWindowsDoNotAuthorizeCapture() async throws {
        let minimized = makeWindow()
        defer { minimized.orderOut(nil); minimized.close() }
        let minimizedID = try XCTUnwrap(UInt32(exactly: minimized.windowNumber))
        try await waitUntil { if case .visible = ScrollWindowServer.lookup(id: minimizedID) { true } else { false } }
        minimized.miniaturize(nil)
        try await waitUntil {
            if case .notVisible = ScrollWindowServer.lookup(id: minimizedID) { minimized.isMiniaturized } else { false }
        }
        XCTAssertFalse(try XCTUnwrap(CaptureEngine.windowGeometry(id: minimizedID)).isOnScreen)

        // A separate window avoids testing close during the asynchronous deminiaturization animation.
        let closed = makeWindow()
        defer { closed.orderOut(nil); closed.close() }
        let closedID = try XCTUnwrap(UInt32(exactly: closed.windowNumber))
        try await waitUntil { if case .visible = ScrollWindowServer.lookup(id: closedID) { true } else { false } }
        closed.close()
        // Let the native run loop flush the close before querying the compositor again.
        try await Task.sleep(for: .milliseconds(20))
        try await waitUntil {
            switch ScrollWindowServer.lookup(id: closedID) {
            case .notVisible, .missing: !closed.isVisible
            case .visible, .unknown: false
            }
        }
        XCTAssertFalse(try CaptureEngine.windowGeometry(id: closedID)?.isOnScreen == true)
        if case .missing = ScrollWindowServer.lookup(id: UInt32.max) {} else { XCTFail("An absent ID must be missing") }
        XCTAssertNil(try CaptureEngine.windowGeometry(id: UInt32.max))
    }

    func testOptionalVisibilityKeyRequiresPositiveListMembership() async throws {
        let window = makeWindow()
        defer { window.orderOut(nil); window.close() }
        let id = try XCTUnwrap(UInt32(exactly: window.windowNumber))
        try await waitUntil { if case .visible = ScrollWindowServer.lookup(id: id) { true } else { false } }
        var record = try nativeRecord(id: id)
        record.removeValue(forKey: kCGWindowIsOnscreen as String)
        var queriedHidden = false
        let visible = ScrollWindowServer.resolve(id: id, onScreen: [record], includingHidden: {
            queriedHidden = true; return nil
        }, primaryTop: primaryTop)
        guard case .visible(let geometry) = visible else { return XCTFail("Positive membership must survive an optional missing key") }
        XCTAssertTrue(geometry.isOnScreen)
        XCTAssertFalse(queriedHidden, "Visible frames require one lightweight list, not a second enumeration")
        let hidden = ScrollWindowServer.resolve(id: id, onScreen: [], includingHidden: { [record] }, primaryTop: primaryTop)
        guard case .notVisible(let hiddenGeometry) = hidden else { return XCTFail("A missing key alone must never authorize capture") }
        XCTAssertFalse(hiddenGeometry.isOnScreen)
    }

    func testUnknownMetadataAndQueryRacesDoNotPretendWindowIsClosed() async throws {
        let window = makeWindow()
        defer { window.orderOut(nil); window.close() }
        let id = try XCTUnwrap(UInt32(exactly: window.windowNumber))
        try await waitUntil { if case .visible = ScrollWindowServer.lookup(id: id) { true } else { false } }
        let record = try nativeRecord(id: id)
        assertUnknown(ScrollWindowServer.resolve(id: id, onScreen: nil, includingHidden: { [record] }, primaryTop: primaryTop))
        assertUnknown(ScrollWindowServer.resolve(id: id, onScreen: [], includingHidden: { nil }, primaryTop: primaryTop))
        // The window became visible between the positive list and the all-windows list.
        assertUnknown(ScrollWindowServer.resolve(id: id, onScreen: [], includingHidden: { [record] }, primaryTop: primaryTop))
        for key in [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowBounds] {
            var invalid = record; invalid.removeValue(forKey: key as String)
            assertUnknown(ScrollWindowServer.resolve(id: id, onScreen: [invalid], includingHidden: { [] }, primaryTop: primaryTop))
        }
        XCTAssertFalse(ScrollTargetError.windowStateUnknown.requiresReselection)
        XCTAssertFalse(ScrollTargetError.windowStateUnknown.localizedDescription.contains("关闭或最小化"))
    }

    func testReusedWindowIdentityAndChangedGeometryRemainRejected() throws {
        let screen = ScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1200, height: 1000), scale: 1)
        let frame = CGRect(x: 100, y: 100, width: 300, height: 400)
        let original = ScrollWindowGeometry(id: 123, ownerPID: 321, frame: frame, isOnScreen: true)
        let origin = CoordinateSpace.globalPointToScreenLocal(CGPoint(x: frame.minX, y: frame.maxY), screen: screen)
        let context = CaptureContext(screen: screen, localRect: CGRect(origin: origin, size: frame.size),
            kind: "window", windowID: original.id, targetWindowFrame: frame)
        let baseline = ScrollTargetGeometry(context: context, window: original)
        let reused = ScrollWindowGeometry(id: original.id, ownerPID: original.ownerPID + 1, frame: frame, isOnScreen: true)
        XCTAssertThrowsError(try baseline.validate(window: reused, screens: [screen])) {
            guard case ScrollTargetError.windowIdentityChanged = $0 else { return XCTFail("Expected reused identity rejection: \($0)") }
        }
        let resized = ScrollWindowGeometry(id: original.id, ownerPID: original.ownerPID,
            frame: frame.insetBy(dx: -10, dy: 0), isOnScreen: true)
        XCTAssertThrowsError(try baseline.validate(window: resized, screens: [screen])) {
            guard case ScrollTargetError.windowResized = $0 else { return XCTFail("Expected changed geometry rejection: \($0)") }
        }
        let moved = ScrollWindowGeometry(id: original.id, ownerPID: original.ownerPID,
            frame: frame.offsetBy(dx: 30, dy: 40), isOnScreen: true)
        XCTAssertEqual(try baseline.validate(window: moved, screens: [screen]).globalRect, moved.frame)
    }

    private var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let window = NSWindow(contentRect: CGRect(x: screen.minX + 30, y: screen.minY + 50, width: 280, height: 300),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.title = "niko-shot window metadata regression"
        window.orderFrontRegardless()
        return window
    }

    private func nativeRecord(id: UInt32) throws -> [String: Any] {
        let records = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
        return try XCTUnwrap(records.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id })
    }

    private func assertUnknown(_ value: ScrollWindowObservation, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unknown = value else { return XCTFail("Untrusted metadata must not authorize capture or claim closure", file: file, line: line) }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw AppError.file("Native window metadata did not reach the expected state") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
