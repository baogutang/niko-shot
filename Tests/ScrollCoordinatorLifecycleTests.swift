// Checks setup cancellation without requesting ScreenCaptureKit or Accessibility consent.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class ScrollCoordinatorLifecycleTests: XCTestCase {
    func testSetupCancellationReleasesEveryOwnedResourceAndCanRepeat() async throws {
        let selection = SelectionSession()
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(), onCapture: { _, _ in })
        let image = try await Task.detached { () -> CGImage in
            guard let context = CGContext(data: nil, width: 96, height: 320, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AppError.imageCreation }
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 320))
            guard let image = context.makeImage() else { throw AppError.imageCreation }
            return image
        }.value
        let screen = ScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 96, height: 320), scale: 1)
        for _ in 0..<2 {
            coordinator.showSetup(image: image, context: CaptureContext(screen: screen, localRect: screen.localBounds, kind: "scroll"))
            XCTAssertTrue(coordinator.isBusy)
            XCTAssertEqual(coordinator.resourceCounts["setup"], 1)
            await coordinator.cancel()
            XCTAssertFalse(coordinator.isBusy)
            XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
            XCTAssertEqual(selection.windowCount, 0)
            XCTAssertEqual(selection.monitorCount, 0)
        }
    }
}
