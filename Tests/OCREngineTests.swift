// Checks actual Vision recognition of rendered mixed scripts and native fast-mode language limitations.
import CoreGraphics
import CoreText
import Foundation
import Vision
import XCTest
@testable import NikoShot

final class OCREngineTests: XCTestCase {
    func testMixedChineseEnglishAndJapanesePreserveSimplifiedCharactersAndKana() async throws {
        let image = try fixture([
            "Hello, world! · 简体汉语识别 · 日本語のテスト",
            "Native screenshot · 计算机截图边缘 · 画像のキャプチャ",
            "Capture 2026 · 测试结果与设备 · 今日は晴れです"
        ])
        for languages in [["zh-Hans", "en-US", "ja-JP"], ["en-US", "zh-Hans", "ja-JP"], ["ja-JP", "en-US", "zh-Hans"]] {
            let blocks = try await OCREngine().recognize(image, languages: languages)
            let text = blocks.map(\.text).joined(separator: "\n")
            for expected in ["Hello", "简体汉语识别", "计算机截图边缘", "日本語のテスト", "画像のキャプチャ", "今日は晴れです"] {
                XCTAssertTrue(text.contains(expected), "Missing \(expected) for \(languages):\n\(text)")
            }
            XCTAssertTrue(blocks.allSatisfy { $0.boundingBox.minX >= 0 && $0.boundingBox.maxX <= 1 && $0.boundingBox.minY >= 0 && $0.boundingBox.maxY <= 1 })
        }
    }

    func testEnglishFirstWithJapaneseEnabledPreservesNativeKanaWithoutChinese() async throws {
        let image = try fixture(["Native screenshot · 日本語のテスト · 画像のキャプチャ · 今日は晴れです"])
        for languages in [["en-US", "ja-JP"], ["ja-JP", "en-US"]] {
            let blocks = try await OCREngine().recognize(image, languages: languages)
            let text = blocks.map(\.text).joined(separator: "\n")
            for expected in ["Native screenshot", "日本語のテスト", "画像のキャプチャ", "今日は晴れです"] {
                XCTAssertTrue(text.contains(expected), "Missing \(expected) for \(languages):\n\(text)")
            }
        }
    }

    func testMissingPrimaryLineUsesRealSupplementalBoundsAndNativeChineseRecovery() throws {
        let image = try fixture([
            "Hello, world! · 简体汉语识别 · 日本語のテスト",
            "Native screenshot · 计算机截图边缘 · 画像のキャプチャ",
            "Capture 2026 · 测试结果与设备 · 今日は晴れです"
        ])
        let chinese = try nativeBlocks(image, languages: ["zh-Hans", "en-US", "ja-JP"])
        // Inject the observed platform failure at the observation boundary, leaving
        // the image and the Japanese supplemental detection entirely native.
        let primary = chinese.filter { $0.text.contains("Hello") || $0.text.contains("Capture 2026") }
        let supplemental = try nativeBlocks(image, languages: ["ja-JP", "zh-Hans", "en-US"])
        XCTAssertEqual(primary.count, 2)
        let detectedMiddle = try XCTUnwrap(supplemental.first { $0.text.contains("Native screenshot") })
        let blocks = try OCREngine.reconcile(image, primary: primary, supplemental: supplemental,
            languages: ["zh-Hans", "en-US", "ja-JP"])
        XCTAssertEqual(blocks.count, 3, "Recovery must preserve all lines without duplicating native observations")
        let middle = try XCTUnwrap(blocks.first { $0.text.contains("Native screenshot") })
        XCTAssertTrue(middle.text.contains("计算机截图边缘"), middle.text)
        XCTAssertTrue(middle.text.contains("画像のキャプチャ"), middle.text)
        // Recovery must retain the native source line's location, while substring
        // selection maps tight-crop recognition geometry back into the source image.
        XCTAssertEqual(middle.boundingBox.midY, detectedMiddle.boundingBox.midY, accuracy: 0.04)
        XCTAssertTrue(blocks.allSatisfy { $0.boundingBox.minX >= 0 && $0.boundingBox.maxX <= 1 && $0.boundingBox.minY >= 0 && $0.boundingBox.maxY <= 1 })
        let text = blocks.map(\.text).joined(separator: "\n")
        for expected in ["简体汉语识别", "日本語のテスト", "测试结果与设备", "今日は晴れです"] {
            XCTAssertTrue(text.contains(expected), text)
        }
    }

    func testSupplementalMergePreservesDisjointLowConfidenceBlocksWithoutDuplicateOrHanReplacement() {
        let primary = OCRBlock(text: "简体汉语识别 日本語の", boundingBox: CGRect(x: 0.05, y: 0.7, width: 0.7, height: 0.1), confidence: 0.5)
        let overlapping = OCRBlock(text: "筒体次語沢別 日本語のテスト", boundingBox: CGRect(x: 0.05, y: 0.7, width: 0.8, height: 0.1), confidence: 0.5)
        let independent = OCRBlock(text: "画像のキャプチャ", boundingBox: CGRect(x: 0.05, y: 0.4, width: 0.5, height: 0.1), confidence: 0.1)
        let blocks = OCREngine.mergingRecognitions(primary: [primary], supplemental: [overlapping, independent, independent])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.first?.id, primary.id)
        XCTAssertEqual(blocks.first?.text, "简体汉语识别 日本語のテスト")
        XCTAssertEqual(blocks.last?.id, independent.id)
        XCTAssertEqual(blocks.last?.text, independent.text)
        XCTAssertEqual(OCREngine.mergingRecognitions(primary: [], supplemental: [independent]).map(\.id), [independent.id])
    }

    func testFastRequestPreservesEnabledScriptsUnsupportedByNativeFastModel() async throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        let fastLanguages = try request.supportedRecognitionLanguages()
        let image = try fixture(["Native capture · 屏幕截图与测试 · 写真のカメラ"])
        let blocks = try await OCREngine().recognize(image, languages: ["zh-Hans", "en-US", "ja-JP"], accurate: false)
        let text = blocks.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("Native capture"), text)
        XCTAssertTrue(text.contains("屏幕截图与测试"), text)
        XCTAssertTrue(text.contains("写真のカメラ"), text)
        // The test exercises the platform's real support query, rather than a mocked language table.
        if !fastLanguages.contains("zh-Hans") || !fastLanguages.contains("ja-JP") {
            XCTAssertFalse(blocks.isEmpty, "Unsupported enabled scripts must retain accurate recognition")
        }
    }

    func testPureEnglishFastRecognitionUsesRealVision() async throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        XCTAssertTrue(try request.supportedRecognitionLanguages().contains("en-US"))
        let image = try fixture(["NATIVE SCREEN CAPTURE 2026"])
        let blocks = try await OCREngine().recognize(image, languages: ["en-US"], accurate: false)
        let text = blocks.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("NATIVE SCREEN CAPTURE"), text)
        XCTAssertTrue(text.contains("2026"), text)
    }

    private func nativeBlocks(_ image: CGImage, languages: [String]) throws -> [OCRBlock] {
        try autoreleasepool {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            request.automaticallyDetectsLanguage = false
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap(OCREngine.nativeBlock)
        }
    }

    private func fixture(_ lines: [String]) throws -> CGImage {
        try autoreleasepool {
            let width = 2400, height = 100 + lines.count * 110
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.textMatrix = .identity
            let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            for (index, text) in lines.enumerated() {
                context.textPosition = CGPoint(x: 40, y: height - 90 - index * 110)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            }
            return try XCTUnwrap(context.makeImage())
        }
    }
}
