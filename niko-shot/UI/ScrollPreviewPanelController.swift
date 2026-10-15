// Shows the accepted long image beside the viewport, following its newest rows.
import AppKit
import Observation

/// A nonactivating, movable side panel; it never captures input meant for the scrolled app.
@MainActor
final class ScrollPreviewPanelController {
    private var panel: CaptureHUDPanel?
    private var content: ScrollPreviewContentView?
    private let state: ScrollControlState
    private var observing = false

    var windowCount: Int { panel == nil ? 0 : 1 }
    var panelFrame: CGRect? { panel?.frame }
    /// Pixel size of the image currently displayed; zero before the first frame.
    var displayedImageSize: CGSize { content?.imageSize ?? .zero }
    var isFollowingTail: Bool { content?.followsTail ?? false }

    init(state: ScrollControlState) { self.state = state }

    func show(near viewport: CGRect, avoiding: CGRect? = nil) {
        let visible = NSScreen.screens.map(\.visibleFrame).max { a, b in
            let x = a.intersection(viewport), y = b.intersection(viewport)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        } ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = Self.placement(near: viewport, avoiding: avoiding, visible: visible)
        if let panel { panel.setFrame(frame, display: true); panel.orderFrontRegardless(); return }
        let panel = CaptureHUDPanel(level: .floating, movable: true)
        let content = ScrollPreviewContentView()
        panel.contentView = content
        panel.setFrame(frame, display: true)
        panel.setAccessibilityLabel("长截图实时预览")
        self.panel = panel; self.content = content
        content.update(preview: state.preview)
        CaptureChrome.present(panel, content: content)
        observe()
    }

    func close() {
        observing = false
        let old = panel
        panel = nil
        content?.clear(); content = nil
        old?.orderOut(nil); old?.contentView = nil; old?.close()
    }

    /// Right of the viewport, else left, else overlapping its right edge; height follows the viewport.
    nonisolated static func placement(near viewport: CGRect, avoiding: CGRect?, visible: CGRect) -> CGRect {
        let width: CGFloat = 220, gap: CGFloat = 14
        let height = max(220, min(viewport.height, visible.height - 16, 560))
        var y = viewport.maxY - height
        y = min(max(y, visible.minY + 8), visible.maxY - height - 8)
        let right = CGRect(x: viewport.maxX + gap, y: y, width: width, height: height)
        let left = CGRect(x: viewport.minX - gap - width, y: y, width: width, height: height)
        for candidate in [right, left] where visible.contains(candidate) && !(avoiding?.intersects(candidate) ?? false) {
            return candidate
        }
        let inside = CGRect(x: min(viewport.maxX, visible.maxX) - width - 8, y: y, width: width, height: height)
        return inside
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        withObservationTracking { _ = state.preview } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing else { return }
                self.observing = false
                self.content?.update(preview: self.state.preview)
                self.observe()
            }
        }
    }
}

/// Header plus a scrollable thumbnail column; scrolling up pauses tail-following until "最新".
@MainActor
final class ScrollPreviewContentView: CaptureHUDMovableBackground {
    private let scrollView = NSScrollView()
    private let imageView = FlippedImageView()
    private let title = NSTextField(labelWithString: "实时预览")
    private let detail = NSTextField(labelWithString: "")
    private let latest = NSButton()
    private(set) var followsTail = true
    private var programmaticScroll = false
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    var imageSize: CGSize { imageView.image.map { CGSize(width: $0.size.width, height: $0.size.height) } ?? .zero }

    init() {
        super.init(cornerRadius: 14)
        title.font = .systemFont(ofSize: 12, weight: .semibold); title.textColor = CaptureChrome.primaryText
        detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); detail.textColor = CaptureChrome.secondaryText
        detail.alignment = .right
        latest.title = "最新"; latest.bezelStyle = .inline; latest.controlSize = .small
        latest.font = .systemFont(ofSize: 10, weight: .medium)
        latest.target = self; latest.action = #selector(followLatest); latest.isHidden = true
        latest.setAccessibilityLabel("回到最新内容")
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = imageView
        scrollView.contentView.postsBoundsChangedNotifications = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        for view in [title, detail, latest, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            latest.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            latest.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userScrolled() }
        }
    }

    required init?(coder: NSCoder) { nil }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }

    func update(preview: ScrollPreviewSnapshot?) {
        guard let preview else {
            imageView.image = nil; detail.stringValue = ""; layoutImage(); return
        }
        imageView.image = NSImage(cgImage: preview.image, size: CGSize(width: preview.image.width, height: preview.image.height))
        detail.stringValue = "\(preview.sourceWidth) × \(preview.sourceHeight)"
        layoutImage()
    }

    func clear() {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        imageView.image = nil
    }

    override func layout() { super.layout(); layoutImage() }

    private func layoutImage() {
        let width = max(1, scrollView.contentSize.width)
        guard let image = imageView.image, image.size.width > 0 else {
            imageView.frame = CGRect(x: 0, y: 0, width: width, height: 0); return
        }
        let height = (image.size.height * width / image.size.width).rounded()
        imageView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        if followsTail { scrollToTail() }
    }

    private func scrollToTail() {
        let maxY = max(0, imageView.frame.height - scrollView.contentSize.height)
        programmaticScroll = true
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        programmaticScroll = false
    }

    private func userScrolled() {
        guard !programmaticScroll else { return }
        let maxY = max(0, imageView.frame.height - scrollView.contentSize.height)
        followsTail = scrollView.contentView.bounds.minY >= maxY - 4
        latest.isHidden = followsTail
        detail.isHidden = !followsTail
    }

    @objc private func followLatest() {
        followsTail = true; latest.isHidden = true; detail.isHidden = false
        scrollToTail()
    }
}

/// Image view in top-left coordinates so the scroll origin is the long image's first row.
@MainActor
private final class FlippedImageView: NSImageView {
    override var isFlipped: Bool { true }
}
