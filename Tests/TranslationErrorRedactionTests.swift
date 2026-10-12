// Exercises all native REST error exits through URLSession, without real accounts or external traffic.
import Foundation
import XCTest
import os
@testable import NikoShot

final class TranslationErrorRedactionTests: XCTestCase, @unchecked Sendable {
    private let key = "credential-redaction-fixture-0123456789-abcdefghijklmnopqrstuvwxyz:fx"
    private let mask = "[已隐藏]"

    override func tearDown() {
        RedactionURLProtocol.install(.response(200, Data()))
        super.tearDown()
    }

    func testEveryProviderRedactsCompleteHTTPBodyBeforeTwoHundredCharacterPreview() async throws {
        let prefix = String(repeating: "x", count: 180)
        let body = prefix + key + " trailing diagnostic"
        RedactionURLProtocol.install(.response(502, Data(body.utf8)))
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let custom = customConfiguration()
        let router = TranslationRouter(session: session, credentials: credentials(key, custom: custom))
        for provider in TranslationProviderID.allCases {
            do {
                _ = try await router.translate(TranslationRequest(text: "public text"), provider: provider, custom: custom, useCache: false)
                XCTFail("Expected a network HTTP failure for \(provider)")
            } catch {
                guard case .http(let status, let detail) = error as? TranslationError else {
                    XCTFail("Expected a preserved HTTP error for \(provider)"); continue
                }
                XCTAssertEqual(status, 502)
                XCTAssertEqual(detail, String((prefix + mask + " trailing diagnostic").prefix(200)))
                XCTAssertFalse(detail.contains(String(key.prefix(20))))
            }
        }
        XCTAssertEqual(RedactionURLProtocol.requestCount, 5)
    }

    func testOfficialProviderMessagesKeepStatusAndNumericCodesWithoutCredentials() async throws {
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let custom = customConfiguration()
        let router = TranslationRouter(session: session, credentials: credentials(key, custom: custom))
        let description = "Credential \(key); literal user token $KEY"
        let fixtures: [(TranslationProviderID, Int, [String: Any], String?)] = [
            (.baidu, 200, ["error_code": "54003", "error_msg": description], "54003"),
            (.google, 200, ["error": ["code": 403, "message": description]], "403"),
            (.youdao, 200, ["errorCode": "206", "errorMsg": description], "206"),
            (.deepl, 456, ["message": description], nil),
            (.custom, 429, ["error": description], nil)
        ]
        for (provider, status, response, code) in fixtures {
            RedactionURLProtocol.install(.response(status, try JSONSerialization.data(withJSONObject: response)))
            do {
                _ = try await router.translate(TranslationRequest(text: "literal $KEY"), provider: provider, custom: custom, useCache: false)
                XCTFail("Expected official error for \(provider)")
            } catch {
                guard let failure = error as? TranslationError else { XCTFail("Expected translation error"); continue }
                switch failure {
                case .provider(let actualCode, let detail):
                    XCTAssertEqual(actualCode, code)
                    XCTAssertFalse(detail.contains(key))
                    XCTAssertTrue(detail.contains(mask))
                    XCTAssertTrue(detail.contains("$KEY"))
                case .http(let actualStatus, let detail):
                    XCTAssertNil(code)
                    XCTAssertEqual(actualStatus, status)
                    XCTAssertFalse(detail.contains(key))
                    XCTAssertTrue(detail.contains(mask))
                    XCTAssertTrue(detail.contains("$KEY"))
                default: XCTFail("Unexpected error category for \(provider)")
                }
            }
            XCTAssertEqual(RedactionURLProtocol.requestCount, 1)
        }
    }

    func testProviderCodeCannotServeAsASecondCredentialEchoChannel() async throws {
        let response: [String: Any] = ["error_code": "auth-\(key)", "error_msg": "invalid credential"]
        RedactionURLProtocol.install(.response(200, try JSONSerialization.data(withJSONObject: response)))
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let router = TranslationRouter(session: session, credentials: credentials(key))
        do {
            _ = try await router.translate(TranslationRequest(text: "public text"), provider: .baidu, useCache: false)
            XCTFail("Expected a provider failure")
        } catch {
            XCTAssertEqual(error as? TranslationError, .provider(code: "auth-\(mask)", message: "invalid credential"))
        }
    }

