// Verifies tolerant row matching, fixed chrome, direction handling and exact reconstruction.
import CoreGraphics
import XCTest
@testable import NikoShot

final class ScrollStitcherTests: XCTestCase {
    private let viewportHeight = 600

    /// Scrolls through a document with uneven steps and expects the stitched image to equal the source rows.
    func testUnevenScrollingReconstructsTheDocumentExactly() throws {
        let document = try ScrollImageFixture.document(width: 800, height: 3_000)
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        var offset = 0
        XCTAssertEqual(try stitcher.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight)), .appended(rows: viewportHeight))
        for step in [37, 120, 3, 260, 410, 88, 199, 333, 17, 451, 240] {
            offset = min(document.height - viewportHeight, offset + step)
            let result = try stitcher.add(ScrollImageFixture.viewport(document, offset: offset, height: viewportHeight))
            guard case .appended = result else { return XCTFail("step \(step) at \(offset): \(result)") }
        }
        let image = try stitcher.makeImage()
        XCTAssertEqual(image.width, 800)
        XCTAssertEqual(image.height, offset + viewportHeight)
        let expected = try XCTUnwrap(document.cropping(to: CGRect(x: 0, y: 0, width: 800, height: image.height)))
        XCTAssertEqual(try ScrollImageFixture.pixels(image), try ScrollImageFixture.pixels(expected))
    }

    /// A toolbar on top and a composer on the bottom stay fixed; both appear exactly once.
    func testFixedHeaderAndFooterAppearOnce() throws {
        let document = try ScrollImageFixture.document(width: 700, height: 2_600)
        let header = 64, footer = 72, body = viewportHeight - header - footer
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        var offset = 0
        _ = try stitcher.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight, header: header, footer: footer))
        for step in [90, 140, 200, 60, 230, 180, 300] {
            offset = min(document.height - body, offset + step)
            let result = try stitcher.add(ScrollImageFixture.viewport(document, offset: offset, height: viewportHeight, header: header, footer: footer))
            guard case .appended = result else { return XCTFail("step \(step): \(result)") }
        }
        XCTAssertEqual(stitcher.footerRows, footer)
        let image = try stitcher.makeImage()
        XCTAssertEqual(image.height, header + offset + body + footer)
        let pixels = try ScrollImageFixture.pixels(image)
        let first = try ScrollImageFixture.pixels(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight, header: header, footer: footer))
        let rowBytes = 700 * 4
        // Header rows come from the first viewport, footer rows from the last; the body is the document.
        XCTAssertEqual(Array(pixels[0..<(header * rowBytes)]), Array(first[0..<(header * rowBytes)]))
        let documentPixels = try ScrollImageFixture.pixels(XCTUnwrap(document.cropping(to: CGRect(x: 0, y: 0, width: 700, height: offset + body))))
        XCTAssertEqual(Array(pixels[(header * rowBytes)..<((header + offset + body) * rowBytes)]), documentPixels)
    }

    /// A chat app's floating "scroll to bottom" pill is screen-still; it must be erased from the
    /// stitched output instead of being baked in once per screen.
    func testFloatingOverlayIsErasedFromOutput() throws {
        let document = try ScrollImageFixture.document(width: 800, height: 3_000)
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        var offset = 0
        _ = try stitcher.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight, floatingPill: true))
        for step in [40, 60, 45, 80, 50] {
            offset = min(document.height - viewportHeight, offset + step)
            let result = try stitcher.add(ScrollImageFixture.viewport(document, offset: offset, height: viewportHeight, floatingPill: true),
                                          hint: step)
            guard case .appended = result else { return XCTFail("step \(step): \(result)") }
        }
        let image = try stitcher.makeImage()
        let pixels = try ScrollImageFixture.pixels(image)
        var pillPixels = 0
        var index = 0
        while index < pixels.count {
            let b = Int(pixels[index]), g = Int(pixels[index + 1]), r = Int(pixels[index + 2])
            if r > 200, 90..<140 ~= g, b < 70 { pillPixels += 1 }
            index += 4
        }
        XCTAssertEqual(pillPixels, 0, "floating pill must be erased everywhere")
        XCTAssertGreaterThan(image.height, offset + 200)
    }

    /// Content-anchored repeats (like identical avatars in a list) move with the document and
    /// must survive; only screen-still blocks get erased.
    func testRepeatedContentIsNotMistakenForOverlay() throws {
        let document = try ScrollImageFixture.document(width: 800, height: 3_000, badges: true)
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        var offset = 0
        _ = try stitcher.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight))
        for step in [60, 80, 70, 50, 90] {
            offset = min(document.height - viewportHeight, offset + step)
            let result = try stitcher.add(ScrollImageFixture.viewport(document, offset: offset, height: viewportHeight),
                                          hint: step)
            guard case .appended = result else { return XCTFail("step \(step): \(result)") }
        }
        let image = try stitcher.makeImage()
        let pixels = try ScrollImageFixture.pixels(image)
        var badgePixels = 0
        var index = 0
        while index < pixels.count {
            let b = Int(pixels[index]), g = Int(pixels[index + 1]), r = Int(pixels[index + 2])
            if 35..<70 ~= r, 115..<165 ~= g, 45..<105 ~= b { badgePixels += 1 }
            index += 4
        }
        let badgesInOutput = (offset + viewportHeight) / 120 + 1
        let expected = badgesInOutput * 30 * 30
        XCTAssertGreaterThan(Double(badgePixels), Double(expected) * 0.85,
            "badge pixels \(badgePixels) should be near \(expected)")
    }

    /// Scrolling up shows already captured content: nothing is appended and the tail is preserved.
    func testBackwardScrollIsReversedAndForwardResumes() throws {
        let document = try ScrollImageFixture.document(width: 800, height: 2_400)
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        _ = try stitcher.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight))
        _ = try stitcher.add(ScrollImageFixture.viewport(document, offset: 300, height: viewportHeight))
        let height = stitcher.outputHeight
        XCTAssertEqual(try stitcher.add(ScrollImageFixture.viewport(document, offset: 180, height: viewportHeight)), .reversed)
        XCTAssertEqual(try stitcher.add(ScrollImageFixture.viewport(document, offset: 300, height: viewportHeight)), .unchanged)
        XCTAssertEqual(stitcher.outputHeight, height)
        XCTAssertEqual(try stitcher.add(ScrollImageFixture.viewport(document, offset: 420, height: viewportHeight)), .appended(rows: 120))
    }

    /// A jump larger than the viewport has no overlap; the stitcher waits until overlap returns.
    func testTooFastScrollIsUnmatchedThenRecovers() throws {
        let document = try ScrollImageFixture.document(width: 800, height: 3_000)
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        _ = try stitcher.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight))
        XCTAssertEqual(try stitcher.add(ScrollImageFixture.viewport(document, offset: 900, height: viewportHeight)), .unmatched)
        XCTAssertEqual(stitcher.outputHeight, viewportHeight)
        XCTAssertEqual(try stitcher.add(ScrollImageFixture.viewport(document, offset: 400, height: viewportHeight)), .appended(rows: 400))
    }

    /// Momentum frames render at fractional offsets; with a precise hint the true shift still stitches.
    func testMomentumResampledFrameStitchesWithPreciseHint() throws {
        let document = try ScrollImageFixture.document(width: 800, height: 3_000)
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        let first = try ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight)
        XCTAssertEqual(try stitcher.add(first), .appended(rows: viewportHeight))
        let blurred = try ScrollImageFixture.resampledViewport(document, offset: 180, height: viewportHeight)
        // Without the hint the relaxed pass stays off; the frame is safely rejected.
        XCTAssertEqual(try stitcher.add(ScrollImageFixture.resampledViewport(document, offset: 180, height: viewportHeight)), .unmatched)
        // With the trackpad delta endorsing the true shift, the frame is rescued.
        let result = try stitcher.add(blurred, hint: 180)
        guard case .appended(let rows) = result else { return XCTFail("expected appended, got \(result)") }
        XCTAssertEqual(rows, 180)
        XCTAssertEqual(stitcher.outputHeight, 180 + viewportHeight)
    }

    func testRetinaSizedFrameMatchesQuickly() throws {
        let document = try ScrollImageFixture.document(width: 2_400, height: 6_000)
        let first = try ScrollImageFixture.viewport(document, offset: 0, height: 1_600)
        let second = try ScrollImageFixture.viewport(document, offset: 420, height: 1_600)
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        _ = try stitcher.add(first)
        let frame = try ScrollFrame(second, pixelsPerPoint: 2)
        let started = ContinuousClock.now
        XCTAssertEqual(try stitcher.add(frame), .appended(rows: 420))
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(3), "Debug builds are slow; release matching is far faster")
    }

    func testOutputLimitStopsAppending() throws {
        let document = try ScrollImageFixture.document(width: 600, height: 2_000)
        var stitcher = ScrollStitcher(pixelsPerPoint: 2, maximumHeight: 900)
        _ = try stitcher.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight))
        XCTAssertEqual(try stitcher.add(ScrollImageFixture.viewport(document, offset: 500, height: viewportHeight)), .limitReached)
        XCTAssertEqual(stitcher.outputHeight, 900)
    }

    func testWorkerPreviewFollowsAcceptedRowsAndFinishReleasesState() async throws {
        let document = try ScrollImageFixture.document(width: 800, height: 2_400)
        let worker = ScrollStitchWorker(pixelsPerPoint: 2)
        let first = try await worker.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight), hint: nil)
        XCTAssertEqual(first.frames, 1)
        XCTAssertEqual(first.preview?.sourceHeight, viewportHeight)
        let second = try await worker.add(ScrollImageFixture.viewport(document, offset: 250, height: viewportHeight), hint: 250)
        XCTAssertEqual(second.result, .appended(rows: 250))
        XCTAssertEqual(second.height, 850)
        // A coincidentally static strip at the bottom is kept once as the footer, outside the preview body.
        XCTAssertLessThanOrEqual(try XCTUnwrap(second.preview?.sourceHeight), 850)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(second.preview?.sourceHeight), 800)
        let image = try await worker.finish()
        XCTAssertEqual(image.height, 850)
        let frames = await worker.frames
        XCTAssertEqual(frames, 0)
    }
}
