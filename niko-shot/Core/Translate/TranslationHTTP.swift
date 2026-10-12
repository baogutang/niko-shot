// Shared 15-second REST transport, form encoding and response checks for all five adapters.
import Foundation

enum TranslationHTTP {
    static func execute(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw TranslationError.decode }
            return (data, response)
        } catch is CancellationError { throw TranslationError.cancelled }
        catch let error as URLError where error.code == .cancelled { throw TranslationError.cancelled }
    }

    static func request(url: String) throws -> URLRequest {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme), parsed.host != nil,
              parsed.user == nil, parsed.password == nil else {
            throw TranslationError.provider(code: "invalid_configuration", message: "服务 URL 必须为有效的 HTTP 或 HTTPS 地址，且不能包含账号密码。")
        }
        var request = URLRequest(url: parsed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        return request
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TranslationError.decode }
        return result
    }
    static func code(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    static func bodyPreview(_ data: Data) -> String { String((String(data: data, encoding: .utf8) ?? "非 UTF-8 响应").prefix(200)) }
    static func requireSuccess(_ status: Int, data: Data, message: String? = nil) throws {
        guard (200..<300).contains(status) else { throw TranslationError.http(status, message ?? bodyPreview(data)) }
    }

    static func form(_ parameters: [String: String]) -> Data {
        Data(parameters.keys.sorted().map { key in "\(encodeComponent(key))=\(encodeComponent(parameters[key] ?? ""))" }.joined(separator: "&").utf8)
    }
    static func encodeComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
    static func languageCodes(_ request: TranslationRequest, provider: TranslationProviderID) throws -> (String?, String) {
        guard let target = request.target.code(for: provider) else {
            throw TranslationError.provider(code: "unsupported_language", message: "\(provider.displayName) 的经典翻译接口不支持目标语言：\(request.target.displayName)。")
        }
        guard request.source == nil || request.source?.sourceCode(for: provider) != nil else {
            throw TranslationError.provider(code: "unsupported_language", message: "\(provider.displayName) 的经典翻译接口不支持所选源语言。")
        }
        return (request.source?.sourceCode(for: provider), target)
    }
}
