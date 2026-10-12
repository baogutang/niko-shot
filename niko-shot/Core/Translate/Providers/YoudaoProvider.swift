// Implements Youdao's v3 SHA256 signing using the official Python3 demo's Unicode code-point truncation.
import Foundation
import CryptoKit

/// The Youdao classic text translation REST adapter.
public struct YoudaoProvider: TranslationService {
    /// Its provider identifier.
    public let id: TranslationProviderID = .youdao
    /// The UI service label.
    public var displayName: String { id.displayName }
    private let session: URLSession
    private let credentials: KeychainStore
    /// Creates an adapter with injectable URLSession and credentials.
    public init(session: URLSession = .shared, credentials: KeychainStore = KeychainStore()) {
        self.session = session; self.credentials = credentials
    }
    /// Checks both required Youdao Keychain accounts.
    public func credentialsStatus() -> CredentialsStatus {
        ["youdao.appKey", "youdao.appSecret"].allSatisfy { !(credentials.get($0) ?? "").isEmpty } ? .ready : .unconfigured
    }
    /// Applies the official Python3 demo's first-ten code points, code-point count and last-ten rule.
    ///
    /// Unicode scalars match Python3 `len` and slicing for valid UTF-8 input; the original text is not normalized.
    /// The official JavaScript demo instead counts UTF-16 code units, so its result can differ for characters
    /// outside the BMP. Those inputs still require verification with a real Youdao account; these fixtures
    /// establish Python3-demo compatibility, not acceptance by the live service.
    /// See the [official demos](https://ai.youdao.com/DOCSIRMA/html/trans/api/wbfy/index.html).
    public static func signingInput(_ text: String) -> String {
        let scalars = text.unicodeScalars
        let count = scalars.count
        guard count > 20 else { return text }
        return String(scalars.prefix(10)) + String(count) + String(scalars.suffix(10))
    }
    /// Computes lowercase SHA256 for a deterministic v3 signing tuple.
    public static func signature(appKey: String, text: String, salt: String, curtime: String, secret: String) -> String {
        SHA256.hash(data: Data((appKey + signingInput(text) + salt + curtime + secret).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Builds a signed form request with optional deterministic salt and Unix time.
    public static func makeRequest(_ request: TranslationRequest, appKey: String, secret: String,
                                   salt: String = UUID().uuidString,
                                   curtime: String = String(Int(Date().timeIntervalSince1970))) throws -> URLRequest {
        guard !appKey.isEmpty, !secret.isEmpty else { throw TranslationError.unconfigured }
        let (source, target) = try TranslationHTTP.languageCodes(request, provider: .youdao)
        var network = try TranslationHTTP.request(url: "https://openapi.youdao.com/api")
        network.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        network.httpBody = TranslationHTTP.form(["q": request.text, "from": source ?? "auto", "to": target,
                                                "appKey": appKey, "salt": salt, "signType": "v3", "curtime": curtime,
                                                "sign": signature(appKey: appKey, text: request.text, salt: salt, curtime: curtime, secret: secret)])
        return network
    }
    /// Parses result lines and preserves Youdao's numeric errorCode exactly.
    public static func parseResponse(_ data: Data, statusCode: Int = 200, redacting credentials: [String] = []) throws -> TranslationResult {
        if let object = try? TranslationHTTP.json(data), let code = TranslationHTTP.code(object["errorCode"]), code != "0" {
            let fallback: [String: String] = ["108": "应用 ID 无效", "110": "应用无权限", "111": "开发者账号无效",
                                             "202": "签名校验失败", "203": "访问 IP 不在白名单内",
                                             "205": "接口与应用平台类型不一致", "206": "时间戳无效导致签名校验失败",
                                             "207": "重复请求", "411": "访问频率受限", "412": "长请求过于频繁"]
            throw TranslationHTTP.providerError(code: code, message: object["errorMsg"] as? String ?? object["error_msg"] as? String ?? fallback[code] ?? "有道翻译服务错误", redacting: credentials)
        }
        try TranslationHTTP.requireSuccess(statusCode, data: data, redacting: credentials)
        let object = try TranslationHTTP.json(data)
        guard TranslationHTTP.code(object["errorCode"]) == "0", let lines = object["translation"] as? [String], !lines.isEmpty else { throw TranslationError.decode }
        let source = (object["l"] as? String)?.components(separatedBy: "2").first
        return TranslationResult(text: lines.joined(separator: "\n"), detectedSource: Language.detected(code: source, provider: .youdao),
                                 rawProviderInfo: object["requestId"] as? String)
    }
    /// Calls the classic Youdao API once, without fallback.
    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        guard let appKey = credentials.get("youdao.appKey"), let secret = credentials.get("youdao.appSecret") else { throw TranslationError.unconfigured }
        let values = [appKey, secret]
        return try await TranslationHTTP.withRedactedErrors(credentials: values) {
            let network = try Self.makeRequest(request, appKey: appKey, secret: secret)
            let (data, response) = try await TranslationHTTP.execute(network, session: session)
            return try Self.parseResponse(data, statusCode: response.statusCode, redacting: values)
        }
    }
}
