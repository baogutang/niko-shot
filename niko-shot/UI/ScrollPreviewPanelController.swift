// Displays only the bounded, accepted scroll-capture thumbnail in a movable native side panel.
import AppKit
import Observation

/// Scalar diagnostics for real panel layout, following, and teardown tests.
struct ScrollPreviewDiagnostics: Sendable {
    let imageSize: CGSize
    let sourceSize: CGSize
    let frames: Int
    let updateCount: Int
    let isFollowingTail: Bool
    let isShowingWholeImage: Bool
    let scrollOffset: CGFloat
    let maximumScrollOffset: CGFloat
    let imageCount: Int
    let observerCount: Int
}

/// A timer-free, nonactivating preview of the complete accepted long screenshot.
@MainActor
final class ScrollPreviewPanelController: NSObject {
    nonisolated(unsafe) private var panel: ScrollPreviewPanel?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    private var content: ScrollPreviewContentView?
    private let state: ScrollControlState
    private var generation = UUID()
    private var isObserving = false

    /// Called only after the user closes the preview, allowing the capture controls to offer reopening.
    var onUserClose: (() -> Void)?

    /// Creates no window, image copy, capture, or polling work until shown.
    init(state: ScrollControlState) { self.state = state; super.init() }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let appearanceObserver { workspaceNotifications.removeObserver(appearanceObserver) }
        guard let remaining = panel else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                (remaining.contentView as? ScrollPreviewContentView)?.clear()
                remaining.orderOut(nil); remaining.contentView = nil; remaining.close()
            }
        } else {
            Task { @MainActor in
                (remaining.contentView as? ScrollPreviewContentView)?.clear()
                remaining.orderOut(nil); remaining.contentView = nil; remaining.close()
            }
        }
    }

    /// Number of retained preview panels; closing must immediately return zero.
    var windowCount: Int { panel == nil ? 0 : 1 }
    /// Actual global AppKit frame, including any user drag.
    var panelFrame: CGRect? { panel?.frame }
    /// Current display and scroll state without copying any image pixels.
    var diagnostics: ScrollPreviewDiagnostics {
        ScrollPreviewDiagnostics(imageSize: content?.imageView.imageSize ?? .zero,
            sourceSize: content?.sourceSize ?? .zero, frames: content?.acceptedFrames ?? 0,
            updateCount: content?.updateCount ?? 0, isFollowingTail: content?.followsTail ?? false,
            isShowingWholeImage: content?.showsWholeImage ?? false,
            scrollOffset: content?.scrollView.contentView.bounds.minY ?? 0,
            maximumScrollOffset: content?.maximumScrollOffset ?? 0,
            imageCount: content?.imageView.hasImage == true ? 1 : 0,
            observerCount: observers.count + (appearanceObserver == nil ? 0 : 1))
    }

    /// Shows beside the capture without activating the app or taking the target's keyboard focus.
    func show(near target: CGRect, avoiding: CGRect? = nil) {
        if panel != nil { reposition(near: target, avoiding: avoiding); return }
        let screen = Self.visibleScreen(for: target)
        let size = CGSize(width: min(260, screen.width), height: min(420, screen.height))
        let frame = Self.placement(near: target, avoiding: avoiding, in: screen, size: size)
        let window = ScrollPreviewPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isMovableByWindowBackground = true
        window.setAccessibilityLabel("长截图实时预览")
        let content = ScrollPreviewContentView(frame: CGRect(origin: .zero, size: size))
        content.onClose = { [weak self] in
            guard let self else { return }
            let callback = self.onUserClose
            self.close()
            callback?()
        }
        window.contentView = content
        self.content = content; panel = window
        generation = UUID()
        content.update(preview: state.preview, frames: state.frames, height: state.height,
                       status: state.status, isPaused: state.isPaused, isWorking: state.isWorking)
        content.layoutSubtreeIfNeeded()
        content.layoutImage(preservePosition: false)
        let boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: content.scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.content?.userScrolled() }
            }
        let screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        observers = [boundsObserver, screenObserver]
        appearanceObserver = workspaceNotifications.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.content?.refreshMaterial() }
            }
        observeState()
        window.orderFrontRegardless()
    }

    /// Repositions the existing panel for a moved capture or control bar; never creates a hidden panel.
    func reposition(near target: CGRect, avoiding: CGRect? = nil) {
        guard let panel else { return }
        let screen = Self.visibleScreen(for: target)
        let size = CGSize(width: min(260, screen.width), height: min(420, screen.height))
        panel.setFrame(Self.placement(near: target, avoiding: avoiding, in: screen, size: size), display: true)
        content?.layoutSubtreeIfNeeded()
        content?.layoutImage(preservePosition: true)
    }

    /// Releases the thumbnail, observation tokens, and native panel synchronously.
    func close() {
        generation = UUID(); isObserving = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let appearanceObserver { workspaceNotifications.removeObserver(appearanceObserver) }
        appearanceObserver = nil
        content?.clear(); content?.onClose = nil; content = nil
        let old = panel; panel = nil
        old?.orderOut(nil); old?.contentView = nil; old?.close()
    }

    private func observeState() {
        guard panel != nil, !isObserving else { return }
        isObserving = true
        let token = generation
        withObservationTracking {
            _ = state.preview; _ = state.frames; _ = state.height
            _ = state.status; _ = state.isPaused; _ = state.isWorking
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.panel != nil, self.generation == token else { return }
                self.isObserving = false
                self.content?.update(preview: self.state.preview, frames: self.state.frames, height: self.state.height,
                    status: self.state.status, isPaused: self.state.isPaused, isWorking: self.state.isWorking)
                self.observeState()
            }
        }
    }

    private static func visibleScreen(for target: CGRect) -> CGRect {
        let screen = NSScreen.screens.max { first, second in
            let a = first.frame.intersection(target), b = second.frame.intersection(target)
            return max(0, a.width) * max(0, a.height) < max(0, b.width) * max(0, b.height)
        } ?? NSScreen.main
        return (screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)).insetBy(dx: 8, dy: 8)
    }

    /// Prefers a clear right side, then left; constrained displays use the least obstructing screen edge.
    nonisolated static func placement(near target: CGRect, avoiding obstacle: CGRect?, in screen: CGRect, size: CGSize) -> CGRect {
        let actual = CGSize(width: min(size.width, screen.width), height: min(size.height, screen.height))
        func clamp(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: min(max(x, screen.minX), screen.maxX - actual.width),
                   y: min(max(y, screen.minY), screen.maxY - actual.height), width: actual.width, height: actual.height)
        }
        let candidates = [
            clamp(target.maxX + 12, target.maxY - actual.height),
            clamp(target.minX - actual.width - 12, target.maxY - actual.height),
            clamp(screen.maxX - actual.width, screen.minY), clamp(screen.minX, screen.minY),
            clamp(screen.maxX - actual.width, screen.maxY - actual.height), clamp(screen.minX, screen.maxY - actual.height)
        ]
        func area(_ frame: CGRect, _ other: CGRect?) -> CGFloat {
            guard let other else { return 0 }
            let intersection = frame.intersection(other)
            return intersection.isNull ? 0 : max(0, intersection.width) * max(0, intersection.height)
        }
        if let clear = candidates.first(where: { area($0, target) == 0 && area($0, obstacle) == 0 }) { return clear }
        return candidates.min { area($0, target) + area($0, obstacle) < area($1, target) + area($1, obstacle) } ?? candidates[0]
    }
}

