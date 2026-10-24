// Implements event-driven resident IPC; notification payloads contain metadata, never result text.
import AppKit
import Darwin
import Dispatch
import Foundation

struct AutomationIPCConfiguration: Sendable {
    let namespace: String
    let directory: URL
    static var live: AutomationIPCConfiguration {
        AutomationIPCConfiguration(namespace: "com.n1ko.niko-shot.automation.v1",
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("niko-shot-automation-\(getuid())", isDirectory: true))
    }
    var isLive: Bool {
        let production = Self.live
        return namespace == production.namespace && directory.standardizedFileURL == production.directory.standardizedFileURL
    }
    func name(_ event: String) -> Notification.Name { Notification.Name("\(namespace).\(event)") }
    func requestDirectory(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    func responseFile(_ id: UUID) -> URL { requestDirectory(id).appendingPathComponent("response.json") }
}

struct AutomationWireRequest: Codable, Sendable {
    let requestID: UUID
    let clientPID: Int32
    let serverPID: Int32
    let command: AutomationCommand
}
struct AutomationWireResponse: Codable, Sendable {
    let requestID: UUID
    let clientPID: Int32
    let serverPID: Int32
    let result: AutomationResponse?
    let error: String?
}

// Cocoa's userInfo is not Sendable. Extract fixed value fields before entering the main actor.
private struct AutomationNotification: Sendable {
    let metadata: Data?
    let requestID: UUID?
    let queryID: UUID?
    let clientPID: Int32?
    let serverPID: Int32?
    let ready: Bool?
    init(_ notification: Notification) {
        let info = notification.userInfo
        metadata = info?["metadata"] as? Data
        requestID = (info?["requestID"] as? String).flatMap(UUID.init(uuidString:))
        queryID = (info?["queryID"] as? String).flatMap(UUID.init(uuidString:))
        clientPID = (info?["clientPID"] as? NSNumber)?.int32Value
        serverPID = (info?["serverPID"] as? NSNumber)?.int32Value
        ready = (info?["ready"] as? NSNumber)?.boolValue
    }
}

// NotificationCenter supports thread-safe removal. This wrapper owns only registration lifetime;
// its nonisolated finalizer unregisters a Cocoa token and never accesses actor-owned UI or state.
private final class AutomationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol
    init(center: NotificationCenter, token: any NSObjectProtocol) { self.center = center; self.token = token }
    deinit { center.removeObserver(token) }
}

// Dispatch source cancellation is thread-safe. The wrapper owns registration lifetime only;
// all process events run on the main queue before accessing actor-owned request state.
private final class AutomationProcessObservation: @unchecked Sendable {
    private let source: any DispatchSourceProcess
    init(processID: Int32, body: @escaping @MainActor @Sendable () -> Void) {
        source = DispatchSource.makeProcessSource(identifier: processID, eventMask: .exit, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { body() } }
        source.activate()
    }
    deinit { source.cancel() }
}

enum AutomationIPCFiles {
    static func prepare(_ configuration: AutomationIPCConfiguration, requestID: UUID? = nil) throws {
        try ensureDirectory(configuration.directory, create: true)
        if let requestID { try ensureDirectory(configuration.requestDirectory(requestID), create: true) }
    }
    static func ensureDirectory(_ url: URL, create: Bool) throws {
        if create, mkdir(url.path, 0o700) != 0, errno != EEXIST { throw posixError() }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError() }
        guard info.st_uid == getuid(), (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (info.st_mode & 0o777) == 0o700 else {
            throw AutomationError.invalidResponse("临时目录的所有者或权限不正确。")
        }
    }
    static func write(_ response: AutomationWireResponse, configuration: AutomationIPCConfiguration) throws {
        try ensureDirectory(configuration.directory, create: false)
        try ensureDirectory(configuration.requestDirectory(response.requestID), create: false)
        let data = try JSONEncoder().encode(response)
        guard data.count <= 16 * 1024 * 1024 else { throw AutomationError.invalidResponse("响应超过 16 MiB。") }
        let path = configuration.responseFile(response.requestID).path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.close() }
        catch { try? handle.close(); try? FileManager.default.removeItem(atPath: path); throw error }
    }
    static func read(configuration: AutomationIPCConfiguration, requestID: UUID) throws -> AutomationWireResponse {
        try ensureDirectory(configuration.directory, create: false)
        try ensureDirectory(configuration.requestDirectory(requestID), create: false)
        let descriptor = open(configuration.responseFile(requestID).path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), (info.st_mode & 0o777) == 0o600,
              info.st_size >= 0, info.st_size <= 16 * 1024 * 1024 else {
            throw AutomationError.invalidResponse("响应文件的所有者、权限或大小不正确。")
        }
        guard let data = try handle.readToEnd() else { throw AutomationError.invalidResponse("响应文件为空。") }
        return try JSONDecoder().decode(AutomationWireResponse.self, from: data)
    }
    static func remove(configuration: AutomationIPCConfiguration, requestID: UUID) {
        try? FileManager.default.removeItem(at: configuration.requestDirectory(requestID))
    }
    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// The resident server uses event-driven observers; process-exit sources exist only for active requests.
