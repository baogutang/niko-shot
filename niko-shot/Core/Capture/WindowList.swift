// Lists on-screen windows in compositor order and supports cycling through overlap.
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
    /// Queried fresh for every capture: a list reused from a few seconds earlier highlights windows
    /// that have since moved or closed. The query runs alongside the screen freeze, so it costs no wall time.
    func windows() async throws -> [WindowCandidate] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ordered = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let ranks = Dictionary(uniqueKeysWithValues: ordered.enumerated().compactMap { index, info -> (UInt32, Int)? in
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            return (number.uint32Value, index)
        })
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return content.windows.filter {
            $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 20 && $0.frame.height > 20
        }.sorted { ranks[$0.windowID, default: .max] < ranks[$1.windowID, default: .max] }.map {
            WindowCandidate(id: $0.windowID, frame: CoordinateSpace.windowToAppKit($0.frame, primaryTop: top), title: $0.title ?? $0.owningApplication?.applicationName ?? "窗口", appBundleID: $0.owningApplication?.bundleIdentifier ?? "")
        }
    }
    /// Returns front-to-back candidates under a global AppKit point.
    nonisolated static func hits(at point: CGPoint, in windows: [WindowCandidate]) -> [WindowCandidate] { windows.filter { $0.frame.contains(point) } }
}
