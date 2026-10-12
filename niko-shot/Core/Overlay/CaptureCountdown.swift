// Displays an event-driven cancellable countdown only while a delayed capture is active.
import AppKit
import SwiftUI

@MainActor
final class CaptureCountdown {
    private var window: NSPanel?
    private var cancelled = false
    private var sleeper: Task<Void, Error>?
    private var localMonitor: Any?
    var windowCount: Int { window == nil ? 0 : 1 }
    var monitorCount: Int { localMonitor == nil ? 0 : 1 }
    /// Cancels the active sleep and immediately removes the countdown UI and listener.
    func cancel() {
        cancelled = true; sleeper?.cancel(); sleeper = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        window?.orderOut(nil); window?.close(); window = nil
    }
    /// Shows a ring without retaining a timer after the countdown finishes.
    func wait(seconds: Int) async throws {
        guard seconds > 0 else { return }
        guard window == nil else { throw AppError.busy }
        cancelled = false
        let panel = CountdownPanel(contentRect: CGRect(x: 0, y: 0, width: 120, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.backgroundColor = .clear; panel.isOpaque = false
        panel.center(); panel.isReleasedWhenClosed = false
        window = panel
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        defer { if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil; sleeper?.cancel(); sleeper = nil; panel.orderOut(nil); panel.close(); window = nil }
        for remaining in stride(from: min(10, seconds), through: 1, by: -1) {
            try Task.checkCancellation()
            if cancelled { throw CancellationError() }
            panel.contentView = NSHostingView(rootView: CountdownRing(remaining: remaining, total: seconds, cancel: { [weak self] in self?.cancel() }))
            panel.makeKeyAndOrderFront(nil)
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct CountdownRing: View {
    let remaining: Int
    let total: Int
    let cancel: () -> Void
    var body: some View {
        ZStack { Circle().fill(.ultraThinMaterial); Circle().trim(from: 0, to: Double(remaining) / Double(total)).stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90)).padding(8); VStack { Text("\(remaining)").font(.system(size: 42, weight: .medium, design: .rounded)).monospacedDigit(); Button("取消", action: cancel).buttonStyle(.plain).font(.caption) } }.padding(4).accessibilityLabel("\(remaining) 秒后截图")
    }
}
