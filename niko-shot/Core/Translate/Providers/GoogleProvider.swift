// Calls Cloud Translation Basic v2 with API-key authentication and an explicit classic NMT model.
import Foundation

/// The Google Cloud Translation Basic v2 REST adapter.
public struct GoogleProvider: TranslationService {
    /// Its provider identifier.
    public let id: TranslationProviderID = .google
    /// The UI service label.
    public var displayName: String { id.displayName }
    private let session: URLSession
    private let credentials: KeychainStore
    /// Creates an adapter with injectable URLSession and Keychain values.
    public init(session: URLSession = .shared, credentials: KeychainStore = KeychainStore()) {
        self.session = session; self.credentials = credentials
    }
    /// Checks whether the API key is configured.
    public func credentialsStatus() -> CredentialsStatus { !(credentials.get("google.key") ?? "").isEmpty ? .ready : .unconfigured }
    /// Builds a JSON request; absent source enables Google's detection.
    public static func makeRequest(_ request: TranslationRequest, key: String) throws -> URLRequest {
        guard !key.isEmpty else { throw TranslationError.unconfigured }
        let (source, target) = try TranslationHTTP.languageCodes(request, provider: .google)
        var network = try TranslationHTTP.request(url: "https://translation.googleapis.com/language/translate/v2?key=\(TranslationHTTP.encodeComponent(key))")
        network.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["q": request.text, "target": target, "format": "text", "model": "nmt"]
        if let source { body["source"] = source }
        network.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return network
    }
    /// Reads Google's plain text result and displays its structured error message for HTTP failures.
    public static func parseResponse(_ data: Data, statusCode: Int = 200) throws -> TranslationResult {
        let object = try? TranslationHTTP.json(data)
        let error = object?["error"] as? [String: Any]
        try TranslationHTTP.requireSuccess(statusCode, data: data, message: error?["message"] as? String)
        if let error {
            throw TranslationError.provider(code: TranslationHTTP.code(error["code"]) ?? "unknown", message: error["message"] as? String ?? "Google 翻译服务错误")
        }
        guard let body = object?["data"] as? [String: Any], let results = body["translations"] as? [[String: Any]],
              let first = results.first, let text = first["translatedText"] as? String else { throw TranslationError.decode }
        return TranslationResult(text: text, detectedSource: Language.detected(code: first["detectedSourceLanguage"] as? String, provider: .google))
    }
    /// Calls Google's Basic v2 API exactly once.
    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        guard let key = credentials.get("google.key") else { throw TranslationError.unconfigured }
        let network = try Self.makeRequest(request, key: key)
        let (data, response) = try await TranslationHTTP.execute(network, session: session)
        return try Self.parseResponse(data, statusCode: response.statusCode)
    }
}
