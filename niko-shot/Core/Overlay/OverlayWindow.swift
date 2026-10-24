// Hosts a single display's frozen-frame interaction in every Space.
import AppKit

final class OverlayWindow: NSWindow {
    /// Builds a screen-saver-level overlay with full-screen Space support. Its content always covers the
    /// display with the frozen frame, so the window is opaque and the compositor skips everything below it.
    init(screen: ScreenGeometry, view: NSView) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = view
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
