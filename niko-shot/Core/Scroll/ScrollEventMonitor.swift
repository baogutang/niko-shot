// Observes scrolling activity over the capture viewport only while a long capture is active.
import AppKit

/// One observed input that may have moved the target's content.
struct ScrollActivity: Sendable, Equatable {
    /// Content shift in points implied by a precise (trackpad / Magic Mouse) delta; positive means scrolled down.
    var preciseDownwardPoints: CGFloat?
    /// The event came from automatic scrolling.
    var isSynthetic = false
}

/// Global monitors never consume events; mouse and wheel observation needs no extra permission.
@MainActor
final class ScrollEventMonitor {
    private var local: Any?
    private var global: Any?
    private var viewport: CGRect = .zero
    private var onActivity: ((ScrollActivity) -> Void)?
    private var dragging = false
    var monitorCount: Int { (local == nil ? 0 : 1) + (global == nil ? 0 : 1) }

    /// Starts observing wheel, scroll-bar drags and keyboard paging (keys only arrive with Accessibility consent).
    func start(viewport: CGRect, onActivity: @escaping (ScrollActivity) -> Void) {
        stop()
        self.viewport = viewport
        self.onActivity = onActivity
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
        }
    }

    func update(viewport: CGRect) { self.viewport = viewport }

    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil; global = nil; onActivity = nil; dragging = false; viewport = .zero
    }

    /// Decodes an AppKit event; also the injection point for permission-free tests.
    func receive(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel:
            guard viewport.contains(NSEvent.mouseLocation) else { return }
            let synthetic = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == AutoScroller.eventMarker
            let delta = event.hasPreciseScrollingDeltas ? -event.scrollingDeltaY : nil
            guard event.scrollingDeltaY != 0 || event.phase == .ended || event.momentumPhase == .ended else { return }
            onActivity?(ScrollActivity(preciseDownwardPoints: delta, isSynthetic: synthetic))
        case .leftMouseDown:
            // 拖动滚动条或内容时，窗口可能在选区外侧（滚动条）——以窗口内拖动为准。
            dragging = viewport.insetBy(dx: -24, dy: -8).contains(NSEvent.mouseLocation)
        case .leftMouseDragged:
            if dragging { onActivity?(ScrollActivity()) }
        case .leftMouseUp:
            if dragging { dragging = false; onActivity?(ScrollActivity()) }
        case .keyDown:
            // 方向键、空格、PageUp/Down、Home/End 会滚动目标内容。
            if [49, 115, 116, 119, 121, 125, 126].contains(Int(event.keyCode)) { onActivity?(ScrollActivity()) }
        default: break
        }
    }

    /// Permission-free test entry with an explicit pointer location.
    func receiveScroll(at point: CGPoint, deltaY: CGFloat, precise: Bool, synthetic: Bool = false) {
        guard viewport.contains(point) else { return }
        onActivity?(ScrollActivity(preciseDownwardPoints: precise ? -deltaY : nil, isSynthetic: synthetic))
    }
}
