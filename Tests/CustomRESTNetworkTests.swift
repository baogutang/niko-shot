// Exercises CustomRESTProvider over real, loopback-only TCP/HTTP without external services or user Keychain items.
import Foundation
import Network
import XCTest
@testable import NikoShot

@MainActor
final class CustomRESTNetworkTests: XCTestCase {
    func testRealJSONAndFormRequestsPreserveTextAndParseNestedResponse() async throws {
        let translated = "译文\n\"quoted\" $KEY"
        let response = try JSONSerialization.data(withJSONObject: ["data": [["text": translated]]])
        let server = try RESTLoopbackServer { _ in .reply(200, response) }
        let session = makeSession()
        defer { session.invalidateAndCancel(); server.stop() }
        try await waitUntil { server.ready }
        let text = "你好\n\"},\"injected\":true,\"q\":\"$KEY & = + / 🇨🇳"
        let key = UUID().uuidString + "+&="
        var configuration = CustomRESTConfiguration(
            name: "loopback", urlTemplate: try server.baseURL() + "/translate?q=$TEXT&key=$KEY",
            headers: ["Authorization": "Bearer $KEY"],
            bodyTemplate: #"{"q":"$TEXT","key":"$KEY","languages":["$SOURCE","$TARGET"],"options":{"enabled":true}}"#,
            responsePath: "data.0.text")
        let credentials = KeychainStore(testValues: [configuration.keyAccount: key])
        let jsonResult = try await CustomRESTProvider(configuration: configuration, session: session, credentials: credentials)
            .translate(TranslationRequest(text: text, source: .english))
        XCTAssertEqual(jsonResult.text, translated)
        let jsonRequest = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(jsonRequest.method, "POST")
        XCTAssertEqual(jsonRequest.headers["content-type"], "application/json; charset=utf-8")
        XCTAssertTrue(jsonRequest.headers["authorization"] == "Bearer " + key, "The fixture authentication value must arrive intact")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: jsonRequest.body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["q", "key", "languages", "options"])
        XCTAssertEqual(body["q"] as? String, text)
        XCTAssertTrue(body["key"] as? String == key, "Only the template key placeholder may expand")
        XCTAssertEqual(body["languages"] as? [String], ["en", "zh-CN"])
        XCTAssertNil(body["injected"])
        let url = try XCTUnwrap(URLComponents(string: "http://127.0.0.1" + jsonRequest.target))
        XCTAssertEqual(url.queryItems?.first(where: { $0.name == "q" })?.value, text)
        XCTAssertTrue(url.queryItems?.first(where: { $0.name == "key" })?.value == key)