    func testCustomHTTPErrorsRedactRawMixedURLJSONAndMultibyteCredentialForms() async throws {
        let secret = "钥e\u{301}🔑/A+\"\\:fx"
        let decomposed = secret.decomposedStringWithCanonicalMapping
        let precomposed = secret.precomposedStringWithCanonicalMapping
        let forms = [
            secret,
            TranslationHTTP.encodeComponent(decomposed),
            lowercasePercentHex(TranslationHTTP.encodeComponent(precomposed)),
            decomposed.utf8.map { String(format: "%%%02X", $0) }.joined(),
            jsonStringInterior(decomposed),
            unicodeEscapes(decomposed),
            unicodeEscapes(precomposed).lowercased(),
            mixedJSONEscapes(decomposed),
            TranslationHTTP.encodeComponent(unicodeEscapes(precomposed).lowercased()),
            jsonStringInterior(unicodeEscapes(decomposed).lowercased())
        ]
        let custom = customConfiguration()
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let router = TranslationRouter(session: session, credentials: credentials(secret, custom: custom))
        for form in forms {
            let body = "rejected credential: " + form + "; literal $KEY"
            RedactionURLProtocol.install(.response(403, Data(body.utf8)))
            do {
                _ = try await router.translate(TranslationRequest(text: "original $KEY"), provider: .custom, custom: custom, useCache: false)
                XCTFail("Expected custom HTTP error")
            } catch {
                guard case .http(let status, let detail) = error as? TranslationError else { XCTFail("Expected HTTP error"); continue }
                XCTAssertEqual(status, 403)
                XCTAssertEqual(detail, "rejected credential: \(mask); literal $KEY")
            }
            XCTAssertEqual(RedactionURLProtocol.requestCount, 1)
        }
    }

    func testCustomEscapedControlCharactersCannotLeakInAnHTTPDiagnostic() async throws {
        let secret = "line\n钥\t\"\\/🔑"
        let custom = customConfiguration()
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let router = TranslationRouter(session: session, credentials: credentials(secret, custom: custom))
        for form in [secret, jsonStringInterior(secret), TranslationHTTP.encodeComponent(secret), unicodeEscapes(secret)] {
            RedactionURLProtocol.install(.response(500, Data(("bad key: " + form).utf8)))
            do {
                _ = try await router.translate(TranslationRequest(text: "public original $KEY"), provider: .custom, custom: custom, useCache: false)
                XCTFail("Expected control-character HTTP error")
            } catch { XCTAssertEqual(error as? TranslationError, .http(500, "bad key: \(mask)")) }
        }
    }

    func testOfficialDecodedJSONMessagesRedactUnicodeAndMixedPercentEscapes() async throws {
        let secret = "钥e\u{301}🔑/A+\"\\:fx"
        let body = "{\"error\":{\"code\":403,\"message\":\"invalid " + unicodeEscapes(secret) + "\"}}"
        RedactionURLProtocol.install(.response(403, Data(body.utf8)))
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let router = TranslationRouter(session: session, credentials: credentials(secret))
        do {
            _ = try await router.translate(TranslationRequest(text: "public text"), provider: .google, useCache: false)
            XCTFail("Expected structured Google HTTP error")
        } catch { XCTAssertEqual(error as? TranslationError, .http(403, "invalid \(mask)")) }
        let encoded = lowercasePercentHex(TranslationHTTP.encodeComponent(secret))
        RedactionURLProtocol.install(.response(200, try JSONSerialization.data(withJSONObject: ["error": ["code": 403, "message": "invalid " + encoded]])))
        do {
            _ = try await router.translate(TranslationRequest(text: "public text"), provider: .google, useCache: false)
            XCTFail("Expected structured Google provider error")
        } catch { XCTAssertEqual(error as? TranslationError, .provider(code: "403", message: "invalid \(mask)")) }
    }

