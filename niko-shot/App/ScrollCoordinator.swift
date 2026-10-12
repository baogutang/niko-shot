// Connects region selection, native scrolling controls, stable-frame capture and the shared editor.
import AppKit
import SwiftUI
import ImageIO

@MainActor
final class ScrollCoordinator {
    private let engine: CaptureEngine
    private let selection: SelectionSession
    private let windows: WindowList
    private let onCapture: (CGImage, CaptureContext) -> Void
    private let state = ScrollControlState()
    private var setupWindow: UtilityWindow?
    private var controls: ScrollControlBarController?
    private var operationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var loopID = UUID()
    private var generation = UUID()
    private var capture: RegionSnapshot?
    private var session: ScrollCaptureSession?
    private var options: ScrollCaptureOptions?
    private var context: CaptureContext?
    private var acceptedSignature: StitchSignature?
    private var pendingImage: CGImage?
    private var previewFile: URL?
    private var screenObserver: NSObjectProtocol?
    private var manualReason: String?
    private(set) var isBusy = false
    var resourceCounts: [String: Int] {
        ["operation": operationTask == nil ? 0 : 1, "loop": loopTask == nil ? 0 : 1,
         "cleanup": cleanupTask == nil ? 0 : 1, "capture": capture == nil ? 0 : 1,
         "worker": session == nil ? 0 : 1, "pendingImage": pendingImage == nil ? 0 : 1,
         "setup": setupWindow == nil ? 0 : 1, "controls": controls?.windowCount ?? 0,
         "displayObserver": screenObserver == nil ? 0 : 1]
    }

    init(engine: CaptureEngine, selection: SelectionSession, windows: WindowList,
         onCapture: @escaping (CGImage, CaptureContext) -> Void) {
        self.engine = engine; self.selection = selection; self.windows = windows; self.onCapture = onCapture
    }

