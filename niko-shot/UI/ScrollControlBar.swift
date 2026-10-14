// Hosts native scroll progress; pixel-level matching controls require an explicit advanced action.
import AppKit
import Observation
import SwiftUI

/// Observable progress supplied by the capture coordinator; the UI never drives a capture timer.
@MainActor @Observable
final class ScrollControlState {
    /// Current effective mode, including a coordinator-selected manual fallback.
    var mode: ScrollCaptureMode = .manual
    /// The stitched image's current height in pixels.
    var height = 0
    /// Number of accepted samples; a small wheel movement adds a partial-screen segment.
    var frames = 0
    /// Current capture or recovery message.
    var status = "准备开始"
    /// A paused capture exposes an explicit Retry action.
    var isPaused = false
    /// An unaligned candidate is retained while capture automatically looks for a safe continuation.
    var isMatching = false
    /// The candidate's normalized correlation, when available.
    var correlation: Float?
    /// Suggested or last confirmed full-width overlap in pixels.
    var overlap = 150
    /// Largest valid overlap; the coordinator sets this to the smaller usable frame height minus one.
    var maximumOverlap = 199
    /// Advanced controls stay collapsed during ordinary manual capture.
    var showsAdvanced = false
    /// First-frame preparation, seam application or PNG encoding disables conflicting commands.
    var isWorking = false
    /// A terminal disk worker can be replaced but must never be retried.
    var requiresRestart = false
    /// A moved region, resized window or changed display needs a new native selection.
    var requiresReselection = false
    /// The user is browsing already-captured content above the accepted boundary.
    var isBacktracking = false
    var ignoredTop = 0
    var ignoredBottom = 0
    /// Shares the actor's bounded accepted-result thumbnail with the companion preview panel.
    var preview: ScrollPreviewSnapshot?
    var showsPreview = true

    var progress: ScrollControlProgress {
        ScrollControlProgress(mode: mode, height: height, frames: frames, status: status,
            isPaused: isPaused, isMatching: isMatching, isWorking: isWorking,
            requiresRestart: requiresRestart, requiresReselection: requiresReselection, isBacktracking: isBacktracking,
            showsAdvanced: showsAdvanced)
    }

    /// Creates idle progress without any window, timer, capture, or permission request.
    init() {}
}

/// Sendable scalar diagnostics for the coordinator and its real workflow tests.
struct ScrollControlProgress: Sendable {
    let mode: ScrollCaptureMode
    let height: Int
    let frames: Int
    let status: String
    let isPaused: Bool
    let isMatching: Bool
    let isWorking: Bool
    let requiresRestart: Bool
    let requiresReselection: Bool
    let isBacktracking: Bool
    let showsAdvanced: Bool
}

/// Owns a nonactivating HUD that accepts keyboard focus only after user interaction.
@MainActor
final class ScrollControlBarController {
    nonisolated(unsafe) private var panel: ScrollHUDPanel?
    private var hosting: NSHostingView<ScrollControlBar>?
    private let state: ScrollControlState
    private let onFinish: () -> Void
    private let onCancel: () -> Void
    private let onRetry: () -> Void
    private let onManualOverlap: (Int) -> Void
    private let onManualMode: () -> Void
    private let onAdvancedSettings: () -> Void
    private let onAutomaticMode: () -> Void
    private let onPause: () -> Void
    private let onTogglePreview: () -> Void
    private var selectionGlobal: CGRect?

    /// Retained HUD count for lifecycle assertions.
    var windowCount: Int { panel == nil ? 0 : 1 }
    var panelFrame: CGRect? { panel?.frame }

    /// Creates controls without allocating a panel or running a timer.
    init(state: ScrollControlState, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void,
         onRetry: @escaping () -> Void, onManualOverlap: @escaping (Int) -> Void,
         onManualMode: @escaping () -> Void, onAdvancedSettings: @escaping () -> Void = {},
         onAutomaticMode: @escaping () -> Void = {}, onPause: @escaping () -> Void = {},
         onTogglePreview: @escaping () -> Void = {}) {
        self.state = state
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.onManualOverlap = onManualOverlap
        self.onManualMode = onManualMode
        self.onAdvancedSettings = onAdvancedSettings; self.onAutomaticMode = onAutomaticMode; self.onPause = onPause
        self.onTogglePreview = onTogglePreview
    }

