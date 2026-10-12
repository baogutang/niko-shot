// Covers pixel boundaries, mixed DPI, negative origins and notch-safe selections.
import XCTest
@testable import NikoShot

final class CoordinateSpaceTests: XCTestCase {
    func testRetinaCropUsesLocalTopLeftPixels() {
        let screen = ScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
        XCTAssertEqual(CoordinateSpace.globalPointToScreenLocal(CGPoint(x: 100, y: 850), screen: screen), CGPoint(x: 100, y: 50))
        XCTAssertEqual(CoordinateSpace.imagePixelRect(fromSelection: CGRect(x: 100, y: 50, width: 20, height: 30), screen: screen), CGRect(x: 200, y: 100, width: 40, height: 60))
    }
    func testLeftAndUpperMixedScaleDisplays() {
        let left = ScreenGeometry(id: 2, frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080), scale: 1)
        let above = ScreenGeometry(id: 3, frame: CGRect(x: 200, y: 900, width: 1000, height: 600), scale: 2)
        XCTAssertEqual(CoordinateSpace.globalPointToScreenLocal(CGPoint(x: -1800, y: 800), screen: left), CGPoint(x: 120, y: 80))
        XCTAssertEqual(CoordinateSpace.globalPointToScreenLocal(CGPoint(x: 250, y: 1400), screen: above), CGPoint(x: 50, y: 100))
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(CoordinateSpace.localToGlobal(rect, screen: above), CGRect(x: 210, y: 1440, width: 30, height: 40))
        XCTAssertEqual(CoordinateSpace.windowToAppKit(CGRect(x: 210, y: -580, width: 30, height: 40), primaryTop: 900), CGRect(x: 210, y: 1440, width: 30, height: 40))
    }
    func testClampRoundingAndNotchSafeArea() {
        let screen = ScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2, safeTop: 32)
        XCTAssertEqual(screen.safeBounds.minY, 32)
        XCTAssertEqual(CoordinateSpace.imagePixelRect(fromSelection: CGRect(x: -10, y: 99.5, width: 20, height: 50), screen: screen), CGRect(x: 0, y: 199, width: 20, height: 1))
    }
}
