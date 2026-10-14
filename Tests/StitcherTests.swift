// Validates real pixel translations, fixed-band trimming and NCC rejection on a worker executor.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import XCTest
import zlib
@testable import NikoShot

@MainActor
final class StitcherTests: XCTestCase {
    func testNoiseAndTextTranslationsResolveEveryBoundaryAtOnePixel() async throws {
        let fixture = ScrollImageFixture()
        for overlap in [80, 81, 137, 199, 200] {
            let previous = try await fixture.frame(width: 193, height: 480, start: 0)
            let current = try await fixture.frame(width: 193, height: 480, start: 480 - overlap)
            let result = try await fixture.match(previous, current)
            XCTAssertEqual(result.overlap, overlap, accuracy: 1, "NCC must resolve the translated document seam")
            XCTAssertGreaterThan(result.correlation, 0.99)
            XCTAssertFalse(result.isAmbiguous)
        }
    }

    func testPyramidMatchingPreservesNativePixelsOnWideRetinaFrames() async throws {
        let fixture = ScrollImageFixture()
        let previous = try await fixture.frame(width: 1_920, height: 640, start: 0)
        let current = try await fixture.frame(width: 1_920, height: 640, start: 493)
        let result = try await fixture.match(previous, current)
        XCTAssertEqual(result.overlap, 147, accuracy: 1)
        XCTAssertGreaterThan(result.correlation, 0.99)
        XCTAssertFalse(result.isAmbiguous)
    }

    func testNaturalWheelAndTrackpadStepsSearchTheWholeViewport() async throws {
        let fixture = ScrollImageFixture()
        let previous = try await fixture.frame(width: 193, height: 1_000, start: 0)
        for movement in [1, 2, 5, 20, 60, 300] {
            let current = try await fixture.frame(width: 193, height: 1_000, start: movement)
            let result = try await fixture.match(previous, current)
            XCTAssertEqual(result.overlap, 1_000 - movement, accuracy: 1)
            XCTAssertGreaterThan(result.correlation, 0.99)
            XCTAssertFalse(result.isAmbiguous)
            XCTAssertFalse(result.isBacktracking)
        }
    }

    func testUpwardMovementIsIdentifiedWithoutConvertingItToAForwardSeam() async throws {
        let fixture = ScrollImageFixture()
        let previous = try await fixture.frame(width: 193, height: 1_000, start: 300)
        for movement in [1, 2, 5, 20, 60, 300] {
            let earlier = try await fixture.frame(width: 193, height: 1_000, start: 300 - movement)
            let result = try await fixture.match(previous, earlier)
            XCTAssertEqual(result.overlap, 1_000 - movement, accuracy: 1)
            XCTAssertGreaterThan(result.correlation, 0.99)
            XCTAssertFalse(result.isAmbiguous)
            XCTAssertTrue(result.isBacktracking)
        }
    }

    func testNaturalMovementWithExplicitFixedBandsDoesNotMatchWindowChrome() async throws {
        let fixture = ScrollImageFixture()
        let previous = try await fixture.frame(width: 193, height: 1_056, start: 0, top: 32, bottom: 24, chrome: 10)
        let current = try await fixture.frame(width: 193, height: 1_056, start: 60, top: 32, bottom: 24, chrome: 220)
        let result = try await fixture.match(previous, current, top: 32, bottom: 24)
        XCTAssertEqual(result.overlap, 940, accuracy: 1)
        XCTAssertGreaterThan(result.correlation, 0.99)
        XCTAssertFalse(result.isAmbiguous)
        XCTAssertFalse(result.isBacktracking)
    }

    func testTallViewportBoundsTheProfileAndStillRefinesAtNativePixels() async throws {
        let fixture = ScrollImageFixture()
        let previous = try await fixture.frame(width: 193, height: 9_000, start: 0)
        let current = try await fixture.frame(width: 193, height: 9_000, start: 21)
        let result = try await fixture.match(previous, current)
        XCTAssertEqual(result.overlap, 8_979, accuracy: 1)
        XCTAssertGreaterThan(result.correlation, 0.99)
        XCTAssertFalse(result.isAmbiguous)
        XCTAssertFalse(result.isBacktracking)
        let budget = try await fixture.analysisBudget(previous)
        XCTAssertLessThanOrEqual(budget.profileFloats, 65_536)
        XCTAssertLessThan(budget.residentBytes, 1_500_000)
    }

