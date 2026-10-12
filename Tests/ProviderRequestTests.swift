// Checks 15-second requests, classic-model selection, secure template expansion and parameter encoding.
import XCTest
@testable import NikoShot

final class ProviderRequestTests: XCTestCase {
    func testBaiduAndYoudaoFormRoundTrip() throws {
        let text = "中文\nquotes\" & plus+ equals= $KEY"
        let request = TranslationRequest(text: text, target: .traditionalChinese)
        let baidu = try BaiduProvider.makeRequest(request, appid: "app", secret: "secret", salt: "7")
        let b = try form(baidu)
        XCTAssertEqual(b["q"], text); XCTAssertEqual(b["from"], "auto"); XCTAssertEqual(b["to"], "cht")
        XCTAssertEqual(b["sign"], BaiduProvider.signature(appid: "app", text: text, salt: "7", secret: "secret"))
        XCTAssertEqual(baidu.timeoutInterval, 15); XCTAssertEqual(baidu.httpMethod, "POST")
        let youdao = try YoudaoProvider.makeRequest(request, appKey: "app", secret: "secret", salt: "7", curtime: "1700000000")
        let y = try form(youdao)
        XCTAssertEqual(y["q"], text); XCTAssertEqual(y["to"], "zh-CHT"); XCTAssertEqual(y["signType"], "v3")
        XCTAssertEqual(y["curtime"], "1700000000"); XCTAssertEqual(youdao.timeoutInterval, 15)
    }
    func testGoogleUsesBasicNMTAndOmitsAutomaticSource() throws {
        let request = try GoogleProvider.makeRequest(TranslationRequest(text: "a\n\"b\""), key: "key+&=")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first?.value, "key+&=")
        let body = try json(request)
        XCTAssertEqual(body["q"] as? String, "a\n\"b\""); XCTAssertEqual(body["model"] as? String, "nmt")
        XCTAssertEqual(body["target"] as? String, "zh-CN"); XCTAssertNil(body["source"])
        XCTAssertEqual(request.timeoutInterval, 15)
        let locked = try GoogleProvider.makeRequest(TranslationRequest(text: "hi", source: .japanese), key: "fixture")
        XCTAssertEqual(try json(locked)["source"] as? String, "ja")
    }
    func testDeepLTraditionalSourceAndTargetAreDifferentCodes() throws {
        let request = try DeepLProvider.makeRequest(TranslationRequest(text: "中文", source: .traditionalChinese, target: .traditionalChinese), key: "fixture:fx")
        XCTAssertEqual(request.url?.host, "api-free.deepl.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "DeepL-Auth-Key fixture:fx")
        let body = try json(request)
        XCTAssertEqual(body["source_lang"] as? String, "ZH"); XCTAssertEqual(body["target_lang"] as? String, "ZH-HANT")
        XCTAssertEqual(body["model_type"] as? String, "latency_optimized"); XCTAssertEqual(request.timeoutInterval, 15)
        let thai = try DeepLProvider.makeRequest(TranslationRequest(text: "hi", target: .thai), key: "fixture")
        XCTAssertEqual(try json(thai)["target_lang"] as? String, "TH")
        XCTAssertThrowsError(try DeepLProvider.makeRequest(TranslationRequest(text: "hi"), key: "fixture\r\nInjected: yes"))
    }
    func testCustomJSONSubstitutionCannotInjectFieldsOrExpandTextSecrets() throws {
        let configuration = CustomRESTConfiguration(name: "fixture", urlTemplate: "https://fixture.test/translate?q=$TEXT&key=$KEY",
                                                     headers: ["Authorization": "Bearer $KEY"],
                                                     bodyTemplate: #"{"q":"$TEXT","lang":["$SOURCE","$TARGET"],"options":{"enabled":true,"n":2},"key":"$KEY"}"#,
                                                     responsePath: "text")
        let text = "\"},\"injected\":true,\"q\":\"\n$KEY & = +"
        let request = try CustomRESTProvider.makeRequest(TranslationRequest(text: text), configuration: configuration, key: "key+&=")
        let body = try json(request)
        XCTAssertEqual(body["q"] as? String, text); XCTAssertNil(body["injected"])
        XCTAssertEqual(body["key"] as? String, "key+&="); XCTAssertEqual(body["lang"] as? [String], ["auto", "zh-CN"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key+&=")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, text)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "key" })?.value, "key+&=")
        XCTAssertEqual(request.timeoutInterval, 15)
    }
    func testCustomFormAndGETTemplates() throws {
        var configuration = CustomRESTConfiguration(name: "fixture", urlTemplate: "https://fixture.test/translate",
                                                     bodyTemplate: "q=$TEXT&from=$SOURCE&to=$TARGET&key=$KEY&literal=a%2Bb",
                                                     bodyFormat: .form, responsePath: "text")
        let text = "A&B + C=\n你好"
        let request = try CustomRESTProvider.makeRequest(TranslationRequest(text: text, source: .english), configuration: configuration, key: "fixture")
        let body = try form(request)
        XCTAssertEqual(body["q"], text); XCTAssertEqual(body["literal"], "a+b"); XCTAssertEqual(body["from"], "en")
        configuration.method = "GET"; configuration.urlTemplate += "?q=$TEXT&target=$TARGET&key=$KEY"; configuration.bodyTemplate = ""
        let get = try CustomRESTProvider.makeRequest(TranslationRequest(text: text), configuration: configuration, key: "fixture")
        XCTAssertEqual(get.httpMethod, "GET"); XCTAssertNil(get.httpBody)
    }
    func testCustomConfigurationRejectsCorruptJSONUnsafeHeadersAndFileURLs() {
        var configuration = CustomRESTConfiguration(name: "fixture", urlTemplate: "https://fixture.test/translate", bodyTemplate: "{q:$TEXT}", responsePath: "text")
        XCTAssertThrowsError(try CustomRESTProvider.makeRequest(TranslationRequest(text: "hi"), configuration: configuration, key: "fixture"))
        configuration.bodyTemplate = "{}"; configuration.headers = ["Authorization": "token $KEY"]
        XCTAssertThrowsError(try CustomRESTProvider.makeRequest(TranslationRequest(text: "hi"), configuration: configuration, key: "fixture\r\nInjected: yes"))
        configuration.headers = [:]; configuration.urlTemplate = "file:///tmp/fixture"
        XCTAssertThrowsError(try CustomRESTProvider.makeRequest(TranslationRequest(text: "hi"), configuration: configuration, key: "fixture"))
    }
    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private func form(_ request: URLRequest) throws -> [String: String] {
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        return body.split(separator: "&").reduce(into: [:]) { result, field in
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pair.first, pair.count == 2 else { return }
            result[String(key).removingPercentEncoding ?? ""] = String(pair[1]).removingPercentEncoding ?? ""
        }
    }
}
