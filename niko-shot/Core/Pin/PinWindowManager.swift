// Manages independent persistent pinned captures and event-driven floating image windows.
import AppKit
import ImageIO
import Observation

struct PinEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let url: URL
    let thumbnail: Data
}

/// Identifies completed native file work for deterministic lifecycle tests.
enum PinFileOperation: Sendable {
    case copy, decode, persist
}

@MainActor @Observable
final class PinWindowManager {
    private(set) var pins: [PinEntry] = []
    @ObservationIgnored private var windows: [UUID: NSWindow] = [:]
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var openingTasks: [UUID: UUID] = [:]
    @ObservationIgnored private var persistenceTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let persistence: PinPersistence
    @ObservationIgnored private let afterFileOperation: (@Sendable (PinFileOperation) async -> Void)?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var presentationGeneration = 0
    @ObservationIgnored private var terminating = false

    /// Uses the app library by default; an isolated directory and post-I/O gate support real-file tests.
    init(directory: URL = AppPaths.pins, afterFileOperation: (@Sendable (PinFileOperation) async -> Void)? = nil) {
        self.directory = directory
        self.persistence = PinPersistence(directory: directory, afterFileOperation: afterFileOperation)
        self.afterFileOperation = afterFileOperation
    }

    /// Counts owned windows and outstanding native work without timers or inspecting pixel data.
    var resourceCounts: [String: Int] {
        ["pinWindows": windows.count, "pinTasks": operations.count + (loadTask == nil ? 0 : 1),
         "pinPersistenceTasks": persistenceTasks.count]
    }

