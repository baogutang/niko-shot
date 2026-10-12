// Dispatches scroll steps only during an active capture; it never observes global input.
import AppKit
@preconcurrency import ApplicationServices // The SDK exports the immutable AX prompt key as a legacy C var; it is read only on MainActor.

/// The automatic dispatcher and the user-driven mode share the same stable-frame stitcher.
public enum ScrollCaptureMode: String, CaseIterable, Sendable, Identifiable {
    case automatic, manual
    /// Stable identity for native mode pickers.
    public var id: String { rawValue }
    /// Localized mode title.
    public var title: String { self == .automatic ? "自动滚动" : "手动滚动" }
}

@MainActor
enum AutoScroller {
    /// Reads Accessibility consent without requesting input-monitoring permission.
    static var isAuthorized: Bool { AXIsProcessTrusted() }

    /// Requests only the consent required to dispatch an automatic scroll step.
    static func requestAuthorization() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Opens the system Accessibility pane for users who want to enable automatic mode.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Dispatches one downward step at a CoreGraphics global top-left point.
    static func step(points: CGFloat, at location: CGPoint) throws {
        guard isAuthorized else { throw AppError.permission("辅助功能") }
        guard points.isFinite, points > 0, location.x.isFinite, location.y.isFinite,
              let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                  wheel1: -Int32(min(8_192, max(1, points.rounded()))), wheel2: 0, wheel3: 0) else {
            throw AppError.file("无法派发滚动事件，请切换手动模式。")
        }
        event.location = location
        event.post(tap: .cghidEventTap)
    }
}