    func testBlankDocumentRowsAtTheViewportEdgeDoNotHideForwardOrBackwardMovement() async throws {
        let fixture = ScrollImageFixture()
        for backward in [false, true] { for blankHeight in [100, 200, 300, 500] {
            let start = backward ? 300 : 0
            let blank = backward ? start..<(start + blankHeight) : (1_000 - blankHeight)..<1_000
            let previous = try await fixture.frame(width: 193, height: 1_000, start: start, blankDocumentRows: blank)
            let current = try await fixture.frame(width: 193, height: 1_000, start: start + (backward ? -60 : 60), blankDocumentRows: blank)
            let result = try await fixture.match(previous, current)
            XCTAssertEqual(result.overlap, 940, accuracy: 1)
            XCTAssertGreaterThan(result.correlation, 0.99)
            XCTAssertFalse(result.isAmbiguous)
            XCTAssertEqual(result.isBacktracking, backward)
        } }
    }

    func testFixedHeaderAndFooterAreRemovedBeforeMatchingAndSignatures() async throws {
        let fixture = ScrollImageFixture()
        let previous = try await fixture.frame(width: 128, height: 430, start: 0, top: 23, bottom: 17, chrome: 10)
        let current = try await fixture.frame(width: 128, height: 430, start: 257, top: 23, bottom: 17, chrome: 220)
        let result = try await fixture.match(previous, current, top: 23, bottom: 17)
        XCTAssertEqual(result.overlap, 133, accuracy: 1)
        XCTAssertGreaterThan(result.correlation, 0.99)
        let differentChrome = try await fixture.frame(width: 128, height: 430, start: 0, top: 23, bottom: 17, chrome: 220)
        let difference = try await fixture.signatureDifference(previous, differentChrome, top: 23, bottom: 17)
        XCTAssertEqual(difference, 0, accuracy: 0.0001)
    }

    func testUnrelatedAndFlatFramesCannotCreateAConfidentSeam() async throws {
        let fixture = ScrollImageFixture()
        let previous = try await fixture.frame(width: 128, height: 400, start: 0)
        let unrelated = try await fixture.frame(width: 128, height: 400, start: 0, seed: 57)
        let result = try await fixture.match(previous, unrelated)
        XCTAssertLessThan(result.correlation, 0.90)
        let flat = try await fixture.solid(width: 128, height: 400)
        let flatResult = try await fixture.match(flat, flat)
        XCTAssertEqual(flatResult.correlation, 0)
        XCTAssertTrue(flatResult.isAmbiguous, "An empty document has no identifiable overlap")
    }

    func testRepeatedStripesAreAmbiguousEvenWithHighCorrelation() async throws {
        let fixture = ScrollImageFixture()
        let previous = try await fixture.frame(width: 128, height: 400, start: 0, periodic: true)
        let current = try await fixture.frame(width: 128, height: 400, start: 260, periodic: true)
        let result = try await fixture.match(previous, current)
        XCTAssertGreaterThan(result.correlation, 0.99)
        XCTAssertTrue(result.isAmbiguous, "Several equally good seams must require a manual decision")
    }

    func testStableSignatureDetectsDuplicatesAndContentOrShapeChanges() async throws {
        let fixture = ScrollImageFixture()
        let first = try await fixture.frame(width: 128, height: 400, start: 0)
        let moved = try await fixture.frame(width: 128, height: 400, start: 260)
        let reshaped = try await fixture.frame(width: 127, height: 400, start: 0)
        let duplicateDifference = try await fixture.signatureDifference(first, first)
        let movedDifference = try await fixture.signatureDifference(first, moved)
        let shapeDifference = try await fixture.signatureDifference(first, reshaped)
        XCTAssertEqual(duplicateDifference, 0)
        XCTAssertGreaterThan(movedDifference, 0.002)
        XCTAssertEqual(shapeDifference, 1)
    }

