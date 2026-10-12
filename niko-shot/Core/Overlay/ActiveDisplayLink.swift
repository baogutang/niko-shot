// Coalesces active overlay layer updates on the view's native display link and records real callback timing.
import AppKit
import QuartzCore

/// A display-synchronized, dirty-only update driver whose selector target does not retain its owner.
@MainActor
public final class ActiveDisplayLink {
    /// A value snapshot of actual callback timestamps; synthetic lifecycle tests do not establish refresh rate.
    public struct Statistics: Codable, Sendable {
        /// Number of display-link callbacks delivered while the view was on a display.
        public fileprivate(set) var frameCount = 0
        /// Number of dirty frames whose layer-update closure ran.
        public fileprivate(set) var layerUpdateCount = 0
        /// Number of pointer or keyboard events explicitly recorded by the overlay.
        public fileprivate(set) var inputEventCount = 0
        /// First callback timestamp from CADisplayLink, or zero before any callback.
        public fileprivate(set) var firstTimestamp: Double = 0
        /// Most recent callback's actual timestamp.
        public fileprivate(set) var timestamp: Double = 0
        /// Most recent callback's target timestamp supplied by CADisplayLink.
        public fileprivate(set) var targetTimestamp: Double = 0
        /// Requested ceiling, capped to this screen's supported maximum and 120 Hz.
        public fileprivate(set) var maximumFPS = 0
        /// Longest measured interval between two actual callbacks.
        public fileprivate(set) var maximumFrameInterval: Double = 0
        /// Longest measured event-to-layer-update latency, in seconds.
        public fileprivate(set) var maximumInputLatency: Double = 0
        /// Average measured callback frequency, or zero until at least two callbacks arrive.
        public fileprivate(set) var averageFPS: Double = 0

        /// Creates an empty snapshot without manufacturing timing evidence.
        public init() {}
    }

    nonisolated(unsafe) private var link: CADisplayLink?
    private var proxy: DisplayLinkProxy?
    private weak var view: NSView?
    private let onFrame: () -> Void
    private var dirty = false
    private var pendingInputTimestamp: Double?
    /// Actual callback statistics for this driver's lifetime.
    public private(set) var statistics = Statistics()
    /// Whether this driver currently owns a scheduled native display link.
    public var isActive: Bool { link != nil }

    /// Creates a dormant driver. The callback should capture an owning view weakly.
    public init(onFrame: @escaping () -> Void) { self.onFrame = onFrame }

    deinit { link?.invalidate() }

    /// Starts only for an attached view and requests at most the display's supported refresh rate.
    public func start(in view: NSView) {
        guard view.window != nil else { return }
        if self.view === view, link != nil { return }
        invalidate()
        self.view = view
        let proxy = DisplayLinkProxy(owner: self)
        let link = view.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        let supported = max(1, view.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        let maximum = min(120, supported)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(60, maximum)), maximum: Float(maximum), preferred: Float(maximum))
        statistics.maximumFPS = maximum
        self.proxy = proxy
        self.link = link
        dirty = true
        link.add(to: .main, forMode: .common)
    }

    /// Requests a single merged layer update on the next display callback.
    public func markDirty() { dirty = true }

    /// Records an event without drawing or introducing a polling timer.
    public func recordInputEvent() {
        statistics.inputEventCount += 1
        if pendingInputTimestamp == nil { pendingInputTimestamp = CACurrentMediaTime() }
    }

    /// Unschedules and releases the link synchronously; repeated calls are harmless.
    public func invalidate() {
        link?.invalidate()
        link = nil
        proxy = nil
        view = nil
        dirty = false
        pendingInputTimestamp = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard self.link === link else { return }
        guard view?.window != nil else { invalidate(); return }
        let previous = statistics.timestamp
        if statistics.frameCount == 0 { statistics.firstTimestamp = link.timestamp }
        else { statistics.maximumFrameInterval = max(statistics.maximumFrameInterval, link.timestamp - previous) }
        statistics.frameCount += 1
        statistics.timestamp = link.timestamp
        statistics.targetTimestamp = link.targetTimestamp
        if statistics.frameCount > 1, statistics.timestamp > statistics.firstTimestamp {
            statistics.averageFPS = Double(statistics.frameCount - 1) / (statistics.timestamp - statistics.firstTimestamp)
        }
        guard dirty else { pendingInputTimestamp = nil; return }
        dirty = false
        statistics.layerUpdateCount += 1
        if let pendingInputTimestamp {
            statistics.maximumInputLatency = max(statistics.maximumInputLatency, CACurrentMediaTime() - pendingInputTimestamp)
            self.pendingInputTimestamp = nil
        }
        onFrame()
    }
}

@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var owner: ActiveDisplayLink?
    init(owner: ActiveDisplayLink) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}
