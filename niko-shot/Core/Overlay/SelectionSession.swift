// Owns the entire capture state machine and deterministically releases every session resource.
import AppKit

struct CaptureContext: Sendable {
    let screen: ScreenGeometry
    let localRect: CGRect
    var kind: String = "region"
    var appBundleID: String = ""
    var windowID: UInt32?
    /// Point bounds of the identified window when selected, used to detect moved display regions.
    var targetWindowFrame: CGRect?
    var globalRect: CGRect { CoordinateSpace.localToGlobal(localRect, screen: screen) }

    /// Imported and stitched images use a synthetic display and cannot identify live screen pixels.
    var hasLiveScreenRegion: Bool {
        screen.id != 0 && screen.scale.isFinite && screen.scale > 0 &&
        localRect.origin.x.isFinite && localRect.origin.y.isFinite &&
        localRect.width.isFinite && localRect.height.isFinite &&
        localRect.width > 0 && localRect.height > 0 && screen.localBounds.contains(localRect)
    }
}

@MainActor
final class SelectionSession {
    enum State: String { case idle, frozen, selecting, selected, annotating, exporting }
    private(set) var state: State = .idle
    private(set) var windows: [OverlayWindow] = []
    private(set) var monitorCount = 0
    private let store = FreezeFrameStore()
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    private var selected: (FrozenFrame, CGRect)?
    private var activeScreen: UInt32?
    private var completion: ((CGImage, CaptureContext) -> Void)?
    private var captureKind = "region"
    private var confirmationTitle: String?
    private var appBundleID = ""
    private var windowID: UInt32?
    private var targetWindowFrame: CGRect?
    private var directScrollSelection = false
    private var windowCandidates: [WindowCandidate] = []
    private var toolbar: ToolbarController?
    private var canvas: AnnotationCanvasView?
    private var editorContext: CaptureContext?
    private var archive: ArchivedFrame?
    private var generation = UUID()
    private var resumedDocument: AnnotationDocument?
    private var resumedContext: CaptureContext?
    var onFinish: ((Bool) -> Void)?
    /// Receives the original viewport after overlays close; nil explicitly requires screen reselection.
    var onScrollCapture: ((CaptureContext?) -> Void)?
    var outputAction: ToolbarAction = .copy
    private var annotationColor = AnnotationColor.red
    private var annotationWidth: CGFloat = 3
    private var imageEditorWindow: NSWindow?
    private var imageEditorSource: FrozenFrame?
    private var completedDisplayStatistics: [ActiveDisplayLink.Statistics] = []
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var retiringCanvases: [UUID: Task<Void, Never>] = [:]
    private let afterImageOperation: (@Sendable () async -> Void)?
    /// Allows real background completion to be gated in cancellation regression tests.
    init(afterImageOperation: (@Sendable () async -> Void)? = nil) { self.afterImageOperation = afterImageOperation }
    /// Cancelled work stays owned until the underlying renderer actually returns.
    var resourceCounts: [String: Int] {
        ["selectionTasks": operations.count, "retiringCanvases": retiringCanvases.count,
         "annotationPreview": canvas?.resourceCounts["preview"] ?? 0,
         "annotationTextAlert": canvas?.resourceCounts["textAlert"] ?? 0]
    }
    var windowCount: Int { windows.count + (imageEditorWindow == nil ? 0 : 1) + (toolbar?.windowCount ?? 0) }
    var frameCount: Int { store.frames.count }
    /// Native display links currently owned by attached selection views; zero after finish.
    var displayLinkCount: Int { selectionViews.reduce(0) { $0 + $1.displayLinkCount } }
    /// Actual per-display callbacks, including snapshots saved before a stage or session ends.
    var displayLinkStatistics: [ActiveDisplayLink.Statistics] {
        completedDisplayStatistics + selectionViews.filter { $0.displayLinkCount > 0 }.map(\.displayLinkStatistics)
    }
    private var selectionViews: [SelectionView] {
        var views = windows.compactMap { $0.contentView as? SelectionView }
        if let view = (imageEditorWindow?.contentView as? NSScrollView)?.documentView as? SelectionView { views.append(view) }
        return views
    }
    private func stopDisplayUpdates(_ view: SelectionView) {
        if view.displayLinkCount > 0 { completedDisplayStatistics.append(view.displayLinkStatistics) }
        view.stopDisplayUpdates()
    }