    func testSparseTextMovementSurvivesBlankPageWithoutAmplifyingOnePixelRasterNoise() async throws {
        let fixture = ScrollImageFixture()
        let first = try await fixture.sparseText(start: 0)
        for movement in [1, 5, 20, 60] {
            let moved = try await fixture.sparseText(start: movement)
            let difference = try await fixture.signatureDifference(first, moved)
            XCTAssertGreaterThan(difference, 0.004, "A real text scroll must pass both stable-frame and duplicate gates")
            let match = try await fixture.match(first, moved)
            XCTAssertEqual(match.overlap, first.height - movement, accuracy: 1)
            XCTAssertGreaterThan(match.correlation, 0.99)
            XCTAssertFalse(match.isAmbiguous)
        }
        let noisy = try await fixture.sparseText(start: 0, rasterPixel: true)
        let noiseDifference = try await fixture.signatureDifference(first, noisy)
        XCTAssertLessThan(noiseDifference, 0.002, "One isolated backing pixel must not imply document scrolling")
    }

    func testRepeatedSeparatorRequiresAgreementAcrossTheWholeOverlap() async throws {
        let fixture = ScrollImageFixture()
        let document = try await fixture.messageDocument()
        let previous = try await fixture.viewport(document, start: 0, height: 1_000)
        for movement in [1, 20, 60, 137, 300] {
            let current = try await fixture.viewport(document, start: movement, height: 1_000)
            let match = try await fixture.match(previous, current)
            XCTAssertEqual(match.overlap, 1_000 - movement, accuracy: 1)
            XCTAssertGreaterThan(match.correlation, 0.99)
            XCTAssertFalse(match.isAmbiguous, "An identical separator alone must not make distinct body content ambiguous")
            XCTAssertFalse(match.isBacktracking)
        }
    }

    func testRetinaTextAndExactlyRepeatingLayoutsRemainDistinctDecisions() async throws {
        let fixture = ScrollImageFixture()
        let document = try await fixture.messageDocument(scale: 2)
        let previous = try await fixture.viewport(document, start: 800, height: 2_000)
        for movement in [1, 39, 137, 601] {
            let current = try await fixture.viewport(document, start: 800 + movement, height: 2_000)
            let match = try await fixture.match(previous, current)
            XCTAssertEqual(match.overlap, 2_000 - movement, accuracy: 1)
            XCTAssertGreaterThan(match.correlation, 0.99)
            XCTAssertFalse(match.isAmbiguous)
        }
        let repeating = try await fixture.messageDocument(repeating: true)
        let first = try await fixture.viewport(repeating, start: 0, height: 1_600)
        let next = try await fixture.viewport(repeating, start: 60, height: 1_600)
        let ambiguous = try await fixture.match(first, next)
        XCTAssertTrue(ambiguous.isAmbiguous, "Identical full layouts have several valid offsets and still require confirmation")
    }

    func testSingleSeparatorAloneCannotAuthorizeAnAutomaticSeam() async throws {
        let fixture = ScrollImageFixture()
        let first = try await fixture.separatorOnly(start: 0)
        let next = try await fixture.separatorOnly(start: 60)
        let match = try await fixture.match(first, next)
        XCTAssertLessThan(match.correlation, 0.9, "A single repeated horizontal edge provides insufficient seam evidence")
        XCTAssertTrue(match.isAmbiguous)
    }
}

struct ScrollPNGInspection: Sendable {
    let width: Int, height: Int, maximumChannelDifference: Int, alphaMismatches: Int
    let validCRCs: Bool, idatChunks: Int
}

