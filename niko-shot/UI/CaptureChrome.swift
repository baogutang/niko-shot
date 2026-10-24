// Shared dark-glass chrome for every floating capture surface: toolbar, long-capture HUD and previews.
import AppKit
import SwiftUI

/// Visual constants shared by AppKit and SwiftUI capture surfaces.
@MainActor
enum CaptureChrome {
    static let cornerRadius: CGFloat = 12
    static let buttonSize: CGFloat = 30
    static let buttonRadius: CGFloat = 7
    /// Icon amber; the HUD is always dark glass, so the accent does not follow the system appearance.
    static var accent: NSColor { NikoAccent.bright }
    static var accentColor: Color { Color(nsColor: accent) }
    static let surfaceTint = NSColor(calibratedWhite: 0.08, alpha: 1)
    static let border = NSColor.white.withAlphaComponent(0.13)
    static let hover = NSColor.white.withAlphaComponent(0.09)
    static let pressed = NSColor.white.withAlphaComponent(0.16)
    static let separator = NSColor.white.withAlphaComponent(0.14)
    static let primaryText = NSColor.white.withAlphaComponent(0.94)
    static let secondaryText = NSColor.white.withAlphaComponent(0.58)

    /// Above full-screen capture overlays, below system alerts.
    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    /// Fades and slightly scales a newly shown surface; respects Reduce Motion.
    static func present(_ panel: NSPanel, content: NSView?) {
        guard !panel.isVisible else { panel.orderFrontRegardless(); return }
        guard !reduceMotion else { panel.alphaValue = 1; panel.orderFrontRegardless(); return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if let layer = content?.layer {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.96; spring.toValue = 1
            spring.stiffness = 420; spring.damping = 32; spring.mass = 1
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "captureChromeEntrance")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }
}

/// A borderless, nonactivating floating panel that never takes the target app's focus unless asked.
@MainActor
final class CaptureHUDPanel: NSPanel {
    var allowsKey = false
    var onCancel: (() -> Void)?

    init(level: NSWindow.Level = CaptureChrome.overlayLevel, movable: Bool = false) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // isFloatingPanel resets the level; assign the capture level afterwards.
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        isMovableByWindowBackground = movable
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Dark vibrant glass with a hairline edge; falls back to an opaque surface for Reduce Transparency.
@MainActor
class CaptureHUDBackground: NSVisualEffectView {
    private let displayNotifications = NSWorkspace.shared.notificationCenter

    init(cornerRadius: CGFloat = CaptureChrome.cornerRadius) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        displayNotifications.addObserver(self, selector: #selector(refresh),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { nil }
    deinit { displayNotifications.removeObserver(self) }

    @objc func refresh() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.borderWidth = contrast ? 1 : 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(contrast ? 0.45 : 0.13).cgColor
        layer?.backgroundColor = CaptureChrome.surfaceTint
            .withAlphaComponent(CaptureChrome.reduceTransparency ? 1 : 0.55).cgColor
    }
}

/// A draggable variant used by HUDs the user may reposition.
@MainActor
class CaptureHUDMovableBackground: CaptureHUDBackground {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// SwiftUI button treatment matching the AppKit toolbar buttons.
struct CaptureHUDButtonStyle: ButtonStyle {
    var prominent = false
    var selected = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? NikoTheme.onAccent : selected ? CaptureChrome.accentColor : Color.white.opacity(0.92))
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: CaptureChrome.buttonRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: CaptureChrome.buttonRadius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func background(_ pressed: Bool) -> Color {
        if prominent { return CaptureChrome.accentColor.opacity(pressed ? 0.75 : hovering ? 0.92 : 1) }
        if selected { return CaptureChrome.accentColor.opacity(pressed ? 0.32 : 0.22) }
        return Color.white.opacity(pressed ? 0.16 : hovering ? 0.09 : 0)
    }
}

/// A small key-cap hint such as "↩" or "esc".
struct CaptureKeyHint: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.horizontal, 5).frame(height: 16)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}
