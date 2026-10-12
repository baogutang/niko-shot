// Uses Core Animation layers for frozen-frame selection; no full-screen drawRect work.
import AppKit
import QuartzCore

@MainActor
final class SelectionView: NSView {
    let frameInfo: FrozenFrame
    var onSelection: ((CGRect) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var selection: CGRect = .zero { didSet { updateLayers() } }
    private var anchor: CGPoint?
    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let badge = CATextLayer()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frameInfo: FrozenFrame) {
        self.frameInfo = frameInfo
        super.init(frame: frameInfo.screen.localBounds)
        wantsLayer = true
        layer?.contents = frameInfo.image
        layer?.contentsGravity = .resize
        dim.fillColor = NSColor.black.withAlphaComponent(0.36).cgColor
        dim.fillRule = .evenOdd
        border.strokeColor = NSColor.controlAccentColor.cgColor
        border.fillColor = NSColor.clear.cgColor
        border.lineWidth = 1 / frameInfo.screen.scale
        badge.fontSize = 12
        badge.alignmentMode = .center
        badge.foregroundColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        badge.cornerRadius = 6
        badge.contentsScale = frameInfo.screen.scale
        [dim, border, badge].forEach { layer?.addSublayer($0) }
        setAccessibilityElement(true)
        setAccessibilityLabel("截图选区，拖动鼠标选择，回车复制，Escape 取消")
        updateLayers()
    }
    required init?(coder: NSCoder) { return nil }

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        path.addRect(bounds)
        if !selection.isEmpty { path.addRect(selection) }
        dim.path = path
        border.path = CGPath(rect: selection, transform: nil)
        badge.isHidden = selection.isEmpty
        let scale = AppSettings.shared.showsPixels ? frameInfo.screen.scale : 1
        let size = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded())) \(scale == 1 ? "pt" : "px")"
        badge.string = size
        badge.frame = CGRect(x: min(max(8, selection.midX - 78), bounds.width - 164), y: max(frameInfo.screen.safeTop + 8, selection.minY - 34), width: 156, height: 26)
        setAccessibilityValue(size)
        CATransaction.commit()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        anchor = bounded(convert(event.locationInWindow, from: nil))
        selection = .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = bounded(convert(event.locationInWindow, from: nil))
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y), width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        onSelection?(selection)
    }
    override func mouseUp(with event: NSEvent) { anchor = nil; onSelection?(selection) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onConfirm?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }
    private func bounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
    }
}
