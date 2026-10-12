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
    // New Unicode vectors were computed independently with Python3 stdlib hashlib.sha256 over UTF-8.
    // They follow the official AuthV3Util.py len/q[:10]/q[-10:] convention, without Unicode normalization.
    func testYoudaoTwentyAndTwentyOneCodePointBoundary() {
        let twenty = "12345678901234567890"
        XCTAssertEqual(YoudaoProvider.signingInput(twenty), twenty)
        XCTAssertEqual(youdaoSignature(twenty), "4a4efc07b91a8e25619fe965e8fe3bcabb58b93e4ef584f685bdb115718fb66f")
        let twentyOne = "1234567890ABCDEFGHIJK"
        XCTAssertEqual(YoudaoProvider.signingInput(twentyOne), "123456789021BCDEFGHIJK")
        XCTAssertEqual(youdaoSignature(twentyOne), "7bf3f4f587ebf5014cb4e96a5ca91d30bf795b29e3a307dd4cdb17d4c480ad87")
    }
    func testYoudaoNFDCombiningMarksCountAsSeparateCodePointsWithoutNormalization() {
        let twenty = "123456789e\u{0301}ABCDEFGHI"
        XCTAssertEqual(Array(YoudaoProvider.signingInput(twenty).utf8), Array(twenty.utf8))
        XCTAssertEqual(youdaoSignature(twenty), "c4e5710cb43342a8181e62292cbf0fab7411d8f4ab79dca198da150e6e42f724")
        let twentyOne = "123456789e\u{0301}ABCDEFGHIJ"
        XCTAssertEqual(YoudaoProvider.signingInput(twentyOne), "123456789e21ABCDEFGHIJ")
        XCTAssertEqual(youdaoSignature(twentyOne), "895bf215bc65eac1d41b94dc5d522ed9b22f93463b047fd98e61510730335e50")
    }
    func testYoudaoNonBMPCharactersMatchPythonCodePointsAndRemainValidUTF8() {
        let twenty = "123456789😀ABCDEFGHIJ"
        XCTAssertEqual(YoudaoProvider.signingInput(twenty), twenty)
        XCTAssertEqual(youdaoSignature(twenty), "ea4492c5188eee02b8dffeedff888fde14e558f94d91e9b7a14590dd41f8a3fc")
        let twentyOne = "123456789😀ABCDEFGHIJK"
        XCTAssertEqual(YoudaoProvider.signingInput(twentyOne), "123456789😀21BCDEFGHIJK")
        XCTAssertEqual(youdaoSignature(twentyOne), "9f6663fcbd827fa3e9f1460babece7dfe60214e8190a70e01d4345ee65498618")
    }
    func testYoudaoZWJSequenceMatchesPythonCodePoints() {
        let text = "123456789👨‍👩‍👧‍👦ABCDEFGHIJK"
        XCTAssertEqual(YoudaoProvider.signingInput(text), "123456789👨27BCDEFGHIJK")
        XCTAssertEqual(youdaoSignature(text), "20a8de623e34132b63c46e1a2241cabef6b9aab821dc82a979dc48fa3382f01a")
        let threeFamilies = String(repeating: "👨‍👩‍👧‍👦", count: 3)
        XCTAssertEqual(YoudaoProvider.signingInput(threeFamilies), "👨‍👩‍👧‍👦👨‍👩21👧‍👦👨‍👩‍👧‍👦")
        XCTAssertEqual(youdaoSignature(threeFamilies), "b0ff42e7f613d79f251f7154bf15135dc3b4100206ffd4aedb39e51ae7c65ece")
    }
    func testDeepLEndpointOnlyUsesDocumentedSuffix() {
        XCTAssertEqual(DeepLProvider.endpoint(for: "fixture:fx"), "https://api-free.deepl.com/v2/translate")
        XCTAssertEqual(DeepLProvider.endpoint(for: "fixture"), "https://api.deepl.com/v2/translate")
        XCTAssertEqual(DeepLProvider.endpoint(for: "fixture:fx:extra"), "https://api.deepl.com/v2/translate")
    }
    private func youdaoSignature(_ text: String) -> String {
        YoudaoProvider.signature(appKey: "youdao-app-key", text: text, salt: "123456", curtime: "1700000000", secret: "test-secret")
    }
}
