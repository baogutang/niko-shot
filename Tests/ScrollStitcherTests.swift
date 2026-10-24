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

    /// A fixed composer alone never makes content look like an overlay: the document-aligned
    /// comparison stays inside the scrolling body instead of reading the anchor's footer.
    func testFixedFooterWithoutOverlayErasesNothing() throws {
        let document = try ScrollImageFixture.denseDocument(width: 800, height: 3_000)
        let footer = 72, body = viewportHeight - footer
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        var offset = 0
        _ = try stitcher.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight, footer: footer))
        for step in [40, 60, 50, 70, 45, 55, 65, 50, 60, 40] {
            offset += step
            let result = try stitcher.add(ScrollImageFixture.viewport(document, offset: offset, height: viewportHeight, footer: footer),
                                          hint: step)
            guard case .appended = result else { return XCTFail("step \(step): \(result)") }
        }
        XCTAssertTrue(stitcher.overlayConfirmed.isEmpty)
        let image = try stitcher.makeImage()
        XCTAssertEqual(image.height, offset + viewportHeight)
        let changed = Self.changedPixels(try ScrollImageFixture.pixels(image), try ScrollImageFixture.pixels(document),
                                         width: 800, rows: 0..<(offset + body))
        XCTAssertEqual(changed, 0, "content pixels were erased although nothing floats over the page")
    }

    /// A pill floating just above the composer is still erased (the upward pairing confirms it where
    /// the downward one would read the footer), and the fill comes from the finished page background.
    func testFloatingPillJustAboveFixedFooterIsErased() throws {
        let document = try ScrollImageFixture.denseDocument(width: 800, height: 3_000)
        let footer = 92   // the fixture pill ends 8 rows above this composer
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        var offset = 0
        _ = try stitcher.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight, footer: footer, floatingPill: true))
        for step in [40, 60, 50, 70, 45, 55, 65, 50, 60, 40] {
            offset += step
            let result = try stitcher.add(ScrollImageFixture.viewport(document, offset: offset, height: viewportHeight, footer: footer,
                                                                      floatingPill: true), hint: step)
            guard case .appended = result else { return XCTFail("step \(step): \(result)") }
        }
        let image = try stitcher.makeImage()
        let pixels = try ScrollImageFixture.pixels(image)
        XCTAssertEqual(Self.pillPixels(pixels), 0)
        XCTAssertEqual(Self.changedPixels(pixels, try ScrollImageFixture.pixels(document), width: 800,
                                          rows: 0..<(offset + viewportHeight - footer), columns: { $0 < 260 || $0 > 540 }), 0)
        // Wherever a segment showed the pill, its centre now carries the page background (≈ 0.985 gray).
        var top = 0, samples = 0, dark = 0
        for (index, segment) in stitcher.segments.enumerated() {
            let origin = stitcher.segmentOrigins[index]
            for row in 474...494 where row >= origin && row < origin + segment.height {
                for x in stride(from: 380, through: 420, by: 4) {
                    let i = ((top + row - origin) * 800 + x) * 4
                    samples += 1
                    if min(pixels[i], pixels[i + 1], pixels[i + 2]) < 235 { dark += 1 }
                }
            }
            top += segment.height
        }
        XCTAssertGreaterThan(samples, 0)
        XCTAssertEqual(dark, 0, "erased pill area must match the page background")
    }

    /// Erasure grows along rows only: a 64 px pill must not wipe text in the neighbouring strips.
    func testOverlayErasureDoesNotSpreadIntoNeighbouringStrips() throws {
        let document = try ScrollImageFixture.denseDocument(width: 800, height: 3_000)
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        var offset = 0
        _ = try stitcher.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight, floatingPill: true))
        for step in [40, 60, 45, 80, 50] {
            offset += step
            let result = try stitcher.add(ScrollImageFixture.viewport(document, offset: offset, height: viewportHeight, floatingPill: true),
                                          hint: step)
            guard case .appended = result else { return XCTFail("step \(step): \(result)") }
        }
        let image = try stitcher.makeImage()
        let pixels = try ScrollImageFixture.pixels(image)
        XCTAssertEqual(Self.pillPixels(pixels), 0)
        // The pill (x 368..432) straddles two ≈93 px strips (x ≈ 299..485); everything beyond them is text.
        XCTAssertEqual(Self.changedPixels(pixels, try ScrollImageFixture.pixels(document), width: 800, rows: 0..<image.height,
                                          columns: { $0 < 260 || $0 > 540 }), 0)
    }

    /// A "back to top" button that appears after the first scroll and hides again before the end is
    /// erased only from frames that showed it; screens captured without it stay untouched.
    func testOverlayIsErasedOnlyFromFramesThatShowedIt() throws {
        let document = try ScrollImageFixture.denseDocument(width: 800, height: 3_000)
        let shown = 2...7
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        var offset = 0
        _ = try stitcher.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight))
        // Steps above 132 rows bring the pill's rows (468..<500) into the appended slice.
        for (index, step) in [140, 150, 135, 160, 145, 155, 140, 150, 135].enumerated() {
            offset += step
            let result = try stitcher.add(ScrollImageFixture.viewport(document, offset: offset, height: viewportHeight,
                                                                      floatingPill: shown.contains(index + 1)), hint: step)
            guard case .appended = result else { return XCTFail("step \(step): \(result)") }
        }
        XCTAssertEqual(stitcher.segments.count, 10)
        let image = try stitcher.makeImage()
        let pixels = try ScrollImageFixture.pixels(image)
        let documentPixels = try ScrollImageFixture.pixels(document)
        XCTAssertEqual(Self.pillPixels(pixels), 0)
        var top = 0
        for (index, segment) in stitcher.segments.enumerated() {
            let origin = stitcher.segmentOrigins[index]
            let rows = top..<(top + segment.height)
            if shown.contains(index) {
                // Only the pill's own box may change (its rows, in the two strips it covers).
                let outsideRows = Self.changedPixels(pixels, documentPixels, width: 800, rows: rows,
                                                     rowFilter: { !(460..<528).contains($0 - top + origin) })
                XCTAssertEqual(outsideRows, 0, "segment \(index) changed outside the pill's rows")
                XCTAssertEqual(Self.changedPixels(pixels, documentPixels, width: 800, rows: rows, columns: { $0 < 260 || $0 > 540 }), 0)
            } else {
                XCTAssertEqual(Self.changedPixels(pixels, documentPixels, width: 800, rows: rows), 0,
                               "segment \(index) came from a frame without the overlay")
            }
            top += segment.height
        }
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

    /// The stitcher measures from the last accepted frame: after a rejected frame the hint must still
    /// cover the whole distance from that frame, or the momentum rescue cannot endorse the true shift.
    func testMomentumRescueNeedsTheHintFromTheAcceptedFrame() throws {
        let document = try ScrollImageFixture.document(width: 800, height: 3_000)
        var stitcher = ScrollStitcher(pixelsPerPoint: 2)
        _ = try stitcher.add(ScrollImageFixture.viewport(document, offset: 0, height: viewportHeight))
        let soft = try ScrollImageFixture.resampledViewport(document, offset: 180, height: viewportHeight)
        var sinceLastCapture = stitcher
        XCTAssertEqual(try sinceLastCapture.add(soft, hint: 80), .unmatched)
        XCTAssertEqual(try stitcher.add(soft, hint: 180), .appended(rows: 180))
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

    /// Orange pill pixels (the fixture's floating overlay) anywhere in a BGRA buffer.
    private static func pillPixels(_ pixels: [UInt8]) -> Int {
        var count = 0, index = 0
        while index < pixels.count {
            let b = Int(pixels[index]), g = Int(pixels[index + 1]), r = Int(pixels[index + 2])
            if r > 200, 90..<140 ~= g, b < 70 { count += 1 }
            index += 4
        }
        return count
    }

    /// Pixels differing between two same-width BGRA buffers, restricted to rows and columns.
    private static func changedPixels(_ a: [UInt8], _ b: [UInt8], width: Int, rows: Range<Int>,
                                      columns: (Int) -> Bool = { _ in true }, rowFilter: (Int) -> Bool = { _ in true }) -> Int {
        var count = 0
        for row in rows where rowFilter(row) {
            for x in 0..<width where columns(x) {
                let i = (row * width + x) * 4
                if a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] { count += 1 }
            }
        }
        return count
    }
}
