// Verifies the instant clipboard, the floating capture thumbnail and magnifier placement.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class CaptureOutputTests: XCTestCase {
    private func image(width: Int = 64, height: Int = 40) throws -> CGImage {
        let context = try ImageUtilities.context(width: width, height: height)
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    func testClipboardIsClaimedBeforeArchivingAndOffersTheFileOnceSaved() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("niko-shot-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let payload = DeferredCapturePayload(image: try image(), date: Date(), file: file)
        let item = NSPasteboardItem()
        item.setDataProvider(payload, forTypes: [.png, .tiff, .fileURL])
        pasteboard.clearContents(); pasteboard.writeObjects([item])

        // Before the archive exists, image types already paste; encoding happens on request.
        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertEqual(NSBitmapImageRep(data: png)?.pixelsWide, 64)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))

        try png.write(to: file)
        payload.fulfill(png: png)
        XCTAssertEqual(pasteboard.string(forType: .fileURL), file.absoluteString)
    }

    func testFailedArchiveStillPastesTheImageWithoutAFileURL() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("niko-shot-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let payload = DeferredCapturePayload(image: try image(), date: Date(),
                                             file: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png"))
        payload.fail()
        let item = NSPasteboardItem()
        item.setDataProvider(payload, forTypes: [.png, .fileURL])
        pasteboard.clearContents(); pasteboard.writeObjects([item])
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNil(pasteboard.string(forType: .fileURL))
    }

    func testThumbnailFitsTheCornerWithoutUpscalingTinyCaptures() {
        XCTAssertEqual(CapturePreviewController.thumbnailSize(for: CGSize(width: 5120, height: 2880)), CGSize(width: 220, height: 124))
        XCTAssertEqual(CapturePreviewController.thumbnailSize(for: CGSize(width: 800, height: 6000)), CGSize(width: 48, height: 150))
        XCTAssertEqual(CapturePreviewController.thumbnailSize(for: CGSize(width: 40, height: 30)), CGSize(width: 80, height: 60))
        let thumbnail = CapturePreviewController.makeThumbnail(try! image(width: 2000, height: 1000), backingScale: 2)
        XCTAssertEqual(thumbnail?.width, 440)
        XCTAssertEqual(thumbnail?.height, 220)
    }

    func testThumbnailPanelOpensInTheCornerAndClosesOnRequest() throws {
        let controller = CapturePreviewController()
        let screen = try XCTUnwrap(NSScreen.main)
        let record = HistoryRecord(id: UUID(), createdAt: Date(), path: "/tmp/none.png", thumbnail: Data(),
                                   width: 64, height: 40, appBundleID: "", captureKind: "region")
        controller.show(record: record, thumbnail: try image(), screenFrame: screen.frame, status: "已复制")
        XCTAssertEqual(controller.windowCount, 1)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.accessibilityLabel() == "截图缩略图" })
        XCTAssertFalse(panel.canBecomeKey, "The thumbnail never takes focus from the app the user is pasting into")
        controller.dismiss(animated: false)
        XCTAssertEqual(controller.windowCount, 0)
    }

    func testColorPickerReadsSRGBHexWithATopLeftOrigin() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 1])!); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        // CoreGraphics draws bottom-up: y 3 is the top row on screen.
        context.setFillColor(CGColor(colorSpace: space, components: [1, 64.0 / 255, 0, 1])!); context.fill(CGRect(x: 0, y: 3, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(SelectionView.hex(of: image, atPixel: CGPoint(x: 0.4, y: 0.7)), "#FF4000")
        XCTAssertEqual(SelectionView.hex(of: image, atPixel: CGPoint(x: 3, y: 3)), "#0000FF")
        XCTAssertEqual(SelectionView.hex(of: image, atPixel: CGPoint(x: 99, y: -5)), "#0000FF", "Out-of-range points clamp to the edge")
    }

    func testLoupeStaysBesideThePointerAndFlipsAwayFromEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700), size = CGSize(width: 135, height: 171)
        XCTAssertEqual(SelectionView.loupeOrigin(for: CGPoint(x: 100, y: 100), size: size, in: bounds, safeTop: 0),
                       CGPoint(x: 120, y: 120))
        let corner = SelectionView.loupeOrigin(for: CGPoint(x: 990, y: 690), size: size, in: bounds, safeTop: 0)
        XCTAssertEqual(corner, CGPoint(x: 990 - 20 - 135, y: 690 - 20 - 171))
        XCTAssertFalse(CGRect(origin: corner, size: size).contains(CGPoint(x: 990, y: 690)), "The loupe never covers its own target")
        let top = SelectionView.loupeOrigin(for: CGPoint(x: 500, y: 0), size: size, in: bounds, safeTop: 32)
        XCTAssertGreaterThanOrEqual(top.y, 32)
    }
}
