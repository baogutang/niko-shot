// Keeps the live scroll viewport visible through mouse-transparent, per-display native overlays.
import AppKit

/// Pixel-free diagnostics for capture exclusion and mixed-display coordinate tests.
struct ScrollSelectionOverlayFrame: Sendable {
    let screenFrame: CGRect
    let globalSelection: CGRect
    let localSelection: CGRect
    let windowNumber: Int
}

/// A light live-screen mask which never freezes pixels, intercepts scrolling, or becomes key.
@MainActor
final class ScrollSelectionOverlayController: NSObject {
    nonisolated(unsafe) private var panels: [ScrollSelectionOverlayPanel] = []
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    private let screenFrames: @MainActor () -> [CGRect]
    /// Last shown viewport, re-applied when displays are reconfigured.
    private var context: CaptureContext?

    /// Uses all attached displays; tests may inject immutable geometry without any capture permission.
    init(screenFrames: @escaping @MainActor () -> [CGRect] = { NSScreen.screens.map(\.frame) }) {
        self.screenFrames = screenFrames
        super.init()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let appearanceObserver { workspaceNotifications.removeObserver(appearanceObserver) }
        let remaining = panels
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                for panel in remaining { panel.orderOut(nil); panel.contentView = nil; panel.close() }
            }
        } else {
            Task { @MainActor in
                for panel in remaining { panel.orderOut(nil); panel.contentView = nil; panel.close() }
            }
        }
    }

    /// Number of retained overlays; session completion must leave none.
    var windowCount: Int { panels.count }
    /// Live WindowServer identifiers for the coordinator's ScreenCaptureKit exclusion filter.
    var windowNumbers: [Int] { panels.map(\.windowNumber) }
    /// Each display's actual frame and transparent cutout, without screenshots or private APIs.
    var frames: [ScrollSelectionOverlayFrame] {
        panels.map { panel in
            let view = panel.contentView as? ScrollSelectionOverlayView
            return ScrollSelectionOverlayFrame(screenFrame: panel.frame,
                globalSelection: view?.globalSelection ?? .zero,
                localSelection: view?.selectionRect ?? .zero, windowNumber: panel.windowNumber)
        }
    }
    /// Owned display/accessibility listeners, for explicit teardown assertions.
    var observerCount: Int { (screenObserver == nil ? 0 : 1) + (appearanceObserver == nil ? 0 : 1) }

    /// Reveals the original viewport while dimming the surrounding live desktops slightly.
    func show(context: CaptureContext) {
        guard Self.valid(context.globalRect), Self.valid(context.screen.frame) else { close(); return }
        apply(context: context)
        if screenObserver == nil {
            // 显示器变化时重新排布而不是关闭：区域模式以蒙层窗口号作为「其下方」的捕获基准，
            // 关掉后窗口号失效，后续帧会把控制条和预览一起截进去。
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.panels.isEmpty, let context = self.context else { return }
                        self.apply(context: context)
                    }
                }
        }
        if appearanceObserver == nil {
            appearanceObserver = workspaceNotifications.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.panels.forEach { $0.contentView?.needsDisplay = true } }
                }
        }
    }

    /// Updates an active viewport in place; a late callback cannot reopen a closed overlay.
    func update(context: CaptureContext) {
        guard !panels.isEmpty else { return }
        guard Self.valid(context.globalRect), Self.valid(context.screen.frame) else { close(); return }
        apply(context: context)
    }

    /// Removes every overlay and listener immediately, without altering the capture context.
    func close() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let appearanceObserver { workspaceNotifications.removeObserver(appearanceObserver) }
        screenObserver = nil; appearanceObserver = nil; context = nil
        let old = panels; panels.removeAll()
        for panel in old { panel.orderOut(nil); panel.contentView = nil; panel.close() }
    }

    /// Keeps panels on unchanged displays, moves leftover panels onto new frames, and only then creates
    /// or closes panels, so window numbers stay valid across display changes.
    private func apply(context: CaptureContext) {
        self.context = context
        var screens: [CGRect] = []
        for frame in screenFrames() where Self.valid(frame) && !screens.contains(frame) { screens.append(frame) }
        if screens.isEmpty { screens = [context.screen.frame] }
        var spare = panels.filter { !screens.contains($0.frame) }
        var placed: [ScrollSelectionOverlayPanel] = []
        for screen in screens {
            let panel: ScrollSelectionOverlayPanel
            if let existing = panels.first(where: { $0.frame == screen && !placed.contains($0) }) { panel = existing }
            else if !spare.isEmpty {
                panel = spare.removeFirst()
                panel.setFrame(screen, display: false)
                panel.contentView?.frame = CGRect(origin: .zero, size: screen.size)
            } else {
                panel = ScrollSelectionOverlayPanel(screenFrame: screen)
            }
            placed.append(panel)
            (panel.contentView as? ScrollSelectionOverlayView)?.setSelection(context.globalRect, on: screen)
            panel.orderFrontRegardless()
        }
        panels = placed
        for panel in spare { panel.orderOut(nil); panel.contentView = nil; panel.close() }
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0
            && rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}

@MainActor
private final class ScrollSelectionOverlayPanel: NSPanel {
    init(screenFrame: CGRect) {
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // Floating preview/controls stay above the tint; ordinary target windows remain below it.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear; isOpaque = false; hasShadow = false
        isReleasedWhenClosed = false; hidesOnDeactivate = false
        ignoresMouseEvents = true; acceptsMouseMovedEvents = false
        becomesKeyOnlyIfNeeded = true
        setAccessibilityElement(false)
        contentView = ScrollSelectionOverlayView(frame: CGRect(origin: .zero, size: screenFrame.size))
        setFrame(screenFrame, display: false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Paints only the surrounding translucent mask and an outside edge; selection pixels remain fully transparent.
@MainActor
final class ScrollSelectionOverlayView: NSView {
    private(set) var selectionRect = CGRect.zero
    private(set) var globalSelection = CGRect.zero
    override var isOpaque: Bool { false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    /// Converts the global AppKit rectangle independently for each display, without a shared DPI assumption.
    func setSelection(_ global: CGRect, on screen: CGRect) {
        globalSelection = global
        let clipped = global.intersection(screen)
        selectionRect = clipped.isNull || clipped.isEmpty ? .zero : clipped.offsetBy(dx: -screen.minX, dy: -screen.minY)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Replace previous cutouts instead of painting a new mask over old transparent pixels.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        let mask = NSBezierPath(rect: bounds)
        mask.windingRule = .evenOdd
        if !selectionRect.isEmpty { mask.appendRect(selectionRect) }
        let strongerContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let reducedTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        NSColor.black.withAlphaComponent(strongerContrast || reducedTransparency ? 0.24 : 0.12).setFill()
        mask.fill()
        guard !selectionRect.isEmpty else { return }
        // The stroke sits outside the selection and does not tint its interior.
        let border = NSBezierPath(rect: selectionRect.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        NSColor(srgbRed: 0.97, green: 0.70, blue: 0.28, alpha: 1).setStroke()
        border.stroke()
    }
}