/// Rasterizes and decodes fixture images away from MainActor; no fixture pixel arrays cross actors.
actor ScrollImageFixture {
    func separatorOnly(start: Int) throws -> CGImage {
        let width = 640, height = 1_000
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScrollCaptureError.image }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1)); context.fill(CGRect(x: 20, y: height - 700 + start, width: width - 40, height: 3))
        guard let image = context.makeImage() else { throw ScrollCaptureError.image }
        return image
    }

    /// A generated document with identical bright separators and distinct paragraphs between them.
    func messageDocument(width: Int = 800, height: Int = 3_600, scale: Int = 1, repeating: Bool = false) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8,
            bytesPerRow: width * scale * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScrollCaptureError.image }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.setFillColor(CGColor(gray: 0.08, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.75, alpha: 1)]
        for block in 0..<(height / 500 + 1) {
            context.setFillColor(CGColor(gray: 0.9, alpha: 1))
            context.fill(CGRect(x: 20, y: height - block * 500 - 403, width: width - 40, height: 3))
            let identity = repeating ? 0 : block
            for line in 0..<3 {
                let label = "Document section \(identity). Row \(line): \(String(repeating: "native ", count: 2 + identity % 5))"
                context.textPosition = CGPoint(x: 35 + identity * 17 % 180, y: height - block * 500 - 150 - line * 40)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes)), context)
            }
        }
        guard let image = context.makeImage() else { throw ScrollCaptureError.image }
        return image
    }

    func viewport(_ document: CGImage, start: Int, height: Int) throws -> CGImage {
        guard start >= 0, height > 0, start <= document.height - height,
              let image = document.cropping(to: CGRect(x: 0, y: start, width: document.width, height: height)) else { throw ScrollCaptureError.image }
        return image
    }

    /// Draws real CoreText on a mostly blank page on the actor executor.
    func sparseText(width: Int = 900, height: Int = 1_200, start: Int, rasterPixel: Bool = false) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScrollCaptureError.image }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Small real text on a mostly empty document.", attributes: attributes))
        context.textPosition = CGPoint(x: 30, y: height - 530 + start)
        CTLineDraw(line, context)
        if rasterPixel {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: width - 20, y: height - 40, width: 1, height: 1))
        }
        guard let image = context.makeImage() else { throw ScrollCaptureError.image }
        return image
    }

    func frame(width: Int, height: Int, start: Int, seed: UInt64 = 1, top: Int = 0, bottom: Int = 0,
               chrome: UInt8 = 70, chromeDetail: Bool = false, alpha: Bool = false, periodic: Bool = false,
               blankDocumentRows: Range<Int>? = nil, screenDither: Bool = false) throws -> CGImage {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for row in 0..<height { for column in 0..<width {
                let value: [UInt8]
                if row < top || row >= height - bottom {
                    if chromeDetail, row == top - 1 || row == height - bottom {
                        value = [30, 30, 30, 255]
                    } else if chromeDetail, column >= 12, column < width - 12,
                              (row >= 6 && row < top - 6) || (row >= height - bottom + 6 && row < height - 6) {
                        value = [((column / 8 + row / 3).isMultiple(of: 2) ? 40 : 200), chrome, 80, 255]
                    } else { value = [chrome, 255 - chrome, 80, 255] }
                }
                else if blankDocumentRows?.contains(start + row - top) == true {
                    let gray: UInt8 = screenDither ? ((row + column).isMultiple(of: 2) ? 251 : 253) : 255
                    value = [gray, gray, gray, 255]
                }
                else { value = Self.pixel(x: column, y: start + row - top, seed: seed, alpha: alpha, periodic: periodic) }
                let offset = (row * width + column) * 4
                for channel in 0..<4 { bytes[offset + channel] = value[channel] }
            } }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScrollCaptureError.image }
        return image
    }

    func solid(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw ScrollCaptureError.image }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ScrollCaptureError.image }
        return image
    }

    func match(_ previous: CGImage, _ current: CGImage, top: Int = 0, bottom: Int = 0) throws -> StitchMatch {
        try Stitcher.match(previous: previous, current: current, ignoringTop: top, ignoringBottom: bottom)
    }
    func signatureDifference(_ first: CGImage, _ second: CGImage, top: Int = 0, bottom: Int = 0) throws -> Float {
        try Stitcher.signature(for: first, ignoringTop: top, ignoringBottom: bottom)
            .normalizedDifference(to: Stitcher.signature(for: second, ignoringTop: top, ignoringBottom: bottom))
    }
    func analysisBudget(_ image: CGImage) throws -> (profileFloats: Int, residentBytes: Int) {
        let analysis = try Stitcher.analyze(image, top: 0, bottom: 0)
        return (analysis.profile.count, analysis.residentBytes)
    }

    func inspect(_ url: URL, expectedWidth: Int, expectedHeight: Int, seed: UInt64 = 1, alpha: Bool = false) throws -> ScrollPNGInspection {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ScrollCaptureError.image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var maximum = 0, alphaMismatches = 0
        if image.width == expectedWidth, image.height == expectedHeight {
            for row in 0..<image.height { for column in 0..<image.width {
                let expected = Self.pixel(x: column, y: row, seed: seed, alpha: alpha, periodic: false)
                let offset = (row * image.width + column) * 4
                for channel in 0..<3 { maximum = max(maximum, abs(Int(bytes[offset + channel]) - Int(expected[channel]))) }
                if bytes[offset + 3] != expected[3] { alphaMismatches += 1 }
            } }
        } else { maximum = 255 }
        let chunks = try Self.inspectChunks(Data(contentsOf: url))
        return ScrollPNGInspection(width: image.width, height: image.height, maximumChannelDifference: maximum,
            alphaMismatches: alphaMismatches, validCRCs: chunks.valid, idatChunks: chunks.idats)
    }

    func rejectsOversizedWriter(in directory: URL) -> Bool {
        do { _ = try ChunkedPNGWriter(directory: directory.appendingPathComponent("must-not-exist"), width: Int.max, checkCancellation: {}) }
        catch ScrollCaptureError.dimensionOverflow { return true }
        catch { return false }
        return false
    }

    private static func pixel(x: Int, y: Int, seed: UInt64, alpha: Bool, periodic: Bool) -> [UInt8] {
        if periodic {
            let shade: UInt8 = (y % 20) < 10 ? 30 : 230
            return [shade, shade, shade, 255]
        }
        var value = UInt64(y) &* 0x9e37_79b9_7f4a_7c15 ^ UInt64(x) &* 0xbf58_476d_1ce4_e5b9 ^ seed &* 0x94d0_49bb_1331_11eb
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb; value ^= value >> 31
        let line = y % 31 < 3
        let red = line ? 245 : Int(value & 255), green = line ? 242 : Int((value >> 16) & 255), blue = line ? 238 : Int((value >> 32) & 255)
        let opacity = alpha ? (x % 11 == 0 ? 0 : (x % 7 == 0 ? 128 : 255)) : 255
        return [UInt8((red * opacity + 127) / 255), UInt8((green * opacity + 127) / 255), UInt8((blue * opacity + 127) / 255), UInt8(opacity)]
    }

    private static func inspectChunks(_ data: Data) throws -> (valid: Bool, idats: Int) {
        guard data.count >= 8, Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else { throw ScrollCaptureError.image }
        func integer(_ at: Int) -> Int {
            data[at..<(at + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        var cursor = 8, valid = true, idats = 0, ended = false
        while cursor + 12 <= data.count {
            let count = integer(cursor)
            guard count <= data.count - cursor - 12 else { throw ScrollCaptureError.image }
            let start = cursor + 4, end = cursor + 8 + count
            let chunk = data[start..<end]
            let actual = chunk.withUnsafeBytes { raw in crc32(0, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt(chunk.count)) }
            valid = valid && UInt32(actual) == UInt32(integer(end))
            let type = String(decoding: data[start..<(start + 4)], as: UTF8.self)
            if type == "IDAT" { idats += 1 }
            if type == "IEND" { ended = true }
            cursor += count + 12
        }
        return (valid && ended && cursor == data.count, idats)
    }
}
