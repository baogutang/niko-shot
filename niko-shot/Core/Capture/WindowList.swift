// Lazily caches native windows in compositor order and supports cycling through overlap.
import AppKit
@preconcurrency import ScreenCaptureKit

struct WindowCandidate: Sendable, Equatable, Identifiable {
    let id: UInt32
    let frame: CGRect
    let title: String
    let appBundleID: String
}

@MainActor
final class WindowList {
    private var cached: [WindowCandidate] = []
    private var refreshedAt = ContinuousClock.now
    private var valid = false
    /// Refreshes on demand after three seconds rather than polling the window server.
    func windows() async throws -> [WindowCandidate] {
        if valid, refreshedAt.duration(to: .now) < .seconds(3) { return cached }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ordered = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let ranks = Dictionary(uniqueKeysWithValues: ordered.enumerated().compactMap { index, info -> (UInt32, Int)? in
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            return (number.uint32Value, index)
        })
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        cached = content.windows.filter {
            $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 20 && $0.frame.height > 20
        }.sorted { ranks[$0.windowID, default: .max] < ranks[$1.windowID, default: .max] }.map {
            WindowCandidate(id: $0.windowID, frame: CoordinateSpace.windowToAppKit($0.frame, primaryTop: top), title: $0.title ?? $0.owningApplication?.applicationName ?? "窗口", appBundleID: $0.owningApplication?.bundleIdentifier ?? "")
        }
        valid = true
        refreshedAt = .now
        return cached
    }
    /// Returns front-to-back candidates under a global AppKit point.
    nonisolated static func hits(at point: CGPoint, in windows: [WindowCandidate]) -> [WindowCandidate] { windows.filter { $0.frame.contains(point) } }
    func invalidate() { valid = false; cached.removeAll() }
}
