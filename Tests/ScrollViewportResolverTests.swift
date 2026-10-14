// Tests actual-content selection, ambiguous panes, explicit regions and mixed-display coordinate conversion.
import CoreGraphics
import XCTest
@testable import NikoShot

final class ScrollViewportResolverTests: XCTestCase {
    func testWindowSelectsMainScrollAreaWithoutItsToolbarFooterOrSidebar() {
        let context = context()
        let main = CGRect(x: 300, y: 190, width: 500, height: 470)
        let sidebar = CGRect(x: 100, y: 190, width: 180, height: 470)
        let result = ScrollViewportResolver.refined(context, scrollAreas: [sidebar, main])
        XCTAssertEqual(result.globalRect, main)
        XCTAssertEqual(result.windowID, context.windowID)
        XCTAssertEqual(result.targetWindowFrame, context.targetWindowFrame)
        XCTAssertEqual(result.appBundleID, context.appBundleID)
        XCTAssertEqual(result.kind, "window")
    }

    func testExplicitRegionAndPreviouslyCroppedWindowKeepTheUserRange() {
        let window = context()
        let selection = CGRect(x: 140, y: 170, width: 310, height: 280)
        let context = CaptureContext(screen: window.screen, localRect: selection, kind: "region",
                                    appBundleID: window.appBundleID, windowID: window.windowID,
                                    targetWindowFrame: window.targetWindowFrame)
        let areas = [CGRect(x: 100, y: 180, width: 700, height: 490)]
        XCTAssertEqual(ScrollViewportResolver.refined(context, scrollAreas: areas).localRect, selection)
        let cropped = CaptureContext(screen: window.screen, localRect: selection, kind: "window",
                                    appBundleID: window.appBundleID, windowID: window.windowID,
                                    targetWindowFrame: window.targetWindowFrame)
        XCTAssertEqual(ScrollViewportResolver.refined(cropped, scrollAreas: areas).localRect, selection)
    }

    func testEqualSeparatePanesDeclineGuessingAndDuplicateNodesAreHarmless() {
        let context = context()
        let left = CGRect(x: 100, y: 180, width: 345, height: 490)
        let right = CGRect(x: 455, y: 180, width: 345, height: 490)
        XCTAssertEqual(ScrollViewportResolver.refined(context, scrollAreas: [left, right]).localRect, context.localRect)
        XCTAssertEqual(ScrollViewportResolver.refined(context, scrollAreas: [left, left]).globalRect, left)
    }

    func testInvalidOffWindowAndSmallAreasFallBackWithoutChangingScope() {
        let context = context()
        for areas in [[], [CGRect(x: 90, y: 180, width: 700, height: 490)],
                      [CGRect(x: 120, y: 180, width: 200, height: 490)],
                      [CGRect(x: 120, y: 180, width: 600, height: 80)],
                      [CGRect(x: CGFloat.infinity, y: 180, width: 600, height: 490)]] {
            XCTAssertEqual(ScrollViewportResolver.refined(context, scrollAreas: areas).localRect, context.localRect)
        }
    }

    func testContentCoordinatesOnAnUpperDisplayKeepItsScaleAndWindowIdentity() {
        let screen = ScreenGeometry(id: 2, frame: CGRect(x: -1_200, y: 900, width: 1_200, height: 900), scale: 1)
        let window = CGRect(x: -1_100, y: 1_000, width: 700, height: 560)
        let context = CaptureContext(screen: screen, localRect: CGRect(x: 100, y: 240, width: 700, height: 560),
                                     kind: "window", appBundleID: "local.fixture", windowID: 42, targetWindowFrame: window)
        let area = CGRect(x: -1_090, y: 1_040, width: 680, height: 470)
        let result = ScrollViewportResolver.refined(context, scrollAreas: [area])
        XCTAssertEqual(result.globalRect, area)
        XCTAssertEqual(result.localRect, CGRect(x: 110, y: 290, width: 680, height: 470))
        XCTAssertEqual(result.screen, screen)
    }

    private func context() -> CaptureContext {
        let screen = ScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1_200, height: 900), scale: 2)
        let window = CGRect(x: 100, y: 140, width: 700, height: 560)
        return CaptureContext(screen: screen, localRect: CGRect(x: 100, y: 200, width: 700, height: 560),
                              kind: "window", appBundleID: "local.fixture", windowID: 42, targetWindowFrame: window)
    }
}
