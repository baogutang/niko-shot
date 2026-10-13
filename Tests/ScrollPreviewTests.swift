// Checks that the live miniature contains only accepted final-image rows, with bounded storage.
import CoreGraphics
import ImageIO
import XCTest
@testable import NikoShot

@MainActor
final class ScrollPreviewTests: XCTestCase {
    func testLivePreviewMatchesTheFinalPNGIncludingTrimmedAlphaAndSeamOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scroll-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ScrollImageFixture()
        let worker = ScrollCaptureSession(options: ScrollCaptureOptions(ignoredTop: 13, ignoredBottom: 7),
            workingDirectory: directory, previewEnabled: true)
        let first = try await fixture.frame(width: 96, height: 380, start: 0, top: 13, bottom: 7, alpha: true)
        let next = try await fixture.frame(width: 96, height: 380, start: 223, top: 13, bottom: 7, alpha: true)
        _ = try await worker.append(first)
        let initialSnapshot = await worker.livePreview
        let initial = try XCTUnwrap(initialSnapshot)
        XCTAssertEqual(initial.sourceWidth, 96); XCTAssertEqual(initial.sourceHeight, 360); XCTAssertEqual(initial.frames, 1)
        _ = try await worker.append(next)
        let liveSnapshot = await worker.livePreview
        let live = try XCTUnwrap(liveSnapshot)
        XCTAssertEqual(live.sourceHeight, 583); XCTAssertEqual(live.frames, 2)
        let miniature = directory.appendingPathComponent("miniature.png")
        try await Self.write(live.image, to: miniature)
        let previewPixels = try await fixture.inspect(miniature, expectedWidth: 96, expectedHeight: 583, alpha: true)
        XCTAssertLessThanOrEqual(previewPixels.maximumChannelDifference, 1)
        XCTAssertEqual(previewPixels.alphaMismatches, 0)
        let output = directory.appendingPathComponent("final.png")
        _ = try await worker.finish(to: output)
        let finalPixels = try await fixture.inspect(output, expectedWidth: 96, expectedHeight: 583, alpha: true)
        XCTAssertLessThanOrEqual(finalPixels.maximumChannelDifference, 1)
        let closedPreview = await worker.livePreview, resources = await worker.resourceCounts
        XCTAssertNil(closedPreview)
        XCTAssertEqual(resources.residentBufferBytes + resources.openFiles + resources.chunkFiles + resources.ownedDirectories, 0)
    }

    func testDuplicateBacktrackingAndUnconfirmedCandidateDoNotChangeThePreview() async throws {
        let worker = ScrollCaptureSession(previewEnabled: true), fixture = ScrollImageFixture()
        let first = try await fixture.frame(width: 96, height: 360, start: 0)
        let second = try await fixture.frame(width: 96, height: 360, start: 100)
        _ = try await worker.append(first); _ = try await worker.append(second)
        let acceptedSnapshot = await worker.livePreview
        let accepted = try XCTUnwrap(acceptedSnapshot)
        let duplicate = try await worker.append(second)
        XCTAssertEqual(duplicate, .duplicate)
        let earlier = try await fixture.frame(width: 96, height: 360, start: 40)
        let backtracking = try await worker.append(earlier)
        XCTAssertEqual(backtracking, .backtracking)
        let unrelated = try await fixture.frame(width: 96, height: 360, start: 0, seed: 123)
        guard case .needsConfirmation = try await worker.append(unrelated) else { return XCTFail("Expected an unconfirmed seam") }
        let retainedSnapshot = await worker.livePreview
        let retained = try XCTUnwrap(retainedSnapshot)
        XCTAssertTrue(retained.image === accepted.image)
        XCTAssertEqual(retained.sourceHeight, 460); XCTAssertEqual(retained.frames, 2)
        _ = try await worker.append(unrelated, forcedOverlap: 100)
        let confirmedSnapshot = await worker.livePreview
        let confirmed = try XCTUnwrap(confirmedSnapshot)
        XCTAssertEqual(confirmed.sourceHeight, 720); XCTAssertEqual(confirmed.frames, 3)
        await worker.cancel()
        let closed = await worker.livePreview
        XCTAssertNil(closed)
    }

    func testVeryLongPreviewKeepsTheWholeDocumentWithinThePixelBudget() async throws {
        let checks = try await Task.detached {
            let image = try ScrollPixelRows.makeSolidForPreview(width: 1_024, height: 1_000)
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

    private static func write(_ image: CGImage, to url: URL) async throws {
        try await Task.detached {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw ScrollCaptureError.image
            }
            CGImageDestinationAddImage(output, image, nil)
            guard CGImageDestinationFinalize(output) else { throw ScrollCaptureError.image }
        }.value
    }
}

private extension ScrollPixelRows {
    static func makeSolidForPreview(width: Int, height: Int) throws -> CGImage {
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScrollCaptureError.image }
        canvas.setFillColor(CGColor(gray: 0.85, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = canvas.makeImage() else { throw ScrollCaptureError.image }
        return image
    }
}