@MainActor
public final class AutomationServer {
    private let bridge: AutomationBridge
    private let configuration: AutomationIPCConfiguration
    private let allowsSilentAutomation: @MainActor () -> Bool
    private let center = DistributedNotificationCenter.default()
    private let processID = getpid()
    private var observations: [AutomationObservation] = []
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var draining: [UUID: Task<Void, Never>] = [:]
    private var clients: [UUID: Int32] = [:]
    private var processObservations: [UUID: AutomationProcessObservation] = [:]
    private var completed: [UUID: Date] = [:]
    private var isStarted = false
    /// Number of currently registered distributed observers.
    public var observerCount: Int { observations.count }
    var operationCount: Int { operations.count }
    var drainingOperationCount: Int { draining.count }
    var processObserverCount: Int { processObservations.count }

    /// Creates a server attached to the resident execution bridge.
    public convenience init(bridge: AutomationBridge = .shared) {
        self.init(bridge: bridge, configuration: .live)
    }
    init(bridge: AutomationBridge, configuration: AutomationIPCConfiguration,
         allowsSilentAutomation: @escaping @MainActor () -> Bool = { AppSettings.shared.allowsSilentAutomation }) {
        self.bridge = bridge; self.configuration = configuration; self.allowsSilentAutomation = allowsSilentAutomation
    }

    /// Registers command, readiness and cancellation observers exactly once.
    public func start() {
        guard !isStarted else { return }
        do { try AutomationIPCFiles.prepare(configuration) } catch { return }
        isStarted = true
        observe("query") { [weak self] in self?.receiveQuery($0) }
        observe("request") { [weak self] in self?.receiveRequest($0) }
        observe("cancel") { [weak self] in self?.receiveCancel($0) }
        bridge.availabilityDidChange = { [weak self] in self?.broadcastReady() }
        broadcastReady()
    }

    /// Notifies waiting clients, removes observers and cancels commands while retaining their drain handles.
    public func stop() {
        let wasStarted = isStarted
        isStarted = false; bridge.availabilityDidChange = nil
        observations.removeAll()
        if wasStarted {
            center.postNotificationName(configuration.name("stopped"), object: String(processID),
                userInfo: ["serverPID": processID], deliverImmediately: true)
        }
        for (id, operation) in operations { draining[id] = operation }
        operations.removeAll(); clients.removeAll(); processObservations.removeAll()
        for (id, operation) in draining {
            operation.cancel(); AutomationIPCFiles.remove(configuration: configuration, requestID: id)
        }
        for id in completed.keys { AutomationIPCFiles.remove(configuration: configuration, requestID: id) }
        completed.removeAll()
    }

    /// Stops synchronously, then waits until every retained command has finished its cancellation cleanup.
    public func stopAndDrain() async {
        stop()
        while !draining.isEmpty {
            let pending = Array(draining.values)
            for operation in pending { await operation.value }
        }
    }