    deinit {
        guard let remaining = panel else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { remaining.orderOut(nil); remaining.contentView = nil; remaining.close() }
        } else {
            Task { @MainActor in remaining.orderOut(nil); remaining.contentView = nil; remaining.close() }
        }
    }

    /// Shows the HUD beside an optional selection in AppKit global coordinates, clamped to its screen.
    func show(near selection: CGRect? = nil) {
        if let panel { resizeForState(); panel.orderFrontRegardless(); return }
        selectionGlobal = selection
        let screen = selection.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let size = CGSize(width: min(384, visible.width - 16), height: desiredHeight)
        let window = ScrollHUDPanel(contentRect: placement(size: size, visible: visible, selection: selection),
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
        window.setAccessibilityLabel("长截图控制条")
        let effect = ScrollHUDMaterial(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        let hosting = NSHostingView(rootView: ScrollControlBar(state: state,
            onFinish: { [weak self] in self?.onFinish() }, onCancel: { [weak self] in self?.onCancel() },
            onRetry: { [weak self] in self?.onRetry() }, onManualOverlap: { [weak self] in self?.onManualOverlap($0) },
            onManualMode: { [weak self] in self?.onManualMode() },
            onAdvancedSettings: { [weak self] in self?.onAdvancedSettings() },
            onAutomaticMode: { [weak self] in self?.onAutomaticMode() }, onPause: { [weak self] in self?.onPause() },
            onTogglePreview: { [weak self] in self?.onTogglePreview() },
            onLayoutChanged: { [weak self] in self?.resizeForState() }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor), hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        window.contentView = effect
        self.hosting = hosting
        panel = window
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { window.orderFrontRegardless() }
        else {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = 1
            }
        }
    }

    /// Removes native content immediately before final image capture or editor presentation.
    func close() {
        let old = panel
        panel = nil
        hosting = nil
        selectionGlobal = nil
        old?.orderOut(nil)
        old?.contentView = nil
        old?.close()
    }

    private var desiredHeight: CGFloat {
        106 + (state.showsAdvanced ? 108 : 0) + (state.isMatching && state.showsAdvanced ? 130 : state.isPaused ? 54 : 0)
    }

    private func resizeForState() {
        guard let panel else { return }
        var frame = panel.frame
        if let selectionGlobal, frame.maxY <= selectionGlobal.minY { frame.origin.y = frame.maxY - desiredHeight }
        frame.size.height = desiredHeight
        if let visible = panel.screen?.visibleFrame { frame = clamped(frame, to: visible) }
        panel.setFrame(frame, display: true)
    }

    private func placement(size: CGSize, visible: CGRect, selection: CGRect?) -> CGRect {
        guard let selection, !selection.isNull, selection.width > 0, selection.height > 0 else {
            return clamped(CGRect(x: visible.midX - size.width / 2, y: visible.minY + 24, width: size.width, height: size.height), to: visible)
        }
        let gap: CGFloat = 12
        let candidates = [
            CGRect(x: selection.midX - size.width / 2, y: selection.minY - size.height - gap, width: size.width, height: size.height),
            CGRect(x: selection.midX - size.width / 2, y: selection.maxY + gap, width: size.width, height: size.height),
            CGRect(x: selection.maxX + gap, y: selection.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: selection.minX - size.width - gap, y: selection.midY - size.height / 2, width: size.width, height: size.height)
        ].map { clamped($0, to: visible) }
        return candidates.min { left, right in
            let a = left.intersection(selection), b = right.intersection(selection)
            let areaA = a.isNull ? 0 : a.width * a.height
            let areaB = b.isNull ? 0 : b.width * b.height
            return areaA < areaB
        } ?? clamped(candidates[0], to: visible)
    }

    private func clamped(_ frame: CGRect, to visible: CGRect) -> CGRect {
        var result = frame
        result.origin.x = min(max(visible.minX + 8, frame.minX), visible.maxX - frame.width - 8)
        result.origin.y = min(max(visible.minY + 8, frame.minY), visible.maxY - frame.height - 8)
        return result
    }
}

@MainActor
private struct ScrollControlBar: View {
    @Bindable var state: ScrollControlState
    let onFinish: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onManualOverlap: (Int) -> Void
    let onManualMode: () -> Void
    let onAdvancedSettings: () -> Void
    let onAutomaticMode: () -> Void
    let onPause: () -> Void
    let onTogglePreview: () -> Void
    let onLayoutChanged: () -> Void
    @State private var overlapText: String
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(state: ScrollControlState, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void,
         onRetry: @escaping () -> Void, onManualOverlap: @escaping (Int) -> Void,
         onManualMode: @escaping () -> Void, onAdvancedSettings: @escaping () -> Void,
         onAutomaticMode: @escaping () -> Void, onPause: @escaping () -> Void, onTogglePreview: @escaping () -> Void,
         onLayoutChanged: @escaping () -> Void) {
        self.state = state
        self.onFinish = onFinish; self.onCancel = onCancel; self.onRetry = onRetry
        self.onManualOverlap = onManualOverlap; self.onManualMode = onManualMode
        self.onAdvancedSettings = onAdvancedSettings; self.onAutomaticMode = onAutomaticMode; self.onPause = onPause
        self.onTogglePreview = onTogglePreview
        self.onLayoutChanged = onLayoutChanged
        _overlapText = State(initialValue: String(state.overlap))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "rectangle.expand.vertical").foregroundStyle(NikoTheme.accent)
                        Text(max(0, state.height).formatted()).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                        Text("px").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("\(state.mode.title) · \(max(0, state.frames)) 段")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(state.mode.title)，长截图高度 \(state.height) 像素，已拼接 \(state.frames) 段")
                ScrollHUDButton(title: state.showsPreview ? "收起实时预览" : "显示实时预览", symbol: "sidebar.right",
                    tint: state.showsPreview ? NikoTheme.accent : .primary, action: onTogglePreview)
                    .accessibilityValue(state.showsPreview ? "已显示" : "已收起")
                ScrollHUDButton(title: state.showsAdvanced ? "收起高级操作" : "展开高级操作", symbol: "slider.horizontal.3",
                    showsTitle: true, visibleTitle: "高级") { state.showsAdvanced.toggle() }
                    .keyboardShortcut(",", modifiers: .command)
                    .accessibilityValue(state.showsAdvanced ? "已展开" : "已收起")
                ScrollHUDButton(title: "结束并编辑长图", symbol: "checkmark", tint: NikoTheme.accent,
                    showsTitle: true, visibleTitle: "完成", prominent: true,
                    enabled: state.frames > 0 && !state.isWorking && !state.requiresRestart, action: onFinish)
                    .keyboardShortcut(.return, modifiers: .command)
                ScrollHUDButton(title: "取消长截图", symbol: "xmark", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
            }.frame(minHeight: 44)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: state.isWorking ? "hourglass" : state.isPaused ? "pause.circle" : "arrow.down")
                    .foregroundStyle(state.isPaused ? Color.orange : NikoTheme.accent)
                Text(state.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(state.status)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 32, alignment: .top)
            if state.showsAdvanced { advancedControls }
            if state.isMatching && state.showsAdvanced { seamControls }
            else if state.isPaused {
                Divider()
                HStack {
                    Text(state.requiresRestart ? "旧分块不会沿用" : state.requiresReselection ? "已停止捕获原位置" : state.isMatching ? "已保留预览中的内容" : "捕获已暂停")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    ScrollHUDButton(title: recoveryTitle, symbol: "arrow.clockwise", showsTitle: true,
                        enabled: !state.isWorking, action: onRetry)
                        .keyboardShortcut("r", modifiers: .command)
                }.frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background { if reduceTransparency { NikoTheme.canvas } }
        .tint(NikoTheme.accent)
        .onChange(of: state.isMatching) { _, matching in
            if matching && state.showsAdvanced && !state.isPaused { onPause() }
            onLayoutChanged()
        }
        .onChange(of: state.isPaused) { _, _ in onLayoutChanged() }
        .onChange(of: state.showsAdvanced) { _, expanded in
            if expanded && state.isMatching && !state.isPaused { onPause() }
            onLayoutChanged()
        }
        .onChange(of: state.overlap) { _, value in overlapText = String(value) }
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Picker("滚动方式", selection: Binding(get: { state.mode }, set: { mode in
                    if mode == .manual { onManualMode() } else { onAutomaticMode() }
                })) {
                    Text("自行滚动").tag(ScrollCaptureMode.manual)
                    Text("自动滚动").tag(ScrollCaptureMode.automatic)
                }.pickerStyle(.segmented).labelsHidden()
                    .accessibilityLabel("高级操作，手动或自动滚动方式")
                    .disabled(state.isWorking || state.requiresRestart || state.requiresReselection)
                ScrollHUDButton(title: state.isPaused ? recoveryTitle : "暂停捕获", symbol: state.isPaused ? "play" : "pause",
                    enabled: !state.isWorking, action: state.isPaused ? onRetry : onPause)
            }.frame(minHeight: 44)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("固定栏").font(.system(size: 12, weight: .medium))
                    Text("顶部 \(state.ignoredTop) · 底部 \(state.ignoredBottom) px")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                ScrollHUDButton(title: "配置固定栏并从首屏重新开始", symbol: "arrow.counterclockwise",
                    showsTitle: true, visibleTitle: "配置与重启…", enabled: !state.isWorking && !state.requiresReselection,
                    action: onAdvancedSettings)
            }.frame(minHeight: 44)
        }
    }

    private var seamControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            HStack {
                Label("确认接缝", systemImage: "rectangle.on.rectangle").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(correlationLabel).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 6) {
                Text("重叠").font(.system(size: 12))
                TextField("重叠像素", text: $overlapText).textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing).font(.system(size: 12)).monospacedDigit()
                    .frame(width: 68, height: 44).accessibilityLabel("手动重叠像素，允许零到 \(maximumOverlap)")
                    .onSubmit(commitOverlap)
                Text("px").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ScrollHUDButton(title: "按此重叠拼接", symbol: "rectangle.stack", showsTitle: true,
                    visibleTitle: "拼接", prominent: true, enabled: validOverlap != nil && !state.isWorking, action: commitOverlap)
                ScrollHUDButton(title: "重试当前帧", symbol: "arrow.clockwise", enabled: !state.isWorking, action: onRetry)
                    .keyboardShortcut("r", modifiers: .command)
            }
            Text("0–\(maximumOverlap) px · 回车确认 · ⌘R 重试")
                .font(.system(size: 11)).foregroundStyle(validOverlap == nil ? Color.red : Color.secondary)
        }.padding(.top, 3)
    }

    private var recoveryTitle: String {
        state.requiresReselection ? "重新选择" : state.requiresRestart ? "重新开始" : "继续重试"
    }
    private var maximumOverlap: Int { max(0, state.maximumOverlap) }
    private var validOverlap: Int? {
        guard let value = Int(overlapText.trimmingCharacters(in: .whitespaces)), (0...maximumOverlap).contains(value) else { return nil }
        return value
    }
    private var correlationLabel: String {
        guard let value = state.correlation, value.isFinite else { return "相关性未知" }
        return "相关性 \(Double(value).formatted(.percent.precision(.fractionLength(1))))"
    }
    private func commitOverlap() {
        guard let value = validOverlap else { return }
        state.overlap = value; onManualOverlap(value)
    }
}

@MainActor
private struct ScrollHUDButton: View {
    let title: String
    let symbol: String
    var tint: Color = .primary
    var showsTitle = false
    var visibleTitle: String?
    var prominent = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                if showsTitle { Text(visibleTitle ?? title).font(.system(size: 12, weight: .medium)) }
            }
            .foregroundStyle(tint).padding(.horizontal, showsTitle ? 10 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(NikoActionButtonStyle(prominent: prominent)).disabled(!enabled).focusable()
        .help(title).accessibilityLabel(title)
    }
}

@MainActor
private final class ScrollHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ScrollHUDMaterial: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor }
    }
}
