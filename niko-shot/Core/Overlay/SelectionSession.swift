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
    var windowCount: Int { windows.count }
    var frameCount: Int { store.frames.count }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        let remainingWindows = windows
        // Sessions are owned and released by the main-actor app coordinator.
        MainActor.assumeIsolated { for window in remainingWindows { window.orderOut(nil); window.close() } }
    }

    /// Starts a snapshot-only session, injectable so teardown can be tested without TCC.
    func start(frames: [FrozenFrame], candidates: [WindowCandidate] = [], kind: String = "region", initial: CaptureContext? = nil, completion: @escaping (CGImage, CaptureContext) -> Void) {
        finish()
        self.completion = completion
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
            confirm()
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
    }

    /// Crops the original snapshot; it never takes a second screenshot.
    func confirm() {
        guard let (frame, rect) = selected, state == .selected else { return }
        let pixels = CoordinateSpace.imagePixelRect(fromSelection: rect, screen: frame.screen)
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        state = .exporting
        let callback = completion
        let context = CaptureContext(screen: frame.screen, localRect: rect, kind: captureKind, appBundleID: appBundleID)
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { frame.image.cropping(to: pixels) }.value
            self?.finish()
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
        state = .idle
    }
}
