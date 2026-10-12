// Defines equal-rank REST providers, canonical language mappings and shared translation values.
import Foundation

/// A user-selected REST translation service; ordering never implies fallback priority.
public enum TranslationProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case baidu, google, youdao, deepl, custom
    /// A stable SwiftUI identity.
    public var id: String { rawValue }
    /// The native settings and result-panel label.
    public var displayName: String {
        switch self {
        case .baidu: "百度"
        case .google: "Google"
        case .youdao: "有道"
        case .deepl: "DeepL"
        case .custom: "自定义 REST"
        }
    }
    /// Keychain account names required by this provider (custom instances supply their own).
    public var credentialAccounts: [String] {
        switch self {
        case .baidu: ["baidu.appid", "baidu.secret"]
        case .google: ["google.key"]
        case .youdao: ["youdao.appKey", "youdao.appSecret"]
        case .deepl: ["deepl.key"]
        case .custom: []
        }
    }
}

/// The application's language vocabulary, independent of provider-specific spelling.
public enum Language: String, CaseIterable, Codable, Identifiable, Sendable {
    case simplifiedChinese, traditionalChinese, english, japanese, korean
    case french, german, spanish, portuguese, russian, italian, thai, arabic, vietnamese, indonesian
    /// A stable SwiftUI identity.
    public var id: String { rawValue }
    /// The localized language picker label.
    public var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁体中文"
        case .english: "英语"
        case .japanese: "日语"
        case .korean: "韩语"
        case .french: "法语"
        case .german: "德语"
        case .spanish: "西班牙语"
        case .portuguese: "葡萄牙语"
        case .russian: "俄语"
        case .italian: "意大利语"
        case .thai: "泰语"
        case .arabic: "阿拉伯语"
        case .vietnamese: "越南语"
        case .indonesian: "印度尼西亚语"
        }
    }
    /// The target-language code accepted by the provider's translation endpoint.
    public func code(for provider: TranslationProviderID) -> String? {
        let index = Self.allCases.firstIndex(of: self) ?? 0
        switch provider {
        case .baidu:
            return ["zh", "cht", "en", "jp", "kor", "fra", "de", "spa", "pt", "ru", "it", "th", "ara", "vie", "id"][index]
        case .google, .custom:
            return ["zh-CN", "zh-TW", "en", "ja", "ko", "fr", "de", "es", "pt", "ru", "it", "th", "ar", "vi", "id"][index]
        case .youdao:
            return ["zh-CHS", "zh-CHT", "en", "ja", "ko", "fr", "de", "es", "pt", "ru", "it", "th", "ar", "vi", "id"][index]
        case .deepl:
            // The current official model-type documentation supports every pair with latency_optimized.
            return ["ZH", "ZH-HANT", "EN", "JA", "KO", "FR", "DE", "ES", "PT", "RU", "IT", "TH", "AR", "VI", "ID"][index]
        }
    }
    /// The source-language spelling; DeepL source Chinese uses its base language code.
    public func sourceCode(for provider: TranslationProviderID) -> String? {
        if provider == .deepl, self == .traditionalChinese { return "ZH" }
        return code(for: provider)
    }
    /// Whether a language is enabled in a provider's source or target picker.
    public func supports(provider: TranslationProviderID, asSource: Bool = false) -> Bool {
        asSource ? sourceCode(for: provider) != nil : code(for: provider) != nil
    }
    /// Recovers the canonical value from a provider's detected-source code.
    public static func detected(code: String?, provider: TranslationProviderID) -> Language? {
        guard let code else { return nil }
        let normalized = code.lowercased().replacingOccurrences(of: "_", with: "-")
        if ["zh", "zh-cn", "zh-hans", "zh-chs"].contains(normalized) { return .simplifiedChinese }
        if ["cht", "zh-tw", "zh-hant", "zh-cht"].contains(normalized) { return .traditionalChinese }
        if normalized.hasPrefix("en-") { return .english }
        if normalized.hasPrefix("pt-") { return .portuguese }
        return allCases.first { $0.sourceCode(for: provider)?.lowercased() == normalized }
    }
}

/// A complete translation request; nil source delegates language detection to the provider.
public struct TranslationRequest: Hashable, Sendable {
    /// Text is transmitted verbatim and signs its original UTF-8 bytes.
    public let text: String
    /// An optional locked source language.
    public let source: Language?
    /// The selected output language.
    public let target: Language
    /// Creates a request defaulting to automatic detection and simplified Chinese output.
    public init(text: String, source: Language? = nil, target: Language = .simplifiedChinese) {
        self.text = text; self.source = source; self.target = target
    }
}

/// A provider result, including its detected source and optional response metadata.
public struct TranslationResult: Equatable, Sendable {
    /// The translated plain text.
    public let text: String
    /// The detected source when returned by the service.
    public let detectedSource: Language?
    /// Non-secret provider metadata, such as its request identifier.
    public let rawProviderInfo: String?
    /// Creates a provider result.
    public init(text: String, detectedSource: Language? = nil, rawProviderInfo: String? = nil) {
        self.text = text; self.detectedSource = detectedSource; self.rawProviderInfo = rawProviderInfo
    }
}

/// Whether all credentials needed by the selected provider are present.
public enum CredentialsStatus: String, Sendable { case unconfigured, ready }

/// Errors preserve HTTP status and provider codes for inline display, without trying another service.
public enum TranslationError: Error, LocalizedError, Equatable, Sendable {
    case http(Int, String)
    case provider(code: String, message: String)
    case decode
    case unconfigured
    case cancelled
    /// A readable error that preserves the original provider or HTTP code.
    public var errorDescription: String? {
        switch self {
        case .http(let code, let message): "[HTTP \(code)] \(message)"
        case .provider(let code, let message): "[error_code \(code)] \(message)"
        case .decode: "翻译服务返回了无法解析的响应。"
        case .unconfigured: "请先在设置中配置当前翻译服务的密钥。"
        case .cancelled: "翻译已取消。"
        }
    }
    /// Formats the current service's failure for a native result row.
    public func displayMessage(provider: TranslationProviderID) -> String {
        switch self {
        case .provider(let code, let message): "[\(provider.displayName) error_code \(code)] \(message)"
        case .http(let code, let message): "[\(provider.displayName) HTTP \(code)] \(message)"
        default: errorDescription ?? "翻译失败"
        }
    }
}

/// A stateless classic-translation REST adapter with an injectable network session.
public protocol TranslationService: Sendable {
    /// The service's equal-rank identifier.
    var id: TranslationProviderID { get }
    /// Its display label.
    var displayName: String { get }
    /// Reports the presence of its required Keychain values.
    func credentialsStatus() -> CredentialsStatus
    /// Translates exactly once, with no retry or provider fallback.
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
}
