// Hosts a native, timer-free recording HUD driven exclusively by observable session updates.
import AppKit
import SwiftUI

/// Owns the floating controls for a single recording session.
@MainActor
final class RecordingControlBarController {
    nonisolated(unsafe) private var panel: RecordingHUDPanel?
    private var hosting: NSHostingView<RecordingControlBar>?
    private let session: RecordingSession
    private let onStop: () -> Void
    private let onCancel: () -> Void
    private let onCamera: (Bool) -> Void

    /// Live HUD window count for coordinator teardown assertions.
    var windowCount: Int { panel == nil ? 0 : 1 }

    /// Creates controls without a window or any independent duration timer.
    init(session: RecordingSession, onStop: @escaping () -> Void,
         onCancel: @escaping () -> Void, onCamera: @escaping (Bool) -> Void) {
        self.session = session
        self.onStop = onStop
        self.onCancel = onCancel
        self.onCamera = onCamera
    }

    deinit {
        guard let remaining = panel else { return }
        // Explicit close() is the normal path; regular deinit avoids the older isolated-deinit runtime.
        if Thread.isMainThread {
            MainActor.assumeIsolated { remaining.orderOut(nil); remaining.contentView = nil; remaining.close() }
        } else {
            Task { @MainActor in remaining.orderOut(nil); remaining.contentView = nil; remaining.close() }
        }
    }

    /// Presents a nonactivating HUD near the bottom of the current screen.
    func show() {
        if let panel { panel.orderFrontRegardless(); return }
        let frame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let size = CGSize(width: min(392, frame.width - 16), height: session.errorMessage == nil ? 68 : 102)
        let window = RecordingHUDPanel(contentRect: CGRect(x: frame.midX - size.width / 2, y: frame.minY + 24, width: size.width, height: size.height),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isMovableByWindowBackground = true
        window.setAccessibilityLabel("录屏控制条")
        let effect = RecordingHUDMaterial(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: RecordingControlBar(session: session,
                                                                 onStop: { [weak self] in self?.onStop() },
                                                                 onCancel: { [weak self] in self?.onCancel() },
                                                                 onCamera: { [weak self] in self?.onCamera($0) },
                                                                 onErrorChanged: { [weak self] in self?.resizeForError($0) }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor), hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        window.contentView = effect
        self.hosting = hosting
        panel = window
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.orderFrontRegardless()
        } else {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = 1
            }
        }
    }

    /// Removes the panel immediately so it cannot appear in a subsequent capture.
    func close() {
        let old = panel
        panel = nil
        hosting = nil
        old?.orderOut(nil)
        old?.contentView = nil
        old?.close()
    }

    private func resizeForError(_ error: String?) {
        guard let panel else { return }
        var frame = panel.frame
        frame.size.height = error == nil ? 68 : 102
        if let screen = panel.screen { frame.origin.y = min(max(screen.visibleFrame.minY + 8, frame.minY), screen.visibleFrame.maxY - frame.height - 8) }
        panel.setFrame(frame, display: true)
    }
}

/// Native duration, transport and camera controls with 44-point pointer targets.
@MainActor
private struct RecordingControlBar: View {
    @Bindable var session: RecordingSession
    let onStop: () -> Void
    let onCancel: () -> Void
    let onCamera: (Bool) -> Void
    let onErrorChanged: (String?) -> Void

    private var interactive: Bool { session.state == .recording || session.state == .paused }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(session.state == .paused ? Color.orange : Color.red).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(durationLabel).font(.system(size: 15, weight: .medium, design: .monospaced)).monospacedDigit()
                            .accessibilityLabel("录制时长 \(durationLabel)")
                        Text(stateTitle).font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(width: 115, alignment: .leading)
                Divider().frame(height: 26).padding(.horizontal, 3)
                RecordingHUDButton(title: session.state == .paused ? "继续录制" : "暂停录制",
                                   symbol: session.state == .paused ? "play.fill" : "pause.fill", enabled: interactive) {
                    if session.state == .paused { session.resume() } else { session.pause() }
                }.keyboardShortcut(.space, modifiers: [])
                RecordingHUDButton(title: "停止录制并保存", symbol: "stop.fill", tint: .red, enabled: interactive, action: onStop)
                    .keyboardShortcut(.return, modifiers: .command)
                RecordingHUDButton(title: session.cameraSession == nil ? "开启摄像头画中画" : "关闭摄像头画中画",
                                   symbol: session.cameraSession == nil ? "video" : "video.fill", selected: session.cameraSession != nil, enabled: interactive) {
                    onCamera(session.cameraSession == nil)
                }.keyboardShortcut("c", modifiers: [.command, .shift])
                RecordingHUDButton(title: "取消录制并丢弃视频", symbol: "xmark", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).help(error)
                    .accessibilityLabel("录屏错误：\(error)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .onChange(of: session.errorMessage) { _, error in onErrorChanged(error) }
    }

    private var durationLabel: String {
        let seconds = Int(session.duration.isFinite ? min(Double(Int.max / 2), max(0, session.duration)) : 0)
        if seconds >= 3600 { return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var stateTitle: String {
        switch session.state {
        case .recording: "录制中"
        case .paused: "已暂停"
        case .preparing: "准备录制"
        case .finishing: "正在保存"
        case .failed: "录制失败"
        case .idle: "等待录制"
        }
    }
}

@MainActor
private struct RecordingHUDButton: View {
    let title: String
    let symbol: String
    var tint: Color = .primary
    var selected = false
    var enabled = true
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint).frame(width: 44, height: 44)
                .background(selected ? Color.accentColor.opacity(0.2) : hovered ? Color.primary.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 11))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
        .focusable()
        .scaleEffect(hovered && enabled && !reduceMotion ? 1.06 : 1)
        .animation(reduceMotion ? nil : .spring(duration: 0.15, bounce: 0.12), value: hovered)
        .onHover { hovered = $0 }.help(title).accessibilityLabel(title)
    }
}

@MainActor
private final class RecordingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RecordingHUDMaterial: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}
