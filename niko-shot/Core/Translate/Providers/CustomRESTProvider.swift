// Safely expands user-authored REST templates and extracts a string from a dotted JSON response path.
import Foundation

/// A serializable REST template; its secret is referenced by a separate Keychain account.
public struct CustomRESTConfiguration: Codable, Equatable, Identifiable, Sendable {
    /// The wire representation of the body template.
    public enum BodyFormat: String, CaseIterable, Codable, Sendable {
        case json, form
        /// The native settings picker label.
        public var displayName: String { self == .json ? "JSON" : "Form" }
    }
    /// Preset-specific code conventions; arbitrary services default to the generic BCP-47 mapping.
    public enum LanguageStyle: String, CaseIterable, Codable, Sendable { case generic, caiyun, libreTranslate }
    /// A stable instance identity, independent of its editable name.
    public var id: UUID
    /// The user-visible service name.
    public var name: String
    /// The HTTP method, normally POST.
    public var method: String
    /// A URL containing optional $KEY, $TEXT, $SOURCE and $TARGET placeholders.
    public var urlTemplate: String
    /// Header value templates, normally including an authentication header.
    public var headers: [String: String]
    /// A valid JSON document or URL-encoded form template.
    public var bodyTemplate: String
    /// The selected template encoding.
    public var bodyFormat: BodyFormat
    /// A dotted JSON path whose array components are decimal indexes.
    public var responsePath: String
    /// Language code and pair restrictions for an official built-in preset.
    public var languageStyle: LanguageStyle
    /// The instance's Keychain account; no secret is serialized into this configuration.
    public var keyAccount: String { "custom.\(id.uuidString).key" }
    /// Authentication is optional for services whose request templates do not reference a key.
    public var requiresAPIKey: Bool {
        if urlTemplate.contains("$KEY") || headers.values.contains(where: { $0.contains("$KEY") }) { return true }
        switch bodyFormat {
        case .json:
            // Request expansion happens after JSON decoding, including Unicode escapes.
            guard let value = try? JSONSerialization.jsonObject(with: Data(bodyTemplate.utf8), options: .fragmentsAllowed) else { return false }
            return Self.referencesKey(value)
        case .form:
            // Both form field names and values are decoded before template expansion.
            return bodyTemplate.components(separatedBy: "&").contains { field in
                field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).contains { part in
                    let raw = String(part).replacingOccurrences(of: "+", with: " ")
                    return (raw.removingPercentEncoding ?? raw).contains("$KEY")
                }
            }
        }
    }

    private static func referencesKey(_ value: Any) -> Bool {
        if let string = value as? String { return string.contains("$KEY") }
        if let array = value as? [Any] { return array.contains(where: referencesKey) }
        if let object = value as? [String: Any] { return object.values.contains(where: referencesKey) }
        return false
    }
    /// Creates a REST template ready for editing or cloning with a fresh UUID.
    public init(id: UUID = UUID(), name: String, method: String = "POST", urlTemplate: String,
                headers: [String: String] = [:], bodyTemplate: String, bodyFormat: BodyFormat = .json,
                responsePath: String, languageStyle: LanguageStyle = .generic) {
        self.id = id; self.name = name; self.method = method; self.urlTemplate = urlTemplate
        self.headers = headers; self.bodyTemplate = bodyTemplate; self.bodyFormat = bodyFormat
        self.responsePath = responsePath; self.languageStyle = languageStyle
    }
    /// Two real classic translation templates; clone them before storing an independent credential.
    public static var presets: [CustomRESTConfiguration] {
        [CustomRESTConfiguration(name: "彩云小译", urlTemplate: "https://api.interpreter.caiyunai.com/v1/translator",
                                 headers: ["X-Authorization": "token $KEY"],
                                 bodyTemplate: #"{"source":["$TEXT"],"trans_type":"$SOURCE2$TARGET","detect":true,"media":"text"}"#,
                                 responsePath: "target.0", languageStyle: .caiyun),
         CustomRESTConfiguration(name: "LibreTranslate", urlTemplate: "https://libretranslate.com/translate",
                                 bodyTemplate: #"{"q":"$TEXT","source":"$SOURCE","target":"$TARGET","format":"text","api_key":"$KEY"}"#,
                                 responsePath: "translatedText", languageStyle: .libreTranslate)]
    }
    /// Explains preset pair restrictions so the UI can disable unsupported combinations.
    public func unsupportedReason(source: Language?, target: Language) -> String? {
        guard languageStyle == .caiyun else { return nil }
        let chinese: Set<Language> = [.simplifiedChinese, .traditionalChinese]
        let chineseSources: Set<Language> = [.simplifiedChinese, .traditionalChinese, .english, .japanese, .korean,
                                           .french, .german, .spanish, .portuguese, .russian, .italian, .vietnamese]
        if chinese.contains(target) {
            if let source, !chineseSources.contains(source) { return "彩云小译暂不支持该源语言→中文的翻译方向。" }
            if source == target { return "彩云小译不支持相同语言之间的翻译。" }
            return nil
        }
        if [.english, .japanese, .korean].contains(target), source == nil || source.map(chinese.contains) == true { return nil }
        return "彩云小译的该目标语言仅接受中文原文；请使用其支持的语言方向。"
    }
    func code(_ language: Language) -> String {
        switch languageStyle {
        case .generic: return language.code(for: .custom) ?? ""
        case .caiyun:
            if language == .simplifiedChinese { return "zh" }
            if language == .traditionalChinese { return "zh-Hant" }
            return language.code(for: .custom) ?? ""
        case .libreTranslate:
            if language == .simplifiedChinese { return "zh" }
            if language == .traditionalChinese { return "zt" }
            return language.code(for: .custom) ?? ""
        }
    }
}