@MainActor
private final class ScrollPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns one CGImage reference and draws it directly, preserving both ends of the accepted screenshot.
@MainActor
final class ScrollPreviewImageView: NSView {
    private var image: CGImage?
    var showsWholeImage = false
    var imageSize: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    var hasImage: Bool { image != nil }
    override var isFlipped: Bool { true }

    func setImage(_ image: CGImage?) { self.image = image; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let usable = bounds.insetBy(dx: 8, dy: 8)
        let scale = min(usable.width / CGFloat(image.width), usable.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: showsWholeImage ? bounds.midY - size.height / 2 : 8)
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: origin.x, y: origin.y + size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
    }
}

@MainActor
private final class ScrollPreviewContentView: NSVisualEffectView {
    let scrollView = NSScrollView()
    let imageView = ScrollPreviewImageView()
    var onClose: (() -> Void)?
    private let dimensions = NSTextField(labelWithString: "尚未捕获")
    private let statusLabel = NSTextField(labelWithString: "准备开始")
    private let placeholder = NSTextField(wrappingLabelWithString: "正在准备首张画面…")
    private let latest = NSButton(title: "回到最新", target: nil, action: nil)
    private let mode = NSSegmentedControl(labels: ["全图", "跟随"], trackingMode: .selectOne, target: nil, action: nil)
    private var displayedImage: CGImage?
    private var updatingScroll = false
    private(set) var sourceSize = CGSize.zero
    private(set) var acceptedFrames = 0
    private(set) var updateCount = 0
    private(set) var followsTail = true
    var showsWholeImage: Bool { mode.selectedSegment == 0 }
    var maximumScrollOffset: CGFloat { max(0, imageView.frame.height - scrollView.contentView.bounds.height) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow; blendingMode = .behindWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        let title = NSTextField(labelWithString: "长截图预览")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭预览") ?? NSImage(),
                             target: self, action: #selector(closePressed))
        close.isBordered = false; close.toolTip = "关闭预览，继续长截图"
        close.setAccessibilityLabel("关闭长截图预览")
        mode.selectedSegment = 1; mode.controlSize = .small; mode.target = self; mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel("长截图预览查看方式")
        mode.setToolTip("缩放查看完整长图", forSegment: 0)
        mode.setToolTip("新增内容时跟随底部；向上浏览暂停跟随", forSegment: 1)
        latest.controlSize = .small; latest.bezelStyle = .rounded; latest.target = self; latest.action = #selector(showLatest)
        latest.setAccessibilityLabel("回到长截图最新内容")
        latest.isHidden = true
        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimensions.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 1; statusLabel.lineBreakMode = .byTruncatingTail
        placeholder.font = .systemFont(ofSize: 12); placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center; placeholder.maximumNumberOfLines = 3
        scrollView.drawsBackground = false; scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay; scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = imageView
        scrollView.setAccessibilityLabel("已拼接长截图预览，可滚动查看")
        imageView.setAccessibilityElement(true); imageView.setAccessibilityRole(.image)
        imageView.setAccessibilityLabel("已接受的完整长截图")
        let footer = NSStackView(views: [dimensions, latest]); footer.orientation = .horizontal
        footer.alignment = .centerY; footer.distribution = .fill; footer.spacing = 8
        dimensions.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let views: [NSView] = [title, close, mode, scrollView, placeholder, footer, statusLabel]
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), title.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 26), close.heightAnchor.constraint(equalToConstant: 26),
            mode.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), mode.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            mode.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10), mode.heightAnchor.constraint(equalToConstant: 24),
            scrollView.topAnchor.constraint(equalTo: mode.bottomAnchor, constant: 8), scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            placeholder.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor), placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4), footer.heightAnchor.constraint(equalToConstant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11)
        ])
        refreshMaterial()
    }

    required init?(coder: NSCoder) { nil }

    func update(preview: ScrollPreviewSnapshot?, frames: Int, height: Int, status: String, isPaused: Bool, isWorking: Bool) {
        let imageChanged = preview.map { displayedImage !== $0.image } ?? (displayedImage != nil)
        if imageChanged {
            displayedImage = preview?.image; imageView.setImage(preview?.image)
            sourceSize = preview.map { CGSize(width: $0.sourceWidth, height: $0.sourceHeight) } ?? .zero
            acceptedFrames = preview?.frames ?? 0
            updateCount += 1
            layoutSubtreeIfNeeded(); layoutImage(preservePosition: true)
        }
        placeholder.isHidden = preview != nil
        placeholder.stringValue = frames > 0 ? "预览暂时不可用\n已捕获内容仍可完成" : "正在准备首张画面…"
        dimensions.stringValue = preview.map { "\($0.sourceWidth) × \($0.sourceHeight) px · 已拼接 \($0.frames) 段" }
            ?? (frames > 0 ? "\(height) px · 已拼接 \(frames) 段" : "尚未捕获")
        dimensions.toolTip = dimensions.stringValue
        let message = status.isEmpty ? (isPaused ? "已暂停" : isWorking ? "正在拼接…" : "滚动后继续拼接") : status
        statusLabel.stringValue = message; statusLabel.toolTip = message
        imageView.setAccessibilityValue(preview.map { "完整长截图，\($0.sourceWidth)乘\($0.sourceHeight)像素，已拼接\($0.frames)段" } ?? "尚无预览")
        refreshLatest()
    }

    func layoutImage(preservePosition: Bool) {
        let oldOffset = scrollView.contentView.bounds.minY
        let viewport = scrollView.contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        updatingScroll = true
        defer { updatingScroll = false }
        let imageSize = imageView.imageSize
        let height = showsWholeImage || imageSize.width == 0 ? viewport.height
            : max(viewport.height, (max(0, viewport.width - 16) / imageSize.width) * imageSize.height + 16)
        imageView.showsWholeImage = showsWholeImage
        imageView.setFrameSize(CGSize(width: viewport.width, height: height))
        imageView.needsDisplay = true
        let offset = showsWholeImage ? 0 : followsTail ? maximumScrollOffset : min(maximumScrollOffset, preservePosition ? oldOffset : 0)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refreshLatest()
    }

    func userScrolled() {
        guard !updatingScroll, !showsWholeImage, imageView.hasImage else { return }
        followsTail = maximumScrollOffset - scrollView.contentView.bounds.minY <= 3
        refreshLatest()
    }

    func clear() {
        displayedImage = nil; imageView.setImage(nil); sourceSize = .zero; acceptedFrames = 0
        scrollView.documentView = nil; onClose = nil
    }

    @objc private func closePressed() { onClose?() }
    @objc private func modeChanged() {
        if !showsWholeImage { followsTail = true }
        layoutImage(preservePosition: false)
    }
    @objc private func showLatest() {
        mode.selectedSegment = 1; followsTail = true; layoutImage(preservePosition: false)
    }
    private func refreshLatest() { latest.isHidden = showsWholeImage || followsTail || !imageView.hasImage }
    func refreshMaterial() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
            layer?.backgroundColor = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                ? NSColor.windowBackgroundColor.cgColor : NSColor.windowBackgroundColor.withAlphaComponent(0.18).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshMaterial() }
}
