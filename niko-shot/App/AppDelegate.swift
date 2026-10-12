// Owns the menu bar lifetime and composes application services.
import AppKit
import SwiftUI
import os
import UniformTypeIdentifiers
import ImageIO

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menu: MainMenuExtra?
    private var settingsWindow: UtilityWindow?
    private var hotkeys: HotkeyCenter?
    private let captureEngine = CaptureEngine()
    private let selectionSession = SelectionSession()
    private var captureTask: Task<Void, Never>?
    private let windowList = WindowList()
    private let countdown = CaptureCountdown()
    private var lastRegion: CaptureContext?
    private let pinManager = PinWindowManager()
    private let menuModel = MenuModel()
    private var historyStore: HistoryStore?
    private var historyWindow: UtilityWindow?
    private var pinsWindow: UtilityWindow?
    private let ocrEngine = OCREngine()
    private var ocrWindow: UtilityWindow?
    private var latestOCRText = ""
    private lazy var recording = RecordingCoordinator(engine: captureEngine, selection: selectionSession, windows: windowList)
    private let launchLog = OSLog(subsystem: "com.n1ko.niko-shot", category: "Lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NSApp.setActivationPolicy(.accessory)
        menuModel.onOpen = { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                do { self.menuModel.recents = try await self.getHistoryStore().list(limit: 3) } catch { ErrorPresenter.show(error) }
            }
        }
        hotkeys = HotkeyCenter(actions: Dictionary(uniqueKeysWithValues: CaptureAction.allCases.map { action in
            (action, { [weak self] in self?.perform(action) })
        }))
        menu = MainMenuExtra(model: menuModel, action: { [weak self] id in
            if id == "history" { self?.showHistory(); return }
            if let action = CaptureAction(rawValue: id) { self?.perform(action) }
        }, settings: { [weak self] in self?.showSettings() })
        os_signpost(.event, log: launchLog, name: "MenuReady")
        if let metricsPath = ProcessInfo.processInfo.environment["NIKO_STARTUP_METRICS"] {
            let uptime = ProcessInfo.processInfo.systemUptime
            try? String(uptime).write(toFile: metricsPath, atomically: true, encoding: .utf8)
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = UtilityWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "niko-shot 设置"
            window.isReleasedWhenClosed = false
            if let hotkeys { window.contentView = NSHostingView(rootView: SettingsView(hotkeys: hotkeys)) }
            window.center()
            window.onClose = { [weak self] in self?.settingsWindow = nil }
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func perform(_ action: CaptureAction) {
        if action == .pins { showPins(); return }
        if action == .togglePins { pinManager.toggleVisibility(); return }
        guard captureTask == nil, selectionSession.state == .idle, !recording.isBusy else { return }
        if action == .record { recording.showSetup(); return }
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.captureTask = nil }
            do {
                try await self.countdown.wait(seconds: AppSettings.shared.captureDelay)
                let frames = try await self.captureEngine.freezeScreens()
                let candidates = try await self.windowList.windows()
                var initial: CaptureContext?
                if action == .repeatRegion { initial = self.lastRegion ?? self.loadLastRegion(frames: frames) }
                if action == .fullscreen, let frame = frames.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) ?? frames.first {
                    initial = CaptureContext(screen: frame.screen, localRect: frame.screen.localBounds, kind: "fullscreen")
                }
                self.selectionSession.start(frames: frames, candidates: candidates, kind: action.rawValue, initial: initial) { [weak self] image, context in self?.handleCapture(image, context: context) }
            } catch is CancellationError {} catch { ErrorPresenter.show(error) }
        }
    }

    func handleCapture(_ image: CGImage, context: CaptureContext) {
        lastRegion = context
        UserDefaults.standard.set(["screen": Double(context.screen.id), "x": context.localRect.minX, "y": context.localRect.minY, "width": context.localRect.width, "height": context.localRect.height], forKey: "lastRegion")
        let action = selectionSession.outputAction
        Task {
            do {
                let id = UUID(), date = Date.now
                let file = AppPaths.captures.appendingPathComponent("\(id.uuidString).png")
                let payload = try await Task.detached(priority: .userInitiated) { () -> (Data, Data, Data) in
                    let png = try Exporters.encode(image, format: .png, date: date)
                    let tiff = try Exporters.encode(image, format: .tiff, date: date)
                    let thumbnail = try Exporters.thumbnail(from: png)
                    try FileManager.default.createDirectory(at: AppPaths.captures, withIntermediateDirectories: true)
                    try png.write(to: file, options: .atomic)
                    return (png, tiff, thumbnail)
                }.value
                let store = try getHistoryStore()
                let record = HistoryRecord(id: id, createdAt: date, path: file.path, thumbnail: payload.2, width: image.width, height: image.height, appBundleID: context.appBundleID, captureKind: context.kind)
                try await store.insert(record)
                try await store.prune(days: AppSettings.shared.historyRetention)
                menuModel.recents = try await store.list(limit: 3)
                let interactiveOCR = action == .ocr || context.kind == "ocr"
                if AppSettings.shared.autoOCR || interactiveOCR { recognizeCapture(image, record: record, show: interactiveOCR) }
                if action == .pin { pinManager.pin(image: image, url: file, thumbnail: payload.2); return }
                if action == .save {
                    guard let (url, format, quality) = SavePanelRouter().destination() else { return }
                    try await Task.detached { try Exporters.encode(image, format: format, quality: quality, date: date).write(to: url, options: .atomic) }.value
                    UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "filenameSequence") + 1, forKey: "filenameSequence")
                    return
                }
                ClipboardWriter.write(png: payload.0, tiff: payload.1, file: file)
            } catch { ErrorPresenter.show(error) }
        }
    }

    private func getHistoryStore() throws -> HistoryStore {
        if let historyStore { return historyStore }
        let store = try HistoryStore(url: AppPaths.root.appendingPathComponent("history.sqlite")); historyStore = store; return store
    }
    func showHistory() {
        do {
            let store = try getHistoryStore()
            if historyWindow == nil {
                let window = makeUtilityWindow(title: "截图历史")
                window.contentView = NSHostingView(rootView: HistoryView(store: store, onOCR: { [weak self] record in self?.reOCR(record) }, onPin: { [weak self] record in self?.openHistoryImage(record, pin: true) }, onEdit: { [weak self] record in self?.openHistoryImage(record, pin: false) }))
                window.onClose = { [weak self] in self?.historyWindow = nil }
                historyWindow = window
            }
            historyWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } catch { ErrorPresenter.show(error) }
    }
    func showPins() {
        pinManager.load()
        if pinsWindow == nil { let window = makeUtilityWindow(title: "贴图库"); window.contentView = NSHostingView(rootView: PinLibraryView(manager: pinManager)); window.onClose = { [weak self] in self?.pinsWindow = nil }; pinsWindow = window }
        pinsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func makeUtilityWindow(title: String) -> UtilityWindow {
        let window = UtilityWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.center(); return window
    }
    private func openHistoryImage(_ record: HistoryRecord, pin: Bool) {
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) { () -> CGImage in
                    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: record.path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppError.imageCreation }; return image
                }.value
                if pin { pinManager.pin(image: image, url: URL(fileURLWithPath: record.path), thumbnail: record.thumbnail) }
                else { selectionSession.edit(image: image, pointSize: CGSize(width: image.width, height: image.height)) { [weak self] image, context in self?.handleCapture(image, context: context) } }
            } catch { ErrorPresenter.show(error) }
        }
    }

    private func recognizeCapture(_ image: CGImage, record: HistoryRecord, show: Bool) {
        let model = OCRViewModel()
        if show { model.isRecognizing = true; presentOCR(model) }
        let languages = AppSettings.shared.ocrLanguages, accurate = AppSettings.shared.accurateOCR
        Task(priority: show ? .userInitiated : .utility) {
            do {
                let blocks = try await ocrEngine.recognize(image, languages: languages, accurate: accurate)
                model.blocks = blocks; model.isRecognizing = false
                let text = blocks.map(\.text).joined(separator: "\n")
                latestOCRText = text
                try await getHistoryStore().updateOCR(id: record.id, text: text)
                NotificationCenter.default.post(name: .captureHistoryChanged, object: nil)
            } catch { model.isRecognizing = false; model.errorMessage = error.localizedDescription }
        }
    }
    private func presentOCR(_ model: OCRViewModel) {
        if ocrWindow == nil { let window = makeUtilityWindow(title: "识别与翻译"); window.onClose = { [weak self] in self?.ocrWindow = nil }; ocrWindow = window }
        ocrWindow?.contentView = NSHostingView(rootView: OCRView(model: model))
        ocrWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func reOCR(_ record: HistoryRecord) {
        Task {
            do {
                let image = try await Task.detached(priority: .utility) { () -> CGImage in
                    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: record.path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppError.imageCreation }; return image
                }.value
                recognizeCapture(image, record: record, show: true)
            } catch { ErrorPresenter.show(error) }
        }
    }

    private func loadLastRegion(frames: [FrozenFrame]) -> CaptureContext? {
        guard let saved = UserDefaults.standard.dictionary(forKey: "lastRegion") as? [String: Double],
              let screen = saved["screen"], let x = saved["x"], let y = saved["y"], let width = saved["width"], let height = saved["height"],
              let frame = frames.first(where: { Double($0.screen.id) == screen }) else { return nil }
        return CaptureContext(screen: frame.screen, localRect: CGRect(x: x, y: y, width: width, height: height))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recording.isBusy else { return .terminateNow }
        Task { await recording.finishForTermination(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.stop()
        captureTask?.cancel()
        countdown.cancel()
        selectionSession.finish()
        pinManager.closeAll()
    }
}
