// Docks a floating "drag the app into this list" guide beside System Settings and watches for consent.
import AppKit
import Observation
import SwiftUI

/// Observable guide content; the same model drives the floating guide and the welcome window.
@MainActor @Observable
final class PermissionGuideModel {
    var kind: PermissionKind = .screenRecording
    var reason: String?
    var state: PermissionState = .notGranted
    var dragging = false
    var granted: Bool { state != .notGranted }
}

/// Opens the privacy list, then floats a draggable app icon next to it until permission is granted.
@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()

    private var panel: CaptureHUDPanel?
    private var timer: Timer?
    private let model = PermissionGuideModel()
    private var lastSettingsFrame: CGRect?
    private var missingSettingsTicks = 0
    private var grantedAt: Date?
    /// Called once when the presented permission becomes granted.
    var onGranted: ((PermissionKind) -> Void)?
    /// Opens the System Settings list; replaceable so tests never launch System Settings.
    var openSettings: (PermissionKind) -> Void = { $0.openSettings() }

    var isPresented: Bool { panel != nil }
    var presentedKind: PermissionKind? { panel == nil ? nil : model.kind }

    /// Opens System Settings at the right list and shows the guide; safe to call repeatedly.
    func present(_ kind: PermissionKind, reason: String? = nil) {
        model.kind = kind
        model.reason = reason
        model.state = kind.state
        grantedAt = nil
        missingSettingsTicks = 0
        openSettings(kind)
        if panel == nil { makePanel() }
        reposition(animated: false)
        if let panel { CaptureChrome.present(panel, content: panel.contentView) }
        startTimer()
    }

    func dismiss() {
        timer?.invalidate(); timer = nil
        let old = panel
        panel = nil
        old?.orderOut(nil); old?.contentView = nil; old?.close()
    }

    private func makePanel() {
        let panel = CaptureHUDPanel(level: .floating, movable: true)
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: PermissionGuideView(model: model,
            close: { [weak self] in self?.dismiss() },
            openSettings: { [weak self] in if let self { self.openSettings(self.model.kind) } },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) },
            relaunch: { AppRelauncher.relaunch() }))
        hosting.frame = CGRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
        panel.setContentSize(Self.size)
        panel.setAccessibilityLabel("权限授权引导")
        self.panel = panel
    }

    static let size = CGSize(width: 480, height: 196)

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard panel != nil else { timer?.invalidate(); timer = nil; return }
        reposition(animated: true)
        let kind = model.kind
        let state = kind.state
        if state != model.state {
            let wasGranted = model.granted
            model.state = state
            if state != .notGranted, !wasGranted {
                grantedAt = .now
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                onGranted?(kind)
            }
        }
        // 立即生效的授权显示成功片刻后自动收起；需要重新打开的保留「重新打开」按钮。
        if let grantedAt, state == .granted, Date.now.timeIntervalSince(grantedAt) > 1.8 { dismiss() }
    }

    private func reposition(animated: Bool) {
        guard let panel else { return }
        let settings = Self.settingsWindowFrame()
        if settings == nil { missingSettingsTicks += 1 } else { missingSettingsTicks = 0 }
        // 设置窗口关闭一段时间且尚未授权时，保持引导在原处，便于再次打开设置。
        let screen = (settings.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        guard settings != lastSettingsFrame || !panel.isVisible else { return }
        lastSettingsFrame = settings
        let frame = Self.placement(size: Self.size, settings: settings, visible: screen)
        if animated, panel.isVisible, !CaptureChrome.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    /// Below the settings window near its list pane, else beside it, else overlapping its lower edge.
    nonisolated static func placement(size: CGSize, settings: CGRect?, visible: CGRect) -> CGRect {
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, visible.minX + 8), visible.maxX - size.width - 8) }
        guard let settings else {
            return CGRect(x: clampX(visible.midX - size.width / 2), y: visible.minY + 80, width: size.width, height: size.height)
        }
        let gap: CGFloat = 12
        let x = clampX(settings.midX - size.width / 2 + settings.width * 0.12)
        let below = settings.minY - gap - size.height
        if below >= visible.minY + 8 { return CGRect(x: x, y: below, width: size.width, height: size.height) }
        let y = min(max(settings.minY + 24, visible.minY + 8), visible.maxY - size.height - 8)
        if settings.maxX + gap + size.width <= visible.maxX - 8 {
            return CGRect(x: settings.maxX + gap, y: y, width: size.width, height: size.height)
        }
        if settings.minX - gap - size.width >= visible.minX + 8 {
            return CGRect(x: settings.minX - gap - size.width, y: y, width: size.width, height: size.height)
        }
        return CGRect(x: x, y: max(visible.minY + 8, settings.minY + 16), width: size.width, height: size.height)
    }

    /// The largest on-screen System Settings window, in AppKit global coordinates (no permission needed).
    static func settingsWindowFrame() -> CGRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").map(\.processIdentifier))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        var best: CGRect?
        for info in list {
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(owner),
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 200, rect.height > 200 else { continue }
            if best.map({ rect.width * rect.height > $0.width * $0.height }) ?? true { best = rect }
        }
        return best.map { CoordinateSpace.windowToAppKit($0, primaryTop: primaryTop) }
    }
}