    func testEveryProviderSanitizesNativeErrorURLNestedErrorsAndDebugDescriptions() async throws {
        let encoded = lowercasePercentHex(TranslationHTTP.encodeComponent(key))
        let failingURL = try XCTUnwrap(URL(string: "https://fixture.invalid/failure?key=" + encoded))
        let underlying = NSError(domain: "fixture-underlying", code: 71,
            userInfo: [NSLocalizedDescriptionKey: "underlying \(key)", NSDebugDescriptionErrorKey: unicodeEscapes(key)])
        let failure = URLError(.timedOut, userInfo: [
            NSLocalizedDescriptionKey: "timeout with \(key)",
            NSURLErrorFailingURLErrorKey: failingURL,
            NSURLErrorFailingURLStringErrorKey: failingURL.absoluteString,
            NSUnderlyingErrorKey: underlying,
            NSDebugDescriptionErrorKey: "debug " + encoded,
            "opaqueRequestBytes": Data(key.utf8),
            "nestedDiagnostics": ["value": key]
        ])
        RedactionURLProtocol.install(.failure(failure as NSError))
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let custom = customConfiguration()
        let router = TranslationRouter(session: session, credentials: credentials(key, custom: custom))
        for provider in TranslationProviderID.allCases {
            do {
                _ = try await router.translate(TranslationRequest(text: "public text"), provider: provider, custom: custom, useCache: false)
                XCTFail("Expected URLSession failure for \(provider)")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
                let native = error as NSError
                XCTAssertEqual(native.domain, NSURLErrorDomain)
                XCTAssertEqual(native.localizedDescription, "timeout with \(mask)")
                XCTAssertFalse(String(describing: native).contains(key))
                XCTAssertFalse(String(describing: native).contains(encoded))
                XCTAssertNil(native.userInfo["opaqueRequestBytes"])
                let child = try XCTUnwrap(native.userInfo[NSUnderlyingErrorKey] as? NSError)
                XCTAssertEqual(child.code, 71)
                XCTAssertEqual(child.localizedDescription, "underlying \(mask)")
                XCTAssertEqual(child.userInfo[NSDebugDescriptionErrorKey] as? String, mask)
                let url = try XCTUnwrap(native.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
                XCTAssertFalse(url.absoluteString.contains(key))
                XCTAssertFalse(url.absoluteString.contains(encoded))
            }
        }
        XCTAssertEqual(RedactionURLProtocol.requestCount, 5)
    }

    func testEveryProviderPreservesCancellationWithoutEchoingUnderlyingDetails() async throws {
        let error = URLError(.cancelled, userInfo: [NSLocalizedDescriptionKey: "cancelled \(key)"])
        RedactionURLProtocol.install(.failure(error as NSError))
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let custom = customConfiguration()
        let router = TranslationRouter(session: session, credentials: credentials(key, custom: custom))
        for provider in TranslationProviderID.allCases {
            do {
                _ = try await router.translate(TranslationRequest(text: "public text"), provider: provider, custom: custom, useCache: false)
                XCTFail("Expected cancellation")
            } catch { XCTAssertEqual(error as? TranslationError, .cancelled) }
        }
    }

    func testEveryProviderLeavesSuccessfulTextAndLiteralPlaceholderTokensUnchanged() async throws {
        let text = "公开正文：$KEY / $TEXT / 中文 e\u{301} 🔑"
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let custom = customConfiguration()
        let router = TranslationRouter(session: session, credentials: credentials(key, custom: custom))
        for provider in TranslationProviderID.allCases {
            let response: [String: Any]
            switch provider {
            case .baidu: response = ["trans_result": [["dst": text]]]
            case .google: response = ["data": ["translations": [["translatedText": text]]]]
            case .youdao: response = ["errorCode": "0", "translation": [text]]
            case .deepl: response = ["translations": [["text": text]]]
            case .custom: response = ["text": text]
            }
            RedactionURLProtocol.install(.response(200, try JSONSerialization.data(withJSONObject: response)))
            let result = try await router.translate(TranslationRequest(text: text), provider: provider, custom: custom, useCache: false)
            XCTAssertEqual(result.text, text)
            XCTAssertEqual(RedactionURLProtocol.requestCount, 1)
        }
    }

    private func customConfiguration() -> CustomRESTConfiguration {
        CustomRESTConfiguration(name: "public redaction fixture", urlTemplate: "https://fixture.invalid/translate",
            bodyTemplate: #"{"q":"$TEXT","api_key":"$KEY"}"#, responsePath: "text")
    }
    private func credentials(_ value: String, custom: CustomRESTConfiguration? = nil) -> KeychainStore {
        var values = ["baidu.appid": "public-app-id", "baidu.secret": value, "google.key": value,
                      "youdao.appKey": "public-app-key", "youdao.appSecret": value, "deepl.key": value]
        if let custom { values[custom.keyAccount] = value }
        return KeychainStore(testValues: values)
    }
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedactionURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func unicodeEscapes(_ text: String) -> String {
        text.utf16.map { String(format: "\\u%04X", $0) }.joined()
    }
    private func jsonStringInterior(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
              let encoded = String(data: data, encoding: .utf8) else { return "" }
        return String(encoded.dropFirst().dropLast())
    }
    private func mixedJSONEscapes(_ text: String) -> String {
        text.unicodeScalars.enumerated().map { index, scalar in
            index.isMultiple(of: 2) ? unicodeEscapes(String(scalar)) : jsonStringInterior(String(scalar))
        }.joined()
    }
    private func lowercasePercentHex(_ text: String) -> String {
        let characters = Array(text)
        var result = "", index = 0
        while index < characters.count {
            if characters[index] == "%", index + 2 < characters.count {
                result += "%" + String(characters[index + 1]).lowercased() + String(characters[index + 2]).lowercased()
                index += 3
            } else { result.append(characters[index]); index += 1 }
        }
        return result
    }
}

// URLSession owns callbacks; the private fixture is independent of other test protocol classes.
private final class RedactionURLProtocol: URLProtocol, @unchecked Sendable {
    enum Fixture: Sendable { case response(Int, Data), failure(NSError) }
    private struct State: Sendable { var fixture: Fixture; var requestCount = 0 }
    private static let state = OSAllocatedUnfairLock(initialState: State(fixture: .response(200, Data())))
    static var requestCount: Int { state.withLock { $0.requestCount } }
    static func install(_ fixture: Fixture) { state.withLock { $0 = State(fixture: fixture) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.state.withLock { state -> Fixture in state.requestCount += 1; return state.fixture }
        switch fixture {
        case .response(let status, let data):
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
