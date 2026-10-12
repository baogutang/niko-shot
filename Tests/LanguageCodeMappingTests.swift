// Fixes all fifteen canonical language mappings and source/target Chinese distinctions.
import XCTest
@testable import NikoShot

final class LanguageCodeMappingTests: XCTestCase {
    func testFullProviderTables() {
        let expected: [TranslationProviderID: [String?]] = [
            .baidu: ["zh", "cht", "en", "jp", "kor", "fra", "de", "spa", "pt", "ru", "it", "th", "ara", "vie", "id"],
            .google: ["zh-CN", "zh-TW", "en", "ja", "ko", "fr", "de", "es", "pt", "ru", "it", "th", "ar", "vi", "id"],
            .youdao: ["zh-CHS", "zh-CHT", "en", "ja", "ko", "fr", "de", "es", "pt", "ru", "it", "th", "ar", "vi", "id"],
            .deepl: ["ZH", "ZH-HANT", "EN", "JA", "KO", "FR", "DE", "ES", "PT", "RU", "IT", "TH", "AR", "VI", "ID"],
            .custom: ["zh-CN", "zh-TW", "en", "ja", "ko", "fr", "de", "es", "pt", "ru", "it", "th", "ar", "vi", "id"]
        ]
        XCTAssertGreaterThanOrEqual(Language.allCases.count, 14)
        for provider in TranslationProviderID.allCases {
            XCTAssertEqual(Language.allCases.map { $0.code(for: provider) }, expected[provider])
        }
    }
    func testDeepLSourceVariantsAndDetectedCodes() {
        XCTAssertEqual(Language.traditionalChinese.sourceCode(for: .deepl), "ZH")
        XCTAssertEqual(Language.traditionalChinese.code(for: .deepl), "ZH-HANT")
        XCTAssertTrue(Language.thai.supports(provider: .deepl))
        XCTAssertTrue(Language.vietnamese.supports(provider: .deepl, asSource: true))
        XCTAssertEqual(Language.detected(code: "jp", provider: .baidu), .japanese)
        XCTAssertEqual(Language.detected(code: "zh-CHT", provider: .youdao), .traditionalChinese)
        XCTAssertEqual(Language.detected(code: "EN-US", provider: .deepl), .english)
        XCTAssertEqual(Language.detected(code: "PT-BR", provider: .deepl), .portuguese)
        XCTAssertNil(Language.detected(code: "unknown", provider: .google))
    }
    func testCaiyunUnsupportedPairAndOfficialPresetCodes() throws {
        let preset = try XCTUnwrap(CustomRESTConfiguration.presets.first)
        XCTAssertNil(preset.unsupportedReason(source: .english, target: .traditionalChinese))
        XCTAssertNotNil(preset.unsupportedReason(source: .english, target: .japanese))
        XCTAssertNotNil(preset.unsupportedReason(source: .thai, target: .simplifiedChinese))
        XCTAssertNil(preset.unsupportedReason(source: .simplifiedChinese, target: .japanese))
        let request = try CustomRESTProvider.makeRequest(TranslationRequest(text: "hello", source: .english, target: .traditionalChinese), configuration: preset, key: "fixture")
        let object = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertEqual(object?["trans_type"] as? String, "en2zh-Hant")
    }
}
