// Owns the menu bar lifetime and composes application services.
import AppKit
import SwiftUI
import os
import UniformTypeIdentifiers
import ImageIO
import UserNotifications
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menu: MainMenuExtra?
    private var settingsWindow: UtilityWindow?
    private var hotkeys: HotkeyCenter?
    private let captureEngine = CaptureEngine()
    private let selectionSession = SelectionSession()
    private var captureTask: Task<Void, Never>?
    private var outputTasks: [UUID: Task<Void, Never>] = [:]
    private var outputPanels: [UUID: SavePanelRouter] = [:]
    private var ocrTasks: [UUID: Task<Void, Never>] = [:]
    private var automationTask: Task<AutomationResponse, Error>?
    private var automationRequestID: UUID?
    private var automationSelectionID: UUID?
    private var automationServer: AutomationServer?
    private var wizard: WelcomeWindowController?
    private var resumesWizardAfterDemo = false
    private var isTerminating = false
    private var isApplicationMenuInstalled = false
    private let windowList = WindowList()
    private let countdown = CaptureCountdown()
    private var lastRegion: CaptureContext?
    private var storedPinManager: PinWindowManager?
    private var pinManager: PinWindowManager {
        if let storedPinManager { return storedPinManager }
        let manager = PinWindowManager()
        storedPinManager = manager
        return manager
    }
    private var pinResourceCounts: [String: Int] {
        storedPinManager?.resourceCounts ?? ["pinWindows": 0, "pinTasks": 0, "pinPersistenceTasks": 0]
    }
    private let menuModel = MenuModel()
    private var historyStore: HistoryStore?
    private var historyWindow: UtilityWindow?
    private var pinsWindow: UtilityWindow?
    private let ocrEngine = OCREngine()
    private var ocrWindow: UtilityWindow?
    private var latestOCRText = UserDefaults.standard.string(forKey: "lastOCRText") ?? ""
    private lazy var recording = RecordingCoordinator(engine: captureEngine, selection: selectionSession, windows: windowList,
                                                       onOCR: { [weak self] in self?.rememberOCRText($0) })
    private lazy var scrolling = ScrollCoordinator(engine: captureEngine, selection: selectionSession, windows: windowList,
                                                   onCapture: { [weak self] image, context in self?.handleCapture(image, context: context) })
    private let launchLog = OSLog(subsystem: "com.n1ko.niko-shot", category: "Lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        selectionSession.onScrollCapture = { [weak self] context in
            guard let self, !self.isTerminating, !self.recording.isBusy, !self.scrolling.isBusy else { return }
            self.installApplicationMenu()
            self.scrolling.continueFromSelection(context: context)
        }
        selectionSession.onRecognizedText = { [weak self] in self?.rememberOCRText($0) }
        CapturePreviewController.shared.onEdit = { [weak self] record in self?.openHistoryImage(record, pin: false) }
        CapturePreviewController.shared.onPin = { [weak self] record in self?.openHistoryImage(record, pin: true) }
        CapturePreviewController.shared.onSave = { [weak self] record in self?.saveHistoryImage(record) }
        selectionSession.onTextWorkspace = { [weak self] model, translation in
            self?.presentOCR(model, translationModel: translation)
        }
        LaunchDiagnostics.record("before-activation-policy")
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        LaunchDiagnostics.record("activation-policy")
        menuModel.onOpen = { [weak self] in
            self?.installApplicationMenu()
            Task { [weak self] in
                guard let self, !self.isTerminating else { return }
                do { self.menuModel.recents = try await self.getHistoryStore().list(limit: 3) }
                catch { if !self.isTerminating { ErrorPresenter.show(error) } }
            }
        }
        hotkeys = HotkeyCenter(actions: Dictionary(uniqueKeysWithValues: CaptureAction.allCases.map { action in
            (action, { [weak self] in self?.perform(action) })
        }))
        menu = MainMenuExtra(model: menuModel, hotkeys: hotkeys, action: { [weak self] id in
            if id == "history" { self?.showHistory(); return }
            if let action = CaptureAction(rawValue: id) { self?.perform(action) }
        }, settings: { [weak self] in self?.showSettings() })
        LaunchDiagnostics.record("status-and-hotkeys")
        os_signpost(.event, log: launchLog, name: "MenuReady")
        if let metricsPath = ProcessInfo.processInfo.environment["NIKO_STARTUP_METRICS"] {
            let uptime = ProcessInfo.processInfo.systemUptime
            try? String(uptime).write(toFile: metricsPath, atomically: true, encoding: .utf8)
        }
        AutomationBridge.shared.handler = { [weak self] command in
            guard let self else { throw AppError.file("niko-shot 已退出。") }
            return try await self.runAutomation(command)
        }
        let server = AutomationServer(); server.start(); automationServer = server
        LaunchDiagnostics.record("automation")
        UNUserNotificationCenter.current().delegate = self
        LaunchDiagnostics.record("notifications")
        // Opt-in first-run replay makes the same native flow testable without resetting preferences.
        if !WelcomeWindowController.isCompleted || ProcessInfo.processInfo.environment["NIKO_REPLAY_ONBOARDING"] == "1" { showWizard() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isTerminating else { return false }
        if !flag { showSettings() }
        return true
    }

    @objc func showSettings() {
        installApplicationMenu()
        if settingsWindow == nil {
            let window = UtilityWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "niko-shot 设置"
            window.toolbarStyle = .unified
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentMinSize = CGSize(width: 780, height: 540)
            window.titlebarSeparatorStyle = .line
            let restoredFrame = window.setFrameUsingName("NikoSettingsWorkspace")
            window.setFrameAutosaveName("NikoSettingsWorkspace")
            if let hotkeys {
                window.contentView = NSHostingView(rootView: SettingsView(hotkeys: hotkeys,
                    onShowWizard: { [weak self] in self?.showWizard() }))
            }
            if !restoredFrame { window.center() }
            window.onClose = { [weak self] in self?.settingsWindow = nil }
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the translation preferences directly without recreating an existing settings workspace.
    @objc func showTranslationSettings() {
        SettingsNavigation.shared.opensTranslation = true
        showSettings()
    }

    func perform(_ action: CaptureAction) {
        guard !isTerminating else { return }
        if action == .pins { showPins(); return }
        if action == .togglePins { pinManager.toggleVisibility(); return }
        guard captureTask == nil, automationTask == nil, selectionSession.state == .idle, !recording.isBusy, !scrolling.isBusy else { return }
        CapturePreviewController.shared.dismiss(animated: false)
        installApplicationMenu()
        if action == .record { recording.showSetup(); return }
        if action == .scroll { scrolling.select(); return }
        let started = ContinuousClock.now, signpost = OSSignpostID(log: launchLog)
        os_signpost(.begin, log: launchLog, name: "HotkeyToOverlay", signpostID: signpost)
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.captureTask = nil
                os_signpost(.end, log: self.launchLog, name: "HotkeyToOverlay", signpostID: signpost)
                if self.resumesWizardAfterDemo, self.selectionSession.state == .idle {
                    self.resumesWizardAfterDemo = false
                    if !self.isTerminating { self.wizard?.show() }
                }
            }
            do {
                try await self.countdown.wait(seconds: AppSettings.shared.captureDelay)
                async let frozen = self.captureEngine.freezeScreens()
                async let listed = self.windowList.windows()
                let (frames, candidates) = try await (frozen, listed)
                try Task.checkCancellation()
                guard !self.isTerminating else { return }
                var initial: CaptureContext?
                if action == .repeatRegion { initial = self.lastRegion ?? self.loadLastRegion(frames: frames) }
                if action == .fullscreen, let frame = frames.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) ?? frames.first {
                    initial = CaptureContext(screen: frame.screen, localRect: frame.screen.localBounds, kind: "fullscreen")
                }
                self.selectionSession.start(frames: frames, candidates: candidates, kind: action.rawValue, initial: initial) { [weak self] image, context in self?.handleCapture(image, context: context) }
                if let path = ProcessInfo.processInfo.environment["NIKO_CAPTURE_METRICS"] {
                    let elapsed = started.duration(to: .now).components
                    let metrics: [String: Any] = ["action": action.rawValue,
                        "milliseconds": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                        "delaySeconds": AppSettings.shared.captureDelay,
                        "screens": frames.map { ["width": $0.image.width, "height": $0.image.height] }]
                    if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted]) {
                        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                    }
                }
                self.selectionSession.onFinish = { [weak self] _ in
                    guard let self, self.resumesWizardAfterDemo else { return }
                    self.resumesWizardAfterDemo = false
                    if !self.isTerminating { self.wizard?.show() }
                }
            } catch is CancellationError {} catch { if !self.isTerminating, !Task.isCancelled { ErrorPresenter.show(error) } }
        }
    }

    func handleCapture(_ image: CGImage, context: CaptureContext) {
        if selectionSession.outputAction == .scroll {
            guard !isTerminating else { return }
            scrolling.continueFromSelection(context: context.hasLiveScreenRegion ? context : nil)
            return
        }
        if context.screen.id != 0 {
            lastRegion = context
            UserDefaults.standard.set(["screen": Double(context.screen.id), "x": context.localRect.minX, "y": context.localRect.minY, "width": context.localRect.width, "height": context.localRect.height], forKey: "lastRegion")
        }
        let action = selectionSession.outputAction
        let id = UUID(), date = Date.now
        let archive = AppPaths.captures.appendingPathComponent("\(id.uuidString).png")
        // Copies claim the clipboard before any encoding, so a paste right after the click already works.
        let clipboard = action == .pin || action == .save ? nil : DeferredCapturePayload(image: image, date: date, file: archive)
        if let clipboard { ClipboardWriter.write(clipboard) }
        CaptureFeedback.playShutter()
        let previewScreen = context.screen.id != 0 ? context.screen.frame : (NSScreen.main?.frame ?? .zero)
        let previewScale = NSScreen.screens.first { $0.frame == previewScreen }?.backingScaleFactor ?? 2
        let taskID = UUID()
        outputTasks[taskID] = Task {
            defer { outputTasks[taskID] = nil }
            do {
                let saved = try await storeCapture(image, context: context, id: id, date: date) { clipboard?.fulfill(png: $0) }
                let record = saved.record
                let file = URL(fileURLWithPath: record.path)
                try Task.checkCancellation()
                guard !isTerminating else { return }
                let interactiveOCR = action == .ocr || action == .translate
                if AppSettings.shared.autoOCR || interactiveOCR || context.kind == "ocr" {
                    recognizeCapture(image, record: record, show: interactiveOCR)
                }
                if action == .pin { pinManager.pin(image: image, url: file, thumbnail: record.thumbnail); return }
                if action == .save {
                    let router = SavePanelRouter()
                    outputPanels[taskID] = router
                    defer { outputPanels[taskID] = nil }
                    guard let (url, format, quality) = withExtendedLifetime(router, { router.destination() }) else { return }
                    try Task.checkCancellation()
                    try await Self.imageWork {
                        let encoded = try Exporters.encode(image, format: format, quality: quality, date: date)
                        try Task.checkCancellation()
                        try encoded.write(to: url, options: .atomic)
                    }
                    UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "filenameSequence") + 1, forKey: "filenameSequence")
                    return
                }
                guard action == .copy, AppSettings.shared.showsCapturePreview, selectionSession.state == .idle else { return }
                let thumbnail = try await Self.imageWork { CapturePreviewController.makeThumbnail(image, backingScale: previewScale) }
                guard let thumbnail, !isTerminating, selectionSession.state == .idle, captureTask == nil else { return }
                CapturePreviewController.shared.show(record: record, thumbnail: thumbnail, screenFrame: previewScreen, status: "已复制")
            } catch is CancellationError { clipboard?.fail() }
            catch { clipboard?.fail(); if !isTerminating, !Task.isCancelled { ErrorPresenter.show(error) } }
        }
    }

    private struct SavedCapture: Sendable {
        let record: HistoryRecord
        let png: Data
    }

    /// Archives a capture: the PNG first (reported through `onArchived`), then its thumbnail and history row.
    private func storeCapture(_ image: CGImage, context: CaptureContext, id: UUID = UUID(), date: Date = .now,
                              onArchived: @MainActor (Data) -> Void = { _ in }) async throws -> SavedCapture {
        let file = AppPaths.captures.appendingPathComponent("\(id.uuidString).png")
        let png = try await Self.imageWork { () -> Data in
            let png = try Exporters.encode(image, format: .png, date: date)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: AppPaths.captures, withIntermediateDirectories: true)
            try png.write(to: file, options: .atomic)
            return png
        }
        do { try Task.checkCancellation() }
        catch { try? FileManager.default.removeItem(at: file); throw error }
        onArchived(png)
        let thumbnail = try await Self.imageWork { try Exporters.thumbnail(from: png) }
        let store = try getHistoryStore()
        let record = HistoryRecord(id: id, createdAt: date, path: file.path, thumbnail: thumbnail,
            width: image.width, height: image.height, appBundleID: context.appBundleID, captureKind: context.kind)
        do { try await store.insert(record) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
        try await store.prune(days: AppSettings.shared.historyRetention)
        menuModel.recents = try await store.list(limit: 3)
        return SavedCapture(record: record, png: png)
    }

    /// Saves an archived capture through the native save panel, keeping the chosen format and quality.
    private func saveHistoryImage(_ record: HistoryRecord) {
        guard !isTerminating else { return }
        let taskID = UUID()
        outputTasks[taskID] = Task {
            defer { outputTasks[taskID] = nil }
            do {
                let image = try await Self.imageWork { () -> CGImage in
                    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: record.path) as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppError.imageCreation }
                    return image
                }
                guard !isTerminating else { return }
                NSApp.activate(ignoringOtherApps: true)
                let router = SavePanelRouter()
                outputPanels[taskID] = router
                defer { outputPanels[taskID] = nil }
                guard let (url, format, quality) = withExtendedLifetime(router, { router.destination() }) else { return }
                let date = record.createdAt
                try await Self.imageWork {
                    let encoded = try Exporters.encode(image, format: format, quality: quality, date: date)
                    try encoded.write(to: url, options: .atomic)
                }
                UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "filenameSequence") + 1, forKey: "filenameSequence")
            } catch is CancellationError {}
            catch { if !isTerminating, !Task.isCancelled { ErrorPresenter.show(error) } }
        }
    }

    private func getHistoryStore() throws -> HistoryStore {
        if let historyStore { return historyStore }
        let store = try HistoryStore(url: AppPaths.root.appendingPathComponent("history.sqlite")); historyStore = store; return store
    }
    @objc func showHistory() {
        installApplicationMenu()
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
        guard !isTerminating else { return }
        installApplicationMenu()
        pinManager.load()
        if pinsWindow == nil { let window = makeUtilityWindow(title: "贴图库"); window.contentView = NSHostingView(rootView: PinLibraryView(manager: pinManager)); window.onClose = { [weak self] in self?.pinsWindow = nil }; pinsWindow = window }
        pinsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func makeUtilityWindow(title: String) -> UtilityWindow {
        let window = UtilityWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified; window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .line
        window.contentMinSize = CGSize(width: 760, height: 500)
        window.center(); return window
    }
    private func openHistoryImage(_ record: HistoryRecord, pin: Bool) {
        guard !isTerminating else { return }
        let taskID = UUID()
        outputTasks[taskID] = Task {
            defer { outputTasks[taskID] = nil }
            do {
                let image = try await Self.imageWork { () -> CGImage in
                    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: record.path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppError.imageCreation }; return image
                }
                try Task.checkCancellation()
                guard !isTerminating, selectionSession.state == .idle else { return }
                if pin { pinManager.pin(image: image, url: URL(fileURLWithPath: record.path), thumbnail: record.thumbnail) }
                else { selectionSession.edit(image: image, pointSize: CGSize(width: image.width, height: image.height)) { [weak self] image, context in self?.handleCapture(image, context: context) } }
            } catch is CancellationError {}
            catch { if !isTerminating, !Task.isCancelled { ErrorPresenter.show(error) } }
        }
    }

    private func recognizeCapture(_ image: CGImage, record: HistoryRecord, show: Bool) {
        let model = OCRViewModel()
        if show { model.isRecognizing = true; presentOCR(model) }
        let languages = AppSettings.shared.ocrLanguages, accurate = AppSettings.shared.accurateOCR
        let taskID = UUID()
        ocrTasks[taskID] = Task(priority: show ? .userInitiated : .utility) {
            defer { ocrTasks[taskID] = nil }
            do {
                let blocks = try await ocrEngine.recognize(image, languages: languages, accurate: accurate)
                try Task.checkCancellation()
                guard !isTerminating else { return }
                model.blocks = blocks; model.isRecognizing = false
                let text = blocks.map(\.text).joined(separator: "\n")
                rememberOCRText(text)
                try await getHistoryStore().updateOCR(id: record.id, text: text)
                NotificationCenter.default.post(name: .captureHistoryChanged, object: nil)
            } catch is CancellationError {}
            catch { if !isTerminating, !Task.isCancelled { model.isRecognizing = false; model.errorMessage = error.localizedDescription } }
        }
    }

    private func rememberOCRText(_ text: String) {
        latestOCRText = text
        UserDefaults.standard.set(text, forKey: "lastOCRText")
    }
    private func presentOCR(_ model: OCRViewModel, translationModel: TranslationViewModel? = nil) {
        installApplicationMenu()
        if ocrWindow == nil {
            let window = makeUtilityWindow(title: "识别与翻译")
            window.contentMinSize = CGSize(width: 760, height: 520)
            window.setContentSize(CGSize(width: 980, height: 620))
            let restoredFrame = window.setFrameUsingName("NikoTextWorkspace")
            window.setFrameAutosaveName("NikoTextWorkspace")
            if !restoredFrame { window.center() }
            window.onClose = { [weak self] in self?.ocrWindow = nil }; ocrWindow = window
        }
        ocrWindow?.contentView = NSHostingView(rootView: OCRView(model: model, translationModel: translationModel))
        ocrWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func reOCR(_ record: HistoryRecord) {
        guard !isTerminating else { return }
        let taskID = UUID()
        ocrTasks[taskID] = Task {
            defer { ocrTasks[taskID] = nil }
            do {
                let image = try await Self.imageWork(priority: .utility) { () -> CGImage in
                    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: record.path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppError.imageCreation }; return image
                }
                try Task.checkCancellation()
                guard !isTerminating else { return }
                recognizeCapture(image, record: record, show: true)
            } catch is CancellationError {}
            catch { if !isTerminating, !Task.isCancelled { ErrorPresenter.show(error) } }
        }
    }

    private func loadLastRegion(frames: [FrozenFrame]) -> CaptureContext? {
        guard let saved = UserDefaults.standard.dictionary(forKey: "lastRegion") as? [String: Double],
              let screen = saved["screen"], let x = saved["x"], let y = saved["y"], let width = saved["width"], let height = saved["height"],
              let frame = frames.first(where: { Double($0.screen.id) == screen }) else { return nil }
        return CaptureContext(screen: frame.screen, localRect: CGRect(x: x, y: y, width: width, height: height))
    }

    private func showWizard() {
        guard !isTerminating else { return }
        installApplicationMenu()
        if wizard == nil {
            let essentials: [CaptureAction] = [.region, .window, .scroll, .ocr, .record, .repeatRegion]
            let shortcuts = essentials.map { action in
                (action.title, (hotkeys?.shortcut(for: action) ?? action.defaultShortcut).displayString)
            }
            wizard = WelcomeWindowController(onDemo: { [weak self] in
                guard let self, self.captureTask == nil, self.automationTask == nil,
                      self.selectionSession.state == .idle, !self.recording.isBusy, !self.scrolling.isBusy else { return }
                self.resumesWizardAfterDemo = true; self.wizard?.close(); self.perform(.region)
            }, onComplete: { [weak self] in self?.wizard = nil }, shortcuts: shortcuts)
        }
        wizard?.show()
    }

    private func installApplicationMenu() {
        guard !isApplicationMenuInstalled else { return }
        isApplicationMenuInstalled = true
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let application = NSMenu(title: "niko-shot")
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        application.addItem(settings); application.addItem(.separator())
        application.addItem(NSMenuItem(title: "退出 niko-shot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applicationItem.submenu = application; main.addItem(applicationItem)
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "文件")
        file.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = file; main.addItem(fileItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
                                    ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key))
        }
        let redo = NSMenuItem(title: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]; edit.insertItem(redo, at: 1)
        editItem.submenu = edit; main.addItem(editItem)
        // Native commands are reachable by keyboard and VoiceOver even when the status popover is closed.
        let toolsItem = NSMenuItem()
        let tools = NSMenu(title: "工具")
        for action in CaptureAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action.rawValue
            tools.addItem(item)
        }
        tools.addItem(.separator())
        let history = NSMenuItem(title: "截图历史", action: #selector(showHistory), keyEquivalent: "")
        history.target = self; tools.addItem(history)
        toolsItem.submenu = tools; main.addItem(toolsItem)
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "窗口")
        window.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: "全部置于前面", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        windowItem.submenu = window; main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    @objc private func performMenuAction(_ item: NSMenuItem) {
        guard let rawValue = item.representedObject as? String, let action = CaptureAction(rawValue: rawValue) else { return }
        perform(action)
    }

    // Cancel the detached encoder/decoder too, then await it before releasing capture ownership.
    private nonisolated static func imageWork<Value: Sendable>(priority: TaskPriority = .userInitiated,
        _ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let worker = Task.detached(priority: priority) {
            try Task.checkCancellation()
            // Return freed ImageIO scratch pages after each bounded operation, on this worker.
            defer { _ = malloc_zone_pressure_relief(nil, 0) }
            return try autoreleasepool { try operation() }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Runs all external entry points through one resident process and the existing native services.
    private func runAutomation(_ command: AutomationCommand) async throws -> AutomationResponse {
        try Task.checkCancellation()
        guard !isTerminating else { throw CancellationError() }
        if command.action == .lastOCR {
            if latestOCRText.isEmpty { latestOCRText = try await getHistoryStore().lastOCRText() }
            return AutomationResponse(text: latestOCRText, message: latestOCRText.isEmpty ? "暂无 OCR 结果。" : "最近一次 OCR")
        }
        guard automationTask == nil, captureTask == nil, outputTasks.isEmpty, selectionSession.state == .idle,
              !recording.isBusy, !scrolling.isBusy else { throw AppError.file("正在执行另一项捕获，请完成或取消后重试。") }
        let requestID = UUID(); automationRequestID = requestID
        let task = Task { try await executeAutomation(command) }
        automationTask = task
        defer { automationTask = nil; automationSelectionID = nil; automationRequestID = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.automationRequestID == requestID else { return }
                self.selectionSession.finish()
                if self.scrolling.isBusy { await self.scrolling.cancel() }
            }
        }
    }

    private func executeAutomation(_ command: AutomationCommand) async throws -> AutomationResponse {
        if command.action == .translate {
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                throw AppError.file("剪贴板没有可翻译的文字。")
            }
            guard let target = Language(rawValue: command.targetLanguage ?? "") ??
                    Language.detected(code: command.targetLanguage ?? "zh", provider: .google) else {
                throw AppError.file("不支持的目标语言：\(command.targetLanguage ?? "")")
            }
            let settings = AppSettings.shared
            let custom = settings.customTranslationServices.first { $0.id == settings.selectedCustomTranslationID }
            let result = try await TranslationRouter.shared.translate(TranslationRequest(text: text, source: nil, target: target),
                provider: settings.translationProvider, custom: custom)
            try Task.checkCancellation()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.text, forType: .string)
            return AutomationResponse(text: result.text, message: "译文已复制。")
        }
        if command.action == .record {
            installApplicationMenu()
            let output = command.outputPath.map { URL(fileURLWithPath: $0) }
            let file = try await recording.startAutomation(delay: command.delay, output: output,
                format: command.recordingFormat.rawValue, autoOCR: command.autoOCR, captureType: command.captureType)
            return AutomationResponse(outputPath: file.path, message: "录制已启动，停止后将完成此文件。")
        }
        let requestedOutput = command.outputPath.map { URL(fileURLWithPath: $0) }
        if let requestedOutput { _ = try imageFormat(for: requestedOutput) }
        try await countdown.wait(seconds: command.delay)
        try Task.checkCancellation()
        let captured: (CGImage, CaptureContext)
        if command.action == .scroll {
            installApplicationMenu()
            captured = try await scrolling.captureForAutomation()
        } else if command.captureType == .window, let windowID = command.windowID {
            let image = try await captureEngine.captureWindow(id: windowID)
            let candidates = try await windowList.windows()
            guard let candidate = candidates.first(where: { $0.id == windowID }),
                  let screen = NSScreen.screens.first(where: { $0.frame.intersects(candidate.frame) }) else {
                throw AppError.file("目标窗口或显示器已关闭。")
            }
            let geometry = ScreenGeometry(id: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                frame: screen.frame, scale: screen.backingScaleFactor, safeTop: screen.safeAreaInsets.top)
            let origin = CoordinateSpace.globalPointToScreenLocal(CGPoint(x: candidate.frame.minX, y: candidate.frame.maxY), screen: geometry)
            captured = (image, CaptureContext(screen: geometry, localRect: CGRect(origin: origin, size: candidate.frame.size),
                kind: "window", appBundleID: candidate.appBundleID, windowID: windowID))
        } else {
            async let frozen = captureEngine.freezeScreens()
            async let listed = windowList.windows()
            let (frames, candidates) = try await (frozen, listed)
            try Task.checkCancellation()
            if command.captureType == .fullscreen,
               let frame = frames.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) ?? frames.first {
                captured = (frame.image, CaptureContext(screen: frame.screen, localRect: frame.screen.localBounds, kind: "fullscreen"))
            } else {
                installApplicationMenu()
                captured = try await selectedAutomationCapture(frames: frames, candidates: candidates,
                    kind: command.captureType.rawValue)
            }
        }
        try Task.checkCancellation()
        let saved = try await storeCapture(captured.0, context: captured.1)
        var text: String?
        if command.autoOCR || command.action == .ocr {
            let blocks = try await ocrEngine.recognize(captured.0, languages: AppSettings.shared.ocrLanguages,
                accurate: AppSettings.shared.accurateOCR)
            try Task.checkCancellation()
            text = blocks.map(\.text).joined(separator: "\n")
            rememberOCRText(text ?? "")
            try await getHistoryStore().updateOCR(id: saved.record.id, text: text ?? "")
            NotificationCenter.default.post(name: .captureHistoryChanged, object: nil)
        }
        var file = URL(fileURLWithPath: saved.record.path)
        if let requestedOutput {
            let format = try imageFormat(for: requestedOutput), date = saved.record.createdAt, quality = AppSettings.shared.jpegQuality
            try await Self.imageWork {
                let encoded = try Exporters.encode(captured.0, format: format, quality: quality, date: date)
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: requestedOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoded.write(to: requestedOutput, options: .atomic)
            }
            file = requestedOutput
        }
        try Task.checkCancellation()
        if command.action == .ocr {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text ?? "", forType: .string)
        } else {
            let payload = DeferredCapturePayload(image: captured.0, date: saved.record.createdAt, file: file)
            payload.fulfill(png: saved.png)
            ClipboardWriter.write(payload)
        }
        return AutomationResponse(outputPath: file.path, text: text,
            message: command.action == .ocr ? "识别文字已复制。" : "截图已保存并复制。")
    }

    private func selectedAutomationCapture(frames: [FrozenFrame], candidates: [WindowCandidate], kind: String) async throws -> (CGImage, CaptureContext) {
        let token = UUID(); automationSelectionID = token
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                selectionSession.start(frames: frames, candidates: candidates, kind: kind,
                    confirmationTitle: "确认截图") { image, context in continuation.resume(returning: (image, context)) }
                selectionSession.onFinish = { completed in if !completed { continuation.resume(throwing: CancellationError()) } }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.automationSelectionID == token else { return }
                self.selectionSession.finish()
            }
        }
    }

    private func imageFormat(for file: URL) throws -> ExportFormat {
        switch file.pathExtension.lowercased() {
        case "", "png": .png
        case "jpg", "jpeg": .jpeg
        case "heic", "heif": .heif
        case "tif", "tiff": .tiff
        default: throw AppError.file("输出文件必须使用 PNG、JPEG、HEIF 或 TIFF 扩展名。")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        let pendingPins = storedPinManager
        pendingPins?.prepareForTermination()
        let stoppedServer = automationServer
        hotkeys?.stop(); stoppedServer?.stop(); wizard?.close(); wizard = nil
        let pendingCapture = captureTask, pendingAutomation = automationTask
        let pendingOutputs = Array(outputTasks.values), pendingOCR = Array(ocrTasks.values)
        pendingCapture?.cancel(); pendingAutomation?.cancel()
        for task in pendingOutputs + pendingOCR { task.cancel() }
        for panel in outputPanels.values { panel.cancel() }
        countdown.cancel(); selectionSession.finish()
        let ownsRecordingResources = recording.resourceCounts.values.contains { $0 > 0 }
        let ownsPinResources = pinResourceCounts.values.contains { $0 > 0 }
        let ownsSelectionResources = selectionSession.resourceCounts.values.contains { $0 > 0 }
        guard ownsSelectionResources || ownsPinResources || ownsRecordingResources || recording.isBusy || scrolling.isBusy || pendingCapture != nil || pendingAutomation != nil ||
                !pendingOutputs.isEmpty || !pendingOCR.isEmpty || (stoppedServer?.drainingOperationCount ?? 0) > 0 else { return .terminateNow }
        Task {
            await selectionSession.finishAndDrain()
            await pendingPins?.finishForTermination()
            if ownsRecordingResources || recording.isBusy { await recording.finishForTermination() }
            if scrolling.isBusy { await scrolling.cancel() }
            await stoppedServer?.stopAndDrain()
            await pendingCapture?.value
            _ = try? await pendingAutomation?.value
            for task in pendingOutputs + pendingOCR { await task.value }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.stop()
        captureTask?.cancel()
        countdown.cancel()
        selectionSession.finish()
        storedPinManager?.closeAll()
        settingsWindow?.close(); settingsWindow = nil
        historyWindow?.close(); historyWindow = nil
        pinsWindow?.close(); pinsWindow = nil
        ocrWindow?.close(); ocrWindow = nil
        wizard?.close(); wizard = nil
        menu?.close(); menu = nil
        let stoppedServer = automationServer
        stoppedServer?.stop(); automationServer = nil
        AutomationBridge.shared.handler = nil
        if let path = ProcessInfo.processInfo.environment["NIKO_TEARDOWN_METRICS"] {
            let metrics: [String: Any] = [
                "selectionWindows": selectionSession.windowCount, "selectionMonitors": selectionSession.monitorCount,
                "displayLinks": selectionSession.displayLinkCount, "countdownWindows": countdown.windowCount,
                "countdownMonitors": countdown.monitorCount, "hotkeyHandlers": hotkeys?.isRunning == true ? 1 : 0,
                "registeredHotkeys": hotkeys?.registeredActions.count ?? 0,
                "automationObservers": stoppedServer?.observerCount ?? 0,
                "automationOperations": stoppedServer?.operationCount ?? 0,
                "automationDrainingTasks": stoppedServer?.drainingOperationCount ?? 0,
                "automationProcessObservers": stoppedServer?.processObserverCount ?? 0,
                "visibleNativeWindows": NSApp.windows.filter(\.isVisible).count,
                "captureTask": captureTask == nil ? 0 : 1, "outputTasks": outputTasks.count, "ocrTasks": ocrTasks.count,
                "outputPanels": outputPanels.count,
                "recording": recording.resourceCounts, "scrolling": scrolling.resourceCounts,
                "pins": pinResourceCounts, "selection": selectionSession.resourceCounts
            ]
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task { [weak self] in
                do { _ = try await AutomationBridge.shared.execute(AutomationCommand.parse(url: url)) }
                catch is CancellationError {}
                catch { if self?.isTerminating == false { ErrorPresenter.show(error) } }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        await MainActor.run {
            guard !self.isTerminating else { return }
            if let path, FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else { self.showHistory() }
        }
    }
}
