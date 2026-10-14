import AppKit
import SwiftUI
import XCTest
@testable import NikoShot

@MainActor
final class FileDragPreviewLayoutTests: XCTestCase {
    func testLargeScreenshotFitsTheThumbnailInsteadOfKeepingItsIntrinsicPixelSize() async throws {
        let image = NSImage(size: CGSize(width: 2400, height: 1600))
        let size = CGSize(width: 108, height: 66)
        let host = NSHostingView(rootView: FileDragPreview(url: URL(fileURLWithPath: "/tmp/niko-drag-fixture.png"), image: image)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        func find(_ root: NSView) -> FileDragView? {
            (root as? FileDragView) ?? root.subviews.lazy.compactMap { find($0) }.first
        }
        let preview = try XCTUnwrap(find(host))
        XCTAssertEqual(preview.bounds.size.width, size.width, accuracy: 1)
        XCTAssertEqual(preview.bounds.size.height, size.height, accuracy: 1)
        XCTAssertEqual(preview.imageScaling, .scaleProportionallyUpOrDown)
    }
}
