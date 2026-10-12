// Runs all REST adapters through injected URLSession/URLProtocol without user secrets or external traffic.
import XCTest
import os
@testable import NikoShot

final class ProviderIntegrationTests: XCTestCase {
    func testAllProvidersReachOnlyTheirEndpointThroughInjectedSession() async throws {
        let custom = CustomRESTConfiguration(name: "fixture", urlTemplate: "https://fixture.test/translate",
                                              bodyTemplate: #"{"q":"$TEXT","key":"$KEY"}"#, responsePath: "data.0.text")
        ProviderURLProtocol.install([
            "fanyi-api.baidu.com": .response(200, #"{"from":"en","trans_result":[{"dst":"百度译文"}]}"#),
            "translation.googleapis.com": .response(200, #"{"data":{"translations":[{"translatedText":"Google译文"}]}}"#),
            "openapi.youdao.com": .response(200, #"{"errorCode":"0","translation":["有道译文"]}"#),
            "api-free.deepl.com": .response(200, #"{"translations":[{"text":"DeepL译文","detected_source_language":"EN"}]}"#),
            "fixture.test": .response(200, #"{"data":[{"text":"自定义译文"}]}"#)
        ])
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let router = TranslationRouter(session: session, credentials: credentials(custom: custom))
        let request = TranslationRequest(text: "Hello, world!")
        async let baidu = router.translate(request, provider: .baidu)
        async let google = router.translate(request, provider: .google)
        async let youdao = router.translate(request, provider: .youdao)
        async let deepl = router.translate(request, provider: .deepl)
        async let rest = router.translate(request, provider: .custom, custom: custom)
        let results = try await [baidu, google, youdao, deepl, rest]
        XCTAssertEqual(results.map(\.text), ["百度译文", "Google译文", "有道译文", "DeepL译文", "自定义译文"])
        for host in ["fanyi-api.baidu.com", "translation.googleapis.com", "openapi.youdao.com", "api-free.deepl.com", "fixture.test"] {
            XCTAssertEqual(ProviderURLProtocol.count(host), 1)
        }
        XCTAssertTrue(ProviderURLProtocol.requests.allSatisfy { $0.httpMethod == "POST" && $0.timeoutInterval == 15 })
    }
    func testCacheSeparatesTextLanguagePairProviderAndBypassesConnectionTests() async throws {
        ProviderURLProtocol.install(["fanyi-api.baidu.com": .response(200, #"{"from":"en","trans_result":[{"dst":"cached"}]}"#)])
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let router = TranslationRouter(session: session, credentials: credentials())
        let request = TranslationRequest(text: "Hello")
        _ = try await router.translate(request, provider: .baidu)
        _ = try await router.translate(request, provider: .baidu)
        XCTAssertEqual(ProviderURLProtocol.count("fanyi-api.baidu.com"), 1)
        _ = try await router.translate(request, provider: .baidu, useCache: false)
        XCTAssertEqual(ProviderURLProtocol.count("fanyi-api.baidu.com"), 2)
        _ = try await router.translate(TranslationRequest(text: "Hello", target: .english), provider: .baidu)
        _ = try await router.translate(TranslationRequest(text: "Hello", source: .english), provider: .baidu)
        _ = try await router.translate(TranslationRequest(text: "Other"), provider: .baidu)
        XCTAssertEqual(ProviderURLProtocol.count("fanyi-api.baidu.com"), 5)
        await router.invalidateCache()
        _ = try await router.translate(request, provider: .baidu)
        XCTAssertEqual(ProviderURLProtocol.count("fanyi-api.baidu.com"), 6)
    }
    func testCustomInstancesAndChangedTemplatesPartitionCache() async throws {
        ProviderURLProtocol.install(["fixture.test": .response(200, #"{"text":"fixture"}"#)])
        var custom = CustomRESTConfiguration(name: "first", urlTemplate: "https://fixture.test/translate", bodyTemplate: #"{"text":"$TEXT"}"#, responsePath: "text")
        var second = custom; second.id = UUID()
        var values = allCredentials; values[custom.keyAccount] = "first-key"; values[second.keyAccount] = "second-key"
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let router = TranslationRouter(session: session, credentials: KeychainStore(testValues: values))
        let request = TranslationRequest(text: "Hello")
        _ = try await router.translate(request, provider: .custom, custom: custom)
        _ = try await router.translate(request, provider: .custom, custom: custom)
        _ = try await router.translate(request, provider: .custom, custom: second)
        custom.bodyTemplate = #"{"text":"$TEXT","changed":true}"#
        _ = try await router.translate(request, provider: .custom, custom: custom)
        XCTAssertEqual(ProviderURLProtocol.count("fixture.test"), 3)
    }
    func testFailureDoesNotRetryCacheOrSelectAnotherConfiguredProvider() async throws {
        ProviderURLProtocol.install(["fanyi-api.baidu.com": .response(429, #"{"error_code":"54003","error_msg":"rate limited"}"#)])
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let router = TranslationRouter(session: session, credentials: credentials())
        for _ in 0..<2 {
            do { _ = try await router.translate(TranslationRequest(text: "Hello"), provider: .baidu); XCTFail("Expected provider error") }
            catch { XCTAssertEqual(error as? TranslationError, .provider(code: "54003", message: "rate limited")) }
        }
        XCTAssertEqual(ProviderURLProtocol.count("fanyi-api.baidu.com"), 2)
        XCTAssertEqual(ProviderURLProtocol.requests.count, 2)
    }
    func testMissingCredentialsAndUnsupportedLanguagesNeverSendNetworkTraffic() async throws {
        ProviderURLProtocol.install([:])
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let unconfigured = TranslationRouter(session: session, credentials: KeychainStore(testValues: [:]))
        let status = await unconfigured.credentialsStatus(provider: .baidu)
        XCTAssertEqual(status, .unconfigured)
        do { _ = try await unconfigured.translate(TranslationRequest(text: "Hello"), provider: .baidu); XCTFail("Expected unconfigured") }
        catch { XCTAssertEqual(error as? TranslationError, .unconfigured) }
        let caiyun = try XCTUnwrap(CustomRESTConfiguration.presets.first)
        let configured = TranslationRouter(session: session, credentials: credentials(custom: caiyun))
        do { _ = try await configured.translate(TranslationRequest(text: "Hello", source: .english, target: .japanese), provider: .custom, custom: caiyun); XCTFail("Expected unsupported") }
        catch { guard case .provider(let code, _) = error as? TranslationError else { return XCTFail("Expected provider language error") }; XCTAssertEqual(code, "unsupported_language") }
        XCTAssertTrue(ProviderURLProtocol.requests.isEmpty)
    }
    func testCancellationPropagatesAndTimeoutDoesNotRetry() async throws {
        ProviderURLProtocol.install(["fanyi-api.baidu.com": .stall])
        let session = makeSession(); defer { session.invalidateAndCancel() }
        let router = TranslationRouter(session: session, credentials: credentials())
        let task = Task { try await router.translate(TranslationRequest(text: "Hello"), provider: .baidu) }
        for _ in 0..<1000 {
            if ProviderURLProtocol.count("fanyi-api.baidu.com") > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? TranslationError, .cancelled) }
        ProviderURLProtocol.install(["fanyi-api.baidu.com": .failure(.timedOut)])
        do { _ = try await router.translate(TranslationRequest(text: "Hello"), provider: .baidu); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(ProviderURLProtocol.count("fanyi-api.baidu.com"), 1)
    }
    private var allCredentials: [String: String] {
        ["baidu.appid": "test-appid", "baidu.secret": "test-secret", "google.key": "google-fixture",
         "youdao.appKey": "test-app-key", "youdao.appSecret": "test-secret", "deepl.key": "fixture:fx"]
    }
    private func credentials(custom: CustomRESTConfiguration? = nil) -> KeychainStore {
        var values = allCredentials
        if let custom { values[custom.keyAccount] = "fixture" }
        return KeychainStore(testValues: values)
    }
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderURLProtocol.self]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }
}

// URLProtocol callbacks are owned by URLSession; shared fixture state is protected by one unfair lock.
private final class ProviderURLProtocol: URLProtocol, @unchecked Sendable {
    enum Fixture: Sendable { case response(Int, String), failure(URLError.Code), stall }
    private struct State: Sendable {
        var fixtures: [String: Fixture] = [:]
        var requests: [URLRequest] = []
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    static func install(_ fixtures: [String: Fixture]) { state.withLock { $0 = State(fixtures: fixtures) } }
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func count(_ host: String) -> Int { state.withLock { $0.requests.filter { $0.url?.host == host }.count } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.state.withLock { state -> Fixture? in
            state.requests.append(request)
            return state.fixtures[request.url?.host ?? ""]
        }
        switch fixture {
        case .response(let status, let body):
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .stall: break
        case nil: client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
    }
    override func stopLoading() {}
}
