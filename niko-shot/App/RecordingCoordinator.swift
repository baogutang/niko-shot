// Connects native recording selection, controls, camera preview and MP4/GIF output.
import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import SwiftUI
import Observation
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class RecordingCoordinator {
    private let engine: CaptureEngine
    private let selection: SelectionSession
    private let windows: WindowList
    private let countdown = CaptureCountdown()
    private lazy var session = RecordingSession()
    private var setupWindow: UtilityWindow?
    private var gifWindow: UtilityWindow?
    private var controls: RecordingControlBarController?
    private lazy var camera = CameraPiPController(onClose: { [weak self] in self?.toggleCamera(false) })
    private var task: Task<Void, Never>?
    private let gifProgress = GIFProgressState()
    private var requestedFormat = "mp4"
    private var terminating = false
    private var activeSavePanel: NSSavePanel?
    private var generation = UUID()
    private var operationID: UUID?
    private var drainingTasks: [UUID: Task<Void, Never>] = [:]
    private var ownsSelection = false
    private var automation: RecordingAutomationPlan?
    private var startup: CheckedContinuation<URL, any Error>?
    private let onOCR: (String) -> Void
    private lazy var automationMedia = RecordingAutomationMedia()
    private(set) var lastAutomationError: String?
    private(set) var isBusy = false

    init(engine: CaptureEngine, selection: SelectionSession, windows: WindowList, onOCR: @escaping (String) -> Void = { _ in }) {
        self.engine = engine; self.selection = selection; self.windows = windows; self.onOCR = onOCR
    }

    /// Counts coordinator UI/tasks and the recording resources without starting capture or timers.
    var resourceCounts: [String: Int] {
        var counts = session.resourceCounts
        counts.merge(["setup": setupWindow == nil ? 0 : 1, "gif": gifWindow == nil ? 0 : 1,
            "controls": controls?.windowCount ?? 0, "cameraUI": camera.windowCount,
            "countdown": countdown.windowCount, "countdownMonitor": countdown.monitorCount,
            "selection": ownsSelection ? selection.windowCount + selection.monitorCount : 0,
            "task": task == nil ? 0 : 1, "startup": startup == nil ? 0 : 1,
            "savePanel": activeSavePanel == nil ? 0 : 1, "draining": drainingTasks.count]) { _, second in second }
        return counts
    }

    /// Opens the native target/audio form and returns only after SCStream has actually started.
    /// The returned file is written when the user stops; nil output keeps an app-owned file plus Save As.
    func startAutomation(delay: Int, output: URL?, format: String, autoOCR: Bool, captureType: AutomationCaptureType? = nil) async throws -> URL {
        try Task.checkCancellation()
        guard !terminating, !isBusy, selection.state == .idle else { throw AppError.busy }
        let plan = try RecordingAutomationPlan(delay: delay, output: output, format: format, autoOCR: autoOCR)
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                generation = token; automation = plan; startup = continuation
                isBusy = true; requestedFormat = plan.format; lastAutomationError = nil
                let initialMode: RecordingSelectionMode
                switch captureType ?? .region {
                case .region: initialMode = .region
                case .window: initialMode = .window
                case .fullscreen: initialMode = .fullscreen
                }
                presentSetup(token: token, initialMode: initialMode)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.startup != nil else { return }
                await self.cancel(generation: token)
            }
        }
    }

    func showSetup(format: String = "mp4") {
        guard !terminating, !isBusy, selection.state == .idle else { return }
        generation = UUID(); automation = nil; requestedFormat = format == "gif" ? "gif" : "mp4"
        isBusy = true; lastAutomationError = nil
        presentSetup(token: generation)
    }

    private func presentSetup(token: UUID, initialMode: RecordingSelectionMode = .region) {
        let window = UtilityWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "开始录屏 · \(requestedFormat.uppercased())"; window.isReleasedWhenClosed = false
        window.onClose = { [weak self] in
            guard let self, self.generation == token else { return }
            self.setupWindow = nil
            Task { await self.cancel(generation: token) }
        }
        window.contentView = NSHostingView(rootView: RecordingSetupView(onStart: { [weak self] mode in
            guard let self, self.generation == token else { return }
            let setup = self.setupWindow; self.setupWindow = nil; setup?.onClose = nil; setup?.close()
            self.select(mode: mode, token: token)
        }, onCancel: { [weak self] in
            guard let self, self.generation == token else { return }; self.setupWindow?.close()
        }, initialMode: initialMode))
        setupWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func select(mode: RecordingSelectionMode, token: UUID) {
        guard generation == token, isBusy, selection.state == .idle else { return }
        let id = UUID(); operationID = id
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.endOperation(id) }
            do {
                let frames = try await self.engine.freezeScreens()
                try self.check(token)
                let candidates = try await self.windows.windows()
                try self.check(token)
                let frame = frames.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) ?? frames.first
                let initial = mode == .fullscreen ? frame.map { CaptureContext(screen: $0.screen, localRect: $0.screen.localBounds, kind: "fullscreen") } : nil
                self.ownsSelection = true
                self.selection.start(frames: frames, candidates: candidates, kind: mode == .window ? "window" : "region", initial: initial, confirmationTitle: "开始录制") { [weak self] _, context in
                    guard let self, self.generation == token else { return }
                    self.ownsSelection = false
                    self.start(context: context, mode: mode, token: token)
                }
                self.selection.onFinish = { [weak self] completed in
                    guard let self, self.generation == token else { return }
                    self.ownsSelection = false
                    // SelectionSession sends completed=true before invoking its confirmed-context callback.
                    if !completed { Task { await self.cancel(generation: token) } }
                }
            } catch { await self.fail(error, token: token) }
        }
    }

    private func start(context: CaptureContext, mode: RecordingSelectionMode, token: UUID) {
        guard generation == token, !terminating else { return }
        let id = UUID(); operationID = id
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.endOperation(id) }
            do {
                let settings = AppSettings.shared
                let target: RecordingTarget
                switch mode {
                case .region: target = .region(displayID: context.screen.id, rect: context.localRect, scale: context.screen.scale)
                case .fullscreen: target = .display(id: context.screen.id, scale: context.screen.scale)
                case .window:
                    guard let id = context.windowID else { throw AppError.file("请点击一个可录制的窗口。") }
                    target = .window(id: id, scale: context.screen.scale)
                }
                if let delay = self.automation?.delay, delay > 0 {
                    try await self.countdown.wait(seconds: delay, actionName: "开始录制")
                    try self.check(token)
                }
                try await self.countdown.wait(seconds: 3, actionName: "开始录制")
                try self.check(token)
                let options = RecordingOptions(fps: settings.recordingFPS, codec: settings.recordingCodec, quality: settings.recordingQuality,
                                               systemAudio: settings.systemAudio, microphone: settings.microphone,
                                               showsCursor: settings.showsCursor, camera: settings.recordingCamera)
                let folder = AppPaths.root.appendingPathComponent("Recordings", isDirectory: true)
                try await RecordingAutomationFiles.prepare(folder)
                try self.check(token)
                let output = self.automation?.video ?? folder.appendingPathComponent("\(UUID().uuidString).mp4")
                try await self.session.start(target: target, options: options, output: output)
                try self.check(token)
                self.controls = RecordingControlBarController(session: self.session, onStop: { [weak self] in
                    guard let self, self.generation == token else { return }; self.stop()
                }, onCancel: { [weak self] in
                    Task { guard let self, self.generation == token else { return }; await self.cancel(generation: token) }
                }, onCamera: { [weak self] enabled in
                    guard let self, self.generation == token else { return }; self.toggleCamera(enabled)
                }, format: self.requestedFormat)
                self.controls?.show()
                if let cameraSession = self.session.cameraSession { self.camera.show(session: cameraSession) }
                if let plan = self.automation { self.completeStartup(.success(plan.destination)) }
            } catch { await self.fail(error, token: token) }
        }
    }

    private func toggleCamera(_ enabled: Bool) {
        let token = generation
        Task {
            do {
                try await session.setCameraEnabled(enabled)
                try check(token)
                if let capture = session.cameraSession { camera.show(session: capture) } else { camera.close() }
            } catch { if generation == token, !terminating, !(error is CancellationError) { ErrorPresenter.show(error) } }
        }
    }

    private func stop() {
        guard !terminating, task == nil else { return }
        let token = generation, id = UUID(); operationID = id
        task = Task {
            defer { endOperation(id) }
            do {
                let video = try await session.stop()
                try check(token, allowTermination: true)
                controls?.close(); controls = nil; camera.close()
                if let plan = automation {
                    try await saveAutomation(video: video, plan: plan, token: token, showsSavePanel: !terminating)
                    automation = nil; isBusy = false
                    return
                }
                guard !terminating else { isBusy = false; return }
                CompletionNotifications.post(title: "录制完成", message: "视频已保存在应用资料中，可另存 MP4 或导出 GIF。", file: video)
                if requestedFormat == "gif" { showGIF(video: video); return }
                let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie, .gif]
                panel.nameFieldStringValue = outputName(extension: "mp4")
                panel.title = "保存录屏 · MP4 或 GIF"
                let types = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 180, height: 28)); types.addItems(withTitles: ["MP4 视频", "GIF 动图"])
                let formatTarget = RecordingFormatTarget(panel: panel, popup: types)
                types.target = formatTarget; types.action = #selector(RecordingFormatTarget.changed)
                panel.accessoryView = types
                activeSavePanel = panel
                defer { activeSavePanel = nil }
                NSApp.activate(ignoringOtherApps: true)
                let response = panel.runModal()
                try check(token, allowTermination: true)
                guard response == .OK, !terminating, let destination = panel.url else { isBusy = false; return }
                if types.indexOfSelectedItem == 1 || destination.pathExtension.lowercased() == "gif" { showGIF(video: video, destination: destination); return }
                try await copyVideo(video, to: destination)
                try check(token, allowTermination: true)
                isBusy = false
                guard !terminating else { return }
                CompletionNotifications.post(title: "视频已保存", message: destination.lastPathComponent, file: destination)
            } catch { await fail(error, token: token) }
        }
    }

    private func saveAutomation(video: URL, plan: RecordingAutomationPlan, token: UUID, showsSavePanel: Bool) async throws {
        let settings = AppSettings.shared
        var recognizedText: String?
        if plan.autoOCR {
            do {
                recognizedText = try await automationMedia.firstFrameText(video: video, languages: settings.ocrLanguages, accurate: settings.accurateOCR)
                try check(token, allowTermination: true)
            } catch is CancellationError { throw CancellationError() }
            catch {
                lastAutomationError = "首帧 OCR 未完成，已有输出未替换：\(error.localizedDescription)"
                throw error
            }
        }
        if plan.format == "gif" {
            gifProgress.running = true; gifProgress.fraction = 0
            defer { gifProgress.running = false }
            try await GifExporter.export(video: video, destination: plan.destination,
                options: GifOptions(width: settings.gifWidth, fps: settings.gifFPS)) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.generation == token, !self.terminating else { return }; self.gifProgress.fraction = fraction
                }
            }
        } else { try await copyVideo(video, to: plan.destination) }
        try check(token, allowTermination: true)
        if let recognizedText { onOCR(recognizedText) }
        guard !terminating else { return }
        CompletionNotifications.post(title: "\(plan.format.uppercased()) 已保存", message: plan.destination.lastPathComponent, file: plan.destination)
        guard showsSavePanel, plan.output == nil else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = plan.format == "gif" ? [.gif] : [.mpeg4Movie]
        panel.nameFieldStringValue = outputName(extension: plan.format); panel.title = "另存录屏 · \(plan.format.uppercased())"
        if let error = lastAutomationError { panel.message = error }
        activeSavePanel = panel
        defer { activeSavePanel = nil }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        try check(token, allowTermination: true)
        guard response == .OK, !terminating, let destination = panel.url else { return }
        try await copyVideo(plan.destination, to: destination)
        try check(token, allowTermination: true)
        if !terminating { CompletionNotifications.post(title: "录屏已另存", message: destination.lastPathComponent, file: destination) }
    }

    private func showGIF(video: URL, destination: URL? = nil) {
        guard !terminating else { isBusy = false; return }
        let token = generation
        gifWindow?.close(); gifProgress.running = false; gifProgress.fraction = 0
        isBusy = true
        let window = UtilityWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "导出 GIF"; window.isReleasedWhenClosed = false
        window.onClose = { [weak self] in
            guard let self, self.generation == token else { return }
            self.gifWindow = nil
            if self.gifProgress.running { self.task?.cancel() }
            else { self.isBusy = false }
        }
        let duration = session.duration, size = session.lastOutputSize
        window.contentView = NSHostingView(rootView: GIFExportWorkspace(state: gifProgress, duration: duration, sourceSize: size, onExport: { [weak self] options in
            guard let self, self.generation == token else { return }; self.exportGIF(video: video, destination: destination, options: options)
        }, onCancel: { [weak self] in
            guard let self, self.generation == token else { return }; self.gifWindow?.close()
        }))
        gifWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func exportGIF(video: URL, destination: URL?, options: GifOptions) {
        guard !terminating, !gifProgress.running, task == nil else { return }
        let token = generation
        var destination = destination
        if destination == nil {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.gif]; panel.nameFieldStringValue = outputName(extension: "gif")
            activeSavePanel = panel
            defer { activeSavePanel = nil }
            guard panel.runModal() == .OK, !terminating else { return }; destination = panel.url
        }
        guard let destination else { return }
        gifProgress.running = true; gifProgress.fraction = 0; isBusy = true
        let id = UUID(); operationID = id
        task = Task {
            defer { if generation == token { gifProgress.running = false; isBusy = false }; endOperation(id) }
            do {
                try await GifExporter.export(video: video, destination: destination, options: options) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.generation == token, !self.terminating else { return }; self.gifProgress.fraction = fraction
                    }
                }
                try check(token)
                gifProgress.running = false; gifWindow?.close()
                guard !terminating else { return }
                CompletionNotifications.post(title: "GIF 已保存", message: destination.lastPathComponent, file: destination)
            } catch is CancellationError {} catch { if generation == token, !terminating { ErrorPresenter.show(error) } }
        }
    }

    private func copyVideo(_ source: URL, to destination: URL) async throws {
        try await RecordingAutomationFiles.copy(source, to: destination)
    }

    private func outputName(extension suffix: String) -> String {
        let name = Exporters.filename(template: AppSettings.shared.filenameTemplate, date: .now,
                                      sequence: UserDefaults.standard.integer(forKey: "filenameSequence"), format: .png)
        return (name as NSString).deletingPathExtension + "." + suffix
    }

    func cancel() async {
        await cancel(generation: generation)
    }

    private func cancel(generation token: UUID, error: any Error = CancellationError(), fromOperation: Bool = false) async {
        guard generation == token else { return }
        let waiter = startup; startup = nil
        let pending = task; pending?.cancel(); task = nil; operationID = nil
        generation = UUID(); let cleanupToken = generation
        automation = nil
        closeTransientUI()
        await session.cancel()
        // ScreenCaptureKit enumeration is not cancellable. Resolve the caller after owned UI/media
        // cleanup, then retain and drain the invalidated operation so no late result can start capture.
        waiter?.resume(throwing: error)
        if !fromOperation, let pending {
            let drainID = UUID(); drainingTasks[drainID] = pending
            await pending.value
            drainingTasks[drainID] = nil
        }
        if generation == cleanupToken { isBusy = false }
    }

    private func closeTransientUI() {
        countdown.cancel()
        if ownsSelection { ownsSelection = false; selection.finish() }
        let setup = setupWindow; setupWindow = nil; setup?.onClose = nil; setup?.close()
        let gif = gifWindow; gifWindow = nil; gif?.onClose = nil; gif?.close()
        controls?.close(); controls = nil; camera.close()
        activeSavePanel?.cancel(nil); activeSavePanel = nil; gifProgress.running = false
    }

    private func completeStartup(_ result: Result<URL, any Error>) {
        let continuation = startup; startup = nil
        continuation?.resume(with: result)
    }

    private func endOperation(_ id: UUID) {
        if operationID == id { operationID = nil; task = nil }
    }

    private func check(_ token: UUID, allowTermination: Bool = false) throws {
        try Task.checkCancellation()
        guard generation == token, allowTermination || !terminating else { throw CancellationError() }
    }

    private func fail(_ error: any Error, token: UUID) async {
        guard generation == token else { return }
        let plan = automation, awaitingStart = startup != nil
        if plan != nil, !(error is CancellationError), lastAutomationError == nil { lastAutomationError = error.localizedDescription }
        await cancel(generation: token, error: error, fromOperation: true)
        guard !terminating, !(error is CancellationError) else { return }
        if let plan {
            if !awaitingStart { CompletionNotifications.post(title: "录屏自动输出未完成", message: lastAutomationError ?? error.localizedDescription, file: plan.video) }
        } else { ErrorPresenter.show(error) }
    }

    func finishForTermination() async {
        terminating = true
        let pending = task
        let isFinalizingVideo = session.state == .finishing && !gifProgress.running
        activeSavePanel?.cancel(nil)
        closeTransientUI()
        for drain in Array(drainingTasks.values) { await drain.value }
        drainingTasks.removeAll()
        if isFinalizingVideo { await pending?.value }
        else if pending != nil || startup != nil { await cancel(generation: generation) }
        else if session.state == .recording || session.state == .paused {
            do {
                let video = try await session.stop()
                if let plan = automation { try await saveAutomation(video: video, plan: plan, token: generation, showsSavePanel: false) }
            } catch { lastAutomationError = error.localizedDescription; await session.cancel() }
        } else { await session.cancel() }
        completeStartup(.failure(CancellationError()))
        automation = nil; task = nil; operationID = nil; isBusy = false
    }
}

