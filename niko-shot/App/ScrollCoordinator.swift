// Connects native target selection, validated live capture, bounded stitching and the shared editor.
import AppKit
import SwiftUI
import ImageIO

/// Injectable native boundaries; production and permission-free flow tests use the same state machine.
@MainActor
struct ScrollCaptureWorkflow {
    var freezeScreens: () async throws -> [FrozenFrame]
    var windows: () async throws -> [WindowCandidate]
    var prepare: (CaptureContext) async throws -> RegionSnapshot
    var makeWorker: (ScrollCaptureOptions) -> ScrollCaptureSession = { ScrollCaptureSession(options: $0) }
    var activate: (CaptureContext) -> Void = { context in
        guard !context.appBundleID.isEmpty else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: context.appBundleID).first?.activate(options: [])
    }
    var scroll: (CGFloat, CGPoint) throws -> Void = { try AutoScroller.step(points: $0, at: $1) }
}

@MainActor
final class ScrollCoordinator {
    private let selection: SelectionSession
    private let workflow: ScrollCaptureWorkflow
    private let onCapture: (CGImage, CaptureContext) -> Void
    private let state = ScrollControlState()
    private var setupWindow: UtilityWindow?
    private var reselectionAlert: NSAlert?
    private var reselectionActions: ScrollReselectionActions?
    private var controls: ScrollControlBarController?
    private var operationTask: Task<Void, Never>?
    private var operationID: UUID?
    private var operations: [UUID: Task<Void, Never>] = [:]
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
    private var automationID: UUID?
    private var automationCompletion: ((Result<(CGImage, CaptureContext), Error>) -> Void)?
    private(set) var isBusy = false
    /// The real viewport and original window identity, including validated window translation.
    var selectedViewport: CaptureContext? { context }
    /// Scalar state for diagnostics and native workflow regression tests, with no retained pixels.
    var controlProgress: ScrollControlProgress { state.progress }
    var resourceCounts: [String: Int] {
        ["operation": operations.count, "loop": loopTask == nil ? 0 : 1,
         "cleanup": cleanupTask == nil ? 0 : 1, "capture": capture == nil ? 0 : 1,
         "worker": session == nil ? 0 : 1, "pendingImage": pendingImage == nil ? 0 : 1,
         "setup": setupWindow == nil ? 0 : 1, "controls": controls?.windowCount ?? 0,
         "reselectionAlert": reselectionAlert == nil ? 0 : 1,
         "reselectionActions": reselectionActions == nil ? 0 : 1,
         "displayObserver": screenObserver == nil ? 0 : 1,
         "automation": automationCompletion == nil ? 0 : 1]
    }

    init(engine: CaptureEngine, selection: SelectionSession, windows: WindowList,
         onCapture: @escaping (CGImage, CaptureContext) -> Void,
         capturePreview: (@MainActor (CaptureContext) async throws -> CGImage)? = nil,
         workflow: ScrollCaptureWorkflow? = nil) {
        self.selection = selection; self.onCapture = onCapture
        if let workflow { self.workflow = workflow }
        else {
            self.workflow = ScrollCaptureWorkflow(freezeScreens: { try await engine.freezeScreens() },
                windows: { try await windows.windows() }, prepare: { context in
                    if let capturePreview {
                        // Existing handoff fixtures supply one immutable live preview, with no TCC calls.
                        let image = try await capturePreview(context)
                        return RegionSnapshot(capture: { image }, validate: { context })
                    }
                    return try await engine.scrollCapture(context: context)
                })
        }
    }

