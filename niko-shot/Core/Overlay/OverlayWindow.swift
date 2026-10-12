// Hosts a single display's frozen-frame interaction in every Space.
import AppKit

final class OverlayWindow: NSWindow {
    /// Builds a non-opaque screen-saver-level overlay with full-screen Space support.
    init(screen: ScreenGeometry, view: NSView) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = view
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
