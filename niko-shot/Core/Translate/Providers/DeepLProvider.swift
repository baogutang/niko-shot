// Selects DeepL Free/Pro by key suffix and the latency goal; DeepL controls the server-side model.
import Foundation

/// The DeepL text translation REST adapter.
public struct DeepLProvider: TranslationService {
    /// Its provider identifier.
    public let id: TranslationProviderID = .deepl
    /// The UI service label.
    public var displayName: String { id.displayName }
    private let session: URLSession
    private let credentials: KeychainStore
    /// Creates an adapter with injectable URLSession and Keychain values.
    public init(session: URLSession = .shared, credentials: KeychainStore = KeychainStore()) {
        self.session = session; self.credentials = credentials
    }
    /// Checks whether a DeepL key is configured.
    public func credentialsStatus() -> CredentialsStatus { !(credentials.get("deepl.key") ?? "").isEmpty ? .ready : .unconfigured }
    /// Resolves the documented Free or Pro endpoint, without inspecting or logging the key.
    public static func endpoint(for key: String) -> String {
        key.hasSuffix(":fx") ? "https://api-free.deepl.com/v2/translate" : "https://api.deepl.com/v2/translate"
    }
    /// Builds an authenticated JSON request; nil source omits source_lang.
    public static func makeRequest(_ request: TranslationRequest, key: String) throws -> URLRequest {
        guard !key.isEmpty else { throw TranslationError.unconfigured }
        guard !key.unicodeScalars.contains(where: { $0.value == 13 || $0.value == 10 }) else {
            throw TranslationError.provider(code: "invalid_credentials", message: "DeepL 密钥不能包含换行符。")
        }
        let (source, target) = try TranslationHTTP.languageCodes(request, provider: .deepl)
        var network = try TranslationHTTP.request(url: endpoint(for: key))
        network.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        network.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": [request.text], "target_lang": target, "model_type": "latency_optimized"]
        if let source { body["source_lang"] = source }
        network.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return network
    }
    /// Supports DeepL's actual detected_source_language field and legacy detect_source samples.
    public static func parseResponse(_ data: Data, statusCode: Int = 200) throws -> TranslationResult {
        let object = try? TranslationHTTP.json(data)
        try TranslationHTTP.requireSuccess(statusCode, data: data, message: object?["message"] as? String)
        guard let results = object?["translations"] as? [[String: Any]], let first = results.first,
              let text = first["text"] as? String else { throw TranslationError.decode }
        return TranslationResult(text: text,
                                 detectedSource: Language.detected(code: first["detected_source_language"] as? String ?? first["detect_source"] as? String, provider: .deepl))
    }
    /// Calls the selected DeepL endpoint exactly once.
    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        guard let key = credentials.get("deepl.key") else { throw TranslationError.unconfigured }
        let network = try Self.makeRequest(request, key: key)
        let (data, response) = try await TranslationHTTP.execute(network, session: session)
        return try Self.parseResponse(data, statusCode: response.statusCode)
    }
}