    /// Uses regular target selection and editing, resuming exactly once on output or cancellation.
    func captureForAutomation() async throws -> (CGImage, CaptureContext) {
        guard !isBusy, selection.state == .idle, automationCompletion == nil else {
            throw AppError.file("已有长截图或截图会话正在进行。")
        }
        try Task.checkCancellation()
        let id = UUID(); automationID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                automationCompletion = { continuation.resume(with: $0) }
                select()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.automationID == id else { return }
                await self.cancel()
            }
        }
    }

    private func completeAutomation(_ result: Result<(CGImage, CaptureContext), Error>) {
        let callback = automationCompletion
        automationCompletion = nil; automationID = nil
        callback?(result)
    }

    /// Defaults to window highlighting; completing the mouse gesture immediately starts manual stitching.
    func select(reselecting: Bool = false) {
        guard !isBusy, operationTask == nil, selection.state == .idle else { return }
        isBusy = true
        resetProgress()
        let token = UUID(); generation = token
        launchOperation { [weak self] in
            guard let self else { return }
            do {
                await self.selection.drainPendingOperations()
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let frames = try await self.workflow.freezeScreens()
                let candidates = try await self.workflow.windows()
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.selection.start(frames: frames, candidates: candidates, kind: "window",
                    confirmationTitle: reselecting ? "选择新滚动范围" : "选择滚动窗口", directScrollSelection: true) { [weak self] _, selected in
                    guard let self, self.generation == token else { return }
                    self.beginSelected(context: selected, token: token)
                }
                self.selection.onFinish = { [weak self] completed in
                    guard let self, self.generation == token, !completed else { return }
                    self.isBusy = false
                    self.completeAutomation(.failure(CancellationError()))
                }
            } catch is CancellationError { await self.cleanup(token: token) }
            catch { await self.fail(error, token: token) }
        }
    }

    /// Reuses the original selected live viewport; annotation and frozen pixels are never appended.
    func continueFromSelection(context: CaptureContext?) {
        guard !isBusy, operationTask == nil, selection.state == .idle else { return }
        guard let context, context.hasLiveScreenRegion else { explainReselection(); return }
        isBusy = true
        resetProgress()
        let token = UUID(); generation = token
        beginSelected(context: context, token: token)
    }

    private func beginSelected(context: CaptureContext, token: UUID) {
        self.context = context
        let preceding = operationTask
        launchOperation { [weak self] in
            guard let self else { return }
            await preceding?.value
            await self.selection.drainPendingOperations()
            guard self.generation == token, !Task.isCancelled, self.selection.state == .idle else { return }
            await self.beginCapture(context: context, mode: .manual, options: ScrollCaptureOptions(), token: token)
        }
    }

    /// Tracks replaced tasks until their native or background work has actually returned.
    private func launchOperation(_ action: @escaping @MainActor () async -> Void) {
        let id = UUID(); operationID = id
        let task = Task { [weak self] in
            defer {
                self?.operations.removeValue(forKey: id)
                if self?.operationID == id { self?.operationTask = nil; self?.operationID = nil }
            }
            guard !Task.isCancelled else { return }
            await action()
        }
        operations[id] = task; operationTask = task
    }

    private func explainReselection() {
        isBusy = true
        let token = UUID(); generation = token
        let alert = NSAlert()
        alert.messageText = "重新选择长截图窗口"
        alert.informativeText = "这张图片没有正在捕获的屏幕选区。请选择当前窗口或屏幕区域，再开始长截图。"
        alert.alertStyle = .informational
        let choose = alert.addButton(withTitle: "选择窗口或区域")
        choose.keyEquivalent = "\r"; choose.tag = 1
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\u{1b}"; cancel.tag = 0
        let actions = ScrollReselectionActions { [weak self] accepted in
            guard let self, self.generation == token else { return }
            self.closeReselectionAlert(); self.isBusy = false
            if accepted { self.select(reselecting: true) }
            else { self.completeAutomation(.failure(CancellationError())) }
        }
        alert.layout()
        for button in alert.buttons { button.target = actions; button.action = #selector(ScrollReselectionActions.respond(_:)) }
        reselectionAlert = alert; reselectionActions = actions
        alert.window.isReleasedWhenClosed = false; alert.window.styleMask.insert(.closable); alert.window.delegate = actions
        alert.window.center(); alert.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func closeReselectionAlert() {
        guard let alert = reselectionAlert else { return }
        reselectionAlert = nil; reselectionActions?.onResponse = nil; reselectionActions = nil
        alert.window.delegate = nil
        for button in alert.buttons { button.target = nil; button.action = nil }
        alert.window.orderOut(nil); alert.window.close()
    }

    /// Advanced controls are explicit; applying them starts a fresh transaction instead of reusing chunks.
    func showSetup(image: CGImage, context: CaptureContext) {
        guard selection.state == .idle, setupWindow == nil else { return }
        guard context.hasLiveScreenRegion else { explainReselection(); return }
        self.context = context; isBusy = true
        let hadSession = session != nil
        let wasPaused = state.isPaused
        state.isPaused = hadSession
        let window = UtilityWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 660),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "长截图高级选项"; window.isReleasedWhenClosed = false
        window.onClose = { [weak self] in
            guard let self else { return }
            self.setupWindow = nil
            if hadSession {
                if !wasPaused && !self.state.requiresRestart && !self.state.requiresReselection { self.retry() }
            } else {
                self.context = nil; self.capture = nil; self.isBusy = false
                self.completeAutomation(.failure(CancellationError()))
            }
        }
        window.contentView = NSHostingView(rootView: ScrollSetupView(image: image, scale: context.screen.scale,
            automaticAllowed: AutoScroller.isAuthorized, onStart: { [weak self] mode, top, bottom in
                guard let self else { return }
                self.setupWindow?.onClose = nil; self.setupWindow?.close(); self.setupWindow = nil
                self.restart(context: context, mode: mode, options: ScrollCaptureOptions(ignoredTop: top, ignoredBottom: bottom))
            }, onOpenAccessibility: { AutoScroller.openSettings() }, onCancel: { [weak self] in self?.setupWindow?.close() },
            initialMode: state.mode, ignoredTop: options?.ignoredTop ?? 0, ignoredBottom: options?.ignoredBottom ?? 0,
            isRestart: hadSession))
        setupWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func beginCapture(context: CaptureContext, mode: ScrollCaptureMode, options: ScrollCaptureOptions, token: UUID) async {
        self.context = context; self.options = options; isBusy = true
        state.mode = mode; state.height = 0; state.frames = 0; state.isPaused = false; state.isMatching = false
        state.isWorking = true; state.requiresRestart = false; state.requiresReselection = false; state.isBacktracking = false
        state.correlation = nil; state.overlap = 150; state.status = "正在捕获首屏…"
        state.ignoredTop = options.ignoredTop; state.ignoredBottom = options.ignoredBottom
        if mode == .automatic, !AutoScroller.isAuthorized, !AutoScroller.requestAuthorization() {
            state.mode = .manual
            state.status = "辅助功能未授权，请自行向下滚动。"
        }
        let worker = workflow.makeWorker(options); session = worker
        if controls == nil {
            controls = ScrollControlBarController(state: state, onFinish: { [weak self] in self?.finish() },
                onCancel: { [weak self] in Task { await self?.cancel() } }, onRetry: { [weak self] in self?.retry() },
                onManualOverlap: { [weak self] in self?.confirmOverlap($0) }, onManualMode: { [weak self] in self?.switchToManual() },
                onAdvancedSettings: { [weak self] in self?.openAdvanced() },
                onAutomaticMode: { [weak self] in self?.switchToAutomatic() }, onPause: { [weak self] in self?.pause() })
        }
        controls?.show(near: context.globalRect)
        do {
            let prepared = try await workflow.prepare(context)
            try Task.checkCancellation()
            guard generation == token else { return }
            capture = prepared
            try updateValidatedContext()
            workflow.activate(self.context ?? context)
            try await Task.sleep(for: .milliseconds(150))
            let provisional = try await prepared.capture()
            acceptedSignature = try await signature(for: provisional, options: options)
            guard let image = try await stableFrame(token: token, requireChange: false) else {
                throw AppError.file("首屏仍在移动，请稳定页面后重试。")
            }
            guard image.height - options.ignoredTop - options.ignoredBottom >= 240 else {
                throw AppError.file("请保留至少 240 像素高的滚动内容。")
            }
            let result = try await worker.append(image)
            let signature = try await signature(for: image, options: options)
            try Task.checkCancellation()
            guard generation == token else { return }
            acceptedSignature = signature; apply(result)
            state.maximumOverlap = image.height - options.ignoredTop - options.ignoredBottom - 1
            state.isWorking = false
            installScreenObserver()
            startLoop(token: token)
        } catch is CancellationError {
            if !Task.isCancelled { await handleCaptureError(CancellationError(), token: token) }
        } catch {
            if let native = error as? AppError, case .permission = native { await fail(error, token: token) }
            else { await handleCaptureError(error, token: token) }
        }
    }

    private func updateValidatedContext(forAutomaticScroll: Bool = false) throws {
        if let current = try capture?.validatedContext(forAutomaticScroll: forAutomaticScroll) { context = current }
    }

    private func signature(for image: CGImage, options: ScrollCaptureOptions) async throws -> StitchSignature {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try Stitcher.signature(for: image, ignoringTop: options.ignoredTop, ignoringBottom: options.ignoredBottom)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func apply(_ result: ScrollAppendResult) {
        if case .appended(let height, let frames) = result {
            state.height = height; state.frames = frames; state.isBacktracking = false
            if !state.isPaused {
                state.status = state.mode == .manual ? "向下滚动，稳定后自动拼接。" : "页面稳定后继续自动滚动…"
            }
        }
    }

    private func startLoop(token: UUID, captureCurrentFirst: Bool = false) {
        guard loopTask == nil, !state.requiresRestart, !state.requiresReselection else { return }
        let id = UUID(); loopID = id
        loopTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token, self.loopID == id { self.loopTask = nil } }
            var currentFirst = captureCurrentFirst, duplicates = 0
            do {
                while self.generation == token, self.loopID == id, !self.state.isPaused, !self.state.isMatching {
                    try Task.checkCancellation()
                    guard let worker = self.session, let options = self.options else { return }
                    try self.updateValidatedContext(forAutomaticScroll: self.state.mode == .automatic && !currentFirst)
                    guard let context = self.context else { return }
                    if self.state.mode == .automatic, !currentFirst {
                        let height = context.localRect.height * context.screen.scale - CGFloat(options.ignoredTop + options.ignoredBottom)
                        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                        let location = CGPoint(x: context.globalRect.midX, y: CoordinateSpace.flippedY(context.globalRect.midY, primaryTop: primaryTop))
                        do { try self.workflow.scroll(max(1, (height - 150) / context.screen.scale), location) }
                        catch {
                            self.state.mode = .manual
                            self.state.status = "自动滚动不可用，请自行向下滚动。"
                        }
                    }
                    currentFirst = false
                    guard let image = try await self.stableFrame(token: token, loop: id) else {
                        self.state.isPaused = true; self.state.status = "页面仍在移动，请稳定后重试。"; return
                    }
                    let result = try await worker.append(image)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    switch result {
                    case .appended:
                        let signature = try await self.signature(for: image, options: options)
                        guard self.generation == token else { return }
                        duplicates = 0; self.acceptedSignature = signature; self.apply(result)
                    case .duplicate:
                        guard self.loopID == id else { return }
                        if self.state.isBacktracking {
                            self.state.isBacktracking = false; self.state.status = "已回到捕获边界，请继续向下滚动。"
                        }
                        if self.state.mode == .automatic {
                            duplicates += 1
                            if duplicates >= 2 { self.state.status = "已到底，正在生成长图…"; self.finish(); return }
                            self.state.status = "页面没有变化，正在确认是否到底…"
                        }
                    case .backtracking:
                        guard self.loopID == id else { return }
                        self.state.isBacktracking = true
                        self.state.status = "正在向上浏览；请回到已捕获位置后继续向下。"
                    case .needsConfirmation(let match):
                        guard self.loopID == id else { return }
                        self.pendingImage = image; self.state.isMatching = true; self.state.isPaused = true; self.state.showsAdvanced = true
                        self.state.correlation = match.correlation; self.state.overlap = match.overlap
                        self.state.maximumOverlap = image.height - options.ignoredTop - options.ignoredBottom - 1
                        self.state.status = match.isAmbiguous ? "接缝存在重复纹理，请在高级操作中确认。" : "接缝相关度不足，请在高级操作中确认。"
                        return
                    }
                }
            } catch is CancellationError {}
            catch { await self.handleCaptureError(error, token: token) }
        }
    }

    private func stableFrame(token: UUID, requireChange: Bool = true, loop: UUID? = nil) async throws -> CGImage? {
        guard let capture, let options, let acceptedSignature else { throw CancellationError() }
        let started = ContinuousClock.now
        var gate = StableFrameGate(), previous: StitchSignature?
        while generation == token, loop == nil || loopID == loop {
            try Task.checkCancellation()
            try updateValidatedContext()
            let image = try await capture.capture()
            let signature = try await signature(for: image, options: options)
            try Task.checkCancellation()
            guard generation == token, loop == nil || loopID == loop else { throw CancellationError() }
            let elapsed = started.duration(to: .now)
            let mode = requireChange && !state.isBacktracking ? state.mode : .automatic
            if gate.observe(previousDifference: previous.map { signature.normalizedDifference(to: $0) } ?? .infinity,
                            acceptedDifference: signature.normalizedDifference(to: acceptedSignature), elapsed: elapsed, mode: mode) { return image }
            if mode == .automatic, elapsed >= .seconds(6) { return nil }
            previous = signature
            try await Task.sleep(for: .milliseconds(120))
        }
        throw CancellationError()
    }

    private func handleCaptureError(_ error: Error, token: UUID) async {
        guard generation == token, !Task.isCancelled else { return }
        let progress = await session?.progress
        guard generation == token, !Task.isCancelled else { return }
        state.isWorking = false; state.isPaused = true
        state.requiresRestart = progress.map { [.failed, .cancelled, .completed, .finishing].contains($0.state) } ?? false
        state.requiresReselection = (error as? ScrollTargetError)?.requiresReselection == true
        state.isMatching = false; pendingImage = nil; state.correlation = nil
        if state.requiresRestart {
            state.status = "拼接会话已结束：\(error.localizedDescription) 请重新开始；此前分块不会沿用。"
        } else { state.status = error.localizedDescription }
    }

    /// Retries a recoverable capture, while terminal workers require a new transaction.
    func retry() {
        guard isBusy, operationTask == nil, session != nil else { return }
        if state.requiresReselection { reselect(); return }
        if state.requiresRestart {
            guard let context, let options else { return }
            restart(context: context, mode: state.mode, options: options); return
        }
        let token = generation, activeLoop = loopTask
        loopID = UUID(); state.isPaused = true
        launchOperation { [weak self] in
            guard let self else { return }
            await activeLoop?.value
            guard self.generation == token, !Task.isCancelled, let worker = self.session else { return }
            self.loopTask = nil
            let progress = await worker.progress
            guard self.generation == token, !Task.isCancelled else { return }
            if [.failed, .cancelled, .completed, .finishing].contains(progress.state) {
                self.state.requiresRestart = true; self.state.status = "拼接会话已结束，请重新开始；此前分块不会沿用。"; return
            }
            if progress.frames == 0 {
                guard let context = self.context, let options = self.options else { return }
                await worker.cancel(); self.session = nil; self.capture = nil
                await self.beginCapture(context: context, mode: self.state.mode, options: options, token: token)
                return
            }
            self.pendingImage = nil; self.state.isPaused = false; self.state.isMatching = false; self.state.correlation = nil
            self.state.status = "正在重新检查当前页面…"
            if let context = self.context { self.workflow.activate(context) }
            self.startLoop(token: token, captureCurrentFirst: true)
        }
    }

    private func pause() {
        guard operationTask == nil, session != nil, !state.isPaused else { return }
        let token = generation, activeLoop = loopTask
        loopID = UUID(); state.isPaused = true; state.status = "已暂停。可继续，或在高级选项中从首屏重新配置。"
        launchOperation { [weak self] in
            await activeLoop?.value
            guard let self, self.generation == token else { return }
            self.loopTask = nil
        }
    }

    private func switchToManual() {
        guard isBusy, operationTask == nil, session != nil else { return }
        state.mode = .manual
        if !state.requiresRestart, !state.requiresReselection { retry() }
    }

    private func switchToAutomatic() {
        guard isBusy, operationTask == nil, session != nil, !state.requiresRestart, !state.requiresReselection else { return }
        guard AutoScroller.isAuthorized || AutoScroller.requestAuthorization() else {
            state.status = "辅助功能未授权，继续手动滚动；高级选项可打开权限设置。"; return
        }
        state.mode = .automatic; retry()
    }

    private func openAdvanced() {
        guard operationTask == nil, setupWindow == nil, let context, let capture else { return }
        let token = generation, activeLoop = loopTask, wasPaused = state.isPaused
        loopID = UUID(); state.isPaused = true
        launchOperation { [weak self] in
            guard let self else { return }
            await activeLoop?.value
            guard self.generation == token, !Task.isCancelled else { return }
            self.loopTask = nil
            do {
                let image = try await capture.capture()
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.state.isPaused = wasPaused
                self.showSetup(image: image, context: context)
            } catch { await self.handleCaptureError(error, token: token) }
        }
    }

    private func restart(context: CaptureContext, mode: ScrollCaptureMode, options: ScrollCaptureOptions) {
        guard operationTask == nil, selection.state == .idle else { return }
        let token = UUID(), activeLoop = loopTask, worker = session
        generation = token; loopID = UUID(); state.isPaused = true
        launchOperation { [weak self] in
            guard let self else { return }
            await activeLoop?.value; await worker?.cancel()
            guard self.generation == token, !Task.isCancelled else { return }
            self.loopTask = nil; self.session = nil; self.capture = nil; self.pendingImage = nil; self.acceptedSignature = nil
            self.removeScreenObserver()
            await self.beginCapture(context: context, mode: mode, options: options, token: token)
        }
    }

    private func reselect() {
        let token = generation
        launchOperation { [weak self] in
            guard let self else { return }
            await self.cleanup(token: token, complete: false)
            guard !Task.isCancelled else { return }
            // The selector starts after this operation retires, through the same tracked handoff.
            self.operationTask = nil; self.operationID = nil
            self.select(reselecting: true)
        }
    }

    private func confirmOverlap(_ overlap: Int) {
        guard operationTask == nil, let image = pendingImage, let worker = session, let options,
              !state.requiresRestart, !state.requiresReselection,
              overlap >= 0, overlap < image.height - options.ignoredTop - options.ignoredBottom else { return }
        let token = generation
        state.isWorking = true; state.status = "正在应用确认的接缝…"
        launchOperation { [weak self] in
            guard let self else { return }
            do {
                let result = try await worker.append(image, forcedOverlap: overlap)
                let signature = try await self.signature(for: image, options: options)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.loopTask = nil; self.pendingImage = nil; self.acceptedSignature = signature
                self.state.isWorking = false; self.state.isPaused = false; self.state.isMatching = false; self.state.correlation = nil; self.apply(result)
                if let context = self.context { self.workflow.activate(context) }
                self.startLoop(token: token)
            } catch { await self.handleCaptureError(error, token: token) }
        }
    }

    /// Completes accepted content and reuses the annotation editor, even when a later capture is paused.
    func finish() {
        guard isBusy, operationTask == nil, let worker = session, let context, state.frames > 0, !state.requiresRestart else { return }
        let token = generation, activeLoop = loopTask
        loopID = UUID(); state.isPaused = true; state.isMatching = false; state.isWorking = true; state.status = "正在逐行生成 PNG…"
        launchOperation { [weak self] in
            guard let self else { return }
            do {
                await activeLoop?.value
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.loopTask = nil
                let folder = AppPaths.root.appendingPathComponent("ScrollPreviews", isDirectory: true)
                let output = folder.appendingPathComponent("\(UUID().uuidString).png")
                self.previewFile = output
                _ = try await worker.finish(to: output)
                let decode = Task.detached(priority: .userInitiated) { () throws -> CGImage in
                    try Task.checkCancellation()
                    guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw AppError.imageCreation }
                    return image
                }
                let image = try await withTaskCancellationHandler { try await decode.value } onCancel: { decode.cancel() }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.controls?.close(); self.controls = nil; self.removeScreenObserver()
                self.session = nil; self.capture = nil; self.options = nil; self.acceptedSignature = nil; self.pendingImage = nil
                self.context = nil; self.previewFile = nil; self.isBusy = false; self.state.isWorking = false
                self.selection.edit(image: image, pointSize: CGSize(width: CGFloat(image.width) / context.screen.scale,
                    height: CGFloat(image.height) / context.screen.scale), kind: "scroll") { [weak self] edited, editedContext in
                    var editedContext = editedContext; editedContext.appBundleID = context.appBundleID
                    guard let self else { return }
                    if self.automationCompletion != nil { self.completeAutomation(.success((edited, editedContext))) }
                    else { self.onCapture(edited, editedContext) }
                }
                self.selection.onFinish = { [weak self] completed in
                    try? FileManager.default.removeItem(at: output)
                    if !completed { self?.completeAutomation(.failure(CancellationError())) }
                }
                CompletionNotifications.post(title: "长截图拼接完成", message: "已进入标注预览，可复制或保存。", file: output)
            } catch is CancellationError { await self.cleanup(token: token) }
            catch { await self.fail(error, token: token) }
        }
    }

    /// Cancels promptly, then drains replaced operations and native requests before reporting zero resources.
    func cancel() async {
        if let cleanupTask { await cleanupTask.value; return }
        closeReselectionAlert()
        let token = generation, activeLoop = loopTask, pending = Array(operations.values)
        activeLoop?.cancel(); for task in pending { task.cancel() }
        let cleanup = Task {
            await self.cleanup(token: token, keepBusy: true)
            await activeLoop?.value
            for task in pending { await task.value }
            await self.selection.drainPendingOperations()
            self.isBusy = false
        }
        cleanupTask = cleanup
        await cleanup.value; cleanupTask = nil
    }

    private func fail(_ error: Error, token: UUID) async {
        guard generation == token, !Task.isCancelled else { return }
        let automated = automationCompletion != nil, ended = UUID()
        await cleanup(token: token, replacement: ended, error: error)
        guard !automated, generation == ended, !Task.isCancelled, cleanupTask == nil else { return }
        // Keep errors cancellable through the main run loop, including during application termination.
        isBusy = true
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "长截图未能开始"; alert.informativeText = error.localizedDescription
        let dismiss = alert.addButton(withTitle: "关闭"); dismiss.tag = 0; dismiss.keyEquivalent = "\r"
        if let native = error as? AppError, case .permission = native {
            let settings = alert.addButton(withTitle: "打开系统设置"); settings.tag = 1
        }
        let actions = ScrollReselectionActions { [weak self] openSettings in
            guard let self, self.generation == ended else { return }
            self.closeReselectionAlert(); self.isBusy = false
            if openSettings, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        alert.layout()
        for button in alert.buttons { button.target = actions; button.action = #selector(ScrollReselectionActions.respond(_:)) }
        reselectionAlert = alert; reselectionActions = actions
        alert.window.isReleasedWhenClosed = false; alert.window.styleMask.insert(.closable); alert.window.delegate = actions
        alert.window.center(); alert.window.makeKeyAndOrderFront(nil)
    }

    private func cleanup(token: UUID, keepBusy: Bool = false, replacement: UUID = UUID(), error: Error? = nil, complete: Bool = true) async {
        guard generation == token else { return }
        generation = replacement; loopID = UUID()
        let worker = session, activeLoop = loopTask
        activeLoop?.cancel()
        closeReselectionAlert()
        setupWindow?.onClose = nil; setupWindow?.close(); setupWindow = nil
        controls?.close(); controls = nil; removeScreenObserver()
        selection.finish(); isBusy = true
        await activeLoop?.value
        await worker?.cancel()
        guard generation == replacement else { return }
        loopTask = nil
        if let previewFile { try? FileManager.default.removeItem(at: previewFile) }
        previewFile = nil; session = nil; capture = nil; options = nil; context = nil; acceptedSignature = nil; pendingImage = nil
        resetProgress()
        isBusy = keepBusy
        if complete { completeAutomation(.failure(error ?? CancellationError())) }
    }

    private func resetProgress() {
        state.isPaused = false; state.isMatching = false; state.isWorking = false; state.correlation = nil
        state.requiresRestart = false; state.requiresReselection = false; state.isBacktracking = false
        state.height = 0; state.frames = 0; state.showsAdvanced = false
        state.ignoredTop = 0; state.ignoredBottom = 0; state.overlap = 150; state.maximumOverlap = 199
        state.mode = .manual; state.status = "准备选择滚动窗口"
    }

    private func installScreenObserver() {
        removeScreenObserver()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.loopID = UUID(); self.state.isPaused = true; self.state.requiresReselection = true
                self.state.status = ScrollTargetError.displayChanged.localizedDescription
            }
        }
    }

    private func removeScreenObserver() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }
}

/// Routes native alert controls without an application-modal loop that would block async cancellation.
@MainActor
private final class ScrollReselectionActions: NSObject, NSWindowDelegate {
    var onResponse: ((Bool) -> Void)?
    init(onResponse: @escaping (Bool) -> Void) { self.onResponse = onResponse; super.init() }
    @objc func respond(_ sender: NSButton) { onResponse?(sender.tag == 1) }
    func windowWillClose(_ notification: Notification) { onResponse?(false) }
}
