// Releases transient SwiftUI content when a utility window closes instead of retaining an idle workspace.
import AppKit

@MainActor
final class UtilityWindow: NSWindow {
    var onClose: (() -> Void)?

    override func close() {
        let callback = onClose
        onClose = nil
        super.close()
        contentView = nil
        callback?()
    }
}