        configuration.urlTemplate = try server.baseURL() + "/form"
        configuration.bodyFormat = .form
        configuration.bodyTemplate = "q=$TEXT&key=$KEY&source=$SOURCE&target=$TARGET&literal=a%2Bb"
        let formResult = try await CustomRESTProvider(configuration: configuration, session: session, credentials: credentials)
            .translate(TranslationRequest(text: text, source: .english))
        XCTAssertEqual(formResult.text, translated)
        XCTAssertEqual(server.requests.count, 2, "Each provider operation must send exactly one HTTP request")
        let formRequest = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(formRequest.headers["content-type"], "application/x-www-form-urlencoded; charset=utf-8")
        let encoded = try XCTUnwrap(String(data: formRequest.body, encoding: .utf8))
        let fields = try XCTUnwrap(URLComponents(string: "http://127.0.0.1/?" + encoded)?.queryItems)
        XCTAssertEqual(Set(fields.map(\.name)), ["q", "key", "source", "target", "literal"])
        XCTAssertEqual(fields.first(where: { $0.name == "q" })?.value, text)
        XCTAssertEqual(fields.first(where: { $0.name == "literal" })?.value, "a+b")
        XCTAssertTrue(fields.first(where: { $0.name == "key" })?.value == key)
        try await waitUntil { server.connectionCount == 0 }
    }

    func testRealHTTPErrorsPreserveStatusAndAtMost200Characters() async throws {
        let longBody = "原始服务错误\n\"invalid request\" $KEY " + String(repeating: "错🇨🇳", count: 180)
        let shortBody = "upstream unavailable\n原始文本"
        let server = try RESTLoopbackServer { request in
            request.target == "/long" ? .reply(429, Data(longBody.utf8)) : .reply(502, Data(shortBody.utf8))
        }
        let session = makeSession()
        defer { session.invalidateAndCancel(); server.stop() }
        try await waitUntil { server.ready }
        for (path, status, expected) in [("/long", 429, String(longBody.prefix(200))), ("/short", 502, shortBody)] {
            let configuration = CustomRESTConfiguration(name: "loopback", urlTemplate: try server.baseURL() + path,
                                                        bodyTemplate: #"{"q":"$TEXT"}"#, responsePath: "text")
            let credentials = KeychainStore(testValues: [configuration.keyAccount: UUID().uuidString])
            do {
                _ = try await CustomRESTProvider(configuration: configuration, session: session, credentials: credentials)
                    .translate(TranslationRequest(text: "测试"))
                XCTFail("A non-2xx response must retain its HTTP error")
            } catch let error as TranslationError {
                guard case .http(let actualStatus, let preview) = error else { return XCTFail("Expected a raw HTTP error") }
                XCTAssertEqual(actualStatus, status)
                XCTAssertEqual(preview, expected)
                XCTAssertLessThanOrEqual(preview.count, 200)
            }
        }
        XCTAssertEqual(server.requests.count, 2, "HTTP failures must not cause retries")
        try await waitUntil { server.connectionCount == 0 }
    }

    func testCancellingRealHangingResponseClosesPeerAndDoesNotRetry() async throws {
        let server = try RESTLoopbackServer { _ in .hang }
        let session = makeSession()
        defer { session.invalidateAndCancel(); server.stop() }
        try await waitUntil { server.ready }
        let configuration = CustomRESTConfiguration(name: "loopback", urlTemplate: try server.baseURL() + "/hang",
                                                    bodyTemplate: #"{"q":"$TEXT"}"#, responsePath: "text")
        let provider = CustomRESTProvider(configuration: configuration, session: session,
                                          credentials: KeychainStore(testValues: [configuration.keyAccount: UUID().uuidString]))
        let task = Task { try await provider.translate(TranslationRequest(text: "取消真实请求")) }
        defer { task.cancel() }
        try await waitUntil { server.requests.count == 1 }
        XCTAssertEqual(server.connectionCount, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("The hanging HTTP operation must cancel") }
        catch { XCTAssertEqual(error as? TranslationError, .cancelled) }
        try await waitUntil { server.peerClosedCount == 1 && server.connectionCount == 0 }
        XCTAssertEqual(server.requests.count, 1)
        let tasksEmpty = await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in continuation.resume(returning: tasks.isEmpty) }
        }
        XCTAssertTrue(tasksEmpty, "Cancellation must release the native URLSession task")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        return URLSession(configuration: configuration)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard clock.now < deadline else { throw RESTLoopbackError.deadline }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum RESTLoopbackError: Error { case deadline, unavailablePort }

private struct RESTLoopbackRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

private enum RESTLoopbackReply: Sendable { case reply(Int, Data), hang }

// All native callbacks use the main queue; no mutable fixture state crosses actor boundaries.
@MainActor
private final class RESTLoopbackServer {
    private struct Peer {
        let connection: NWConnection
        var buffer = Data()
        var recorded = false
    }
    private let listener: NWListener
    private let responder: (RESTLoopbackRequest) -> RESTLoopbackReply
    private var peers: [UUID: Peer] = [:]
    private(set) var ready = false
    private(set) var requests: [RESTLoopbackRequest] = []
    private(set) var peerClosedCount = 0
    var connectionCount: Int { peers.count }

    init(responder: @escaping (RESTLoopbackRequest) -> RESTLoopbackReply) throws {
        self.responder = responder
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { if case .ready = state { self?.ready = true } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                let id = UUID()
                self.peers[id] = Peer(connection: connection)
                connection.start(queue: .main)
                self.receive(id)
            }
        }
        listener.start(queue: .main)
    }

    func baseURL() throws -> String {
        guard let port = listener.port, port.rawValue != 0 else { throw RESTLoopbackError.unavailablePort }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    func stop() {
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
        for peer in peers.values { peer.connection.cancel() }
        peers.removeAll()
    }

    private func receive(_ id: UUID) {
        peers[id]?.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated { self?.consume(id, data: data, complete: complete, error: error) }
        }
    }

    private func consume(_ id: UUID, data: Data?, complete: Bool, error: NWError?) {
        guard var peer = peers[id] else { return }
        if complete || error != nil {
            peerClosedCount += 1
            peer.connection.cancel()
            peers.removeValue(forKey: id)
            return
        }
        if let data, !peer.recorded { peer.buffer.append(data) }
        guard peer.buffer.count <= 65_536 else { peer.connection.cancel(); peers.removeValue(forKey: id); return }
        peers[id] = peer
        if !peer.recorded, let request = parse(peer.buffer) {
            peers[id]?.recorded = true
            requests.append(request)
            switch responder(request) {
            case .reply(let status, let body):
                var response = Data("HTTP/1.1 \(status) Fixture\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                peer.connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                    MainActor.assumeIsolated { self?.peers.removeValue(forKey: id)?.connection.cancel() }
                })
                return
            case .hang:
                // Advertise a body and send only one byte, keeping a real HTTP transfer outstanding.
                peer.connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n{".utf8), completion: .idempotent)
            }
        }
        receive(id)
    }

    private func parse(_ buffer: Data) -> RESTLoopbackRequest? {
        guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            headers[String(pair[0]).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard let count = Int(headers["content-length"] ?? "0"), (0...65_536).contains(count),
              buffer.count >= boundary.upperBound + count else { return nil }
        return RESTLoopbackRequest(method: String(parts[0]), target: String(parts[1]), headers: headers,
                                   body: buffer.subdata(in: boundary.upperBound..<(boundary.upperBound + count)))
    }
}