    /// Reuses the annotation editor for history images and completed long screenshots.
    func edit(image: CGImage, pointSize: CGSize, kind: String = "edited", completion: @escaping (CGImage, CaptureContext) -> Void) {
        finish(); completedDisplayStatistics.removeAll(); generation = UUID(); state = .annotating; outputAction = .copy; self.completion = completion
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let viewport = CGSize(width: min(900, screen.width - 80), height: min(650, screen.height - 100))
        let factor = max(1, pointSize.width / max(1, viewport.width - 16))
        let canvasSize = CGSize(width: pointSize.width / factor, height: pointSize.height / factor)
        let geometry = ScreenGeometry(id: 0, frame: CGRect(origin: screen.origin, size: canvasSize), scale: CGFloat(image.width) / max(1, canvasSize.width))
        captureKind = kind; imageEditorSource = FrozenFrame(screen: geometry, image: image)
        let context = CaptureContext(screen: geometry, localRect: CGRect(origin: .zero, size: canvasSize), kind: kind)
        editorContext = context
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "niko-shot 标注"; window.isReleasedWhenClosed = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autoresizingMask = [.width, .height]
        let canvas = AnnotationCanvasView(image: image, size: canvasSize)
        configure(canvas)
        self.canvas = canvas; scroll.documentView = canvas; window.contentView = scroll
        window.center(); imageEditorWindow = window; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas); NSApp.activate(ignoringOtherApps: true)
        showToolbar(context: CaptureContext(screen: geometry, localRect: CGRect(x: 0, y: 0, width: window.frame.width, height: window.frame.height)))
        screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.finish() } }
        monitorCount = 1
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        let remainingWindows = windows
        let remainingToolbar = toolbar
        let remainingEditor = imageEditorWindow
        let remainingCanvas = canvas
        for operation in operations.values { operation.cancel() }
        for operation in retiringCanvases.values { operation.cancel() }
        if let archive { try? FileManager.default.removeItem(at: archive.url) }
        // Sessions are owned and released by the main-actor app coordinator.
        MainActor.assumeIsolated {
            remainingCanvas?.prepareForFinish()
            remainingToolbar?.close()
            ((remainingEditor?.contentView as? NSScrollView)?.documentView as? SelectionView)?.stopDisplayUpdates()
            remainingEditor?.close()
            for window in remainingWindows {
                (window.contentView as? SelectionView)?.stopDisplayUpdates()
                window.orderOut(nil); window.close()
            }
        }
    }

    /// Starts a snapshot-only session, injectable so teardown can be tested without TCC.
    func start(frames: [FrozenFrame], candidates: [WindowCandidate] = [], kind: String = "region", initial: CaptureContext? = nil, autoConfirm: Bool = true, confirmationTitle: String? = nil, directScrollSelection: Bool = false, completion: @escaping (CGImage, CaptureContext) -> Void) {
        finish()
        completedDisplayStatistics.removeAll()
        self.completion = completion
        generation = UUID()
        outputAction = .copy
        captureKind = kind
        appBundleID = initial?.appBundleID ?? ""
        windowID = initial?.windowID
        targetWindowFrame = initial?.targetWindowFrame
        self.directScrollSelection = directScrollSelection
        self.confirmationTitle = confirmationTitle
        windowCandidates = candidates
        store.replace(frames)
        state = .frozen
        for frame in frames {
            let view = SelectionView(frameInfo: frame)
            view.candidates = candidates
            view.windowMode = kind == "window"
            if directScrollSelection { view.configureForScrollSelection() }
            view.onSelection = { [weak self, weak view] rect in
                let global = CoordinateSpace.localToGlobal(rect, screen: frame.screen)
                let target = view?.selectedWindow ?? self?.windowCandidates.first { $0.frame.contains(CGPoint(x: global.midX, y: global.midY)) }
                self?.appBundleID = target?.appBundleID ?? ""
                self?.windowID = target?.id
                self?.targetWindowFrame = target?.frame
                if directScrollSelection { self?.captureKind = view?.windowMode == true ? "window" : "region" }
                self?.select(frame: frame, rect: rect)
            }
            if directScrollSelection {
                view.onSelectionCompleted = { [weak self] in self?.confirm() }
                view.onSelectionModeChanged = { [weak self] in
                    guard let self else { return }
                    self.selected = nil; self.activeScreen = nil; self.state = .selecting
                    for overlay in self.windows { overlay.ignoresMouseEvents = false }
                }
            }
            view.onConfirm = { [weak self] in self?.confirm() }
            view.onCancel = { [weak self] in self?.finish() }
            if confirmationTitle == nil && !directScrollSelection {
                view.onAnnotate = { [weak self] in self?.beginAnnotation(tool: .rectangle) }
                view.onSave = { [weak self] in self?.outputAction = .save; self?.confirm() }
            } else if !directScrollSelection { view.setAccessibilityLabel("选择区域，Enter \(confirmationTitle ?? "确认")，Escape 取消") }
            let window = OverlayWindow(screen: frame.screen, view: view)
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        monitorCount = 1
        state = .selecting
        if let initial, let frame = store.frames[initial.screen.id],
           let view = windows.first(where: { ($0.contentView as? SelectionView)?.frameInfo.screen.id == frame.screen.id })?.contentView as? SelectionView {
            view.selection = SelectionGeometry.clamp(initial.localRect, bounds: frame.screen.localBounds)
            view.selectedWindow = candidates.first { $0.id == initial.windowID }
            select(frame: frame, rect: view.selection)
            if autoConfirm { confirm() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func select(frame: FrozenFrame, rect: CGRect) {
        guard state != .exporting else { return }
        if let activeScreen, activeScreen != frame.screen.id { return }
        activeScreen = frame.screen.id
        for window in windows {
            window.ignoresMouseEvents = (window.contentView as? SelectionView)?.frameInfo.screen.id != activeScreen
            if window.ignoresMouseEvents, let view = window.contentView as? SelectionView { stopDisplayUpdates(view) }
        }
        selected = (frame, rect)
        state = rect.isEmpty ? .selecting : .selected
        if !rect.isEmpty && !directScrollSelection { showToolbar(context: CaptureContext(screen: frame.screen, localRect: rect, kind: captureKind, appBundleID: appBundleID, windowID: windowID, targetWindowFrame: targetWindowFrame)) }
        updateScrollAvailability()
    }

    private func showToolbar(context: CaptureContext) {
        if toolbar == nil {
            toolbar = ToolbarController(onTool: { [weak self] tool in self?.beginAnnotation(tool: tool) }, onAction: { [weak self] action in self?.perform(action) }, onColor: { [weak self] color in
                guard let rgb = color.usingColorSpace(.deviceRGB) else { return }
                let value = AnnotationColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
                self?.annotationColor = value; self?.canvas?.color = value
            }, onWidth: { [weak self] width in self?.annotationWidth = width; self?.canvas?.strokeWidth = width }, confirmationTitle: confirmationTitle)
        }
        if let window = imageEditorWindow { toolbar?.show(near: window.frame, screenFrame: window.screen?.frame ?? NSScreen.main?.frame ?? window.frame) }
        else { toolbar?.show(near: context.globalRect, screenFrame: context.screen.frame) }
        updateScrollAvailability()
    }

    private var scrollCaptureContext: CaptureContext? {
        guard imageEditorWindow == nil else { return nil }
        if let editorContext, editorContext.hasLiveScreenRegion { return editorContext }
        guard let (frame, rect) = selected else { return nil }
        let context = CaptureContext(screen: frame.screen, localRect: rect, kind: captureKind,
                                     appBundleID: appBundleID, windowID: windowID, targetWindowFrame: targetWindowFrame)
        return context.hasLiveScreenRegion ? context : nil
    }

    private var scrollUnavailableReason: String? {
        guard state == .selected || state == .annotating else {
            return state == .exporting ? "正在输出截图，请等待完成。" : "请先框选要滚动捕获的屏幕区域。"
        }
        if imageEditorWindow != nil { return nil }
        guard let context = scrollCaptureContext else { return "请先框选要滚动捕获的屏幕区域。" }
        guard context.localRect.height * context.screen.scale >= 240 else { return "选区高度不足 240 像素，请增大选区后开始长截图。" }
        return nil
    }

    private func updateScrollAvailability() {
        let reason = scrollUnavailableReason
        toolbar?.setScrollAvailability(enabled: reason == nil,
            explanation: reason ?? (imageEditorWindow == nil ? "沿当前选区捕获滚动内容。" : "历史或导入图片没有屏幕选区；点击后重新选择屏幕区域。"))
    }

    /// Hands live coordinates to scrolling without exporting or baking the current annotations.
    func requestScrollCapture() {
        guard scrollUnavailableReason == nil else { return }
        outputAction = .scroll
        guard let callback = onScrollCapture else { confirm(); return }
        let context = scrollCaptureContext
        finish(completed: true)
        callback(context)
    }

    /// Crops, archives and releases the full-screen backing images before native annotation.
    func beginAnnotation(tool: AnnotationTool) {
        guard confirmationTitle == nil else { return }
        if let canvas { canvas.tool = tool; toolbar?.setSelectedTool(tool); return }
        if imageEditorWindow != nil, state == .selected { applyEditorCrop(tool: tool); return }
        guard let (frame, rect) = selected, state == .selected else { return }
        state = .annotating
        let token = generation
        let context = CaptureContext(screen: frame.screen, localRect: rect, kind: captureKind, appBundleID: appBundleID, windowID: windowID, targetWindowFrame: targetWindowFrame)
        let pixels = CoordinateSpace.imagePixelRect(fromSelection: rect, screen: frame.screen)
        let gate = afterImageOperation
        runOperation { [weak self] in
            do {
                let result = try await Self.imageWork(after: gate) { () -> (CGImage, ArchivedFrame) in
                    guard let crop = frame.image.cropping(to: pixels) else { throw AppError.imageCreation }
                    return (crop, try SnapshotArchive.write(frame))
                }
                guard !Task.isCancelled, let self, self.generation == token, self.state == .annotating else { try? FileManager.default.removeItem(at: result.1.url); return }
                self.archive = result.1; self.editorContext = context
                let stage = AnnotationStageView(frame: frame.screen.localBounds)
                stage.wantsLayer = true; stage.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
                let canvas = AnnotationCanvasView(image: result.0, size: rect.size)
                if var restored = self.resumedDocument, let previous = self.resumedContext {
                    restored.rebase(by: CGPoint(x: previous.localRect.minX - rect.minX, y: previous.localRect.minY - rect.minY), canvasSize: rect.size)
                    canvas.document = restored; canvas.refresh()
                }
                canvas.frame = rect; canvas.tool = tool
                canvas.color = self.annotationColor; canvas.strokeWidth = self.annotationWidth
                canvas.onAction = { [weak self] action in self?.perform(action) }
                canvas.onToolChange = { [weak self] tool in self?.toolbar?.setSelectedTool(tool) }
                canvas.onDocumentChange = { [weak self, weak canvas] in self?.toolbar?.setUndoAvailability(canUndo: canvas?.document.canUndo ?? false, canRedo: canvas?.document.canRedo ?? false) }
                stage.addSubview(canvas)
                self.canvas = canvas
                for window in self.windows {
                    if let view = window.contentView as? SelectionView { self.stopDisplayUpdates(view) }
                    if (window.contentView as? SelectionView)?.frameInfo.screen.id == frame.screen.id {
                        window.contentView = stage; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas)
                    } else { window.close(); window.contentView = nil }
                }
                self.store.clear(); self.selected = nil
                self.toolbar?.setSelectedTool(tool)
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.finish(); ErrorPresenter.show(error)
            }
        }
    }

    private func perform(_ action: ToolbarAction) {
        switch action {
        case .undo: canvas?.undo()
        case .redo: canvas?.redo()
        case .close: finish()
        case .scroll: requestScrollCapture()
        case .selection:
            if imageEditorWindow != nil { toggleEditorSelection(); return }
            guard let archive else { return }
            let callback = completion, kind = captureKind, savedDocument = canvas?.document, savedContext = editorContext, token = generation
            let candidates = windowCandidates
            let gate = afterImageOperation
            runOperation { [weak self] in
                do {
                    let frame = try await Self.imageWork(after: gate) { try SnapshotArchive.read(archive) }
                    guard !Task.isCancelled, let self, self.generation == token, let callback else { return }
                    self.start(frames: [frame], candidates: candidates, kind: kind, initial: savedContext, autoConfirm: false, completion: callback)
                    self.resumedDocument = savedDocument; self.resumedContext = savedContext
                } catch {
                    guard !Task.isCancelled, self?.generation == token else { return }
                    ErrorPresenter.show(error)
                }
            }
        default: outputAction = action; confirm()
        }
    }

    private func configure(_ view: AnnotationCanvasView) {
        view.onAction = { [weak self] action in self?.perform(action) }
        view.onToolChange = { [weak self] tool in self?.toolbar?.setSelectedTool(tool) }
        view.onDocumentChange = { [weak self, weak view] in self?.toolbar?.setUndoAvailability(canUndo: view?.document.canUndo ?? false, canRedo: view?.document.canRedo ?? false) }
        view.color = annotationColor; view.strokeWidth = annotationWidth
    }

    private func toggleEditorSelection() {
        guard let window = imageEditorWindow, let scroll = window.contentView as? NSScrollView, let source = imageEditorSource else { return }
        if state == .selected { applyEditorCrop(); return }
        guard let canvas, state == .annotating else { return }
        resumedDocument = canvas.document; resumedContext = editorContext
        retire(canvas)
        canvas.onAction = nil; canvas.onDocumentChange = nil; canvas.onToolChange = nil
        self.canvas = nil
        let view = SelectionView(frameInfo: source)
        view.selection = editorContext?.localRect ?? source.screen.localBounds
        selected = (source, view.selection); state = .selected
        view.onSelection = { [weak self] rect in
            self?.selected = (source, rect); self?.state = rect.isEmpty ? .selecting : .selected
            self?.updateScrollAvailability()
        }
        view.onConfirm = { [weak self] in self?.applyEditorCrop(output: .copy) }
        view.onAnnotate = { [weak self] in self?.applyEditorCrop() }
        view.onSave = { [weak self] in self?.applyEditorCrop(output: .save) }
        view.onCancel = { [weak self] in self?.finish() }
        scroll.documentView = view; window.makeFirstResponder(view)
    }

    private func applyEditorCrop(tool: AnnotationTool = .rectangle, output: ToolbarAction? = nil) {
        guard let (frame, rect) = selected, !rect.isEmpty, let window = imageEditorWindow, let scroll = window.contentView as? NSScrollView else { return }
        let token = generation, previous = resumedContext
        var document = resumedDocument
        if let previous { document?.rebase(by: CGPoint(x: previous.localRect.minX - rect.minX, y: previous.localRect.minY - rect.minY), canvasSize: rect.size) }
        let savedDocument = document
        let pixels = CoordinateSpace.imagePixelRect(fromSelection: rect, screen: frame.screen)
        state = .annotating
        let gate = afterImageOperation
        runOperation { [weak self, weak window, weak scroll] in
            guard let image = try? await Self.imageWork(after: gate, { frame.image.cropping(to: pixels) }) else { return }
            guard !Task.isCancelled, let self, self.generation == token, self.state == .annotating, let window, let scroll else { return }
            let view = AnnotationCanvasView(image: image, size: rect.size)
            if let savedDocument { view.document = savedDocument; view.refresh() }
            view.tool = tool; self.configure(view); self.canvas = view
            self.editorContext = CaptureContext(screen: frame.screen, localRect: rect, kind: self.captureKind)
            if let old = scroll.documentView as? SelectionView { self.stopDisplayUpdates(old) }
            self.selected = nil; scroll.documentView = view; window.makeFirstResponder(view)
            self.toolbar?.setSelectedTool(tool)
            self.toolbar?.setUndoAvailability(canUndo: view.document.canUndo, canRedo: view.document.canRedo)
            if let output { self.outputAction = output; self.confirm() }
        }
    }

    /// Crops the original snapshot; it never takes a second screenshot.
    func confirm() {
        if directScrollSelection, let (frame, rect) = selected, state == .selected,
           rect.height * frame.screen.scale >= 240, rect.width * frame.screen.scale >= 2 {
            let callback = completion
            let context = CaptureContext(screen: frame.screen, localRect: rect, kind: captureKind,
                appBundleID: appBundleID, windowID: windowID, targetWindowFrame: targetWindowFrame)
            // Only geometry is handed off. The scroll coordinator obtains its own live first frame.
            finish(completed: true)
            callback?(frame.image, context)
            return
        }
        if directScrollSelection { return }
        if imageEditorWindow != nil, state == .selected { applyEditorCrop(output: outputAction); return }
        if let canvas, let context = editorContext, state == .annotating {
            state = .exporting
            updateScrollAvailability()
            let document = canvas.document, base = canvas.base, callback = completion
            let token = generation
            let scale = CGFloat(base.width) / max(1, document.canvasSize.width)
            let gate = afterImageOperation
            runOperation { [weak self] in
                do {
                    let image = try await Self.imageWork(after: gate) { try AnnotationRenderer.render(base: base, document: document, scale: scale) }
                    guard !Task.isCancelled, let self, self.generation == token, self.state == .exporting else { return }
                    self.finish(completed: true); callback?(image, context)
                } catch {
                    guard !Task.isCancelled, let self, self.generation == token else { return }
                    self.finish(); ErrorPresenter.show(error)
                }
            }
            return
        }
        guard let (frame, rect) = selected, state == .selected else { return }
        let pixels = CoordinateSpace.imagePixelRect(fromSelection: rect, screen: frame.screen)
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        state = .exporting
        updateScrollAvailability()
        let callback = completion
        let token = generation
        let context = CaptureContext(screen: frame.screen, localRect: rect, kind: captureKind, appBundleID: appBundleID, windowID: windowID, targetWindowFrame: targetWindowFrame)
        let gate = afterImageOperation
        runOperation { [weak self] in
            let image = try? await Self.imageWork(after: gate) { frame.image.cropping(to: pixels) }
            guard !Task.isCancelled, let self, self.generation == token, self.state == .exporting else { return }
            self.finish(completed: image != nil)
            if let image { callback?(image, context) }
        }
    }

    /// Closes all overlays and removes listeners; also used for cancellation and display changes.
    func finish(completed: Bool = false) {
        let didFinish = onFinish; onFinish = nil
        for operation in operations.values { operation.cancel() }
        if let canvas { retire(canvas) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let view = (imageEditorWindow?.contentView as? NSScrollView)?.documentView as? SelectionView {
            stopDisplayUpdates(view)
            view.onSelection = nil; view.onConfirm = nil; view.onCancel = nil; view.onAnnotate = nil; view.onSave = nil
        }
        imageEditorWindow?.close(); imageEditorWindow?.contentView = nil; imageEditorWindow = nil; imageEditorSource = nil
        for window in windows {
            if let view = window.contentView as? SelectionView {
                stopDisplayUpdates(view)
                view.onSelection = nil; view.onConfirm = nil; view.onCancel = nil
                view.onAnnotate = nil; view.onSave = nil
                view.onSelectionCompleted = nil; view.onSelectionModeChanged = nil
            }
            window.orderOut(nil)
            window.close()
            window.contentView = nil
        }
        windows.removeAll()
        store.clear()
        selected = nil
        activeScreen = nil
        appBundleID = ""; windowID = nil; targetWindowFrame = nil; confirmationTitle = nil; directScrollSelection = false
        windowCandidates.removeAll()
        completion = nil
        monitorCount = 0
        toolbar?.close(); toolbar = nil
        canvas?.onAction = nil; canvas = nil; editorContext = nil
        resumedDocument = nil; resumedContext = nil
        if let archive { try? FileManager.default.removeItem(at: archive.url) }
        archive = nil
        generation = UUID()
        state = .idle
        persistDisplayStatisticsIfRequested()
        didFinish?(completed)
    }

    /// Completes native rendering and preview cancellation before application termination.
    func finishAndDrain() async {
        finish()
        await drainPendingOperations()
    }

    /// Waits for cancelled crop/render/preview workers without changing a newer session's state.
    func drainPendingOperations() async {
        while !operations.isEmpty || !retiringCanvases.isEmpty {
            let pending = Array(operations.values) + Array(retiringCanvases.values)
            for operation in pending { await operation.value }
        }
    }

    private func retire(_ view: AnnotationCanvasView) {
        view.prepareForFinish()
        let id = UUID()
        retiringCanvases[id] = Task { [weak self] in
            await view.finishAndDrain()
            self?.retiringCanvases.removeValue(forKey: id)
        }
    }

    private func runOperation(_ work: @escaping @MainActor @Sendable () async -> Void) {
        let id = UUID()
        operations[id] = Task { [weak self] in
            defer { self?.operations.removeValue(forKey: id) }
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    private nonisolated static func imageWork<Value: Sendable>(after: (@Sendable () async -> Void)?,
        _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try autoreleasepool { try work() }
            await after?()
            return value
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func persistDisplayStatisticsIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["NIKO_DISPLAYLINK_METRICS"], !path.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(displayLinkStatistics) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
