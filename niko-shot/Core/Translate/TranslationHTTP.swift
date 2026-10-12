// Shared 15-second REST transport, form encoding and response checks for all five adapters.
import Foundation

enum TranslationHTTP {
    // Sanitize only failures; successful translations and source text stay verbatim.
    static func withRedactedErrors<Value: Sendable>(credentials: [String],
        operation: @Sendable () async throws -> Value) async throws -> Value {
        do { return try await operation() }
        catch is CancellationError { throw TranslationError.cancelled }
        catch let error as URLError where error.code == .cancelled { throw TranslationError.cancelled }
        catch {
            let redactor = CredentialErrorRedactor(credentials)
            if let translation = error as? TranslationError {
                switch translation {
                case .http(let status, let detail): throw TranslationError.http(status, redactor.redact(detail))
                case .provider(let code, let detail):
                    throw TranslationError.provider(code: redactor.redact(code), message: redactor.redact(detail))
                default: throw translation
                }
            }
            // URLSession errors can retain a failing URL and nested errors in userInfo.
            // Preserve native error identity, but never forward opaque carriers of a request.
            throw redactor.redact(error as NSError)
        }
    }

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
    static func providerError(code: String, message: String, redacting credentials: [String]) -> TranslationError {
        let redactor = CredentialErrorRedactor(credentials)
        return .provider(code: redactor.redact(code), message: redactor.redact(message))
    }
    static func bodyPreview(_ data: Data, redacting credentials: [String] = []) -> String {
        let complete = String(data: data, encoding: .utf8) ?? "非 UTF-8 响应"
        return String(CredentialErrorRedactor(credentials).redact(complete).prefix(200))
    }
    static func requireSuccess(_ status: Int, data: Data, message: String? = nil, redacting credentials: [String] = []) throws {
        guard (200..<300).contains(status) else {
            let detail = message.map { CredentialErrorRedactor(credentials).redact($0) } ?? bodyPreview(data, redacting: credentials)
            throw TranslationError.http(status, detail)
        }
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

// Recognizes raw, percent-encoded and JSON-escaped spellings without decoding or
// re-expanding source text. Matching completes before any diagnostic truncation.
private struct CredentialErrorRedactor {
    private let expression: NSRegularExpression?
    private let hidesEntireDetail: Bool
    private static let replacement = "[已隐藏]"

    init(_ credentials: [String]) {
        // Swift String equality collapses canonically equivalent Unicode spellings;
        // percent/JSON encodings still distinguish their bytes, so deduplicate bytes.
        var seen = Set<Data>()
        var values: [String] = []
        for credential in credentials where !credential.isEmpty {
            for value in [credential, credential.precomposedStringWithCanonicalMapping, credential.decomposedStringWithCanonicalMapping] {
                if seen.insert(Data(value.utf8)).inserted { values.append(value) }
            }
        }
        values.sort { $0.utf8.count > $1.utf8.count }
        guard !values.isEmpty else { expression = nil; hidesEntireDetail = false; return }
        let patterns = values.map { value in
            value.unicodeScalars.map(Self.scalarPattern).joined()
        }
        let compiled = try? NSRegularExpression(pattern: patterns.map { "(?:\($0))" }.joined(separator: "|"))
        expression = compiled
        // A pathological credential must fail closed if ICU cannot compile its pattern.
        hidesEntireDetail = compiled == nil
    }

    func redact(_ value: String) -> String {
        if hidesEntireDetail { return Self.replacement }
        guard let expression else { return value }
        return expression.stringByReplacingMatches(in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value), withTemplate: Self.replacement)
    }

    func redact(_ error: NSError, depth: Int = 0) -> NSError {
        var info: [String: Any] = [:]
        if depth < 4 {
            for (key, value) in error.userInfo {
                if let safe = safeValue(value, depth: depth + 1) { info[redact(key)] = safe }
            }
        }
        info[NSLocalizedDescriptionKey] = redact(error.localizedDescription)
        let domain = redact(error.domain)
        if domain == NSURLErrorDomain {
            return URLError(URLError.Code(rawValue: error.code), userInfo: info) as NSError
        }
        return NSError(domain: domain, code: error.code, userInfo: info)
    }

    private func safeValue(_ value: Any, depth: Int) -> Any? {
        guard depth < 5 else { return nil }
        if let text = value as? String { return redact(text) }
        if let url = value as? URL {
            let safe = redact(url.absoluteString)
            if let parsed = URL(string: safe) { return parsed }
            return safe
        }
        if let error = value as? NSError { return redact(error, depth: depth) }
        if let values = value as? [String: Any] {
            var safe: [String: Any] = [:]
            for (key, nested) in values {
                if let item = safeValue(nested, depth: depth + 1) { safe[redact(key)] = item }
            }
            return safe
        }
        if let values = value as? [Any] { return values.compactMap { safeValue($0, depth: depth + 1) } }
        if let number = value as? NSNumber { return number }
        // Data, tasks and other objects may describe or retain unredacted request material.
        return nil
    }

    private static func scalarPattern(_ scalar: Unicode.Scalar) -> String {
        let raw = String(scalar)
        let escaped = jsonEscape(raw)
        let unicode = raw.utf16.map { String(format: "\\u%04X", $0) }.joined()
        let tokens = Set([raw, escaped, unicode, jsonEscape(escaped), jsonEscape(unicode)])
        var alternatives = tokens.map { NSRegularExpression.escapedPattern(for: $0) }
        // Percent escapes may be mixed with raw characters and use either hex case.
        alternatives.append(contentsOf: tokens.map { token in
            token.utf8.map { "%" + hexPattern(String(format: "%02X", $0)) }.joined()
        })
        alternatives.append(unicodeEscapePattern(raw, doubledBackslash: false))
        alternatives.append(unicodeEscapePattern(raw, doubledBackslash: true))
        if scalar.value == 32 { alternatives.append("\\+") }
        return "(?:" + alternatives.sorted().joined(separator: "|") + ")"
    }

    private static func jsonEscape(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 34: "\\\""
            case 92: "\\\\"
            case 47: "\\/"
            case 8: "\\b"
            case 9: "\\t"
            case 10: "\\n"
            case 12: "\\f"
            case 13: "\\r"
            case 0..<32: String(format: "\\u%04X", scalar.value)
            default: String(scalar)
            }
        }.joined()
    }

    private static func unicodeEscapePattern(_ text: String, doubledBackslash: Bool) -> String {
        text.utf16.map { unit in
            let prefix = doubledBackslash ? "\\\\u" : "\\u"
            let first = prefix.utf8.map(encodedASCII).joined()
            let hexadecimal = String(format: "%04X", unit).utf8.map { byte in
                if (65...70).contains(byte) { return "(?:" + encodedASCII(byte) + "|" + encodedASCII(byte + 32) + ")" }
                return encodedASCII(byte)
            }.joined()
            return first + hexadecimal
        }.joined()
    }

    private static func encodedASCII(_ byte: UInt8) -> String {
        "(?:" + NSRegularExpression.escapedPattern(for: String(Unicode.Scalar(byte))) + "|%" + hexPattern(String(format: "%02X", byte)) + ")"
    }

    private static func hexPattern(_ hexadecimal: String) -> String {
        hexadecimal.map { character in
            if ("A"..."F").contains(String(character)) { return "[\(character.lowercased())\(character)]" }
            return String(character)
        }.joined()
    }
}
