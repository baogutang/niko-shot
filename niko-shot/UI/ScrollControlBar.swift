// Hosts timer-free native scroll-capture progress and explicit seam-confirmation controls.
import AppKit
import Observation
import SwiftUI

/// Observable progress supplied by the capture coordinator; the UI never drives a capture timer.
@MainActor @Observable
final class ScrollControlState {
    /// Current effective mode, including a coordinator-selected manual fallback.
    var mode: ScrollCaptureMode = .automatic
    /// The stitched image's current height in pixels.
    var height = 0
    /// Number of accepted screen-sized frames.
    var frames = 0
    /// Current capture or recovery message.
    var status = "准备开始"
    /// A paused capture exposes an explicit Retry action.
    var isPaused = false
    /// A candidate needs seam confirmation, including ambiguous high-correlation matches.
    var isMatching = false
    /// The candidate's normalized correlation, when available.
    var correlation: Float?
    /// Suggested or last confirmed full-width overlap in pixels.
    var overlap = 150
    /// Largest valid overlap; the coordinator sets this to the smaller usable frame height minus one.
    var maximumOverlap = 199

    /// Creates idle progress without any window, timer, capture, or permission request.
    init() {}
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
    private var selectionGlobal: CGRect?

    /// Retained HUD count for lifecycle assertions.
    var windowCount: Int { panel == nil ? 0 : 1 }

    /// Creates controls without allocating a panel or running a timer.
    init(state: ScrollControlState, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void,
         onRetry: @escaping () -> Void, onManualOverlap: @escaping (Int) -> Void,
         onManualMode: @escaping () -> Void) {
        self.state = state
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.onManualOverlap = onManualOverlap
        self.onManualMode = onManualMode
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
        let size = CGSize(width: min(480, visible.width - 16), height: desiredHeight)
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
        effect.layer?.cornerRadius = NikoTheme.cornerRadius
        effect.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: ScrollControlBar(state: state,
            onFinish: { [weak self] in self?.onFinish() }, onCancel: { [weak self] in self?.onCancel() },
            onRetry: { [weak self] in self?.onRetry() }, onManualOverlap: { [weak self] in self?.onManualOverlap($0) },
            onManualMode: { [weak self] in self?.onManualMode() }, onLayoutChanged: { [weak self] in self?.resizeForState() }))
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

    private var desiredHeight: CGFloat { state.isMatching ? 264 : state.isPaused ? 210 : 144 }

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
    let onLayoutChanged: () -> Void
    @State private var overlapText: String

    init(state: ScrollControlState, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void,
         onRetry: @escaping () -> Void, onManualOverlap: @escaping (Int) -> Void,
         onManualMode: @escaping () -> Void, onLayoutChanged: @escaping () -> Void) {
        self.state = state
        self.onFinish = onFinish; self.onCancel = onCancel; self.onRetry = onRetry
        self.onManualOverlap = onManualOverlap; self.onManualMode = onManualMode
        self.onLayoutChanged = onLayoutChanged
        _overlapText = State(initialValue: String(state.overlap))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("\(max(0, state.height).formatted()) px").font(.system(size: 17, weight: .semibold)).monospacedDigit()
                        Text("\(max(0, state.frames)) 屏").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(state.status).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(state.status)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("长截图总高度 \(state.height) 像素，已捕获 \(state.frames) 屏。\(state.status)")
                ScrollHUDButton(title: "结束并编辑长图", symbol: "checkmark", tint: .accentColor, action: onFinish)
                    .keyboardShortcut(.return, modifiers: .command)
                ScrollHUDButton(title: "取消长截图", symbol: "xmark", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            HStack {
                Label(state.mode.title, systemImage: state.mode == .automatic ? "arrow.down" : "hand.draw")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if state.mode == .automatic {
                    ScrollHUDButton(title: "改为手动", symbol: "hand.draw", showsTitle: true, action: onManualMode)
                        .keyboardShortcut("m", modifiers: [.command, .shift])
                }
            }
            if state.mode == .manual {
                Text("滚动后自动捕获，完成请点结束。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("手动模式：请自行滚动，画面稳定后自动捕获，完成请点结束")
            }
            if state.isMatching {
                Divider()
                HStack {
                    Label("确认接缝", systemImage: "rectangle.on.rectangle").font(.callout.weight(.medium))
                    Spacer()
                    Text(correlationLabel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 8) {
                    Text("重叠").font(.callout)
                    TextField("重叠像素", text: $overlapText).textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing).font(.system(.body, design: .monospaced))
                        .frame(width: 64).accessibilityLabel("手动重叠像素，允许零到 \(maximumOverlap)")
                        .onSubmit(commitOverlap)
                    Text("px").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    ScrollHUDButton(title: "按此重叠拼接", symbol: "rectangle.stack", showsTitle: true,
                                    enabled: validOverlap != nil, action: commitOverlap)
                    ScrollHUDButton(title: "重试当前帧", symbol: "arrow.clockwise", action: onRetry)
                        .keyboardShortcut("r", modifiers: .command)
                }
                Text("允许 0–\(maximumOverlap) px；输入后按回车确认，⌘R 重试。")
                    .font(.caption2).foregroundStyle(validOverlap == nil ? Color.red : Color.secondary)
            } else if state.isPaused {
                Divider()
                HStack {
                    Label("捕获已暂停", systemImage: "pause.circle").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    ScrollHUDButton(title: "继续重试", symbol: "arrow.clockwise", showsTitle: true, action: onRetry)
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .padding(12)
        .onChange(of: state.isMatching) { _, _ in onLayoutChanged() }
        .onChange(of: state.isPaused) { _, _ in onLayoutChanged() }
        .onChange(of: state.mode) { _, _ in onLayoutChanged() }
        .onChange(of: state.overlap) { _, value in overlapText = String(value) }
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
        state.overlap = value
        onManualOverlap(value)
    }
}

@MainActor
private struct ScrollHUDButton: View {
    let title: String
    let symbol: String
    var tint: Color = .primary
    var showsTitle = false
    var enabled = true
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                if showsTitle { Text(title).font(.callout) }
            }
            .foregroundStyle(tint).padding(.horizontal, showsTitle ? 10 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .background(hovered ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: NikoTheme.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: NikoTheme.cornerRadius))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45).focusable()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: hovered)
        .onHover { hovered = $0 }.help(title).accessibilityLabel(title)
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
}
