// Implements Baidu's classic signed form API using the original, unencoded UTF-8 text.
import Foundation
import CryptoKit

/// The Baidu general translation REST adapter.
public struct BaiduProvider: TranslationService {
    /// Its provider identifier.
    public let id: TranslationProviderID = .baidu
    /// The UI service label.
    public var displayName: String { id.displayName }
    private let session: URLSession
    private let credentials: KeychainStore
    /// Creates an adapter with injectable URLSession and credential fixtures.
    public init(session: URLSession = .shared, credentials: KeychainStore = KeychainStore()) {
        self.session = session; self.credentials = credentials
    }
    /// Checks the two required Baidu Keychain accounts.
    public func credentialsStatus() -> CredentialsStatus {
        ["baidu.appid", "baidu.secret"].allSatisfy { !(credentials.get($0) ?? "").isEmpty } ? .ready : .unconfigured
    }
    /// Computes the documented MD5 signing string from raw source text.
    public static func signature(appid: String, text: String, salt: String, secret: String) -> String {
        Insecure.MD5.hash(data: Data((appid + text + salt + secret).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Builds a 15-second, URL-encoded request, optionally with a deterministic test salt.
    public static func makeRequest(_ request: TranslationRequest, appid: String, secret: String,
                                   salt: String = String(UInt64.random(in: 1...UInt64.max))) throws -> URLRequest {
        guard !appid.isEmpty, !secret.isEmpty else { throw TranslationError.unconfigured }
        let (source, target) = try TranslationHTTP.languageCodes(request, provider: .baidu)
        var network = try TranslationHTTP.request(url: "https://fanyi-api.baidu.com/api/trans/vip/translate")
        network.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        network.httpBody = TranslationHTTP.form(["q": request.text, "from": source ?? "auto", "to": target,
                                                "appid": appid, "salt": salt,
                                                "sign": signature(appid: appid, text: request.text, salt: salt, secret: secret)])
        return network
    }
    /// Parses every result line while preserving Baidu's error code and message.
    public static func parseResponse(_ data: Data, statusCode: Int = 200, redacting credentials: [String] = []) throws -> TranslationResult {
        if let object = try? TranslationHTTP.json(data), let code = TranslationHTTP.code(object["error_code"]), code != "0" {
            throw TranslationHTTP.providerError(code: code, message: object["error_msg"] as? String ?? "百度翻译服务错误", redacting: credentials)
        }
        try TranslationHTTP.requireSuccess(statusCode, data: data, redacting: credentials)
        let object = try TranslationHTTP.json(data)
        guard let results = object["trans_result"] as? [[String: Any]], !results.isEmpty else { throw TranslationError.decode }
        let lines = try results.map { result -> String in
            guard let text = result["dst"] as? String else { throw TranslationError.decode }; return text
        }
        return TranslationResult(text: lines.joined(separator: "\n"),
                                 detectedSource: Language.detected(code: object["from"] as? String, provider: .baidu),
                                 rawProviderInfo: object["request_id"] as? String)
    }
    /// Calls the selected Baidu API once without retries.
    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        guard let appid = credentials.get("baidu.appid"), let secret = credentials.get("baidu.secret") else { throw TranslationError.unconfigured }
        let values = [appid, secret]
        return try await TranslationHTTP.withRedactedErrors(credentials: values) {
            let network = try Self.makeRequest(request, appid: appid, secret: secret)
            let (data, response) = try await TranslationHTTP.execute(network, session: session)
            return try Self.parseResponse(data, statusCode: response.statusCode, redacting: values)
        }
    }
}