    private func observe(_ event: String, body: @escaping @MainActor @Sendable (AutomationNotification) -> Void) {
        let token = center.addObserver(forName: configuration.name(event), object: String(processID), queue: .main) { notification in
            let payload = AutomationNotification(notification)
            MainActor.assumeIsolated { body(payload) }
        }
        observations.append(AutomationObservation(center: center, token: token))
    }
    private func broadcastReady() {
        guard isStarted, bridge.handler != nil else { return }
        center.postNotificationName(configuration.name("ready"), object: String(processID),
            userInfo: ["serverPID": processID, "ready": true], deliverImmediately: true)
    }
    private func receiveQuery(_ notification: AutomationNotification) {
        guard isStarted, let query = notification.queryID,
              let client = notification.clientPID, client > 0 else { return }
        center.postNotificationName(configuration.name("ready"), object: String(processID),
            userInfo: ["serverPID": processID, "clientPID": client, "queryID": query.uuidString, "ready": bridge.handler != nil], deliverImmediately: true)
    }
    private func receiveRequest(_ notification: AutomationNotification) {
        guard isStarted, let data = notification.metadata, data.count <= 65_536,
              let request = try? JSONDecoder().decode(AutomationWireRequest.self, from: data),
              request.serverPID == processID, request.clientPID > 0,
              operations[request.requestID] == nil, draining[request.requestID] == nil,
              completed[request.requestID] == nil else { return }
        pruneCompleted()
        do {
            try AutomationIPCFiles.ensureDirectory(configuration.directory, create: false)
            try AutomationIPCFiles.ensureDirectory(configuration.requestDirectory(request.requestID), create: false)
        } catch { return }
        clients[request.requestID] = request.clientPID
        processObservations[request.requestID] = AutomationProcessObservation(processID: request.clientPID) { [weak self] in
            self?.clientExited(requestID: request.requestID, processID: request.clientPID)
        }
        operations[request.requestID] = Task { [weak self] in
            guard let self else { return }
            let result: AutomationResponse?, errorMessage: String?
            // Only CLI requests arrive here; Shortcuts and URLs call the bridge in-process.
            do {
                let command = try request.command.validatedForCommandLine(allowsSilentAutomation: self.allowsSilentAutomation())
                result = try await self.bridge.execute(command); errorMessage = nil
            }
            catch { result = nil; errorMessage = error is CancellationError ? "操作已取消。" : error.localizedDescription }
            self.operations[request.requestID] = nil
            self.draining[request.requestID] = nil
            self.clients[request.requestID] = nil
            self.processObservations[request.requestID] = nil
            guard self.isStarted, !Task.isCancelled else {
                AutomationIPCFiles.remove(configuration: self.configuration, requestID: request.requestID); return
            }
            self.completed[request.requestID] = Date()
            let response = AutomationWireResponse(requestID: request.requestID, clientPID: request.clientPID,
                serverPID: self.processID, result: result, error: errorMessage)
            do {
                try AutomationIPCFiles.write(response, configuration: self.configuration)
                self.center.postNotificationName(self.configuration.name("response"), object: String(request.clientPID),
                    userInfo: ["requestID": request.requestID.uuidString, "serverPID": self.processID, "clientPID": request.clientPID], deliverImmediately: true)
            } catch { AutomationIPCFiles.remove(configuration: self.configuration, requestID: request.requestID) }
        }
    }
    private func receiveCancel(_ notification: AutomationNotification) {
        guard let id = notification.requestID, let client = notification.clientPID,
              clients[id] == client else { return }
        operations[id]?.cancel()
    }
    private func clientExited(requestID: UUID, processID: Int32) {
        guard clients[requestID] == processID, let operation = operations.removeValue(forKey: requestID) else { return }
        clients[requestID] = nil; processObservations[requestID] = nil
        draining[requestID] = operation; operation.cancel()
        AutomationIPCFiles.remove(configuration: configuration, requestID: requestID)
    }
    private func pruneCompleted() {
        let expired = completed.filter { Date().timeIntervalSince($0.value) > 600 }.map(\.key)
        for id in expired { completed[id] = nil; AutomationIPCFiles.remove(configuration: configuration, requestID: id) }
        if completed.count > 256 {
            for item in completed.sorted(by: { $0.value < $1.value }).prefix(completed.count - 256) {
                completed[item.key] = nil; AutomationIPCFiles.remove(configuration: configuration, requestID: item.key)
            }
        }
    }
}

/// Per-invocation client; observers and one-shot deadlines exist only while connecting or executing.
@MainActor
final class AutomationIPCClient {
    private let configuration: AutomationIPCConfiguration
    private let residentPIDLookup: @MainActor @Sendable () -> Int32?
    private let canResolveResident: Bool
    private let center = DistributedNotificationCenter.default()
    private let processID = getpid()
    private var observations: [AutomationObservation] = []
    private var timer: Timer?
    private var processObservation: AutomationProcessObservation?
    private var expectedServerPID: Int32?
    private var queryID: UUID?
    private var requestID: UUID?
    private var connection: CheckedContinuation<Int32, any Error>?
    private var response: CheckedContinuation<AutomationResponse, any Error>?
    var observerCount: Int { observations.count }
    var timerCount: Int { timer == nil ? 0 : 1 }
    var processObserverCount: Int { processObservation == nil ? 0 : 1 }
    var pendingRequestID: UUID? { requestID }
    var pendingQueryID: UUID? { queryID }

