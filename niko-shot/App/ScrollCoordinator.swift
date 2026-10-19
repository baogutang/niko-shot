// Drives long captures: target selection, input-paced viewport snapshots, stitching and the editor handoff.
import AppKit
import Carbon

/// Injectable native boundaries; production and permission-free flow tests share the same state machine.
@MainActor
struct ScrollCaptureWorkflow {
    var freezeScreens: () async throws -> [FrozenFrame]
    var windows: () async throws -> [WindowCandidate]
    var resolveViewport: (CaptureContext) async -> CaptureContext = { $0 }
    /// Creates a validated single-frame source; the second argument is our overlay's window on that display.
    var prepareSource: (CaptureContext, CGWindowID?) async throws -> RegionSnapshot
    var activate: (CaptureContext) -> Void = { context in
        guard !context.appBundleID.isEmpty else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: context.appBundleID).first?.activate(options: [])
    }
    var scroll: (CGFloat, CGPoint) throws -> Void = { try AutoScroller.step(points: $0, at: $1) }
    var isAutoScrollAuthorized: () -> Bool = { AutoScroller.isAuthorized }
    var requestAutoScrollPermission: () -> Void = { PermissionGuide.shared.present(.accessibility, reason: "自动滚动长截图") }
    /// Delay after the last scroll input before collecting a settled frame.
    var settleDelays: [Duration] = [.milliseconds(110), .milliseconds(320)]
    var activationDelay: Duration = .milliseconds(140)
    var showsChrome = true
}

@MainActor
final class ScrollCoordinator {
    private let selection: SelectionSession
    private let workflow: ScrollCaptureWorkflow
    private let onCapture: (CGImage, CaptureContext) -> Void
    let state = ScrollControlState()
    private(set) var isBusy = false
    private var generation = UUID()
    private var selecting = false
    private(set) var context: CaptureContext?
    private var source: RegionSnapshot?
    private var worker: ScrollStitchWorker?
    private var overlay: ScrollSelectionOverlayController?
    private var controls: ScrollControlBarController?
    private var preview: ScrollPreviewPanelController?
    private let monitor = ScrollEventMonitor()
    private let keys = TransientHotkeys()
    private var startTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var capturePending = false
    private var hintPoints: CGFloat = 0
    private var hintPrecise = true
    private var unmatchedStreak = 0
    private var lastScrollInput: ContinuousClock.Instant = .now
    /// Quiet time after the last scroll input before an unmatched frame counts as real;
    /// momentum frames render at sub-pixel offsets and fail row equality while still moving.
    /// Internal so tests can pin the boundary deterministically.
    var mismatchSettle: Duration = .milliseconds(300)
    private var stalledDownward = 0
    private var screenObserver: NSObjectProtocol?
    private var automationID: UUID?
    private var automationCompletion: ((Result<(CGImage, CaptureContext), Error>) -> Void)?

    var selectedViewport: CaptureContext? { context }
    var resourceCounts: [String: Int] {
        ["start": startTask == nil ? 0 : 1, "capture": captureTask == nil ? 0 : 1,
         "settle": settleTask == nil ? 0 : 1, "auto": autoTask == nil ? 0 : 1, "finish": finishTask == nil ? 0 : 1,
         "source": source == nil ? 0 : 1, "worker": worker == nil ? 0 : 1,
         "controls": controls?.windowCount ?? 0, "preview": preview?.windowCount ?? 0,
         "overlay": overlay?.windowCount ?? 0, "monitors": monitor.monitorCount, "hotkeys": keys.count,
         "displayObserver": screenObserver == nil ? 0 : 1, "automation": automationCompletion == nil ? 0 : 1]
    }

    init(engine: CaptureEngine, selection: SelectionSession, windows: WindowList,
         onCapture: @escaping (CGImage, CaptureContext) -> Void, workflow: ScrollCaptureWorkflow? = nil) {
        self.selection = selection
        self.onCapture = onCapture
        self.workflow = workflow ?? ScrollCaptureWorkflow(
            freezeScreens: { try await engine.freezeScreens() },
            windows: { try await windows.windows() },
            resolveViewport: { await ScrollViewportResolver.resolve($0) },
            prepareSource: { context, overlayID in
                try await WindowFrameGrabber().prepare(context: context, ownWindowID: overlayID)
            })
    }

