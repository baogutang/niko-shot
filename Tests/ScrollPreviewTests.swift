// Checks that the live miniature stays bounded and the side panel follows the newest rows.
import AppKit
import CoreGraphics
import XCTest
@testable import NikoShot

@MainActor
final class ScrollPreviewTests: XCTestCase {
    func testVeryLongPreviewKeepsTheWholeDocumentWithinThePixelBudget() async throws {
        let checks = try await Task.detached {
            let image = try ScrollImageFixture.document(width: 1_024, height: 1_000)
            var preview = ScrollPreviewAccumulator()
            var observedBytes = 0
            for frame in 1...48 {
                try preview.append(image, firstRow: 0, rows: image.height, sourceHeight: frame * image.height, frames: frame)
                observedBytes = max(observedBytes, preview.residentBufferBytes)
            }
            guard let final = preview.snapshot else { throw ScrollCaptureError.image }
            return (final.sourceWidth, final.sourceHeight, final.frames, final.image.width, final.image.height, observedBytes)
        }.value
        XCTAssertEqual(checks.0, 1_024); XCTAssertEqual(checks.1, 48_000); XCTAssertEqual(checks.2, 48)
        XCTAssertLessThanOrEqual(checks.3, ScrollPreviewAccumulator.maximumWidth)
        XCTAssertLessThanOrEqual(checks.4, ScrollPreviewAccumulator.maximumHeight)
        XCTAssertLessThanOrEqual(checks.3 * checks.4, ScrollPreviewAccumulator.maximumPixels)
        XCTAssertLessThanOrEqual(checks.5, ScrollPreviewAccumulator.maximumPixels * 4)
    }

    func testFooterDiscoveryRebuildsThePreviewWithoutDuplicatingRows() async throws {
        let document = try ScrollImageFixture.document(width: 600, height: 2_000)
        let worker = ScrollStitchWorker(pixelsPerPoint: 2)
        _ = try await worker.add(ScrollImageFixture.viewport(document, offset: 0, height: 500, header: 40, footer: 60), hint: nil)
        let update = try await worker.add(ScrollImageFixture.viewport(document, offset: 150, height: 500, header: 40, footer: 60), hint: 150)
        XCTAssertEqual(update.result, .appended(rows: 150))
        // Body content height (without the single footer) matches the preview's source height.
        XCTAssertEqual(update.preview?.sourceHeight, update.height - 60)
    }

    func testPanelPlacementPrefersTheRightThenLeftAndAvoidsControls() {
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let viewport = CGRect(x: 300, y: 200, width: 600, height: 500)
        let right = ScrollPreviewPanelController.placement(near: viewport, avoiding: nil, visible: visible)
        XCTAssertEqual(right.minX, viewport.maxX + 14)
        XCTAssertEqual(right.maxY, viewport.maxY)
        let wide = CGRect(x: 600, y: 200, width: 820, height: 500)
        let left = ScrollPreviewPanelController.placement(near: wide, avoiding: nil, visible: visible)
        XCTAssertEqual(left.maxX, wide.minX - 14)
        XCTAssertTrue(visible.contains(left))
    }

    func testShowFollowsTailAndCloseReleasesPanel() throws {
        let state = ScrollControlState()
        let controller = ScrollPreviewPanelController(state: state)
        controller.show(near: CGRect(x: 200, y: 200, width: 400, height: 400))
        XCTAssertEqual(controller.windowCount, 1)
        XCTAssertTrue(controller.isFollowingTail)
        controller.close()
        XCTAssertEqual(controller.windowCount, 0)
    }

    func testHUDPlacementPrefersBelowThenAbove() {
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = CGSize(width: 600, height: 56)
        let below = ScrollControlBarController.placement(size: size, near: CGRect(x: 400, y: 300, width: 500, height: 400), visible: visible)
        XCTAssertEqual(below.maxY, 288)
        let above = ScrollControlBarController.placement(size: size, near: CGRect(x: 400, y: 20, width: 500, height: 400), visible: visible)
        XCTAssertEqual(above.minY, 432)
    }
}
