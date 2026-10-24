// Hands keyboard focus back to the app the user was working in once niko-shot's own UI goes away.
import AppKit

/// An accessory app that closes its last window stays active with nothing to type into, so ⌘V after a
/// capture would land nowhere. This remembers the last other app that was active and yields to it.
@MainActor
final class FocusReturn {
    private(set) var lastExternalApp: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    init() {
        record(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.record(app) }
        }
    }

    func stop() {
        pending?.cancel(); pending = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    /// Yields focus shortly after the current event, once `allowed` still holds: a window opened in the
    /// meantime (save panel, OCR workspace) or a capture that started keeps focus where it is.
    func returnSoon(when allowed: @escaping @MainActor () -> Bool) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self, allowed() else { return }
            self.returnNow()
        }
    }

    private func returnNow() {
        guard NSApp.isActive,
              !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
              let app = lastExternalApp, !app.isTerminated else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }

    private func record(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular else { return }
        lastExternalApp = app
    }
}