    init(configuration: AutomationIPCConfiguration = .live,
         residentPIDLookup: (@MainActor @Sendable () -> Int32?)? = nil) {
        self.configuration = configuration
        canResolveResident = residentPIDLookup != nil || configuration.isLive
        if let residentPIDLookup { self.residentPIDLookup = residentPIDLookup }
        else if configuration.isLive { self.residentPIDLookup = { ResidentInstanceLock.currentPID() } }
        else { self.residentPIDLookup = { nil } }
    }

    func connect(serverPID: Int32?, timeout: TimeInterval = 10,
                 launch: (@MainActor (AutomationIPCClient) -> Void)? = nil) async throws -> Int32 {
        guard connection == nil, response == nil else { throw AutomationError.executionFailed("客户端已有待处理命令。") }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection = continuation; expectedServerPID = serverPID; queryID = id
                observe("ready", object: nil) { [weak self] in self?.receiveReady($0) }
                observe("stopped", object: nil) { [weak self] in self?.receiveStopped($0) }
                deadline(timeout)
                if Task.isCancelled { fail(CancellationError()); return }
                if let candidate = lockedResident() ?? serverPID { bindServer(candidate, phase: id) }
                else if let launch { launch(self) }
                else { fail(AutomationError.unavailable) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in guard self?.queryID == id else { return }; self?.fail(CancellationError()) }
        }
    }
    func launched(serverPID: Int32?, error: (any Error)?, phase: UUID) {
        guard connection != nil, queryID == phase else { return }
        // A concurrent launch may have lost the resident lock or exited before LaunchServices replies.
        if let resident = lockedResident() { bindServer(resident, phase: phase); return }
        if let error {
            if canResolveResident { awaitResidentReadiness() }
            else { fail(error) }
            return
        }
        guard let serverPID, serverPID > 0 else { fail(AutomationError.unavailable); return }
        bindServer(serverPID, phase: phase)
    }
    func execute(_ command: AutomationCommand, serverPID: Int32, timeout: TimeInterval = 300) async throws -> AutomationResponse {
        guard connection == nil, response == nil else { throw AutomationError.executionFailed("客户端已有待处理命令。") }
        let command = try command.validated()
        try Task.checkCancellation()
        guard serverPID > 0, Darwin.kill(serverPID, 0) == 0 || errno == EPERM else {
            throw AutomationError.executionFailed("niko-shot 服务进程已退出，操作已取消。")
        }
        let id = UUID()
        try AutomationIPCFiles.prepare(configuration, requestID: id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                response = continuation; requestID = id; expectedServerPID = serverPID
                observe("response", object: String(processID)) { [weak self] in self?.receiveResponse($0) }
                observe("stopped", object: String(serverPID)) { [weak self] in self?.receiveStopped($0) }
                watchServer(serverPID, phase: id)
                deadline(timeout)
                if Task.isCancelled { fail(CancellationError()); return }
                do {
                    let metadata = try JSONEncoder().encode(AutomationWireRequest(requestID: id, clientPID: processID,
                        serverPID: serverPID, command: command))
                    center.postNotificationName(configuration.name("request"), object: String(serverPID),
                        userInfo: ["metadata": metadata], deliverImmediately: true)
                } catch { fail(error) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in guard self?.requestID == id else { return }; self?.fail(CancellationError()) }
        }
    }
    func cancel() { fail(CancellationError()) }

    private func observe(_ event: String, object: String?, body: @escaping @MainActor @Sendable (AutomationNotification) -> Void) {
        let token = center.addObserver(forName: configuration.name(event), object: object, queue: .main) { notification in
            let payload = AutomationNotification(notification)
            MainActor.assumeIsolated { body(payload) }
        }
        observations.append(AutomationObservation(center: center, token: token))
    }
    private func query(_ serverPID: Int32) {
        guard let queryID else { return }
        center.postNotificationName(configuration.name("query"), object: String(serverPID),
            userInfo: ["queryID": queryID.uuidString, "clientPID": processID], deliverImmediately: true)
    }
    private func receiveReady(_ notification: AutomationNotification) {
        guard connection != nil, let server = notification.serverPID,
              notification.ready == true else { return }
        if server != expectedServerPID {
            // The winner may publish ready after the losing process exited but before its PID was readable.
            guard let phase = queryID, lockedResident() == server else { return }
            bindServer(server, phase: phase)
            return
        }
        if let value = notification.queryID {
            guard value == queryID, notification.clientPID == processID else { return }
        }
        let continuation = connection; connection = nil
        clear(); continuation?.resume(returning: server)
    }
    private func receiveStopped(_ notification: AutomationNotification) {
        guard connection != nil || response != nil, let server = notification.serverPID,
              server > 0, server == expectedServerPID else { return }
        if connection != nil, let phase = queryID, let resident = lockedResident(excluding: expectedServerPID) {
            bindServer(resident, phase: phase); return
        }
        fail(AutomationError.executionFailed("niko-shot 服务已停止，操作已取消。"))
    }
    private func lockedResident(excluding processID: Int32? = nil) -> Int32? {
        guard let resident = residentPIDLookup(), resident > 0, resident != processID,
              Darwin.kill(resident, 0) == 0 || errno == EPERM else { return nil }
        return resident
    }
    private func bindServer(_ processID: Int32, phase: UUID) {
        guard connection != nil, queryID == phase else { return }
        guard processID > 0, Darwin.kill(processID, 0) == 0 || errno == EPERM else {
            if canResolveResident { awaitResidentReadiness() }
            else { fail(AutomationError.executionFailed("niko-shot 服务进程已退出，操作已取消。")) }
            return
        }
        expectedServerPID = processID
        watchServer(processID, phase: phase)
        query(processID)
        // Keep the original query UUID and one-shot startup deadline across every handoff.
    }
    private func awaitResidentReadiness() {
        expectedServerPID = nil; processObservation = nil
        // The already-registered ready observer and original deadline remain; there is no polling.
    }
    private func watchServer(_ processID: Int32, phase: UUID) {
        processObservation = AutomationProcessObservation(processID: processID) { [weak self] in
            guard let self, self.expectedServerPID == processID,
                  self.queryID == phase || self.requestID == phase else { return }
            if self.connection != nil, self.queryID == phase {
                if let resident = self.lockedResident(excluding: processID) {
                    self.bindServer(resident, phase: phase); return
                }
                if self.canResolveResident { self.awaitResidentReadiness(); return }
            }
            self.fail(AutomationError.executionFailed("niko-shot 服务进程已退出，操作已取消。"))
        }
    }
    private func receiveResponse(_ notification: AutomationNotification) {
        guard response != nil, let id = requestID, notification.requestID == id,
              notification.serverPID == expectedServerPID, notification.clientPID == processID else { return }
        do {
            let wire = try AutomationIPCFiles.read(configuration: configuration, requestID: id)
            guard wire.requestID == id, wire.clientPID == processID, wire.serverPID == expectedServerPID,
                  (wire.result == nil) != (wire.error == nil) else { throw AutomationError.invalidResponse("请求身份或结果类型不匹配。") }
            if let error = wire.error { fail(AutomationError.executionFailed(error)); return }
            guard let result = wire.result else { throw AutomationError.invalidResponse("缺少执行结果。") }
            let continuation = response; response = nil
            clear(); continuation?.resume(returning: result)
        } catch { fail(error) }
    }
    private func deadline(_ interval: TimeInterval) {
        let timer = Timer(timeInterval: max(0.001, interval), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail(AutomationError.timeout) }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func fail(_ error: any Error) {
        if let requestID, let serverPID = expectedServerPID {
            center.postNotificationName(configuration.name("cancel"), object: String(serverPID),
                userInfo: ["requestID": requestID.uuidString, "clientPID": processID], deliverImmediately: true)
        }
        let connection = connection, response = response
        self.connection = nil; self.response = nil
        clear(); connection?.resume(throwing: error); response?.resume(throwing: error)
    }
    private func clear() {
        timer?.invalidate(); timer = nil; observations.removeAll(); processObservation = nil
        if let requestID { AutomationIPCFiles.remove(configuration: configuration, requestID: requestID) }
        requestID = nil; queryID = nil; expectedServerPID = nil
    }
}

