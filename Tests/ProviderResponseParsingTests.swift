// Parses representative successes, raw provider errors, HTTP failures and malformed responses for all five services.
import XCTest
@testable import NikoShot

final class ProviderResponseParsingTests: XCTestCase {
    func testAllFiveSuccessShapes() throws {
        let baidu = try BaiduProvider.parseResponse(Data(#"{"from":"en","to":"zh","trans_result":[{"src":"hello","dst":"你好"},{"src":"world","dst":"世界"}]}"#.utf8))
        XCTAssertEqual(baidu.text, "你好\n世界"); XCTAssertEqual(baidu.detectedSource, .english)
        let google = try GoogleProvider.parseResponse(Data(#"{"data":{"translations":[{"translatedText":"你好","detectedSourceLanguage":"en"}]}}"#.utf8))
        XCTAssertEqual(google.text, "你好"); XCTAssertEqual(google.detectedSource, .english)
        let youdao = try YoudaoProvider.parseResponse(Data(#"{"errorCode":"0","translation":["你好","世界"],"l":"en2zh-CHS","requestId":"fixture-id"}"#.utf8))
        XCTAssertEqual(youdao.text, "你好\n世界"); XCTAssertEqual(youdao.detectedSource, .english)
        XCTAssertEqual(youdao.rawProviderInfo, "fixture-id")
        let deepl = try DeepLProvider.parseResponse(Data(#"{"translations":[{"text":"你好","detected_source_language":"EN"}]}"#.utf8))
        XCTAssertEqual(deepl.text, "你好"); XCTAssertEqual(deepl.detectedSource, .english)
        let custom = try CustomRESTProvider.parseResponse(Data(#"{"data":{"trans_result":[{"dst":"自定义译文"}]}}"#.utf8), responsePath: "data.trans_result.0.dst")
        XCTAssertEqual(custom.text, "自定义译文")
    }
    func testRawBaiduAndYoudaoProviderCodes() {
        XCTAssertThrowsError(try BaiduProvider.parseResponse(Data(#"{"error_code":"54003","error_msg":"Invalid Sign"}"#.utf8))) { error in
            XCTAssertEqual(error as? TranslationError, .provider(code: "54003", message: "Invalid Sign"))
        }
        XCTAssertThrowsError(try BaiduProvider.parseResponse(Data(#"{"error_code":58002,"error_msg":"Rate limited"}"#.utf8), statusCode: 429)) { error in
            XCTAssertEqual(error as? TranslationError, .provider(code: "58002", message: "Rate limited"))
        }
        XCTAssertThrowsError(try YoudaoProvider.parseResponse(Data(#"{"errorCode":"108","errorMsg":"Invalid application"}"#.utf8))) { error in
            XCTAssertEqual(error as? TranslationError, .provider(code: "108", message: "Invalid application"))
        }
        for (code, message) in ["111": "开发者账号无效", "203": "访问 IP 不在白名单内", "205": "接口与应用平台类型不一致", "206": "时间戳无效导致签名校验失败"] {
            XCTAssertThrowsError(try YoudaoProvider.parseResponse(Data("{\"errorCode\":\"\(code)\"}".utf8))) { error in
                XCTAssertEqual(error as? TranslationError, .provider(code: code, message: message))
            }
        }
        XCTAssertThrowsError(try YoudaoProvider.parseResponse(Data(#"{"errorCode":"206","errorMsg":"raw timestamp detail"}"#.utf8))) { error in
            XCTAssertEqual(error as? TranslationError, .provider(code: "206", message: "raw timestamp detail"))
        }
    }
    func testGoogle403And429MessageAndDeepLQuota() {
        for code in [403, 429] {
            XCTAssertThrowsError(try GoogleProvider.parseResponse(Data(#"{"error":{"code":403,"message":"API key not valid"}}"#.utf8), statusCode: code)) { error in
                XCTAssertEqual(error as? TranslationError, .http(code, "API key not valid"))
            }
        }
        XCTAssertThrowsError(try DeepLProvider.parseResponse(Data(#"{"message":"Quota exceeded"}"#.utf8), statusCode: 456)) { error in
            XCTAssertEqual(error as? TranslationError, .http(456, "Quota exceeded"))
        }
        XCTAssertThrowsError(try GoogleProvider.parseResponse(Data("upstream unavailable".utf8), statusCode: 503)) { error in
            XCTAssertEqual(error as? TranslationError, .http(503, "upstream unavailable"))
        }
    }
    func testCustomBodyPreviewAndInvalidJSONPaths() {
        let long = String(repeating: "错", count: 250)
        XCTAssertThrowsError(try CustomRESTProvider.parseResponse(Data(long.utf8), statusCode: 502, responsePath: "text")) { error in
            XCTAssertEqual(error as? TranslationError, .http(502, String(repeating: "错", count: 200)))
        }
        for path in ["items.9.text", "items.-1.text", "items.x.text", "items.0.missing", "items.0", "items..text"] {
            XCTAssertThrowsError(try CustomRESTProvider.parseResponse(Data(#"{"items":[{"text":"valid"}]}"#.utf8), responsePath: path)) { error in
                XCTAssertEqual(error as? TranslationError, .decode)
            }
        }
    }
    func testMalformedSuccessDoesNotCreateAnEmptyTranslation() {
        XCTAssertThrowsError(try BaiduProvider.parseResponse(Data(#"{"trans_result":[]}"#.utf8)))
        XCTAssertThrowsError(try GoogleProvider.parseResponse(Data("broken JSON".utf8)))
        XCTAssertThrowsError(try YoudaoProvider.parseResponse(Data(#"{"errorCode":"0","translation":[]}"#.utf8)))
        XCTAssertThrowsError(try DeepLProvider.parseResponse(Data(#"{"translations":[{"detected_source_language":"EN"}]}"#.utf8)))
    }
}
