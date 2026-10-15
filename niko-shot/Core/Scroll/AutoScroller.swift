// Dispatches tagged pixel wheel steps for automatic long captures; requires Accessibility consent.
import AppKit
@preconcurrency import ApplicationServices // The SDK exports the immutable AX prompt key as a legacy C var; it is read only on MainActor.

@MainActor
enum AutoScroller {
    /// Marks synthetic events so the monitor can tell them apart from the user's own scrolling.
    static let eventMarker: Int64 = 0x4e494b4f53484f54
    /// Reads Accessibility consent without prompting.
    static var isAuthorized: Bool { AXIsProcessTrusted() }

    /// Asks macOS to list the app in the Accessibility pane (shows the system prompt once).
    @discardableResult
    static func requestAuthorization() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Dispatches one step at a CoreGraphics global top-left point; positive points scroll toward the end.
    static func step(points: CGFloat, at location: CGPoint) throws {
        guard isAuthorized else { throw AppError.permission("辅助功能") }
        let magnitude = Int32(min(8_192, max(1, abs(points).rounded())))
        guard points.isFinite, points != 0, location.x.isFinite, location.y.isFinite,
              let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                  wheel1: points > 0 ? -magnitude : magnitude, wheel2: 0, wheel3: 0) else {
            throw AppError.file("无法派发滚动事件，请改为手动滚动。")
        }
        event.location = location
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        event.post(tap: .cghidEventTap)
    }
}