    /// Starts the same frozen-frame region selector used by screenshots.
    func select() {
        guard !isBusy, selection.state == .idle else { return }
        isBusy = true
        let token = UUID(); generation = token
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.operationTask = nil } }
            do {
                let frames = try await self.engine.freezeScreens()
                let candidates = try await self.windows.windows()
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.selection.start(frames: frames, candidates: candidates, kind: "scroll", confirmationTitle: "选择滚动区域") { [weak self] image, selected in
                    var selected = selected
                    if selected.appBundleID.isEmpty {
                        selected.appBundleID = candidates.first(where: { $0.frame.contains(CGPoint(x: selected.globalRect.midX, y: selected.globalRect.midY)) })?.appBundleID ?? ""
                    }
                    self?.showSetup(image: image, context: selected)
                }
                self.selection.onFinish = { [weak self] completed in if !completed { self?.isBusy = false } }
            } catch is CancellationError { await self.cleanup(token: token) }
            catch { await self.fail(error, token: token) }
        }
    }

    /// Opens mode confirmation and the fixed-header/footer crop controls for a chosen viewport.
    func showSetup(image: CGImage, context: CaptureContext) {
        guard session == nil, selection.state == .idle else { return }
        setupWindow?.close(); isBusy = true
        let window = UtilityWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 740),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "滚动长截图"; window.isReleasedWhenClosed = false
        window.onClose = { [weak self] in self?.setupWindow = nil; self?.isBusy = false }
        window.contentView = NSHostingView(rootView: ScrollSetupView(image: image, scale: context.screen.scale,
            automaticAllowed: AutoScroller.isAuthorized, onStart: { [weak self] mode, top, bottom in
                self?.setupWindow?.close(); self?.start(context: context, mode: mode, top: top, bottom: bottom)
            }, onOpenAccessibility: { AutoScroller.openSettings() }, onCancel: { [weak self] in self?.setupWindow?.close() }))
        setupWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func start(context: CaptureContext, mode: ScrollCaptureMode, top: Int, bottom: Int) {
        guard !isBusy, operationTask == nil, selection.state == .idle else { return }
        isBusy = true
        let token = UUID(); generation = token
        self.context = context
        let options = ScrollCaptureOptions(ignoredTop: top, ignoredBottom: bottom)
        self.options = options
        manualReason = nil
        state.mode = mode; state.height = 0; state.frames = 0; state.isPaused = false; state.isMatching = false
        state.correlation = nil; state.overlap = 150; state.status = "正在捕获首屏…"
        if mode == .automatic, !AutoScroller.isAuthorized, !AutoScroller.requestAuthorization() {
            state.mode = .manual
            manualReason = "辅助功能未授权，已切换手动模式。"
            state.status = "辅助功能未授权，已切换手动模式。滚动后会自动捕获，完成请点结束。"
        }
        let worker = ScrollCaptureSession(options: options)
        session = worker
        controls = ScrollControlBarController(state: state, onFinish: { [weak self] in self?.finish() },
            onCancel: { [weak self] in Task { await self?.cancel() } }, onRetry: { [weak self] in self?.retry() },
            onManualOverlap: { [weak self] overlap in self?.confirmOverlap(overlap) }, onManualMode: { [weak self] in self?.switchToManual() })
        controls?.show(near: context.globalRect)
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.operationTask = nil } }
            do {
                let prepared = try await self.engine.regionCapture(screen: context.screen, rect: context.localRect)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.capture = prepared
                if context.appBundleID.isEmpty {
                    let candidates = try await self.windows.windows()
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    self.context?.appBundleID = candidates.first(where: {
                        $0.frame.contains(CGPoint(x: context.globalRect.midX, y: context.globalRect.midY))
                    })?.appBundleID ?? ""
                }
                self.activateTarget()
                try await Task.sleep(for: .milliseconds(300))
                guard let capture = self.capture else { throw CancellationError() }
                let provisional = try await capture.capture()
                let firstSignature = try await self.signature(for: provisional, options: options)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.acceptedSignature = firstSignature
                guard let image = try await self.stableFrame(token: token, requireChange: false) else {
                    throw AppError.file("首屏仍在移动，请稳定页面后重新开始。")
                }
                guard image.height - top - bottom >= 240 else { throw AppError.file("请保留至少 240 像素高的滚动内容。") }
                let result = try await worker.append(image)
                let signature = try await self.signature(for: image, options: options)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.acceptedSignature = signature; self.apply(result)
                self.state.maximumOverlap = image.height - top - bottom - 1
                self.screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { _ = Task<Void, Never> { await self?.cancel() } }
                }
                self.startLoop(token: token)
            } catch is CancellationError { await self.cleanup(token: token) }
            catch { await self.fail(error, token: token) }
        }
    }

    private func activateTarget() {
        guard let bundleID = context?.appBundleID, !bundleID.isEmpty else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate(options: [])
    }

    private func signature(for image: CGImage, options: ScrollCaptureOptions) async throws -> StitchSignature {
        try await Task.detached(priority: .userInitiated) {
            try Stitcher.signature(for: image, ignoringTop: options.ignoredTop, ignoringBottom: options.ignoredBottom)
        }.value
    }

    private func apply(_ result: ScrollAppendResult) {
        if case .appended(let height, let frames) = result {
            state.height = height; state.frames = frames
            state.status = state.mode == .manual ? (manualReason ?? "") + "滚动后自动捕获，完成请点结束。" : "页面稳定后继续滚动…"
        }
    }

    private func startLoop(token: UUID, captureCurrentFirst: Bool = false) {
        guard loopTask == nil else { return }
        let id = UUID(); loopID = id
        loopTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token, self.loopID == id { self.loopTask = nil } }
            var currentFirst = captureCurrentFirst, duplicates = 0
            do {
                while self.generation == token, self.loopID == id, !self.state.isPaused, !self.state.isMatching {
                    try Task.checkCancellation()
                    guard let context = self.context, let worker = self.session, let options = self.options else { return }
                    if self.state.mode == .automatic, !currentFirst {
                        let height = context.localRect.height * context.screen.scale - CGFloat(options.ignoredTop + options.ignoredBottom)
                        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                        let location = CGPoint(x: context.globalRect.midX, y: CoordinateSpace.flippedY(context.globalRect.midY, primaryTop: primaryTop))
                        do { try AutoScroller.step(points: max(1, (height - 150) / context.screen.scale), at: location) }
                        catch {
                            self.state.mode = .manual
                            self.manualReason = "自动滚动不可用，已切换手动。"
                            self.state.status = "自动滚动不可用，已切换手动。请自行滚动，完成请点结束。"
                        }
                    }
                    currentFirst = false
                    guard let image = try await self.stableFrame(token: token, loop: id) else {
                        self.state.isPaused = true; self.state.status = "页面仍在移动或动画未停止。请稳定页面后重试。"; return
                    }
                    let result = try await worker.append(image)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    switch result {
                    case .appended:
                        let signature = try await self.signature(for: image, options: options)
                        try Task.checkCancellation()
                        guard self.generation == token else { return }
                        duplicates = 0; self.acceptedSignature = signature
                        self.apply(result)
                    case .duplicate:
                        if self.state.mode == .automatic {
                            duplicates += 1
                            if duplicates >= 2 { self.state.status = "已到底，正在生成长图…"; self.finish(); return }
                            self.state.status = "页面没有变化，正在确认是否到底…"
                        }
                    case .needsConfirmation(let match):
                        self.pendingImage = image; self.state.isMatching = true; self.state.isPaused = true
                        self.state.correlation = match.correlation; self.state.overlap = match.overlap
                        self.state.maximumOverlap = image.height - options.ignoredTop - options.ignoredBottom - 1
                        self.state.status = match.isAmbiguous ? "页面重复纹理使接缝不明确。请确认重叠像素，或调整页面后重试。" : "接缝相关度不足。请确认重叠像素，或调整页面后重试。"
                        return
                    }
                }
            } catch is CancellationError {}
            catch {
                guard self.generation == token else { return }
                self.state.isPaused = true; self.state.status = error.localizedDescription
            }
        }
    }

    private func stableFrame(token: UUID, requireChange: Bool = true, loop: UUID? = nil) async throws -> CGImage? {
        guard let capture, let options, let acceptedSignature else { throw CancellationError() }
        let started = ContinuousClock.now
        var gate = StableFrameGate(), previous: StitchSignature?
        while generation == token, loop == nil || loopID == loop {
            try Task.checkCancellation()
            let image = try await capture.capture()
            let signature = try await signature(for: image, options: options)
            try Task.checkCancellation()
            guard generation == token, loop == nil || loopID == loop else { throw CancellationError() }
            let elapsed = started.duration(to: .now)
            let mode = requireChange ? state.mode : .automatic
            if gate.observe(previousDifference: previous.map { signature.normalizedDifference(to: $0) } ?? .infinity,
                            acceptedDifference: signature.normalizedDifference(to: acceptedSignature), elapsed: elapsed, mode: mode) {
                return image
            }
            if mode == .automatic, elapsed >= .seconds(6) { return nil }
            previous = signature
            try await Task.sleep(for: .milliseconds(120))
        }
        throw CancellationError()
    }

    private func retry() {
        guard isBusy, operationTask == nil, session != nil else { return }
        let token = generation, activeLoop = loopTask
        // Stop between frames. Cancelling an in-flight append would cancel its entire disk transaction.
        loopID = UUID(); state.isPaused = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.operationTask = nil } }
            await activeLoop?.value
            guard self.generation == token, !Task.isCancelled else { return }
            self.loopTask = nil; self.pendingImage = nil
            self.state.isPaused = false; self.state.isMatching = false; self.state.correlation = nil
            self.state.status = "正在重新检查当前页面…"; self.activateTarget()
            self.startLoop(token: token, captureCurrentFirst: true)
        }
    }

    private func switchToManual() {
        guard isBusy, operationTask == nil, session != nil else { return }
        manualReason = nil; state.mode = .manual; retry()
    }

    private func confirmOverlap(_ overlap: Int) {
        guard operationTask == nil, let image = pendingImage, let worker = session, let options,
              overlap >= 0, overlap < image.height - options.ignoredTop - options.ignoredBottom else { return }
        let token = generation
        state.status = "正在应用确认的接缝…"
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.operationTask = nil } }
            do {
                let result = try await worker.append(image, forcedOverlap: overlap)
                let signature = try await self.signature(for: image, options: options)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.pendingImage = nil; self.acceptedSignature = signature
                self.state.isPaused = false; self.state.isMatching = false; self.state.correlation = nil; self.apply(result)
                self.activateTarget(); self.startLoop(token: token)
            } catch is CancellationError {}
            catch { if self.generation == token { self.state.status = error.localizedDescription } }
        }
    }

    private func finish() {
        guard isBusy, operationTask == nil, let worker = session, let context, state.frames > 0 else { return }
        let token = generation, activeLoop = loopTask
        loopID = UUID()
        state.isPaused = true; state.isMatching = false; state.status = "正在逐行生成 PNG…"
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.operationTask = nil } }
            do {
                await activeLoop?.value
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.loopTask = nil
                self.state.isPaused = true; self.state.isMatching = false; self.state.status = "正在逐行生成 PNG…"
                let folder = AppPaths.root.appendingPathComponent("ScrollPreviews", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let output = folder.appendingPathComponent("\(UUID().uuidString).png")
                self.previewFile = output
                _ = try await worker.finish(to: output)
                let image = try await Task.detached(priority: .userInitiated) { () -> CGImage in
                    guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                        throw AppError.imageCreation
                    }
                    return image
                }.value
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.controls?.close(); self.controls = nil
                self.removeScreenObserver()
                self.session = nil; self.capture = nil; self.options = nil; self.acceptedSignature = nil; self.pendingImage = nil
                self.context = nil; self.previewFile = nil; self.isBusy = false
                self.selection.edit(image: image, pointSize: CGSize(width: CGFloat(image.width) / context.screen.scale,
                    height: CGFloat(image.height) / context.screen.scale), kind: "scroll") { [weak self] edited, editedContext in
                    var editedContext = editedContext; editedContext.appBundleID = context.appBundleID
                    self?.onCapture(edited, editedContext)
                }
                // The preview is eagerly decoded, so its temporary source can be removed when the editor closes.
                self.selection.onFinish = { _ in try? FileManager.default.removeItem(at: output) }
                CompletionNotifications.post(title: "长截图拼接完成", message: "已进入标注预览，可复制或保存。", file: output)
            } catch is CancellationError { await self.cleanup(token: token) }
            catch { await self.fail(error, token: token) }
        }
    }

    /// Stops capture before removing owned chunks and awaiting all outstanding native work.
    func cancel() async {
        if let cleanupTask { await cleanupTask.value; return }
        let token = generation, activeLoop = loopTask, operation = operationTask
        activeLoop?.cancel(); operation?.cancel()
        let cleanup = Task {
            await self.cleanup(token: token, keepBusy: true)
            await activeLoop?.value; await operation?.value
            self.isBusy = false
        }
        cleanupTask = cleanup
        await cleanup.value
        cleanupTask = nil
    }

    private func fail(_ error: Error, token: UUID) async {
        guard generation == token, !Task.isCancelled else { return }
        let ended = UUID()
        await cleanup(token: token, replacement: ended)
        // Cancellation or a newer session can arrive while the disk worker releases its chunks.
        guard generation == ended, !Task.isCancelled, cleanupTask == nil else { return }
        ErrorPresenter.show(error)
    }

    private func cleanup(token: UUID, keepBusy: Bool = false, replacement: UUID = UUID()) async {
        guard generation == token else { return }
        generation = replacement; loopID = UUID()
        let worker = session
        loopTask?.cancel(); loopTask = nil
        operationTask = nil
        setupWindow?.close(); controls?.close(); controls = nil
        removeScreenObserver()
        selection.finish()
        isBusy = true
        await worker?.cancel()
        guard generation == replacement else { return }
        if let previewFile { try? FileManager.default.removeItem(at: previewFile) }
        previewFile = nil; session = nil; capture = nil; options = nil; context = nil; acceptedSignature = nil; pendingImage = nil
        manualReason = nil
        state.isPaused = false; state.isMatching = false; state.correlation = nil
        isBusy = keepBusy
    }

    private func removeScreenObserver() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }
}
