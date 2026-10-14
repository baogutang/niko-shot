// 像素级回归：平移、重复空白、撕裂/丢帧、回滚、固定栏、到底及超长输出。
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import NikoShot

@MainActor
final class RowHashStitcherTests: XCTestCase {
    func testHashMatchesKnownXXHash64Vectors() {
        XCTAssertEqual(Data().withUnsafeBytes { ExactRowHash.hash($0) }, 0xef46db3751d8e999)
        XCTAssertEqual(Data("a".utf8).withUnsafeBytes { ExactRowHash.hash($0) }, 0xd24ec4f1a98c6e5b)
        XCTAssertEqual(Data("abc".utf8).withUnsafeBytes { ExactRowHash.hash($0) }, 0x44bc2cf5ad770999)
    }

    func testProviderPaddingIsExcludedFromHashesAndCanonicalBytes() throws {
        let width = 11, height = 35, stride = 64
        func image(padding: UInt8) throws -> CGImage {
            var data = Data(repeating: padding, count: stride * height)
            data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                for y in 0..<height { for x in 0..<width {
                    let p = y * stride + x * 4
                    raw[p] = UInt8(x); raw[p + 1] = UInt8(y); raw[p + 2] = 21; raw[p + 3] = 255
                } }
            }
            guard let provider = CGDataProvider(data: data as CFData), let result = CGImage(width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScrollCaptureError.image }
            return result
        }
        let a = try RowHashFrame(image(padding: 0)), b = try RowHashFrame(image(padding: 212))
        XCTAssertEqual(a.bytes.count, width * height * 4)
        XCTAssertEqual(a.bytes, b.bytes); XCTAssertEqual(a.hashes, b.hashes)
    }

    func testOneAndFivePixelStepsProduceAnExactThreeScreenDocument() async throws {
        let fixture = ScrollImageFixture()
        var stitcher = RowHashStitcher()
        let offsets = [0, 1, 2, 7, 12, 137, 287, 430, 577, 732]
        for (i, offset) in offsets.enumerated() {
            let frame = try await fixture.frame(width: 64, height: 320, start: offset)
            XCTAssertEqual(try stitcher.append(frame), .appended(height: 320 + offset, frames: i + 1))
        }
        let expected = try await fixture.frame(width: 64, height: 1_052, start: 0)
        XCTAssertEqual(try RowHashFrame(stitcher.composedImage()).bytes, try RowHashFrame(expected).bytes)
    }

    func testRepeatedBlankLastRowsDoNotChooseTheFirstWhiteLineAsASeam() async throws {
        let fixture = ScrollImageFixture()
        var stitcher = RowHashStitcher()
        let blank = 270..<400
        let first = try await fixture.frame(width: 48, height: 320, start: 0, blankDocumentRows: blank)
        let next = try await fixture.frame(width: 48, height: 320, start: 5, blankDocumentRows: blank)
        _ = try stitcher.append(first)
        XCTAssertEqual(try stitcher.append(next), .appended(height: 325, frames: 2))
        let expected = try await fixture.frame(width: 48, height: 325, start: 0, blankDocumentRows: blank)
        XCTAssertEqual(try RowHashFrame(stitcher.composedImage()).bytes, try RowHashFrame(expected).bytes)
    }

    func testAWholeUnrelatedFrameIsSkippedAndTheAcceptedBoundarySurvives() async throws {
        let fixture = ScrollImageFixture()
        var stitcher = RowHashStitcher()
        let first = try await fixture.frame(width: 48, height: 320, start: 0)
        let lost = try await fixture.frame(width: 48, height: 320, start: 900)
        let recovered = try await fixture.frame(width: 48, height: 320, start: 160)
        _ = try stitcher.append(first)
        XCTAssertEqual(try stitcher.append(lost), .skipped)
        XCTAssertEqual(stitcher.height, 320); XCTAssertEqual(stitcher.frames, 1)
        XCTAssertEqual(try stitcher.append(recovered), .appended(height: 480, frames: 2))
        let expected = try await fixture.frame(width: 48, height: 480, start: 0)
        XCTAssertEqual(try RowHashFrame(stitcher.composedImage()).bytes, try RowHashFrame(expected).bytes)
    }

    func testTornFrameAndSingleChangedPixelNeverPassExactMatching() async throws {
        let fixture = ScrollImageFixture()
        var stitcher = RowHashStitcher()
        let first = try await fixture.frame(width: 48, height: 320, start: 0)
        let next = try await fixture.frame(width: 48, height: 320, start: 5)
        _ = try stitcher.append(first)
        let pixels = try RowHashFrame(next)
        var changed = pixels.bytes
        changed[48 * 4 * 200 + 1] ^= 1
        let corrupted = try Self.bgra(changed, width: 48, height: 320)
        XCTAssertEqual(try stitcher.append(corrupted), .skipped)
        XCTAssertEqual(try stitcher.append(next), .appended(height: 325, frames: 2))
    }

    func testBacktrackingIntoAccumulatedMiddleNeverAppendsOrMovesTheBoundary() async throws {
        let fixture = ScrollImageFixture()
        var stitcher = RowHashStitcher()
        for offset in [0, 100, 200, 300] { _ = try stitcher.append(try await fixture.frame(width: 48, height: 320, start: offset)) }
        let earlier = try await fixture.frame(width: 48, height: 320, start: 50)
        XCTAssertEqual(try stitcher.append(earlier), .duplicate)
        XCTAssertTrue(stitcher.isBacktracking); XCTAssertEqual(stitcher.height, 620)
        let next = try await fixture.frame(width: 48, height: 320, start: 305)
        XCTAssertEqual(try stitcher.append(next), .appended(height: 625, frames: 5))
        XCTAssertFalse(stitcher.isBacktracking)
    }

    func testStickyHeaderAndFooterAppearOnlyOnceAndKeepEveryBodyRow() async throws {
        let fixture = ScrollImageFixture()
        var stitcher = RowHashStitcher()
        let top = 21, bottom = 14, viewport = 355
        for offset in [0, 5, 10, 150, 300] {
            let image = try await fixture.frame(width: 64, height: viewport, start: offset, top: top, bottom: bottom, chromeDetail: true)
            guard case .appended = try stitcher.append(image) else { return XCTFail("Fixed chrome must not obscure the moving body") }
        }
        XCTAssertEqual(stitcher.ignoredTop, top); XCTAssertEqual(stitcher.ignoredBottom, bottom)
        try stitcher.includeFooter()
        let expected = try await fixture.frame(width: 64, height: viewport + 300, start: 0, top: top, bottom: bottom, chromeDetail: true)
        // Footer detail uses viewport y in the fixture; compare to the actual final footer.
        let reference = try RowHashFrame(expected)
        var bytes = reference.bytes
        let last = try RowHashFrame(try await fixture.frame(width: 64, height: viewport, start: 300, top: top, bottom: bottom, chromeDetail: true))
        bytes.replaceSubrange((viewport + 300 - bottom) * 64 * 4..<bytes.count,
            with: last.bytes.suffix(bottom * 64 * 4))
        XCTAssertEqual(try RowHashFrame(stitcher.composedImage()).bytes, bytes)
    }

    func testExplicitIgnoredBandsAreOmittedFromTheOutput() async throws {
        let fixture = ScrollImageFixture()
        var stitcher = RowHashStitcher(options: ScrollCaptureOptions(ignoredTop: 13, ignoredBottom: 7))
        for offset in [0, 5, 80] { _ = try stitcher.append(try await fixture.frame(width: 48, height: 340, start: offset, top: 13, bottom: 7)) }
        try stitcher.includeFooter()
        let expected = try await fixture.frame(width: 48, height: 400, start: 0)
        XCTAssertEqual(try RowHashFrame(stitcher.composedImage()).bytes, try RowHashFrame(expected).bytes)
    }

    func testWidthAndHeightChangesRequireRestartWithoutLosingAcceptedRows() async throws {
        var stitcher = RowHashStitcher(); let fixture = ScrollImageFixture()
        _ = try stitcher.append(try await fixture.frame(width: 48, height: 320, start: 0))
        for size in [(49, 320), (48, 321)] {
            let next = try await fixture.frame(width: size.0, height: size.1, start: 1)
            XCTAssertThrowsError(try stitcher.append(next)) { guard case ScrollTargetError.windowResized = $0 else { return XCTFail("Expected restart") } }
            XCTAssertEqual(stitcher.height, 320)
        }
    }

    func testBottomRequiresEightActualDuplicateScrollEvents() async throws {
        let image = try await ScrollImageFixture().frame(width: 48, height: 320, start: 0)
        let frame = try RowHashFrame(image)
        var detector = ScrollBottomDetector()
        XCTAssertFalse(detector.observe(frame, result: .appended(height: 320, frames: 1), isScrollEvent: false, backtracking: false, ignoredBottom: 0))
        for count in 1...8 {
            XCTAssertEqual(detector.observe(frame, result: .duplicate, isScrollEvent: true, backtracking: false, ignoredBottom: 0), count == 8)
        }
        XCTAssertFalse(detector.observe(frame, result: .skipped, isScrollEvent: true, backtracking: false, ignoredBottom: 0))
        XCTAssertEqual(detector.consecutiveDuplicates, 0)
    }

    func testWhiteTailAndWhitePageNeverProveBottomEvenWithChatBubblesAbove() async throws {
        let fixture = ScrollImageFixture()
        for image in [try await fixture.solid(width: 48, height: 320),
                      try await fixture.frame(width: 48, height: 320, start: 0, blankDocumentRows: 270..<400)] {
            let frame = try RowHashFrame(image); var detector = ScrollBottomDetector()
            XCTAssertTrue(frame.hasSolidTail())
            for _ in 0..<20 { XCTAssertFalse(detector.observe(frame, result: .duplicate, isScrollEvent: true, backtracking: false, ignoredBottom: 0)) }
            XCTAssertEqual(detector.consecutiveDuplicates, 0)
        }
    }

    func testThreeScreenWorkerPreviewAndPNGContainExactlyAcceptedPixelsAndReleaseResources() async throws {
        let fixture = ScrollImageFixture(), session = RowHashScrollSession()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("row-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for offset in [0, 200, 400, 600, 800] { _ = try await session.append(try await fixture.frame(width: 96, height: 360, start: offset)) }
        let preview = await session.livePreview
        XCTAssertEqual(preview?.sourceHeight, 1_160)
        let output = folder.appendingPathComponent("image.png")
        _ = try await session.finish(to: output)
        let inspected = try await fixture.inspect(output, expectedWidth: 96, expectedHeight: 1_160)
        XCTAssertEqual(inspected.maximumChannelDifference, 0)
        let resources = await session.resourceCounts
        XCTAssertEqual(resources.openFiles + resources.chunkFiles + resources.ownedDirectories + resources.residentBufferBytes, 0)
    }

    func testMoreThan32767RowsUsesChunkedPNGWithoutAFullCanvas() async throws {
        let fixture = ScrollImageFixture(), session = RowHashScrollSession(previewEnabled: false)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("row-chunk-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for offset in stride(from: 0, through: 33_000, by: 500) {
            _ = try await session.append(try await fixture.frame(width: 16, height: 600, start: offset))
        }
        let active = await session.resourceCounts
        XCTAssertGreaterThan(active.chunkFiles, 1)
        let output = folder.appendingPathComponent("image.png")
        _ = try await session.finish(to: output)
        let inspected = try await fixture.inspect(output, expectedWidth: 16, expectedHeight: 33_600)
        XCTAssertEqual(inspected.maximumChannelDifference, 0); XCTAssertTrue(inspected.validCRCs)
        let resources = await session.resourceCounts
        XCTAssertEqual(resources.residentBufferBytes + resources.openFiles + resources.chunkFiles + resources.ownedDirectories, 0)
    }

    func testRenderingVarianceMatchesGeometryButKeepsTheOriginalAcceptedPixels() async throws {
        let fixture = ScrollImageFixture()
        var strict = RowHashStitcher(), tolerant = RowHashStitcher(allowsRenderingVariance: true)
        let offsets = [0, 2, 7, 150, 300]
        var expected = Data()
        for (i, offset) in offsets.enumerated() {
            let source = try await fixture.frame(width: 128, height: 360, start: offset)
            let frame = try Self.renderingVariance(source, phase: i)
            let rows = try RowHashFrame(frame)
            if i == 0 { _ = try strict.append(frame); expected = rows.bytes }
            else {
                if i == 1 { XCTAssertEqual(try strict.append(frame), .skipped) }
                expected.append(rows.bytes.suffix((offset - offsets[i - 1]) * 128 * 4))
            }
            XCTAssertEqual(try tolerant.append(frame), .appended(height: 360 + offset, frames: i + 1))
        }
        XCTAssertEqual(try RowHashFrame(tolerant.composedImage()).bytes, expected,
                       "The tolerance is for validation only; output must never blur or average the captured pixels")
    }

    func testRenderingVarianceNeverAllowsAVisibleChangedPixelOrUnrelatedContent() async throws {
        let fixture = ScrollImageFixture()
        var stitcher = RowHashStitcher(allowsRenderingVariance: true)
        _ = try stitcher.append(try await fixture.frame(width: 128, height: 360, start: 0))
        let valid = try Self.renderingVariance(try await fixture.frame(width: 128, height: 360, start: 5), phase: 1)
        var changed = try RowHashFrame(valid).bytes
        changed[200 * 128 * 4 + 23] ^= 64
        XCTAssertEqual(try stitcher.append(Self.bgra(changed, width: 128, height: 360)), .skipped)
        let unrelated = try await fixture.frame(width: 128, height: 360, start: 0, seed: 999)
        XCTAssertEqual(try stitcher.append(unrelated), .skipped)
        XCTAssertEqual(try stitcher.append(valid), .appended(height: 365, frames: 2))
    }

    func testRenderingVarianceCannotInventMotionOnACompletelyFlatPage() async throws {
        let fixture = ScrollImageFixture()
        var stitcher = RowHashStitcher(allowsRenderingVariance: true)
        let white = try await fixture.solid(width: 128, height: 360)
        _ = try stitcher.append(white)
        XCTAssertEqual(try stitcher.append(Self.renderingVariance(white, phase: 1)), .skipped)
        XCTAssertEqual(stitcher.height, 360)
    }

    func testBGRADeviceRGBProviderKeepsItsPixelsAndColorSpaceDuringMatching() throws {
        var data = Data(repeating: 0, count: 64 * 64 * 4)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for p in stride(from: 0, to: raw.count, by: 4) { raw[p] = 248; raw[p + 1] = 251; raw[p + 2] = 252; raw[p + 3] = 255 }
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 256, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let frame = try RowHashFrame(image)
        XCTAssertEqual(frame.bytes, data)
        XCTAssertTrue(frame.image === image)
    }

    func testDitheredSolidTailStillCannotProveBottom() throws {
        var data = Data(repeating: 0, count: 128 * 360 * 4)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for p in stride(from: 0, to: raw.count, by: 4) { raw[p] = 230; raw[p + 1] = 241; raw[p + 2] = 251; raw[p + 3] = 255 }
        }
        let image = try Self.renderingVariance(Self.bgra(data, width: 128, height: 360), phase: 1)
        let frame = try RowHashFrame(image); var detector = ScrollBottomDetector()
        XCTAssertFalse(frame.hasSolidTail())
        XCTAssertTrue(frame.hasSolidTail(maximumDifference: 3))
        for _ in 0..<20 { XCTAssertFalse(detector.observe(frame, result: .duplicate, isScrollEvent: true, backtracking: false, ignoredBottom: 0)) }
    }

    private static func renderingVariance(_ image: CGImage, phase: Int) throws -> CGImage {
        let frame = try RowHashFrame(image)
        var bytes = frame.bytes
        bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for y in 0..<frame.height { for x in 0..<frame.width { for channel in 0..<3 {
                let p = (y * frame.width + x) * 4 + channel
                let noise = ((x * 31 + y * 11 + phase * 5 + channel) % 3) - 1
                raw[p] = UInt8(clamping: Int(raw[p]) + noise)
            } } }
        }
        return try bgra(bytes, width: frame.width, height: frame.height)
    }

    private static func bgra(_ bytes: Data, width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: bytes as CFData), let image = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScrollCaptureError.image }
        return image
    }
}
