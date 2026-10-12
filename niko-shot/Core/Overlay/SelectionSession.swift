// Owns the entire capture state machine and deterministically releases every session resource.
import AppKit

struct CaptureContext: Sendable {
    let screen: ScreenGeometry
    let localRect: CGRect
    var kind: String = "region"
    var appBundleID: String = ""
    var globalRect: CGRect { CoordinateSpace.localToGlobal(localRect, screen: screen) }
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
    private var appBundleID = ""
    private var toolbar: ToolbarController?
    private var canvas: AnnotationCanvasView?
    private var editorContext: CaptureContext?
    private var archive: ArchivedFrame?
    private var generation = UUID()
    private var resumedDocument: AnnotationDocument?
    private var resumedContext: CaptureContext?
    var outputAction: ToolbarAction = .copy
    private var annotationColor = AnnotationColor.red
    private var annotationWidth: CGFloat = 3
    var windowCount: Int { windows.count }
    var frameCount: Int { store.frames.count }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        let remainingWindows = windows
        let remainingToolbar = toolbar
        if let archive { try? FileManager.default.removeItem(at: archive.url) }
        // Sessions are owned and released by the main-actor app coordinator.
        MainActor.assumeIsolated { remainingToolbar?.close(); for window in remainingWindows { window.orderOut(nil); window.close() } }
    }

    /// Starts a snapshot-only session, injectable so teardown can be tested without TCC.
    func start(frames: [FrozenFrame], candidates: [WindowCandidate] = [], kind: String = "region", initial: CaptureContext? = nil, autoConfirm: Bool = true, completion: @escaping (CGImage, CaptureContext) -> Void) {
        finish()
        self.completion = completion
        generation = UUID()
        outputAction = .copy
        captureKind = kind
        store.replace(frames)
        state = .frozen
        for frame in frames {
            let view = SelectionView(frameInfo: frame)
            view.candidates = candidates
            view.windowMode = kind == "window"
            view.onSelection = { [weak self, weak view] rect in
                self?.appBundleID = view?.selectedWindow?.appBundleID ?? ""
                self?.select(frame: frame, rect: rect)
            }
            view.onConfirm = { [weak self] in self?.confirm() }
            view.onCancel = { [weak self] in self?.finish() }
            view.onAnnotate = { [weak self] in self?.beginAnnotation(tool: .rectangle) }
            view.onSave = { [weak self] in self?.outputAction = .save; self?.confirm() }
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
            select(frame: frame, rect: view.selection)
            if autoConfirm { confirm() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func select(frame: FrozenFrame, rect: CGRect) {
        guard state != .exporting else { return }
        if let activeScreen, activeScreen != frame.screen.id { return }
        activeScreen = frame.screen.id
        for window in windows { window.ignoresMouseEvents = (window.contentView as? SelectionView)?.frameInfo.screen.id != activeScreen }
        selected = (frame, rect)
        state = rect.isEmpty ? .selecting : .selected
        if !rect.isEmpty { showToolbar(context: CaptureContext(screen: frame.screen, localRect: rect, kind: captureKind, appBundleID: appBundleID)) }
    }

    private func showToolbar(context: CaptureContext) {
        if toolbar == nil {
            toolbar = ToolbarController(onTool: { [weak self] tool in self?.beginAnnotation(tool: tool) }, onAction: { [weak self] action in self?.perform(action) }, onColor: { [weak self] color in
                guard let rgb = color.usingColorSpace(.deviceRGB) else { return }
                let value = AnnotationColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
                self?.annotationColor = value; self?.canvas?.color = value
            }, onWidth: { [weak self] width in self?.annotationWidth = width; self?.canvas?.strokeWidth = width })
        }
        toolbar?.show(near: context.globalRect, screenFrame: context.screen.frame)
    }

    /// Crops, archives and releases the full-screen backing images before native annotation.
    func beginAnnotation(tool: AnnotationTool) {
        if let canvas { canvas.tool = tool; toolbar?.setSelectedTool(tool); return }
        guard let (frame, rect) = selected, state == .selected else { return }
        state = .annotating
        let token = generation
        let context = CaptureContext(screen: frame.screen, localRect: rect, kind: captureKind, appBundleID: appBundleID)
        let pixels = CoordinateSpace.imagePixelRect(fromSelection: rect, screen: frame.screen)
        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> (CGImage, ArchivedFrame) in
                    guard let crop = frame.image.cropping(to: pixels) else { throw AppError.imageCreation }
                    return (crop, try SnapshotArchive.write(frame))
                }.value
                guard let self, self.generation == token, self.state == .annotating else { try? FileManager.default.removeItem(at: result.1.url); return }
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
                    if (window.contentView as? SelectionView)?.frameInfo.screen.id == frame.screen.id {
                        window.contentView = stage; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas)
                    } else { window.close(); window.contentView = nil }
                }
                self.store.clear(); self.selected = nil
                self.toolbar?.setSelectedTool(tool)
            } catch { self?.finish(); ErrorPresenter.show(error) }
        }
    }

    private func perform(_ action: ToolbarAction) {
        switch action {
        case .undo: canvas?.undo()
        case .redo: canvas?.redo()
        case .close: finish()
        case .selection:
            guard let archive else { return }
            let callback = completion, kind = captureKind, savedDocument = canvas?.document, savedContext = editorContext, token = generation
            Task { [weak self] in
                do {
                    let frame = try await Task.detached(priority: .userInitiated) { try SnapshotArchive.read(archive) }.value
                    guard let self, self.generation == token, let callback else { return }
                    self.start(frames: [frame], kind: kind, initial: savedContext, autoConfirm: false, completion: callback)
                    self.resumedDocument = savedDocument; self.resumedContext = savedContext
                } catch { ErrorPresenter.show(error) }
            }
        default: outputAction = action; confirm()
        }
    }

    /// Crops the original snapshot; it never takes a second screenshot.
    func confirm() {
        if let canvas, let context = editorContext, state == .annotating {
            state = .exporting
            let document = canvas.document, base = canvas.base, callback = completion
            let token = generation
            let scale = CGFloat(base.width) / max(1, document.canvasSize.width)
            Task { [weak self] in
                do {
                    let image = try await Task.detached(priority: .userInitiated) { try AnnotationRenderer.render(base: base, document: document, scale: scale) }.value
                    guard let self, self.generation == token, self.state == .exporting else { return }
                    self.finish(); callback?(image, context)
                } catch { self?.finish(); ErrorPresenter.show(error) }
            }
            return
        }
        guard let (frame, rect) = selected, state == .selected else { return }
        let pixels = CoordinateSpace.imagePixelRect(fromSelection: rect, screen: frame.screen)
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        state = .exporting
        let callback = completion
        let token = generation
        let context = CaptureContext(screen: frame.screen, localRect: rect, kind: captureKind, appBundleID: appBundleID)
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { frame.image.cropping(to: pixels) }.value
            guard let self, self.generation == token, self.state == .exporting else { return }
            self.finish()
            if let image { callback?(image, context) }
        }
    }

    /// Closes all overlays and removes listeners; also used for cancellation and display changes.
    func finish() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for window in windows {
            if let view = window.contentView as? SelectionView {
                view.onSelection = nil; view.onConfirm = nil; view.onCancel = nil
                view.onAnnotate = nil; view.onSave = nil
            }
            window.orderOut(nil)
            window.close()
            window.contentView = nil
        }
        windows.removeAll()
        store.clear()
        selected = nil
        activeScreen = nil
        completion = nil
        monitorCount = 0
        toolbar?.close(); toolbar = nil
        canvas?.onAction = nil; canvas = nil; editorContext = nil
        resumedDocument = nil; resumedContext = nil
        if let archive { try? FileManager.default.removeItem(at: archive.url) }
        archive = nil
        generation = UUID()
        state = .idle
    }
}
