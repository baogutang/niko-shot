// Displays an event-driven cancellable countdown only while a delayed capture is active.
import AppKit
import SwiftUI

@MainActor
final class CaptureCountdown {
    private var window: NSPanel?
    private var cancelled = false
    private var sleeper: Task<Void, Error>?
    /// Esc is a short-lived global key: the countdown never activates niko-shot, so menus and hover
    /// states in the app being captured stay open until the shot is taken.
    private let escape = TransientHotkeys()
    var windowCount: Int { window == nil ? 0 : 1 }
    var monitorCount: Int { escape.count }
    /// Cancels the active sleep and immediately removes the countdown UI and listener.
    func cancel() {
        cancelled = true; sleeper?.cancel(); sleeper = nil
        escape.unregister()
        window?.orderOut(nil); window?.close(); window = nil
    }
    /// Shows a ring without retaining a timer after the countdown finishes.
    func wait(seconds: Int, actionName: String = "截图") async throws {
        guard seconds > 0 else { return }
        guard window == nil else { throw AppError.busy }
        cancelled = false
        let panel = CountdownPanel(contentRect: CGRect(x: 0, y: 0, width: 120, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.backgroundColor = .clear; panel.isOpaque = false
        panel.center(); panel.isReleasedWhenClosed = false
        window = panel
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        escape.register([(keyCode: 53, action: { [weak self] in self?.cancel() })])
        defer { escape.unregister(); sleeper?.cancel(); sleeper = nil; panel.orderOut(nil); panel.close(); window = nil }
        for remaining in stride(from: min(10, seconds), through: 1, by: -1) {
            try Task.checkCancellation()
            if cancelled { throw CancellationError() }
            panel.contentView = NSHostingView(rootView: CountdownRing(remaining: remaining, total: seconds, actionName: actionName, cancel: { [weak self] in self?.cancel() }))
            panel.orderFrontRegardless()
            let sleep = Task { try await Task.sleep(for: .seconds(1)) }
            sleeper = sleep
            try await withTaskCancellationHandler { try await sleep.value } onCancel: { sleep.cancel() }
            sleeper = nil
        }
        if cancelled { throw CancellationError() }
    }
}

@MainActor
private final class CountdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CountdownRing: View {
    let remaining: Int
    let total: Int
    let actionName: String
    let cancel: () -> Void
    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().trim(from: 0, to: Double(remaining) / Double(total))
                .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90)).padding(8)
            VStack(spacing: 0) {
                Text("\(remaining)").font(.system(size: 42, weight: .medium, design: .rounded)).monospacedDigit()
                    .accessibilityLabel("\(remaining) 秒后\(actionName)")
                Button("取消", action: cancel).buttonStyle(.plain).font(.caption)
                    .frame(minWidth: 44, minHeight: 44).accessibilityLabel("取消\(actionName)倒计时")
            }
        }.padding(4).accessibilityElement(children: .contain).accessibilityLabel("\(actionName)倒计时")
    }
}