@MainActor
private struct PermissionGuideView: View {
    @Bindable var model: PermissionGuideModel
    let close: () -> Void
    let openSettings: () -> Void
    let reveal: () -> Void
    let relaunch: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bob = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .offset(y: bob ? -4 : 2)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: bob)
                    .opacity(model.granted ? 0 : 1)
                DraggableAppIcon(dragging: $model.dragging)
                    .frame(width: 76, height: 76)
                Text(model.granted ? "已添加" : "拖动我").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(width: 84)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: model.kind.symbol).foregroundStyle(Color.accentColor)
                    Text("授予「\(model.kind.title)」权限").font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.07), in: Circle())
                    }
                    .buttonStyle(.plain).help("关闭引导").accessibilityLabel("关闭引导")
                }
                if let reason = model.reason {
                    Text("\(reason)需要此权限。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                step(1, "把左侧的 niko-shot 图标拖进上方「\(model.kind.settingsListName)」列表",
                     detail: "拖不进去时，点列表下方的 ＋，在「应用程序」里选择 niko-shot")
                step(2, model.kind.needsRelaunchAfterGrant ? "打开 niko-shot 的开关，再按提示重新打开应用" : "打开 niko-shot 右侧的开关")
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    status
                    Spacer(minLength: 0)
                    switch model.state {
                    case .notGranted:
                        Button("在访达中显示", action: reveal).controlSize(.small)
                            .help("从访达把 niko-shot 拖进列表")
                        Button("打开设置", action: openSettings).controlSize(.small)
                    case .grantedNeedsRelaunch:
                        Button("重新打开 niko-shot", action: relaunch)
                            .controlSize(.small).buttonStyle(.borderedProminent)
                            .help("屏幕录制权限在重新打开应用后生效")
                    case .granted:
                        EmptyView()
                    }
                }
            }
        }
        .padding(16)
        .frame(width: PermissionGuide.size.width, height: PermissionGuide.size.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.state)
        .onAppear { bob = true }
    }

    private func step(_ number: Int, _ text: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(number)").font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white).frame(width: 16, height: 16)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .granted:
            Label("已授权，可以继续使用", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
        case .grantedNeedsRelaunch:
            Label("已授权，重新打开后生效", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
        case .notGranted:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(model.dragging ? "松开到列表里…" : "等待授权…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The application bundle as a file drag; System Settings' privacy lists accept it like a Finder drop.
@MainActor
private struct DraggableAppIcon: NSViewRepresentable {
    @Binding var dragging: Bool

    func makeNSView(context: Context) -> AppIconDragView {
        let view = AppIconDragView()
        view.onDragChange = { dragging = $0 }
        return view
    }

    func updateNSView(_ view: AppIconDragView, context: Context) {
        view.onDragChange = { dragging = $0 }
    }
}

@MainActor
final class AppIconDragView: NSView, NSDraggingSource {
    var onDragChange: ((Bool) -> Void)?
    private let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("niko-shot 应用图标，拖到系统设置的列表中")
        toolTip = "把我拖进系统设置的列表"
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area); tracking = area
    }

    /// The guide panel moves by its background; without this, dragging the icon would drag the panel
    /// instead of the application, and nothing would ever reach the System Settings list.
    override var mouseDownCanMoveWindow: Bool { false }

    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let tile = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: tile, xRadius: 16, yRadius: 16)
        NikoAccent.nsColor.withAlphaComponent(hovering ? 0.16 : 0.09).setFill()
        path.fill()
        path.lineWidth = 1.5
        path.setLineDash([5, 4], count: 2, phase: 0)
        NikoAccent.nsColor.withAlphaComponent(0.65).setStroke()
        path.stroke()
        let side = min(tile.width, tile.height) - 18
        icon.draw(in: CGRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side))
    }

    private var downPoint: CGPoint?

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) { downPoint = nil; NSCursor.openHand.set() }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        downPoint = nil
        let session = beginDraggingSession(with: [makeDraggingItem()], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        onDragChange?(true)
    }

    /// The running application bundle as a Finder-style file drag, which privacy lists accept as an addition.
    /// `NSURL` writes both the modern file-URL type and the legacy filename types older lists still read.
    func makeDraggingItem(bundleURL: URL = Bundle.main.bundleURL) -> NSDraggingItem {
        let dragging = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        let side = min(bounds.width, bounds.height) - 18
        dragging.setDraggingFrame(CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side), contents: icon)
        return dragging
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { onDragChange?(false) }
    }
}