/// Immutable recording automation contract; no user output is opened during setup or countdown.
struct RecordingAutomationPlan: Sendable {
    let delay: Int
    let output: URL?
    let format: String
    let autoOCR: Bool
    let video: URL
    let destination: URL

    init(delay: Int, output: URL?, format: String, autoOCR: Bool) throws {
        let format = format.lowercased()
        guard (0...10).contains(delay), ["mp4", "gif"].contains(format) else { throw AppError.file("录屏延时必须为 0–10 秒，格式必须为 MP4 或 GIF。") }
        guard output == nil || output?.isFileURL == true else { throw AppError.file("录屏输出必须是本机文件路径。") }
        self.delay = delay; self.output = output?.standardizedFileURL; self.format = format; self.autoOCR = autoOCR
        let id = UUID().uuidString
        let folder = AppPaths.root.appendingPathComponent("Recordings", isDirectory: true)
        video = folder.appendingPathComponent("\(id).mp4")
        destination = self.output ?? folder.appendingPathComponent("\(id).\(format)")
    }
}

/// Decodes only the first visible video sample and sends a detached image value to the Vision actor.
actor RecordingAutomationMedia {
    func firstFrameText(video: URL, languages: [String], accurate: Bool) async throws -> String {
        let image = try await firstFrame(video)
        let blocks = try await OCREngine().recognize(image, languages: languages, accurate: accurate)
        try Task.checkCancellation()
        return blocks.map(\.text).joined(separator: "\n")
    }

    private func firstFrame(_ video: URL) async throws -> CGImage {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecordingError.empty }
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingError.encoder("首帧解码器无法读取这个视频。") }
        reader.add(output)
        guard reader.startReading() else { throw RecordingError.encoder(reader.error?.localizedDescription ?? "首帧解码失败。") }
        let context = CIContext(options: [.cacheIntermediates: false])
        while reader.status == .reading {
            try Task.checkCancellation()
            let decoded = autoreleasepool { () -> (hasSample: Bool, image: CGImage?) in
                guard let sample = output.copyNextSampleBuffer() else { return (false, nil) }
                guard CMSampleBufferDataIsReady(sample), let pixels = CMSampleBufferGetImageBuffer(sample) else { return (true, nil) }
                let frame = CIImage(cvPixelBuffer: pixels)
                return (true, context.createCGImage(frame, from: frame.extent))
            }
            if let image = decoded.image { return image }
            if !decoded.hasSample { break }
        }
        if reader.status == .failed { throw RecordingError.encoder(reader.error?.localizedDescription ?? "视频首帧无法解码。") }
        throw RecordingError.empty
    }
}

