// Connects native recording selection, controls, camera preview and MP4/GIF output.
import AppKit
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
    private(set) var isBusy = false

    init(engine: CaptureEngine, selection: SelectionSession, windows: WindowList) {
        self.engine = engine; self.selection = selection; self.windows = windows
    }

    func showSetup(format: String = "mp4") {
        guard !terminating, !isBusy, selection.state == .idle else { return }
        isBusy = true; requestedFormat = format
        let window = UtilityWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "开始录屏"; window.isReleasedWhenClosed = false
        window.onClose = { [weak self] in self?.setupWindow = nil; self?.isBusy = false }
        window.contentView = NSHostingView(rootView: RecordingSetupView(onStart: { [weak self] mode in
            self?.setupWindow?.close(); self?.select(mode: mode)
        }, onCancel: { [weak self] in self?.setupWindow?.close() }))
        setupWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func select(mode: RecordingSelectionMode) {
        guard !isBusy, selection.state == .idle else { return }
        isBusy = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                let frames = try await self.engine.freezeScreens()
                let candidates = try await self.windows.windows()
                let frame = frames.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) ?? frames.first
                let initial = mode == .fullscreen ? frame.map { CaptureContext(screen: $0.screen, localRect: $0.screen.localBounds, kind: "fullscreen") } : nil
                self.selection.start(frames: frames, candidates: candidates, kind: mode == .window ? "window" : "region", initial: initial, confirmationTitle: "开始录制") { [weak self] _, context in
                    self?.start(context: context, mode: mode)
                }
                self.selection.onFinish = { [weak self] completed in if !completed { self?.isBusy = false } }
            } catch is CancellationError { self.isBusy = false }
            catch { self.isBusy = false; ErrorPresenter.show(error) }
        }
    }

    private func start(context: CaptureContext, mode: RecordingSelectionMode) {
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
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
                try await self.countdown.wait(seconds: 3)
                try Task.checkCancellation()
                let options = RecordingOptions(fps: settings.recordingFPS, codec: settings.recordingCodec, quality: settings.recordingQuality,
                                               systemAudio: settings.systemAudio, microphone: settings.microphone,
                                               showsCursor: settings.showsCursor, camera: settings.recordingCamera)
                let folder = AppPaths.root.appendingPathComponent("Recordings", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let output = folder.appendingPathComponent("\(UUID().uuidString).mp4")
                try await self.session.start(target: target, options: options, output: output)
                try Task.checkCancellation()
                self.controls = RecordingControlBarController(session: self.session, onStop: { [weak self] in self?.stop() },
                                                              onCancel: { [weak self] in Task { await self?.cancel() } },
                                                              onCamera: { [weak self] enabled in self?.toggleCamera(enabled) })
                self.controls?.show()
                if let cameraSession = self.session.cameraSession { self.camera.show(session: cameraSession) }
            } catch is CancellationError { await self.cancel() }
            catch { await self.cancel(); ErrorPresenter.show(error) }
        }
    }

    private func toggleCamera(_ enabled: Bool) {
        Task {
            do {
                try await session.setCameraEnabled(enabled)
                if let capture = session.cameraSession { camera.show(session: capture) } else { camera.close() }
            } catch { ErrorPresenter.show(error) }
        }
    }

    private func stop() {
        guard !terminating, task == nil else { return }
        task = Task {
            defer { task = nil }
            do {
                let video = try await session.stop()
                controls?.close(); controls = nil; camera.close()
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
                guard panel.runModal() == .OK, !terminating, let destination = panel.url else { isBusy = false; return }
                if types.indexOfSelectedItem == 1 || destination.pathExtension.lowercased() == "gif" { showGIF(video: video, destination: destination); return }
                try await copyVideo(video, to: destination)
                isBusy = false
                guard !terminating else { return }
                CompletionNotifications.post(title: "视频已保存", message: destination.lastPathComponent, file: destination)
            } catch { controls?.close(); controls = nil; camera.close(); isBusy = false; ErrorPresenter.show(error) }
        }
    }

    private func showGIF(video: URL, destination: URL? = nil) {
        guard !terminating else { isBusy = false; return }
        gifWindow?.close(); gifProgress.running = false; gifProgress.fraction = 0
        isBusy = true
        let window = UtilityWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "导出 GIF"; window.isReleasedWhenClosed = false
        window.onClose = { [weak self] in
            self?.gifWindow = nil
            if self?.gifProgress.running == true { self?.task?.cancel() }
            else { self?.isBusy = false }
        }
        let duration = session.duration, size = session.lastOutputSize
        window.contentView = NSHostingView(rootView: GIFExportWorkspace(state: gifProgress, duration: duration, sourceSize: size, onExport: { [weak self] options in
            self?.exportGIF(video: video, destination: destination, options: options)
        }, onCancel: { [weak self] in self?.gifWindow?.close() }))
        gifWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func exportGIF(video: URL, destination: URL?, options: GifOptions) {
        guard !terminating, !gifProgress.running, task == nil else { return }
        var destination = destination
        if destination == nil {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.gif]; panel.nameFieldStringValue = outputName(extension: "gif")
            activeSavePanel = panel
            defer { activeSavePanel = nil }
            guard panel.runModal() == .OK, !terminating else { return }; destination = panel.url
        }
        guard let destination else { return }
        gifProgress.running = true; gifProgress.fraction = 0; isBusy = true
        task = Task {
            defer { task = nil; gifProgress.running = false; isBusy = false }
            do {
                try await GifExporter.export(video: video, destination: destination, options: options) { [weak gifProgress] fraction in
                    Task { @MainActor in gifProgress?.fraction = fraction }
                }
                gifProgress.running = false; gifWindow?.close()
                guard !terminating else { return }
                CompletionNotifications.post(title: "GIF 已保存", message: destination.lastPathComponent, file: destination)
            } catch is CancellationError {} catch { ErrorPresenter.show(error) }
        }
    }

    private func copyVideo(_ source: URL, to destination: URL) async throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        try await Task.detached(priority: .userInitiated) {
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".niko-shot-\(UUID().uuidString).mp4")
            try FileManager.default.copyItem(at: source, to: stage)
            defer { try? FileManager.default.removeItem(at: stage) }
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage) }
            else { try FileManager.default.moveItem(at: stage, to: destination) }
        }.value
    }

    private func outputName(extension suffix: String) -> String {
        let name = Exporters.filename(template: AppSettings.shared.filenameTemplate, date: .now,
                                      sequence: UserDefaults.standard.integer(forKey: "filenameSequence"), format: .png)
        return (name as NSString).deletingPathExtension + "." + suffix
    }

    func cancel() async {
        task?.cancel(); task = nil; countdown.cancel(); selection.finish()
        setupWindow?.close(); gifWindow?.close(); controls?.close(); controls = nil; camera.close()
        await session.cancel(); isBusy = false
    }

    func finishForTermination() async {
        terminating = true
        let pending = task
        let isFinalizingVideo = session.state == .finishing && !gifProgress.running
        if !isFinalizingVideo { pending?.cancel() }
        activeSavePanel?.cancel(nil)
        countdown.cancel(); selection.finish()
        setupWindow?.close(); gifWindow?.close(); controls?.close(); controls = nil; camera.close()
        // Wait for cancellation cleanup before replying to AppKit's termination request.
        // A video already being finalized gets to finish writing its valid MP4.
        await pending?.value
        if session.state == .recording || session.state == .paused { _ = try? await session.stop() }
        else { await session.cancel() }
        task = nil; isBusy = false
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
