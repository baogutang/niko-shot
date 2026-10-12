// Verifies raw-text signing against hardcoded official and independently computed UTF-8 fixtures.
import XCTest
@testable import NikoShot

final class ProviderSigningTests: XCTestCase {
    func testBaiduOfficialAppleVector() {
        XCTAssertEqual(BaiduProvider.signature(appid: "2015063000000001", text: "apple", salt: "1435660288", secret: "12345678"),
                       "f89f9594663708c1605f3d736d01d2d4")
    }
    func testBaiduSignsUnencodedUnicodeAndNewline() {
        XCTAssertEqual(BaiduProvider.signature(appid: "2015063000000001", text: "你好\nA&B + =%", salt: "1435660288", secret: "12345678"),
                       "b7a170eda23cf8c7570966ea9932db97")
    }
    func testYoudaoShortAndLongVectors() {
        XCTAssertEqual(YoudaoProvider.signature(appKey: "youdao-app-key", text: "hello", salt: "123456", curtime: "1700000000", secret: "test-secret"),
                       "cec6df22a943e9f86e8ed2aa38b25c7291e86e2454b998a2f076e7a098513da1")
        let long = "1234567890ABCDEFGHIJabcdefghij"
        XCTAssertEqual(YoudaoProvider.signingInput(long), "123456789030abcdefghij")
        XCTAssertEqual(YoudaoProvider.signature(appKey: "youdao-app-key", text: long, salt: "123456", curtime: "1700000000", secret: "test-secret"),
                       "b0c3cf972e8f50e7952dc011a3daea67b0154831ae1b64844a1d5ebf619501b2")
        XCTAssertEqual(YoudaoProvider.signingInput("12345678901234567890"), "12345678901234567890")
    }
    func testYoudaoUsesGraphemeCountInsteadOfUTF8OrUTF16() {
        let text = "123456789👨‍👩‍👧‍👦ABCDEFGHIJK"
        XCTAssertEqual(text.count, 21)
        XCTAssertEqual(YoudaoProvider.signingInput(text), "123456789👨‍👩‍👧‍👦21BCDEFGHIJK")
        XCTAssertEqual(YoudaoProvider.signature(appKey: "youdao-app-key", text: text, salt: "123456", curtime: "1700000000", secret: "test-secret"),
                       "db133cbb799c3d3d5b95cf65283a103a86fadd8bef0b9ccb110b5486fdf4ebbb")
    }
    func testDeepLEndpointOnlyUsesDocumentedSuffix() {
        XCTAssertEqual(DeepLProvider.endpoint(for: "fixture:fx"), "https://api-free.deepl.com/v2/translate")
        XCTAssertEqual(DeepLProvider.endpoint(for: "fixture"), "https://api.deepl.com/v2/translate")
        XCTAssertEqual(DeepLProvider.endpoint(for: "fixture:fx:extra"), "https://api.deepl.com/v2/translate")
    }
}
