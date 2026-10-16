// Hover hints for capture chrome. System tool tips sit far below the screen-saver-level capture overlay,
// so a toolbar button's help would open underneath it and never be seen; this one rides one level above.
import AppKit

@MainActor
final class HUDTooltip {
    static let shared = HUDTooltip()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private weak var owner: NSView?
    private var pending: Task<Void, Never>?
    private var hiddenAt = Date.distantPast
    /// First hint after a pause waits a moment; moving along the bar switches at once.
    var restingDelay: Duration = .milliseconds(380)
    var warmDelay: Duration = .milliseconds(30)

    var isVisible: Bool { panel?.isVisible == true }
    var text: String { label.stringValue }

    /// Shows `text` for `view` after the hover delay; a later call for another view replaces it.
    func schedule(_ text: String, for view: NSView) {
        guard !text.isEmpty else { return }
        pending?.cancel()
        owner = view
        let warm = isVisible || Date().timeIntervalSince(hiddenAt) < 0.6
        let delay = warm ? warmDelay : restingDelay
        pending = Task { [weak self, weak view] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let view, self.owner === view, view.window?.isVisible == true else { return }
            self.show(text, for: view)
        }
    }

    /// Hides the hint if it belongs to `view` (or any hint when `view` is nil).
    func hide(for view: NSView? = nil) {
        if let view, owner !== view { return }
        pending?.cancel(); pending = nil
        owner = nil
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        hiddenAt = Date()
    }

    func show(_ text: String, for view: NSView) {
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label.attributedStringValue = Self.attributed(text)
        let textSize = label.intrinsicContentSize
        let size = CGSize(width: ceil(textSize.width) + 20, height: ceil(textSize.height) + 10)
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        panel.setFrame(Self.frame(size: size, anchor: anchor, visible: screen.visibleFrame), display: false)
        label.frame = CGRect(x: 10, y: 5, width: size.width - 20, height: size.height - 10)
        panel.orderFrontRegardless()
    }

    /// Above the control, centred on it; below it when the screen top is too close; always on screen.
    nonisolated static func frame(size: CGSize, anchor: CGRect, visible: CGRect) -> CGRect {
        let gap: CGFloat = 6
        var y = anchor.maxY + gap
        if y + size.height > visible.maxY { y = anchor.minY - gap - size.height }
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 4), visible.maxX - size.width - 4)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// "名称  快捷键": the shortcut after two spaces reads lighter than the name.
    private static func attributed(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let parts = text.components(separatedBy: "  ")
        result.append(NSAttributedString(string: parts[0], attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]))
        if parts.count > 1 {
            result.append(NSAttributedString(string: "   " + parts.dropFirst().joined(separator: "  "), attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.6)]))
        }
        return result
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setAccessibilityElement(false)
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.94).cgColor
        background.layer?.cornerRadius = 7
        background.layer?.cornerCurve = .continuous
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        background.layer?.borderWidth = 0.5
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        background.addSubview(label)
        panel.contentView = background
        return panel
    }
}