    /// Loads only lightweight library metadata; full images are decoded when opened.
    func load() {
        guard !loaded, !terminating else { return }; loaded = true
        let index = directory.appendingPathComponent("index.json")
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            do {
                let entries = try await Self.fileWork(priority: .utility) {
                    try Task.checkCancellation()
                    return autoreleasepool { () -> [PinEntry] in
                        guard let data = try? Data(contentsOf: index), let decoded = try? JSONDecoder().decode([PinEntry].self, from: data) else { return [] }
                        return decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
                    }
                }
                guard !Task.isCancelled, let self, !self.terminating else { return }
                self.pins = entries
            } catch { self?.presentError(error) }
        }
    }
    /// Copies a capture into the pin library so history retention cannot remove it.
    func pin(image: CGImage, url: URL, thumbnail: Data) {
        guard !terminating else { return }
        load()
        let entry = PinEntry(id: UUID(), url: directory.appendingPathComponent("\(UUID().uuidString).png"), thumbnail: thumbnail)
        let taskID = UUID(), generation = presentationGeneration
        let loading = loadTask, directory = directory, gate = afterFileOperation
        operations[taskID] = Task { [weak self] in
            defer { self?.operations.removeValue(forKey: taskID) }
            do {
                await loading?.value
                try Task.checkCancellation()
                try await Self.fileWork(priority: .utility) {
                    try Task.checkCancellation()
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: entry.url)
                        await gate?(.copy)
                        try Task.checkCancellation()
                    } catch {
                        try? FileManager.default.removeItem(at: entry.url)
                        throw error
                    }
                }
                guard !Task.isCancelled, let self, !self.terminating else {
                    await Self.discardUncommittedFile(entry.url)
                    return
                }
                self.pins.insert(entry, at: 0)
                self.persist()
                if generation == self.presentationGeneration { self.present(image, id: entry.id) }
            } catch { self?.presentError(error) }
        }
    }
    /// Reuses a visible pin or decodes its image away from the main actor before opening it.
    func show(id: UUID) {
        guard !terminating else { return }
        if let window = windows[id] { window.orderFrontRegardless(); return }
        guard openingTasks[id] == nil, let entry = pins.first(where: { $0.id == id }) else { return }
        let taskID = UUID(), generation = presentationGeneration, gate = afterFileOperation
        openingTasks[id] = taskID
        operations[taskID] = Task { [weak self] in
            defer {
                self?.operations.removeValue(forKey: taskID)
                if self?.openingTasks[id] == taskID { self?.openingTasks.removeValue(forKey: id) }
            }
            do {
                let image = try await Self.fileWork(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let image = try autoreleasepool { () throws -> CGImage in
                        guard let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppError.imageCreation }
                        return image
                    }
                    await gate?(.decode)
                    try Task.checkCancellation()
                    return image
                }
                guard !Task.isCancelled, let self, !self.terminating,
                      generation == self.presentationGeneration, self.pins.contains(where: { $0.id == id }) else { return }
                self.present(image, id: id)
            } catch { self?.presentError(error) }
        }
    }
    private func present(_ image: CGImage, id: UUID) {
        guard !terminating, pins.contains(where: { $0.id == id }) else { return }
        if let window = windows[id] { if visible { window.orderFrontRegardless() }; return }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let scale = max(CGFloat(image.width) / (screen.width * 0.65), CGFloat(image.height) / (screen.height * 0.65), 1)
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = true; window.hasShadow = true
        let view = PinImageView(); view.image = NSImage(cgImage: image, size: .zero); view.imageScaling = .scaleProportionallyUpOrDown
        view.closeAction = { [weak self] in self?.closeWindow(id: id) }
        view.setAccessibilityLabel("贴图，双指缩放，滚轮调整透明度，双击关闭")
        window.contentView = view; window.center(); windows[id] = window
        if visible { window.orderFrontRegardless() }
    }
    /// Removes a library entry and its independent capture file.
    func remove(id: UUID) {
        guard !terminating else { return }
        if let taskID = openingTasks[id] { operations[taskID]?.cancel() }
        closeWindow(id: id)
        if let entry = pins.first(where: { $0.id == id }) { try? FileManager.default.removeItem(at: entry.url) }
        pins.removeAll { $0.id == id }; persist()
    }
    /// Toggles existing windows without decoding images or starting idle work.
    func toggleVisibility() {
        guard !terminating else { return }
        visible.toggle(); for window in windows.values { if visible { window.orderFrontRegardless() } else { window.orderOut(nil) } }
    }
    /// Closes current windows and invalidates older pending presentation requests.
    func closeAll() {
        presentationGeneration += 1
        for taskID in openingTasks.values { operations[taskID]?.cancel() }
        for id in Array(windows.keys) { closeWindow(id: id) }
    }
    /// Synchronously blocks new work and late windows; committed index writes continue to completion.
    func prepareForTermination() {
        guard !terminating else { return }
        terminating = true
        loadTask?.cancel()
        for task in operations.values { task.cancel() }
        closeAll()
    }
    /// Drains cancelled native work and every committed index write before the resident can exit.
    func finishForTermination() async {
        prepareForTermination()
        await waitForPendingOperations()
    }
    /// Waits for owned tasks, including persistence scheduled by a just-completed copy; no polling timer is used.
    func waitForPendingOperations() async {
        while loadTask != nil || !operations.isEmpty || !persistenceTasks.isEmpty {
            if let loading = loadTask { await loading.value }
            for task in Array(operations.values) { await task.value }
            for task in Array(persistenceTasks.values) { await task.value }
        }
    }
    private func closeWindow(id: UUID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        (window.contentView as? PinImageView)?.image = nil
        window.contentView = nil
        window.close()
    }
    private func persist() {
        let entries = pins; revision += 1; let version = revision, writer = persistence
        let taskID = UUID()
        persistenceTasks[taskID] = Task { [weak self] in
            defer { self?.persistenceTasks.removeValue(forKey: taskID) }
            do { try await writer.save(entries, revision: version) }
            catch { self?.presentError(error) }
        }
    }
    private func presentError(_ error: any Error) {
        guard !terminating, !Task.isCancelled, !(error is CancellationError) else { return }
        ErrorPresenter.show(error)
    }
    private nonisolated static func fileWork<Value: Sendable>(priority: TaskPriority, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let worker = Task.detached(priority: priority, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
    private nonisolated static func discardUncommittedFile(_ url: URL) async {
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }.value
    }
}

private actor PinPersistence {
    private var writtenRevision = 0
    private let directory: URL
    private let afterFileOperation: (@Sendable (PinFileOperation) async -> Void)?
    init(directory: URL, afterFileOperation: (@Sendable (PinFileOperation) async -> Void)?) {
        self.directory = directory
        self.afterFileOperation = afterFileOperation
    }
    func save(_ entries: [PinEntry], revision: Int) async throws {
        guard revision > writtenRevision else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        writtenRevision = revision
        await afterFileOperation?(.persist)
    }
}

private final class PinImageView: NSImageView {
    var closeAction: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { closeAction?() } else { super.mouseDown(with: event) } }
    override func magnify(with event: NSEvent) {
        guard let window else { return }
        let factor = max(0.5, 1 + event.magnification)
        var frame = window.frame
        let size = CGSize(width: min(4096, max(32, frame.width * factor)), height: min(4096, max(32, frame.height * factor)))
        frame.origin.x += (frame.width - size.width) / 2; frame.origin.y += (frame.height - size.height) / 2; frame.size = size
        window.setFrame(frame, display: true)
    }
    override func scrollWheel(with event: NSEvent) { if let window { window.alphaValue = min(1, max(0.15, window.alphaValue + event.scrollingDeltaY * 0.008)) } }
}