    // MARK: - Entry points

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

    /// Highlights windows; a click starts at once, a dragged region starts on release.
    func select() {
        guard !isBusy, selection.state == .idle else { return }
        isBusy = true; selecting = true
        state.reset()
        let token = UUID(); generation = token
        startTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.startTask = nil } }
            do {
                await self.selection.drainPendingOperations()
                let frames = try await self.workflow.freezeScreens()
                let candidates = try await self.workflow.windows()
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.selection.start(frames: frames, candidates: candidates, kind: "window",
                                     confirmationTitle: "开始长截图", directScrollSelection: true) { [weak self] _, selected in
                    guard let self, self.generation == token else { return }
                    self.selecting = false
                    self.begin(context: selected, token: token)
                }
                self.selection.onFinish = { [weak self] completed in
                    guard let self, self.generation == token, !completed else { return }
                    self.selecting = false
                    self.reset()
                    self.completeAutomation(.failure(CancellationError()))
                }
            } catch is CancellationError {
                guard self.generation == token else { return }
                self.reset(); self.completeAutomation(.failure(CancellationError()))
            } catch {
                guard self.generation == token else { return }
                self.fail(error)
            }
        }
    }

    /// Continues from a screenshot selection; imported images have no live region and must reselect.
    func continueFromSelection(context: CaptureContext?) {
        guard !isBusy, selection.state == .idle else { return }
        guard let context, context.hasLiveScreenRegion else { explainReselection(); return }
        isBusy = true
        state.reset()
        let token = UUID(); generation = token
        begin(context: context, token: token)
    }

    private func explainReselection() {
        let alert = NSAlert()
        alert.messageText = "选择要长截图的窗口或区域"
        alert.informativeText = "历史图片或导入图片没有对应的屏幕位置。请在屏幕上重新选择要滚动的内容。"
        alert.addButton(withTitle: "选择窗口或区域")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { select() }
        else { completeAutomation(.failure(CancellationError())) }
    }

    // MARK: - Session

    private func begin(context initial: CaptureContext, token: UUID) {
        startTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.startTask = nil } }
            await self.selection.drainPendingOperations()
            guard self.generation == token, !Task.isCancelled else { return }
            let context = await self.workflow.resolveViewport(initial)
            guard self.generation == token, !Task.isCancelled else { return }
            self.context = context
            self.presentChrome(for: context)
            do {
                let overlayID = self.overlay?.frames.first { $0.screenFrame == context.screen.frame }.map { CGWindowID($0.windowNumber) }
                let source = try await self.workflow.prepareSource(context, overlayID)
                guard self.generation == token, !Task.isCancelled else { await source.stop(); return }
                self.source = source
                self.worker = ScrollStitchWorker(pixelsPerPoint: context.screen.scale)
                self.workflow.activate(context)
                try await Task.sleep(for: self.workflow.activationDelay)
                guard self.generation == token else { return }
                self.state.phase = .capturing
                self.setStatus("正在长截图", "向下滚动内容，自动拼接；完成后点「完成」或按 ↩")
                self.startInputs(token: token)
                self.requestCapture()
            } catch is CancellationError {
            } catch {
                guard self.generation == token else { return }
                self.fail(error)
            }
        }
    }

    private func presentChrome(for context: CaptureContext) {
        guard workflow.showsChrome else { return }
        let overlay = self.overlay ?? ScrollSelectionOverlayController()
        overlay.show(context: context)
        self.overlay = overlay
        let controls = self.controls ?? ScrollControlBarController(state: state,
            onFinish: { [weak self] in self?.finish() },
            onCancel: { [weak self] in Task { await self?.cancel() } },
            onToggleAutomatic: { [weak self] in self?.toggleAutomatic() },
            onTogglePreview: { [weak self] in self?.togglePreview() })
        controls.show(near: context.globalRect)
        self.controls = controls
        if preview == nil { preview = ScrollPreviewPanelController(state: state) }
        if state.showsPreview { preview?.show(near: context.globalRect, avoiding: controls.panelFrame) }
    }

    private func startInputs(token: UUID) {
        guard let context else { return }
        monitor.start(viewport: context.globalRect) { [weak self] activity in
            guard let self, self.generation == token else { return }
            self.receive(activity)
        }
        keys.register([(kVK_Escape, { [weak self] in Task { await self?.cancel() } }),
                       (kVK_Return, { [weak self] in self?.finish() }),
                       (kVK_ANSI_KeypadEnter, { [weak self] in self?.finish() })])
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.phase == .capturing else { return }
                self.stopAutomatic()
                self.setStatus("显示器已变化", "已保留拼好的内容，可点「完成」或重新开始", tone: .warning)
            }
        }
    }

    private func stopInputs() {
        monitor.stop()
        keys.unregister()
        settleTask?.cancel(); settleTask = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    /// Activity from the user's wheel, scroll-bar drag or paging keys; automatic steps arrive tagged.
    func receive(_ activity: ScrollActivity) {
        guard state.phase == .capturing else { return }
        if state.isAutomatic {
            if !activity.isSynthetic { stopAutomatic(); setStatus("已切换为手动", "检测到手动滚动，继续向下滚动即可") }
            return
        }
        if let points = activity.preciseDownwardPoints { hintPoints += points } else { hintPrecise = false }
        lastScrollInput = .now
        requestCapture()
        settleTask?.cancel()
        let delays = workflow.settleDelays
        settleTask = Task { [weak self] in
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.requestCapture()
            }
            self?.settleTask = nil
        }
    }

    // MARK: - Capturing

    private func requestCapture() {
        capturePending = true
        guard captureTask == nil, state.phase == .capturing, !state.isAutomatic else { return }
        let token = generation
        captureTask = Task { [weak self] in
            guard let self else { return }
            while self.capturePending, self.generation == token, self.state.phase == .capturing, !Task.isCancelled {
                self.capturePending = false
                _ = await self.captureOnce(token: token)
            }
            if self.generation == token { self.captureTask = nil }
        }
    }

    @discardableResult
    private func captureOnce(token: UUID) async -> ScrollStitchResult? {
        guard let source, let worker else { return nil }
        let hint = takeHint()
        do {
            try refreshGeometry()
            let image = try await source.capture()
            guard generation == token, !Task.isCancelled else { return nil }
            let update = try await worker.add(image, hint: hint)
            guard generation == token else { return nil }
            apply(update, hint: hint)
            return update.result
        } catch is CancellationError {
            return nil
        } catch {
            guard generation == token else { return nil }
            handleCaptureError(error)
            return nil
        }
    }

    private func takeHint() -> Int? {
        defer { hintPoints = 0; hintPrecise = true }
        guard hintPrecise, hintPoints != 0, let scale = context?.screen.scale else { return nil }
        return Int((hintPoints * scale).rounded())
    }

    private func refreshGeometry() throws {
        guard let current = try source?.validatedContext(), let previous = context,
              current.globalRect != previous.globalRect else { return }
        context = current
        monitor.update(viewport: current.globalRect)
        overlay?.update(context: current)
        controls?.show(near: current.globalRect)
        if state.showsPreview { preview?.show(near: current.globalRect, avoiding: controls?.panelFrame) }
    }

    private func apply(_ update: ScrollStitchUpdate, hint: Int?) {
        state.width = update.width; state.height = update.height; state.frames = update.frames
        if let preview = update.preview { state.preview = preview }
        guard state.phase == .capturing else { return }
        let automatic = state.isAutomatic
        switch update.result {
        case .appended:
            unmatchedStreak = 0; stalledDownward = 0
            if update.firstFrameUniform {
                setStatus("选区几乎是纯色", "请确认选中的是可滚动的内容区域", tone: .warning)
            } else if automatic {
                setStatus("正在自动滚动", "到底后自动完成，可随时暂停")
            } else {
                setStatus("正在长截图", "继续向下滚动；完成后点「完成」或按 ↩")
            }
        case .unchanged:
            unmatchedStreak = 0
            if !automatic, (hint ?? 0) > 0 || !hintPrecise {
                stalledDownward += 1
                if stalledDownward >= 3 { setStatus("似乎已到底部", "点「完成」结束，或继续滚动", tone: .success) }
            }
        case .reversed:
            unmatchedStreak = 0
            setStatus("正在向上浏览", "不会重复拼接；回到末尾后继续向下即可")
        case .unmatched:
            // 惯性滚动尚未平息时的失配帧不计入警告；等稳定后的帧仍对不上才提示。
            if automatic || ContinuousClock.now - lastScrollInput >= mismatchSettle {
                unmatchedStreak += 1
            }
            if unmatchedStreak >= 2 {
                setStatus("画面没对上", "滚动太快或内容在变化，请向上回滚一点再继续", tone: .warning)
            }
        case .limitReached:
            setStatus("已达到长图上限", "正在生成长图…", tone: .success)
            finish()
        }
    }

    private func setStatus(_ title: String, _ message: String, tone: ScrollControlState.Tone = .normal) {
        state.title = title; state.message = message; state.tone = tone
    }

    private func handleCaptureError(_ error: Error) {
        stopAutomatic()
        if let native = error as? AppError, case .permission = native { fail(error); return }
        let message = error.localizedDescription
        setStatus("捕获已暂停", message, tone: .warning)
    }

    // MARK: - Automatic scrolling

    func toggleAutomatic() {
        guard state.phase == .capturing else { return }
        if state.isAutomatic {
            stopAutomatic()
            setStatus("已暂停自动滚动", "可以手动继续滚动，或点「完成」")
            return
        }
        guard workflow.isAutoScrollAuthorized() else {
            workflow.requestAutoScrollPermission()
            setStatus("需要辅助功能权限", "授权后再点「自动」；也可以直接手动滚动", tone: .warning)
            return
        }
        state.isAutomatic = true
        settleTask?.cancel(); settleTask = nil
        setStatus("正在自动滚动", "到底后自动完成，可随时暂停")
        let token = generation
        autoTask = Task { [weak self] in
            await self?.runAutomatic(token: token)
            if self?.generation == token { self?.autoTask = nil }
        }
    }

    private func stopAutomatic() {
        state.isAutomatic = false
        autoTask?.cancel()
    }

    private func runAutomatic(token: UUID) async {
        await captureTask?.value
        var factor: CGFloat = 0.42, stalls = 0
        while generation == token, state.isAutomatic, state.phase == .capturing, !Task.isCancelled {
            guard let context, let source else { return }
            let points = max(24, context.localRect.height * factor)
            do {
                _ = try source.validatedContext(forAutomaticScroll: true)
                let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                let point = CGPoint(x: context.globalRect.midX, y: CoordinateSpace.flippedY(context.globalRect.midY, primaryTop: primaryTop))
                try workflow.scroll(points, point)
            } catch {
                guard generation == token else { return }
                stopAutomatic()
                setStatus("自动滚动已停止", error.localizedDescription, tone: .warning)
                return
            }
            hintPoints = points; hintPrecise = true
            try? await Task.sleep(for: .milliseconds(170))
            guard generation == token, state.isAutomatic, !Task.isCancelled else { return }
            switch await captureOnce(token: token) {
            case .appended?:
                stalls = 0; factor = min(0.42, factor * 1.25)
            case .unchanged?:
                stalls += 1
                if stalls >= 3 {
                    setStatus("已到底部", "正在生成长图…", tone: .success)
                    state.isAutomatic = false
                    finish()
                    return
                }
            case .unmatched?:
                // 应用把像素步长放大时会丢失重叠：退回一点，并缩小后续步长。
                factor = max(0.12, factor * 0.5)
                let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                let point = CGPoint(x: context.globalRect.midX, y: CoordinateSpace.flippedY(context.globalRect.midY, primaryTop: primaryTop))
                try? workflow.scroll(-points * 0.6, point)
                try? await Task.sleep(for: .milliseconds(170))
                _ = await captureOnce(token: token)
            case .reversed?, nil:
                break
            case .limitReached?:
                return
            }
        }
    }

    // MARK: - Completion

    /// Collects one settled frame, composes the long image and opens it in the shared editor.
    func finish() {
        guard state.canFinish, finishTask == nil, let context else { return }
        let token = generation
        stopInputs()
        stopAutomatic()
        state.phase = .finishing
        setStatus("正在生成长图", "收取最后一屏…")
        finishTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.finishTask = nil } }
            await self.autoTask?.value
            await self.captureTask?.value
            guard self.generation == token, let worker = self.worker, let source = self.source else { return }
            if let image = try? await source.capture(), let update = try? await worker.add(image, hint: self.takeHint()) {
                self.state.width = update.width; self.state.height = update.height; self.state.frames = update.frames
            }
            do {
                let image = try await worker.finish()
                guard self.generation == token else { return }
                await source.stop()
                guard self.generation == token else { return }
                self.closeChrome()
                self.source = nil; self.worker = nil; self.context = nil
                self.isBusy = false
                self.openEditor(image, context: context)
            } catch {
                guard self.generation == token else { return }
                self.fail(error)
            }
        }
    }

    private func openEditor(_ image: CGImage, context: CaptureContext) {
        let scale = max(1, context.screen.scale)
        selection.edit(image: image, pointSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale),
                       kind: "scroll") { [weak self] edited, editedContext in
            var editedContext = editedContext
            editedContext.appBundleID = context.appBundleID
            guard let self else { return }
            if self.automationCompletion != nil { self.completeAutomation(.success((edited, editedContext))) }
            else { self.onCapture(edited, editedContext) }
        }
        selection.onFinish = { [weak self] completed in
            if !completed { self?.completeAutomation(.failure(CancellationError())) }
        }
        state.reset()
    }

    /// Cancels promptly, then waits for in-flight native captures before reporting idle.
    func cancel() async {
        let pending = [startTask, captureTask, settleTask, autoTask, finishTask].compactMap { $0 }
        let oldSource = source
        let wasSelecting = selecting
        generation = UUID()
        stopInputs(); stopAutomatic()
        for task in pending { task.cancel() }
        closeChrome()
        if wasSelecting { selection.finish() }
        for task in pending { await task.value }
        await oldSource?.stop()
        reset()
        completeAutomation(.failure(CancellationError()))
    }

    private func fail(_ error: Error) {
        let automated = automationCompletion != nil
        let oldSource = source
        generation = UUID()
        stopInputs(); stopAutomatic()
        for task in [startTask, captureTask, settleTask, autoTask, finishTask].compactMap({ $0 }) { task.cancel() }
        closeChrome()
        if selecting { selection.finish() }
        Task { await oldSource?.stop() }
        reset()
        completeAutomation(.failure(error))
        guard !automated else { return }
        if let native = error as? AppError, case .permission(let name) = native {
            PermissionGuide.shared.present(name.contains("辅助") ? .accessibility : .screenRecording, reason: "长截图")
        } else {
            ErrorPresenter.show(error)
        }
    }

    private func closeChrome() {
        controls?.close(); controls = nil
        preview?.close(); preview = nil
        overlay?.close(); overlay = nil
    }

    private func reset() {
        startTask = nil; captureTask = nil; settleTask = nil; autoTask = nil; finishTask = nil
        source = nil; worker = nil; context = nil; selecting = false
        capturePending = false; hintPoints = 0; hintPrecise = true; unmatchedStreak = 0; stalledDownward = 0
        state.reset()
        isBusy = false
    }

    private func togglePreview() {
        guard let context, let preview else { return }
        state.showsPreview.toggle()
        if state.showsPreview { preview.show(near: context.globalRect, avoiding: controls?.panelFrame) }
        else { preview.close() }
    }

    private func completeAutomation(_ result: Result<(CGImage, CaptureContext), Error>) {
        let callback = automationCompletion
        automationCompletion = nil; automationID = nil
        callback?(result)
    }
}