/// A user-defined REST adapter whose only secret is supplied by the Keychain.
public struct CustomRESTProvider: TranslationService {
    /// Its equal-rank provider identifier.
    public let id: TranslationProviderID = .custom
    /// The configured instance name.
    public var displayName: String { configuration.name }
    /// The immutable request template selected for this adapter.
    public let configuration: CustomRESTConfiguration
    private let session: URLSession
    private let credentials: KeychainStore
    /// Creates a custom adapter with injectable transport and credentials.
    public init(configuration: CustomRESTConfiguration, session: URLSession = .shared, credentials: KeychainStore = KeychainStore()) {
        self.configuration = configuration; self.session = session; self.credentials = credentials
    }
    /// Accepts key-free self-hosted services, otherwise requires the instance's Keychain value.
    public func credentialsStatus() -> CredentialsStatus {
        !configuration.requiresAPIKey || credentials.contains(configuration.keyAccount) ? .ready : .unconfigured
    }
    /// Builds JSON structurally before substitutions, so quotes and newlines cannot corrupt or inject its body.
    public static func makeRequest(_ request: TranslationRequest, configuration: CustomRESTConfiguration, key: String) throws -> URLRequest {
        guard !configuration.requiresAPIKey || !key.isEmpty else { throw TranslationError.unconfigured }
        if let reason = configuration.unsupportedReason(source: request.source, target: request.target) {
            throw TranslationError.provider(code: "unsupported_language", message: reason)
        }
        let substitutions = ["$KEY": key, "$TEXT": request.text, "$SOURCE": request.source.map(configuration.code) ?? "auto", "$TARGET": configuration.code(request.target)]
        let method = configuration.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(method) else {
            throw TranslationError.provider(code: "invalid_configuration", message: "不支持的 HTTP Method。")
        }
        let url = replacing(configuration.urlTemplate, values: substitutions.mapValues(TranslationHTTP.encodeComponent))
        var network = try TranslationHTTP.request(url: url)
        network.httpMethod = method
        network.setValue(configuration.bodyFormat == .json ? "application/json; charset=utf-8" : "application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let tokens = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        for (name, template) in configuration.headers {
            let value = replacing(template, values: substitutions)
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(tokens.contains),
                  !value.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) else {
                throw TranslationError.provider(code: "invalid_configuration", message: "HTTP Header 名称或值无效。")
            }
            network.setValue(value, forHTTPHeaderField: name)
        }
        if !configuration.bodyTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if method == "GET" || method == "HEAD" {
                throw TranslationError.provider(code: "invalid_configuration", message: "GET/HEAD 请将参数写入 URL 模板并留空 Body。")
            }
            switch configuration.bodyFormat {
            case .json:
                guard let template = try? JSONSerialization.jsonObject(with: Data(configuration.bodyTemplate.utf8), options: .fragmentsAllowed) else {
                    throw TranslationError.provider(code: "invalid_configuration", message: "Body 模板不是有效 JSON；占位符应放在 JSON 字符串内部。")
                }
                network.httpBody = try JSONSerialization.data(withJSONObject: expandJSON(template, values: substitutions), options: [.sortedKeys, .fragmentsAllowed])
            case .form:
                var fields: [String: String] = [:]
                for field in configuration.bodyTemplate.components(separatedBy: "&") where !field.isEmpty {
                    let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard let name = pair.first else { continue }
                    let decodedName = decodeForm(String(name))
                    let value = pair.count > 1 ? decodeForm(String(pair[1])) : ""
                    fields[replacing(decodedName, values: substitutions)] = replacing(value, values: substitutions)
                }
                network.httpBody = TranslationHTTP.form(fields)
            }
        }
        return network
    }
    /// Extracts a string at a dotted path and retains a status plus 200-character body for HTTP errors.
    public static func parseResponse(_ data: Data, statusCode: Int = 200, responsePath: String, redacting credentials: [String] = []) throws -> TranslationResult {
        try TranslationHTTP.requireSuccess(statusCode, data: data, redacting: credentials)
        guard var value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { throw TranslationError.decode }
        let components = responsePath.split(separator: ".", omittingEmptySubsequences: false)
        for component in components {
            if let dictionary = value as? [String: Any], let child = dictionary[String(component)] { value = child }
            else if let array = value as? [Any], let index = Int(component), array.indices.contains(index) { value = array[index] }
            else { throw TranslationError.decode }
        }
        guard let text = value as? String else { throw TranslationError.decode }
        return TranslationResult(text: text)
    }
    /// Calls exactly this configured instance once.
    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let key = credentials.get(configuration.keyAccount) ?? ""
        return try await TranslationHTTP.withRedactedErrors(credentials: [key]) {
            let network = try Self.makeRequest(request, configuration: configuration, key: key)
            let (data, response) = try await TranslationHTTP.execute(network, session: session)
            return try Self.parseResponse(data, statusCode: response.statusCode, responsePath: configuration.responsePath, redacting: [key])
        }
    }
    private static func replacing(_ template: String, values: [String: String]) -> String {
        // Scan only the original template. Substituted user text containing "$KEY" stays literal.
        var output = ""
        var remainder = template[...]
        let placeholders = ["$SOURCE", "$TARGET", "$TEXT", "$KEY"]
        while let first = remainder.first {
            if first == "$", let token = placeholders.first(where: { remainder.hasPrefix($0) }) {
                output.append(values[token] ?? ""); remainder = remainder.dropFirst(token.count)
            } else { output.append(first); remainder = remainder.dropFirst() }
        }
        return output
    }
    private static func expandJSON(_ value: Any, values: [String: String]) -> Any {
        if let string = value as? String { return replacing(string, values: values) }
        if let array = value as? [Any] { return array.map { expandJSON($0, values: values) } }
        if let object = value as? [String: Any] { return object.mapValues { expandJSON($0, values: values) } }
        return value
    }
    private static func decodeForm(_ value: String) -> String { value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value }
}
