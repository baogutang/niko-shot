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
    private let format: String

    /// Live HUD window count for coordinator teardown assertions.
    var windowCount: Int { panel == nil ? 0 : 1 }

    /// Creates controls without a window or any independent duration timer.
    init(session: RecordingSession, onStop: @escaping () -> Void,
         onCancel: @escaping () -> Void, onCamera: @escaping (Bool) -> Void,
         format: String = "mp4") {
        self.session = session
        self.onStop = onStop
        self.onCancel = onCancel
        self.onCamera = onCamera
        self.format = format.lowercased() == "gif" ? "GIF" : "MP4"
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
        let size = CGSize(width: min(352, frame.width - 16), height: session.errorMessage == nil ? 64 : 100)
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
        window.setAccessibilityHelp("当前录制格式 \(format)")
        let effect = RecordingHUDMaterial(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        let hosting = NSHostingView(rootView: RecordingControlBar(session: session, format: format,
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
        frame.size.height = error == nil ? 64 : 100
        if let screen = panel.screen { frame.origin.y = min(max(screen.visibleFrame.minY + 8, frame.minY), screen.visibleFrame.maxY - frame.height - 8) }
        panel.setFrame(frame, display: true)
    }
}

/// Native duration, transport and camera controls with 44-point pointer targets.
@MainActor
private struct RecordingControlBar: View {
    @Bindable var session: RecordingSession
    let format: String
    let onStop: () -> Void
    let onCancel: () -> Void
    let onCamera: (Bool) -> Void
    let onErrorChanged: (String?) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var interactive: Bool { session.state == .recording || session.state == .paused }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(session.state == .paused ? Color.orange : interactive ? Color.red : Color.secondary).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(durationLabel).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                            .accessibilityLabel("录制时长 \(durationLabel)")
                        Text("\(format) · \(stateTitle)").font(.system(size: 11)).foregroundStyle(.secondary)
                            .accessibilityLabel("录制格式 \(format)，\(stateTitle)")
                    }
                }.frame(width: 102, alignment: .leading)
                Divider().frame(height: 24).padding(.horizontal, 4)
                RecordingHUDButton(title: session.state == .paused ? "继续录制" : "暂停录制",
                                   symbol: session.state == .paused ? "play.fill" : "pause.fill", selected: session.state == .paused, enabled: interactive) {
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
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.red)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).help(error)
                    .accessibilityLabel("录屏错误：\(error)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background { if reduceTransparency { NikoTheme.canvas } }
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
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : tint).frame(width: 44, height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(NikoActionButtonStyle(prominent: selected)).disabled(!enabled)
        .focusable()
        .help(title).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor }
    }
}