/// The main executable's headless entry point. It launches an argument-free resident when needed.
@MainActor
public enum AutomationCLI {
    /// Processes complete `CommandLine.arguments`; returns nil for a normal GUI launch.
    public static func runIfNeeded(arguments: [String]) -> Int32? {
        let values = Array(arguments.dropFirst())
        guard !values.isEmpty else { return nil }
        if isSystemLaunchArgument(values[0]) { return nil }
        if values == ["help"] || values == ["--help"] || values == ["-h"] {
            write(help, to: .standardOutput); return 0
        }
        if values == ["version"] || values == ["--version"] {
            write("niko-shot \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")\n", to: .standardOutput); return 0
        }
        let command: AutomationCommand
        do { command = try AutomationCommand.parse(arguments: values) }
        catch { write("\(error.localizedDescription)\n", to: .standardError); return 64 }
        let result = AutomationCLIResult()
        let loop = CFRunLoopGetCurrent()
        Task { @MainActor in
            defer { CFRunLoopStop(loop) }
            let client = AutomationIPCClient()
            defer { client.cancel() }
            do {
                let resident = NSRunningApplication.runningApplications(withBundleIdentifier: "com.n1ko.niko-shot")
                    .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
                    .sorted { $0.processIdentifier < $1.processIdentifier }.first
                let server = try await client.connect(serverPID: resident?.processIdentifier ?? ResidentInstanceLock.currentPID()) { client in
                    guard let phase = client.pendingQueryID else { return }
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    configuration.arguments = []; configuration.activates = false
                    let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
                    let enclosingApp = executable?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    let appURL = enclosingApp?.pathExtension == "app" ? enclosingApp ?? Bundle.main.bundleURL : Bundle.main.bundleURL
                    guard appURL.pathExtension == "app" else { client.launched(serverPID: nil, error: AutomationError.unavailable, phase: phase); return }
                    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
                        let pid = application?.processIdentifier
                        Task { @MainActor in client.launched(serverPID: pid, error: error, phase: phase) }
                    }
                }
                let response = try await client.execute(command, serverPID: server)
                let output = renderedOutput(response, action: command.action)
                if !output.isEmpty { write(output + "\n", to: .standardOutput) }
                result.code = 0
            } catch {
                write("\(error.localizedDescription)\n", to: .standardError); result.code = 1
            }
        }
        while result.code == nil { CFRunLoopRun() }
        return result.code ?? 1
    }

    /// LaunchServices adds `-psn_…` and Cocoa accepts `-AppleLanguages (en)`-style defaults; CLI flags are lowercase.
    static func isSystemLaunchArgument(_ value: String) -> Bool {
        if value.hasPrefix("-psn_") { return true }
        guard value.hasPrefix("-"), let next = value.dropFirst().first else { return false }
        return next.isUppercase
    }

    static func renderedOutput(_ response: AutomationResponse, action: AutomationAction) -> String {
        switch action {
        case .ocr, .translate, .lastOCR: return response.text ?? response.message
        case .capture, .record, .scroll: return response.outputPath ?? response.message
        }
    }
    private static func write(_ value: String, to handle: FileHandle) { try? handle.write(contentsOf: Data(value.utf8)) }
    private static var help: String {
        """
        niko-shot — 原生截图自动化
        用法：niko <command> [options]
          capture [--region|--window|--fullscreen] [--window-id ID] [--delay 0…10] [--output PATH] [--no-auto-ocr]
          ocr --clipboard [--region|--window|--fullscreen] [--delay 0…10]
          translate [--to zh|zh-Hant|en|ja|ko|fr|de|es|pt|ru|it|th|ar|vi|id]
          record [--region|--window|--fullscreen] [--format mp4|gif] [--delay 0…10] [--output PATH]
          scroll [--delay 0…10] [--output PATH] [--no-auto-ocr]
          last-ocr
          help | version
        OCR 命令先截图，再把识别文字写入剪贴板；翻译命令读取剪贴板文字。
        路径支持 ~ 和相对路径；互动操作等待最多 300 秒。
        --fullscreen、--window-id 与 last-ocr 需在 设置 → 通用 打开「允许命令行静默截图」。

        """
    }
}

@MainActor private final class AutomationCLIResult { var code: Int32? }
