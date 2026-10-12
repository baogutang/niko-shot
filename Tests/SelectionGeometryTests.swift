// Covers centered ratio locks, screen bounds and front-to-back overlapping windows.
import XCTest
@testable import NikoShot

final class SelectionGeometryTests: XCTestCase {
    func testCenteredAspectLockAndEightHandles() {
        let rect = SelectionGeometry.drag(anchor: CGPoint(x: 100, y: 100), point: CGPoint(x: 130, y: 120), aspect: 2, centered: true)
        XCTAssertEqual(rect, CGRect(x: 60, y: 80, width: 80, height: 40))
        XCTAssertEqual(SelectionGeometry.handles(rect).count, 8)
        XCTAssertEqual(SelectionGeometry.clamp(CGRect(x: -10, y: 100, width: 30, height: 40), bounds: CGRect(x: 0, y: 0, width: 100, height: 100)), CGRect(x: 0, y: 60, width: 30, height: 40))
    }
    func testOverlappingWindowOrderPreserved() {
        let first = WindowCandidate(id: 3, frame: CGRect(x: 0, y: 0, width: 100, height: 100), title: "Front", appBundleID: "front")
        let second = WindowCandidate(id: 2, frame: first.frame, title: "Behind", appBundleID: "behind")
        XCTAssertEqual(WindowList.hits(at: CGPoint(x: 30, y: 30), in: [first, second]).map(\.id), [3, 2])
    }
    func testEdgeResizeDoesNotMoveUnrelatedAxis() {
        let rect = CGRect(x: 20, y: 30, width: 100, height: 80)
        XCTAssertEqual(SelectionGeometry.resize(rect, handle: 1, to: CGPoint(x: 70, y: 10), aspect: nil, centered: false), CGRect(x: 20, y: 10, width: 100, height: 100))
        XCTAssertEqual(SelectionGeometry.resize(rect, handle: 3, to: CGPoint(x: 140, y: 70), aspect: nil, centered: true), CGRect(x: 0, y: 30, width: 140, height: 80))
    }
}
