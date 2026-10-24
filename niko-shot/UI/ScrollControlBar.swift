// Compact long-capture HUD: live progress, guidance, automatic scrolling and completion.
import AppKit
import Observation
import SwiftUI

/// Observable scalar progress shared by the HUD and the live preview.
@MainActor @Observable
final class ScrollControlState {
    enum Phase: Sendable { case preparing, capturing, finishing }
    enum Tone: Sendable { case normal, warning, success }

    var phase: Phase = .preparing
    var isAutomatic = false
    var width = 0
    var height = 0
    var frames = 0
    var title = "准备长截图"
    var message = "正在捕获首屏…"
    var tone: Tone = .normal
    var preview: ScrollPreviewSnapshot?
    var showsPreview = true
    var canFinish: Bool { frames > 0 && phase == .capturing }

    init() {}

    func reset() {
        phase = .preparing; isAutomatic = false; width = 0; height = 0; frames = 0
        title = "准备长截图"; message = "正在捕获首屏…"; tone = .normal; preview = nil; showsPreview = true
    }
}

/// Owns the nonactivating HUD; buttons work without stealing the scrolled app's focus.
@MainActor
final class ScrollControlBarController {
    private var panel: CaptureHUDPanel?
    private let state: ScrollControlState
    private let onFinish: () -> Void
    private let onCancel: () -> Void
    private let onToggleAutomatic: () -> Void
    private let onTogglePreview: () -> Void

    var windowCount: Int { panel == nil ? 0 : 1 }
    var panelFrame: CGRect? { panel?.frame }

    init(state: ScrollControlState, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void,
         onToggleAutomatic: @escaping () -> Void, onTogglePreview: @escaping () -> Void) {
        self.state = state; self.onFinish = onFinish; self.onCancel = onCancel
        self.onToggleAutomatic = onToggleAutomatic; self.onTogglePreview = onTogglePreview
    }

    /// Shows the HUD below (or above) the viewport, clamped to the viewport's display.
    func show(near viewport: CGRect) {
        let size = CGSize(width: 600, height: 56)
        let visible = NSScreen.screens.map(\.visibleFrame).max { a, b in
            let x = a.intersection(viewport), y = b.intersection(viewport)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        } ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = Self.placement(size: size, near: viewport, visible: visible)
        if let panel { panel.setFrame(frame, display: true); panel.orderFrontRegardless(); return }
        let panel = CaptureHUDPanel(level: .floating, movable: true)
        let background = CaptureHUDMovableBackground(cornerRadius: 14)
        let hosting = NSHostingView(rootView: ScrollHUDView(state: state,
            onFinish: { [weak self] in self?.onFinish() }, onCancel: { [weak self] in self?.onCancel() },
            onToggleAutomatic: { [weak self] in self?.onToggleAutomatic() },
            onTogglePreview: { [weak self] in self?.onTogglePreview() }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        panel.contentView = background
        panel.setFrame(frame, display: true)
        panel.setAccessibilityLabel("长截图控制条")
        self.panel = panel
        CaptureChrome.present(panel, content: background)
    }

    func close() {
        let old = panel
        panel = nil
        old?.orderOut(nil); old?.contentView = nil; old?.close()
    }

    /// Prefers below the viewport, then above, then inside its lower edge.
    nonisolated static func placement(size: CGSize, near viewport: CGRect, visible: CGRect) -> CGRect {
        let gap: CGFloat = 12
        let x = min(max(viewport.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let below = viewport.minY - gap - size.height
        if below >= visible.minY + 8 { return CGRect(x: x, y: below, width: size.width, height: size.height) }
        let above = viewport.maxY + gap
        if above + size.height <= visible.maxY - 8 { return CGRect(x: x, y: above, width: size.width, height: size.height) }
        return CGRect(x: x, y: max(visible.minY + 8, viewport.minY + 16), width: size.width, height: size.height)
    }
}

@MainActor
private struct ScrollHUDView: View {
    @Bindable var state: ScrollControlState
    let onFinish: () -> Void
    let onCancel: () -> Void
    let onToggleAutomatic: () -> Void
    let onTogglePreview: () -> Void
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(state.message).font(.system(size: 11)).foregroundStyle(messageColor)
                    .lineLimit(1).truncationMode(.tail).help(state.message)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: state.height > 0 ? "\(state.height) px" : "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
                Text("\(state.frames) 段").font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 74, alignment: .trailing)
            .accessibilityLabel("长图高度 \(state.height) 像素，已拼接 \(state.frames) 段")
            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 26)
            Button(action: onToggleAutomatic) {
                Label(state.isAutomatic ? "暂停" : "自动", systemImage: state.isAutomatic ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .medium)).labelStyle(.titleAndIcon)
                    .padding(.horizontal, 9).frame(height: 30)
            }
            .buttonStyle(CaptureHUDButtonStyle(selected: state.isAutomatic))
            .disabled(state.phase != .capturing)
            .help(state.isAutomatic ? "暂停自动滚动，继续手动滚动" : "自动向下滚动直到底部（需要辅助功能权限）")
            Button(action: onTogglePreview) {
                Image(systemName: "sidebar.right").font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30)
            }
            .buttonStyle(CaptureHUDButtonStyle(selected: state.showsPreview))
            .help(state.showsPreview ? "隐藏实时预览" : "显示实时预览")
            .accessibilityLabel(state.showsPreview ? "隐藏实时预览" : "显示实时预览")
            Button(action: onCancel) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
            }
            .buttonStyle(CaptureHUDButtonStyle())
            .help("取消长截图（Esc）").accessibilityLabel("取消长截图")
            Button(action: onFinish) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    Text("完成").font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12).frame(height: 30)
            }
            .buttonStyle(CaptureHUDButtonStyle(prominent: true))
            .disabled(!state.canFinish)
            .help("完成并进入标注（↩）").accessibilityLabel("完成长截图")
        }
        .padding(.leading, 12).padding(.trailing, 10)
        .frame(height: 56)
        .onAppear { pulse = true }
    }

    private var messageColor: Color {
        switch state.tone {
        case .normal: .white.opacity(0.6)
        case .warning: Color(nsColor: .systemOrange)
        case .success: Color(nsColor: .systemGreen)
        }
    }

    private var indicator: some View {
        ZStack {
            Circle().fill(indicatorColor.opacity(0.2)).frame(width: 30, height: 30)
            if state.phase == .capturing && !reduceMotion {
                Circle().stroke(indicatorColor.opacity(0.55), lineWidth: 1.5)
                    .frame(width: 30, height: 30)
                    .scaleEffect(pulse ? 1.35 : 1).opacity(pulse ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
            }
            Image(systemName: indicatorSymbol).font(.system(size: 13, weight: .bold)).foregroundStyle(indicatorColor)
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private var indicatorColor: Color {
        state.tone == .warning ? Color(nsColor: .systemOrange) : state.tone == .success ? Color(nsColor: .systemGreen) : CaptureChrome.accentColor
    }

    private var indicatorSymbol: String {
        switch state.phase {
        case .preparing: "viewfinder"
        case .finishing: "hourglass"
        case .capturing: state.tone == .warning ? "exclamationmark" : state.isAutomatic ? "arrow.down.to.line" : "arrow.down"
        }
    }
}
