// Exercises native DistributedNotificationCenter IPC using private fixtures, never real capture or TCC.
import Darwin
import Foundation
import XCTest
@testable import NikoShot

@MainActor
final class AutomationIPCTests: XCTestCase {
    func testNativeRoundTripKeepsResultTextOutOfNotificationsAndRemovesResponse() async throws {
        let configuration = fixtureConfiguration(), bridge = AutomationBridge(), recorder = AutomationCommandRecorder()
        let secret = "私密 OCR fixture: \"你好\"\n第二行"
        bridge.handler = { command in recorder.commands.append(command); return AutomationResponse(outputPath: "/tmp/image.png", text: secret, message: "完成") }
        let server = AutomationServer(bridge: bridge, configuration: configuration), client = AutomationIPCClient(configuration: configuration)
        let notifications = AutomationNotificationRecorder(), center = DistributedNotificationCenter.default()
        var tokens: [any NSObjectProtocol] = []
        for event in ["query", "ready", "request", "response", "cancel", "stopped"] {
            tokens.append(center.addObserver(forName: configuration.name(event), object: nil, queue: .main) { notification in
                let info = notification.userInfo ?? [:]
                let serialized = String(describing: info) + ((info["metadata"] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "")
                MainActor.assumeIsolated { notifications.payloads.append(serialized) }
            })
        }
        defer { client.cancel(); server.stop(); for token in tokens { center.removeObserver(token) }; try? FileManager.default.removeItem(at: configuration.directory) }
        server.start(); server.start()
        XCTAssertEqual(server.observerCount, 3)
        let pid = try await client.connect(serverPID: getpid(), timeout: 2)
        XCTAssertEqual(pid, getpid()); XCTAssertEqual(client.observerCount, 0); XCTAssertEqual(client.timerCount, 0)
        let response = try await client.execute(AutomationCommand(action: .capture), serverPID: pid, timeout: 2)
        XCTAssertEqual(response.text, secret); XCTAssertEqual(response.outputPath, "/tmp/image.png")
        XCTAssertEqual(recorder.commands.count, 1)
        XCTAssertEqual(client.observerCount, 0); XCTAssertEqual(client.timerCount, 0); XCTAssertNil(client.pendingRequestID)
        XCTAssertEqual(client.processObserverCount + server.processObserverCount, 0)
        XCTAssertFalse(notifications.payloads.isEmpty)
        XCTAssertTrue(notifications.payloads.allSatisfy { !$0.contains(secret) && !$0.contains("私密 OCR") })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: configuration.directory, includingPropertiesForKeys: nil).isEmpty)
        server.stop(); server.stop(); XCTAssertEqual(server.observerCount, 0); XCTAssertEqual(server.operationCount, 0)
    }

    func testHandshakeWaitsForHandlerWithoutReplayingTheCommand() async throws {
        let configuration = fixtureConfiguration(), bridge = AutomationBridge(), recorder = AutomationCommandRecorder()
        let server = AutomationServer(bridge: bridge, configuration: configuration), client = AutomationIPCClient(configuration: configuration)
        let state = AutomationConnectionState()
        defer { client.cancel(); server.stop(); try? FileManager.default.removeItem(at: configuration.directory) }
        server.start()
        let connection = Task { let pid = try await client.connect(serverPID: getpid(), timeout: 2); state.connected = true; return pid }
        try await waitUntil { client.observerCount == 2 }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(state.connected)
        XCTAssertTrue(recorder.commands.isEmpty)
        bridge.handler = { command in recorder.commands.append(command); return AutomationResponse(message: "ready") }
        let pid = try await connection.value
        let result = try await client.execute(AutomationCommand(action: .scroll), serverPID: pid, timeout: 2)
        XCTAssertEqual(result.message, "ready"); XCTAssertEqual(recorder.commands.map(\.action), [.scroll])
        XCTAssertEqual(client.observerCount + client.timerCount, 0)
    }

    func testResponsePermissionsRequestBindingAndDuplicateSuppression() async throws {
        let configuration = fixtureConfiguration(), bridge = AutomationBridge(), recorder = AutomationCommandRecorder()
        bridge.handler = { command in recorder.commands.append(command); try await Task.sleep(for: .milliseconds(40)); return AutomationResponse(text: "private") }
        let server = AutomationServer(bridge: bridge, configuration: configuration), center = DistributedNotificationCenter.default()
        defer { server.stop(); try? FileManager.default.removeItem(at: configuration.directory) }
        server.start()
        let id = UUID(); try AutomationIPCFiles.prepare(configuration, requestID: id)
        let request = AutomationWireRequest(requestID: id, clientPID: getpid(), serverPID: getpid(), command: AutomationCommand(action: .lastOCR))
        let metadata = try JSONEncoder().encode(request)
        for _ in 0..<2 { center.postNotificationName(configuration.name("request"), object: String(getpid()), userInfo: ["metadata": metadata], deliverImmediately: true) }
        try await waitUntil { FileManager.default.fileExists(atPath: configuration.responseFile(id).path) }
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: configuration.directory.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: configuration.requestDirectory(id).path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: configuration.responseFile(id).path)
        XCTAssertEqual((rootAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let wire = try AutomationIPCFiles.read(configuration: configuration, requestID: id)
        XCTAssertEqual(wire.requestID, id); XCTAssertEqual(wire.clientPID, getpid()); XCTAssertEqual(wire.result?.text, "private")
        center.postNotificationName(configuration.name("request"), object: String(getpid()), userInfo: ["metadata": metadata], deliverImmediately: true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(recorder.commands.count, 1, "Duplicate notification delivery must not perform another capture")
    }

    func testTimeoutAndCancellationReleaseObserversTimerAndPrivateFiles() async throws {
        let configuration = fixtureConfiguration(), client = AutomationIPCClient(configuration: configuration)
        defer { client.cancel(); try? FileManager.default.removeItem(at: configuration.directory) }
        do { _ = try await client.execute(AutomationCommand(action: .capture), serverPID: getpid(), timeout: 0.04); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? AutomationError, .timeout) }
        XCTAssertEqual(client.observerCount + client.timerCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: configuration.directory, includingPropertiesForKeys: nil).isEmpty)
        let bridge = AutomationBridge(), recorder = AutomationCommandRecorder()
        bridge.handler = { command in recorder.commands.append(command); try await Task.sleep(for: .seconds(30)); return AutomationResponse() }
        let server = AutomationServer(bridge: bridge, configuration: configuration)
        defer { server.stop() }; server.start()
        let operation = Task { try await client.execute(AutomationCommand(action: .scroll), serverPID: getpid(), timeout: 2) }
        try await waitUntil { recorder.commands.count == 1 && server.operationCount == 1 }
        let id = try XCTUnwrap(client.pendingRequestID)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        try await waitUntil { server.operationCount == 0 }
        XCTAssertEqual(client.observerCount + client.timerCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.requestDirectory(id).path))
        server.stop(); XCTAssertEqual(server.observerCount, 0)
    }

    func testClientRejectsResponseForAnotherProcessAndUnsafeDirectory() async throws {
        let configuration = fixtureConfiguration(), client = AutomationIPCClient(configuration: configuration)
        defer { client.cancel(); try? FileManager.default.removeItem(at: configuration.directory) }
        let operation = Task { try await client.execute(AutomationCommand(action: .lastOCR), serverPID: getpid(), timeout: 2) }
        try await waitUntil { client.pendingRequestID != nil }
        let id = try XCTUnwrap(client.pendingRequestID)
        try AutomationIPCFiles.write(AutomationWireResponse(requestID: id, clientPID: getpid() + 1, serverPID: getpid(), result: AutomationResponse(text: "wrong recipient"), error: nil), configuration: configuration)
        DistributedNotificationCenter.default().postNotificationName(configuration.name("response"), object: String(getpid()),
            userInfo: ["requestID": id.uuidString, "clientPID": getpid(), "serverPID": getpid()], deliverImmediately: true)
        do { _ = try await operation.value; XCTFail("Expected recipient mismatch") }
        catch { guard case .invalidResponse = error as? AutomationError else { return XCTFail("Expected bound-response error, got \(error)") } }
        XCTAssertEqual(client.observerCount + client.timerCount, 0)
        let unsafe = fixtureConfiguration()
        try FileManager.default.createDirectory(at: unsafe.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: unsafe.directory) }
        let unsafeClient = AutomationIPCClient(configuration: unsafe)
        do { _ = try await unsafeClient.execute(AutomationCommand(action: .lastOCR), serverPID: getpid(), timeout: 0.1); XCTFail("Expected unsafe directory") }
        catch { XCTAssertTrue(error is AutomationError) }
        XCTAssertEqual(unsafeClient.observerCount + unsafeClient.timerCount, 0)
    }

    func testStoppedServerReleasesRegistrationOwnerAndCLIUsesActionAppropriateOutput() {
        let configuration = fixtureConfiguration(), bridge = AutomationBridge()
        var server: AutomationServer? = AutomationServer(bridge: bridge, configuration: configuration)
        weak let weakServer = server
        server?.start(); XCTAssertEqual(server?.observerCount, 3)
        server?.stop(); XCTAssertEqual(server?.observerCount, 0)
        server = nil; XCTAssertNil(weakServer)
        let response = AutomationResponse(outputPath: "/tmp/capture.png", text: "automatic OCR", message: "done")
        XCTAssertEqual(AutomationCLI.renderedOutput(response, action: .capture), "/tmp/capture.png")
        XCTAssertEqual(AutomationCLI.renderedOutput(response, action: .scroll), "/tmp/capture.png")
        XCTAssertEqual(AutomationCLI.renderedOutput(response, action: .ocr), "automatic OCR")
        XCTAssertEqual(AutomationCLI.renderedOutput(response, action: .translate), "automatic OCR")
        XCTAssertNil(AutomationCLI.runIfNeeded(arguments: ["niko-shot"]))
        XCTAssertEqual(AutomationCLI.runIfNeeded(arguments: ["niko-shot", "unknown"]), 64)
        try? FileManager.default.removeItem(at: configuration.directory)
    }

    func testStoppingServerImmediatelyReleasesClientAndRetainsCleanupUntilDrain() async throws {
        let configuration = fixtureConfiguration(), bridge = AutomationBridge(), recorder = AutomationCommandRecorder()
        let suspendedCleanup = AutomationSuspension(), drainState = AutomationConnectionState()
        bridge.handler = { command in
            recorder.commands.append(command)
            do { try await Task.sleep(for: .seconds(30)) }
            catch { await suspendedCleanup.wait(); throw error }
            return AutomationResponse()
        }
        let server = AutomationServer(bridge: bridge, configuration: configuration), client = AutomationIPCClient(configuration: configuration)
        defer { suspendedCleanup.release(); client.cancel(); server.stop(); try? FileManager.default.removeItem(at: configuration.directory) }
        server.start()
        let operation = Task { try await client.execute(AutomationCommand(action: .scroll), serverPID: getpid(), timeout: 30) }
        try await waitUntil { recorder.commands.count == 1 && server.operationCount == 1 }
        let id = try XCTUnwrap(client.pendingRequestID), stoppedAt = ContinuousClock.now
        server.stop()
        XCTAssertEqual(server.observerCount + server.operationCount + server.processObserverCount, 0)
        XCTAssertEqual(server.drainingOperationCount, 1, "Synchronous stop must retain unfinished cancellation cleanup")
        do { _ = try await operation.value; XCTFail("Expected service-stop error") }
        catch { XCTAssertEqual(error as? AutomationError, .executionFailed("niko-shot 服务已停止，操作已取消。")) }
        XCTAssertLessThan(ContinuousClock.now - stoppedAt, .seconds(1), "A native stop notification must beat the 30-second request deadline")
        XCTAssertEqual(client.observerCount + client.timerCount + client.processObserverCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.requestDirectory(id).path))
        try await waitUntil { suspendedCleanup.waiting }

        // An old draining operation must not clear a later request's observers, task or result.
        bridge.handler = { _ in AutomationResponse(message: "next request") }
        server.start()
        let next = try await client.execute(AutomationCommand(action: .lastOCR), serverPID: getpid(), timeout: 2)
        XCTAssertEqual(next.message, "next request"); XCTAssertEqual(server.drainingOperationCount, 1)
        let drain = Task { await server.stopAndDrain(); drainState.connected = true }
        await Task.yield()
        XCTAssertFalse(drainState.connected, "stopAndDrain must await the retained handler rather than just cancel its task")
        suspendedCleanup.release(); await drain.value
        XCTAssertTrue(suspendedCleanup.finished); XCTAssertTrue(drainState.connected)
        XCTAssertEqual(server.drainingOperationCount + server.operationCount + server.processObserverCount + server.observerCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: configuration.directory, includingPropertiesForKeys: nil).isEmpty)
    }

    func testStoppingServerAlsoReleasesPendingNativeReadinessHandshake() async throws {
        let configuration = fixtureConfiguration(), bridge = AutomationBridge()
        let server = AutomationServer(bridge: bridge, configuration: configuration), client = AutomationIPCClient(configuration: configuration)
        defer { client.cancel(); server.stop(); try? FileManager.default.removeItem(at: configuration.directory) }
        server.start()
        let connection = Task { try await client.connect(serverPID: getpid(), timeout: 30) }
        try await waitUntil { client.observerCount == 2 && client.processObserverCount == 1 }
        let stoppedAt = ContinuousClock.now
        server.stop()
        do { _ = try await connection.value; XCTFail("Expected stop during readiness handshake") }
        catch { XCTAssertEqual(error as? AutomationError, .executionFailed("niko-shot 服务已停止，操作已取消。")) }
        XCTAssertLessThan(ContinuousClock.now - stoppedAt, .seconds(1))
        await server.stopAndDrain()
        XCTAssertEqual(client.observerCount + client.timerCount + client.processObserverCount, 0)
    }

    func testIndependentClientProcessExitCancelsAndCleansOnlyItsRequest() async throws {
        let configuration = fixtureConfiguration(), bridge = AutomationBridge(), recorder = AutomationCommandRecorder()
        let abandonedCleanup = AutomationSuspension(), survivingRequest = AutomationSuspension()
        bridge.handler = { command in
            recorder.commands.append(command)
            if command.action == .scroll {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { await abandonedCleanup.wait(); throw error }
                return AutomationResponse()
            }
            await survivingRequest.wait()
            return AutomationResponse(text: "adjacent request survived")
        }
        let fixtureProcess = try independentProcess()
        let server = AutomationServer(bridge: bridge, configuration: configuration), client = AutomationIPCClient(configuration: configuration)
        defer {
            abandonedCleanup.release(); survivingRequest.release(); client.cancel(); server.stop()
            if fixtureProcess.isRunning { fixtureProcess.terminate() }
            try? FileManager.default.removeItem(at: configuration.directory)
        }
        let childPID = fixtureProcess.processIdentifier
        XCTAssertNotEqual(childPID, getpid(), "The exit fixture must never terminate XCTest")
        server.start()
        let abandonedID = UUID(); try AutomationIPCFiles.prepare(configuration, requestID: abandonedID)
        let metadata = try JSONEncoder().encode(AutomationWireRequest(requestID: abandonedID, clientPID: childPID,
            serverPID: getpid(), command: AutomationCommand(action: .scroll)))
        DistributedNotificationCenter.default().postNotificationName(configuration.name("request"), object: String(getpid()),
            userInfo: ["metadata": metadata], deliverImmediately: true)
        try await waitUntil { recorder.commands.count == 1 && server.processObserverCount == 1 }
        let survivingOperation = Task { try await client.execute(AutomationCommand(action: .lastOCR), serverPID: getpid(), timeout: 2) }
        try await waitUntil { survivingRequest.waiting && server.operationCount == 2 && server.processObserverCount == 2 }
        let survivingID = try XCTUnwrap(client.pendingRequestID)
        XCTAssertEqual(kill(childPID, SIGKILL), 0, "Only the independent fixture process is killed")
        try await waitUntil { abandonedCleanup.waiting && server.operationCount == 1 && server.processObserverCount == 1 }
        XCTAssertEqual(server.drainingOperationCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.requestDirectory(abandonedID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.requestDirectory(survivingID).path))
        XCTAssertEqual(client.pendingRequestID, survivingID)
        survivingRequest.release()
        let response = try await survivingOperation.value
        XCTAssertEqual(response.text, "adjacent request survived")
        XCTAssertEqual(client.observerCount + client.timerCount + client.processObserverCount + server.processObserverCount, 0)
        abandonedCleanup.release(); await server.stopAndDrain()
        XCTAssertTrue(abandonedCleanup.finished)
        XCTAssertEqual(server.drainingOperationCount + server.operationCount + server.observerCount, 0)
        try await waitUntil { !fixtureProcess.isRunning }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: configuration.directory, includingPropertiesForKeys: nil).isEmpty)
    }

    func testIndependentServerProcessExitImmediatelyReleasesClient() async throws {
        let configuration = fixtureConfiguration(), client = AutomationIPCClient(configuration: configuration)
        let fixtureProcess = try independentProcess(), pid = fixtureProcess.processIdentifier
        defer {
            client.cancel(); if fixtureProcess.isRunning { fixtureProcess.terminate() }
            try? FileManager.default.removeItem(at: configuration.directory)
        }
        XCTAssertNotEqual(pid, getpid())
        let operation = Task { try await client.execute(AutomationCommand(action: .lastOCR), serverPID: pid, timeout: 30) }
        try await waitUntil { client.pendingRequestID != nil && client.processObserverCount == 1 }
        let exitedAt = ContinuousClock.now
        XCTAssertEqual(kill(pid, SIGKILL), 0)
        do { _ = try await operation.value; XCTFail("Expected server process exit") }
        catch { XCTAssertEqual(error as? AutomationError, .executionFailed("niko-shot 服务进程已退出，操作已取消。")) }
        XCTAssertLessThan(ContinuousClock.now - exitedAt, .seconds(1))
        XCTAssertEqual(client.observerCount + client.timerCount + client.processObserverCount, 0)
        try await waitUntil { !fixtureProcess.isRunning }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: configuration.directory, includingPropertiesForKeys: nil).isEmpty)
    }

    func testExitedColdLaunchTransfersHandshakeToLockedResidentWithoutReplayingCommand() async throws {
        let configuration = fixtureConfiguration(), bridge = AutomationBridge(), commands = AutomationCommandRecorder()
        let lookup = AutomationResidentLookup(), handshake = AutomationHandshakeRecorder()
        bridge.handler = { command in commands.commands.append(command); return AutomationResponse(text: "resident ready") }
        let server = AutomationServer(bridge: bridge, configuration: configuration)
        let client = AutomationIPCClient(configuration: configuration, residentPIDLookup: { lookup.value() })
        let losingProcess = try independentProcess(), center = DistributedNotificationCenter.default()
        let tokens = observeHandshake(configuration, recorder: handshake)
        defer {
            client.cancel(); server.stop(); for token in tokens { center.removeObserver(token) }
            if losingProcess.isRunning { losingProcess.terminate() }
            try? FileManager.default.removeItem(at: configuration.directory)
        }
        server.start()
        let losingPID = losingProcess.processIdentifier
        let connection = Task { try await client.connect(serverPID: losingPID, timeout: 2) }
        try await waitUntil { handshake.queries.count == 1 && client.processObserverCount == 1 }
        let phase = try XCTUnwrap(client.pendingQueryID)
        lookup.processID = getpid()
        XCTAssertEqual(kill(losingPID, SIGKILL), 0)
        let resident = try await connection.value
        XCTAssertEqual(resident, getpid())
        let result = try await client.execute(AutomationCommand(action: .lastOCR), serverPID: resident, timeout: 2)
        try await waitUntil { handshake.queries.count >= 2 && handshake.requests.count == 1 }
        XCTAssertEqual(result.text, "resident ready")
        XCTAssertEqual(Set(handshake.queries.map(\.id)), [phase], "Handoff must keep the original query identity")
        XCTAssertEqual(handshake.queries.map(\.serverPID), [losingPID, getpid()])
        XCTAssertEqual(commands.commands.map(\.action), [.lastOCR]); XCTAssertEqual(handshake.requests.count, 1)
        XCTAssertEqual(client.observerCount + client.timerCount + client.processObserverCount + server.processObserverCount, 0)
        await server.stopAndDrain()
    }

    func testLaunchCallbackUsesLockedResidentEvenWhenNewInstanceLivesOrLaunchReportsError() async throws {
        for reportsLaunchError in [false, true] {
            let configuration = fixtureConfiguration(), bridge = AutomationBridge(), commands = AutomationCommandRecorder()
            let lookup = AutomationResidentLookup()
            bridge.handler = { command in commands.commands.append(command); return AutomationResponse(message: "winner") }
            let server = AutomationServer(bridge: bridge, configuration: configuration)
            let client = AutomationIPCClient(configuration: configuration, residentPIDLookup: { lookup.value() })
            let losingProcess = try independentProcess()
            defer {
                client.cancel(); server.stop(); if losingProcess.isRunning { losingProcess.terminate() }
                try? FileManager.default.removeItem(at: configuration.directory)
            }
            server.start()
            let connection = Task {
                try await client.connect(serverPID: nil, timeout: 2) { client in
                    guard let phase = client.pendingQueryID else { return XCTFail("Expected launch phase") }
                    lookup.processID = getpid()
                    client.launched(serverPID: reportsLaunchError ? nil : losingProcess.processIdentifier,
                        error: reportsLaunchError ? POSIXError(.ECHILD) : nil, phase: phase)
                }
            }
            let pid = try await connection.value
            XCTAssertEqual(pid, getpid()); XCTAssertTrue(losingProcess.isRunning)
            let result = try await client.execute(AutomationCommand(action: .lastOCR), serverPID: pid, timeout: 2)
            XCTAssertEqual(result.message, "winner"); XCTAssertEqual(commands.commands.count, 1)
            XCTAssertEqual(client.observerCount + client.timerCount + client.processObserverCount, 0)
            await server.stopAndDrain()
        }
    }

    func testReadyEventCanResolveWinnerAfterLosingProcessExitBeforeLockPIDIsAvailable() async throws {
        let configuration = fixtureConfiguration(), lookup = AutomationResidentLookup()
        let client = AutomationIPCClient(configuration: configuration, residentPIDLookup: { lookup.value() })
        let losingProcess = try independentProcess(), bridge = AutomationBridge(), commands = AutomationCommandRecorder()
        bridge.handler = { command in commands.commands.append(command); return AutomationResponse(text: "late winner") }
        let server = AutomationServer(bridge: bridge, configuration: configuration)
        defer {
            client.cancel(); server.stop(); if losingProcess.isRunning { losingProcess.terminate() }
            try? FileManager.default.removeItem(at: configuration.directory)
        }
        let connection = Task { try await client.connect(serverPID: losingProcess.processIdentifier, timeout: 2) }
        try await waitUntil { client.pendingQueryID != nil && client.processObserverCount == 1 }
        let phase = try XCTUnwrap(client.pendingQueryID)
        XCTAssertEqual(kill(losingProcess.processIdentifier, SIGKILL), 0)
        try await waitUntil { client.processObserverCount == 0 }
        XCTAssertEqual(client.pendingQueryID, phase); XCTAssertEqual(client.timerCount, 1)
        DistributedNotificationCenter.default().postNotificationName(configuration.name("stopped"), object: nil,
            userInfo: [:], deliverImmediately: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(client.pendingQueryID, phase, "A stop notification without a bound PID cannot cancel cold-start handoff")
        lookup.processID = getpid(); server.start()
        let pid = try await connection.value
        let result = try await client.execute(AutomationCommand(action: .lastOCR), serverPID: pid, timeout: 2)
        XCTAssertEqual(pid, getpid()); XCTAssertEqual(result.text, "late winner")
        XCTAssertEqual(commands.commands.count, 1)
        XCTAssertEqual(client.observerCount + client.timerCount + client.processObserverCount, 0)
        await server.stopAndDrain()
    }

    func testCancelledLaunchCallbackAndOldReadyIdentityCannotAffectNextHandshake() async throws {
        let configuration = fixtureConfiguration(), bridge = AutomationBridge(), lookup = AutomationResidentLookup()
        let server = AutomationServer(bridge: bridge, configuration: configuration)
        let client = AutomationIPCClient(configuration: configuration, residentPIDLookup: { lookup.value() })
        defer { client.cancel(); server.stop(); try? FileManager.default.removeItem(at: configuration.directory) }
        let first = Task { try await client.connect(serverPID: nil, timeout: 2) { _ in } }
        try await waitUntil { client.pendingQueryID != nil }
        let cancelledPhase = try XCTUnwrap(client.pendingQueryID)
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected first handshake cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        server.start(); lookup.processID = getpid()
        let second = Task { try await client.connect(serverPID: getpid(), timeout: 2) }
        try await waitUntil { client.pendingQueryID != nil && client.processObserverCount == 1 }
        let nextPhase = try XCTUnwrap(client.pendingQueryID)
        XCTAssertNotEqual(nextPhase, cancelledPhase)
        client.launched(serverPID: nil, error: POSIXError(.EIO), phase: cancelledPhase)
        DistributedNotificationCenter.default().postNotificationName(configuration.name("ready"), object: String(getpid()),
            userInfo: ["serverPID": getpid(), "clientPID": getpid(), "queryID": cancelledPhase.uuidString, "ready": true], deliverImmediately: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(client.pendingQueryID, nextPhase)
        bridge.handler = { _ in AutomationResponse(message: "next handshake") }
        let resident = try await second.value
        XCTAssertEqual(resident, getpid())
        let result = try await client.execute(AutomationCommand(action: .lastOCR), serverPID: resident, timeout: 2)
        XCTAssertEqual(result.message, "next handshake")
        XCTAssertEqual(client.observerCount + client.timerCount + client.processObserverCount, 0)
        await server.stopAndDrain()
    }

    func testHandshakeHandoffDoesNotResetTotalStartupDeadline() async throws {
        let configuration = fixtureConfiguration(), lookup = AutomationResidentLookup(), handshake = AutomationHandshakeRecorder()
        let client = AutomationIPCClient(configuration: configuration, residentPIDLookup: { lookup.value() })
        let losingProcess = try independentProcess(), silentWinner = try independentProcess()
        let center = DistributedNotificationCenter.default(), tokens = observeHandshake(configuration, recorder: handshake)
        defer {
            client.cancel(); for token in tokens { center.removeObserver(token) }
            if losingProcess.isRunning { losingProcess.terminate() }; if silentWinner.isRunning { silentWinner.terminate() }
            try? FileManager.default.removeItem(at: configuration.directory)
        }
        let began = ContinuousClock.now
        let connection = Task { try await client.connect(serverPID: losingProcess.processIdentifier, timeout: 0.8) }
        try await waitUntil { handshake.queries.count == 1 }
        let phase = try XCTUnwrap(client.pendingQueryID)
        try await Task.sleep(for: .milliseconds(500))
        lookup.processID = silentWinner.processIdentifier
        XCTAssertEqual(kill(losingProcess.processIdentifier, SIGKILL), 0)
        try await waitUntil { handshake.queries.count == 2 }
        XCTAssertEqual(client.pendingQueryID, phase)
        do { _ = try await connection.value; XCTFail("Expected original startup deadline") }
        catch { XCTAssertEqual(error as? AutomationError, .timeout) }
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(1100), "Resetting the deadline on handoff would wait about 1.3 seconds")
        XCTAssertEqual(Set(handshake.queries.map(\.id)), [phase]); XCTAssertTrue(handshake.requests.isEmpty)
        XCTAssertEqual(client.observerCount + client.timerCount + client.processObserverCount, 0)
    }

    func testIsolatedConfigurationAndExecutionNeverAdoptOrReplayToAnotherResident() async throws {
        let configuration = fixtureConfiguration(), production = AutomationIPCConfiguration.live
        XCTAssertFalse(configuration.isLive)
        XCTAssertFalse(AutomationIPCConfiguration(namespace: production.namespace, directory: configuration.directory).isLive)
        XCTAssertFalse(AutomationIPCConfiguration(namespace: configuration.namespace, directory: production.directory).isLive)
        let isolatedClient = AutomationIPCClient(configuration: configuration)
        do { _ = try await isolatedClient.connect(serverPID: nil, timeout: 0.1); XCTFail("Isolated configuration cannot consult the production lock") }
        catch { XCTAssertEqual(error as? AutomationError, .unavailable) }

        let lookup = AutomationResidentLookup(), bridge = AutomationBridge(), commands = AutomationCommandRecorder()
        lookup.processID = getpid()
        bridge.handler = { command in commands.commands.append(command); return AutomationResponse() }
        let server = AutomationServer(bridge: bridge, configuration: configuration)
        let client = AutomationIPCClient(configuration: configuration, residentPIDLookup: { lookup.value() })
        let alreadyChosenServer = try independentProcess(), handshake = AutomationHandshakeRecorder()
        let center = DistributedNotificationCenter.default(), tokens = observeHandshake(configuration, recorder: handshake)
        defer {
            client.cancel(); server.stop(); for token in tokens { center.removeObserver(token) }
            if alreadyChosenServer.isRunning { alreadyChosenServer.terminate() }
            try? FileManager.default.removeItem(at: configuration.directory)
        }
        server.start()
        let operation = Task { try await client.execute(AutomationCommand(action: .capture), serverPID: alreadyChosenServer.processIdentifier, timeout: 2) }
        try await waitUntil { handshake.requests.count == 1 && client.processObserverCount == 1 }
        XCTAssertEqual(kill(alreadyChosenServer.processIdentifier, SIGKILL), 0)
        do { _ = try await operation.value; XCTFail("Execution must fail when its selected server exits") }
        catch { XCTAssertEqual(error as? AutomationError, .executionFailed("niko-shot 服务进程已退出，操作已取消。")) }
        XCTAssertEqual(lookup.calls, 0, "Resident lookup is permitted only before a command is sent")
        XCTAssertTrue(handshake.queries.isEmpty); XCTAssertEqual(handshake.requests.count, 1); XCTAssertTrue(commands.commands.isEmpty)
        XCTAssertEqual(client.observerCount + client.timerCount + client.processObserverCount, 0)
        await server.stopAndDrain()
    }

    private func observeHandshake(_ configuration: AutomationIPCConfiguration, recorder: AutomationHandshakeRecorder) -> [any NSObjectProtocol] {
        let center = DistributedNotificationCenter.default()
        return ["query", "request"].map { event in
            center.addObserver(forName: configuration.name(event), object: nil, queue: .main) { notification in
                let query = (notification.userInfo?["queryID"] as? String).flatMap(UUID.init(uuidString:))
                let target = (notification.object as? String).flatMap(Int32.init)
                let request = (notification.userInfo?["metadata"] as? Data).flatMap { try? JSONDecoder().decode(AutomationWireRequest.self, from: $0) }
                MainActor.assumeIsolated {
                    if let query, let target { recorder.queries.append((query, target)) }
                    if let request { recorder.requests.append(request.requestID) }
                }
            }
        }
    }

    private func independentProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func fixtureConfiguration() -> AutomationIPCConfiguration {
        let id = UUID().uuidString
        return AutomationIPCConfiguration(namespace: "com.n1ko.niko-shot.test.\(id)",
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("niko-shot-ipc-test-\(id)", isDirectory: true))
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw AutomationError.timeout
    }
}

@MainActor private final class AutomationNotificationRecorder { var payloads: [String] = [] }
@MainActor private final class AutomationConnectionState { var connected = false }
@MainActor private final class AutomationResidentLookup {
    var processID: Int32?
    var calls = 0
    func value() -> Int32? { calls += 1; return processID }
}
@MainActor private final class AutomationHandshakeRecorder {
    var queries: [(id: UUID, serverPID: Int32)] = []
    var requests: [UUID] = []
}

@MainActor private final class AutomationSuspension {
    var waiting = false
    var finished = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        waiting = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        finished = true
    }
    func release() {
        released = true
        let pending = continuation; continuation = nil; pending?.resume()
    }
}