/// Copies completed media in bounded cancellable blocks before an atomic destination replacement.
enum RecordingAutomationFiles {
    static func prepare(_ folder: URL) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func copy(_ source: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        guard source.isFileURL, destination.isFileURL else { throw AppError.file("录屏输出必须是本机文件路径。") }
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            var directory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: destination.path, isDirectory: &directory), directory.boolValue {
                throw AppError.file("输出路径已经是一个目录，请选择文件路径。")
            }
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let stage = parent.appendingPathComponent(".niko-recording-output-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: stage) }
            let file = stage.appendingPathComponent("media")
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw AppError.file("无法暂存录屏输出。") }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            var written: Int64 = 0
            while true {
                try Task.checkCancellation()
                let hadData = try autoreleasepool { () throws -> Bool in
                    guard let data = try input.read(upToCount: 262_144), !data.isEmpty else { return false }
                    try output.write(contentsOf: data)
                    written += Int64(data.count); progress(written)
                    return true
                }
                if !hadData { break }
            }
            try output.synchronize(); try output.close(); try input.close()
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: file) }
            else { try FileManager.default.moveItem(at: file, to: destination) }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

@MainActor @Observable
private final class GIFProgressState { var running = false; var fraction = 0.0 }

@MainActor
private struct GIFExportWorkspace: View {
    let state: GIFProgressState
    let duration: Double
    let sourceSize: CGSize
    let onExport: (GifOptions) -> Void
    let onCancel: () -> Void
    var body: some View { GifExportView(duration: duration, sourceSize: sourceSize, isExporting: state.running, progress: state.fraction, onExport: onExport, onCancel: onCancel) }
}

@MainActor
private final class RecordingFormatTarget: NSObject {
    weak var panel: NSSavePanel?
    weak var popup: NSPopUpButton?
    init(panel: NSSavePanel, popup: NSPopUpButton) { self.panel = panel; self.popup = popup }
    @objc func changed() {
        let gif = popup?.indexOfSelectedItem == 1
        panel?.allowedContentTypes = gif ? [.gif] : [.mpeg4Movie]
        if let name = panel?.nameFieldStringValue { panel?.nameFieldStringValue = (name as NSString).deletingPathExtension + (gif ? ".gif" : ".mp4") }
    }
}

@MainActor
enum CompletionNotifications {
    static func post(title: String, message: String, file: URL) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            var allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if settings.authorizationStatus == .notDetermined { allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
            guard allowed else { return }
            let content = UNMutableNotificationContent(); content.title = title; content.body = message; content.userInfo = ["path": file.path]
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
