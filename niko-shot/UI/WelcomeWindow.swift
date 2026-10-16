// First-run welcome: live permission status with drag-to-authorize guides and the essential shortcuts.
import AppKit
import Observation
import SwiftUI

/// Live permission status for the welcome window and settings; refreshed while visible.
@MainActor @Observable
final class PermissionStatusModel {
    private(set) var granted: [PermissionKind: Bool] = [:]
    private(set) var states: [PermissionKind: PermissionState] = [:]
    @ObservationIgnored private var timer: Timer?

    init() { refresh() }

    func refresh() {
        for kind in PermissionKind.allCases {
            let state = kind.state
            states[kind] = state
            granted[kind] = state == .granted
        }
    }

    func startUpdating() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopUpdating() { timer?.invalidate(); timer = nil }
}

/// Owns the welcome window; only "开始使用" persists completion.
@MainActor
final class WelcomeWindowController {
    static let completionKey = "permissionWizardCompleted"
    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completionKey) }

    private var window: UtilityWindow?
    private let defaults: UserDefaults
    private let onDemo: () -> Void
    private let onComplete: () -> Void
    private let status = PermissionStatusModel()
    private let shortcuts: [(String, String)]
    var windowCount: Int { window == nil ? 0 : 1 }

    init(onDemo: @escaping () -> Void, onComplete: @escaping () -> Void, defaults: UserDefaults = .standard,
         shortcuts: [(String, String)] = []) {
        self.onDemo = onDemo; self.onComplete = onComplete; self.defaults = defaults; self.shortcuts = shortcuts
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); status.refresh(); return }
        let window = UtilityWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 640),
                                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "欢迎使用 niko-shot"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeView(status: status, shortcuts: shortcuts,
            authorize: { kind in PermissionGuide.shared.present(kind) },
            demo: { [weak self] in self?.onDemo() },
            finish: { [weak self] in self?.complete() }))
        window.onClose = { [weak self] in self?.status.stopUpdating(); self?.window = nil }
        window.center()
        self.window = window
        status.startUpdating()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        status.stopUpdating()
        let old = window
        window = nil
        old?.onClose = nil
        old?.close()
    }

    private func complete() {
        defaults.set(true, forKey: Self.completionKey)
        close()
        onComplete()
    }
}

@MainActor
private struct WelcomeView: View {
    @Bindable var status: PermissionStatusModel
    let shortcuts: [(String, String)]
    let authorize: (PermissionKind) -> Void
    let demo: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable().frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .accessibilityHidden(true)
                Text("欢迎使用 niko-shot").font(.system(size: 26, weight: .bold))
                Text("截图、标注、长截图、文字识别与录屏，都在菜单栏里随叫随到。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.top, 44).padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 10) {
                Text("权限").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(PermissionKind.allCases) { kind in permissionCard(kind) }
                Text("麦克风和摄像头只在你开启对应的录制选项时才会询问。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 36)

            if !shortcuts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("常用快捷键").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                        ForEach(shortcuts, id: \.0) { item in
                            HStack {
                                Text(item.0).font(.system(size: 12))
                                Spacer(minLength: 6)
                                Text(item.1).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                        }
                    }
                }
                .padding(.horizontal, 36).padding(.top, 22)
            }

            Spacer(minLength: 16)
            Divider()
            HStack(spacing: 10) {
                Button("试截一张", action: demo).controlSize(.large)
                    .disabled(status.granted[.screenRecording] != true)
                    .help(status.granted[.screenRecording] == true ? "拖动框选一块区域，按 ↩ 复制" : "先授予屏幕录制权限")
                Spacer()
                Button("开始使用", action: finish).controlSize(.large).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 600, height: 640)
    }

    private func permissionCard(_ kind: PermissionKind) -> some View {
        let granted = status.granted[kind] == true
        return HStack(spacing: 14) {
            Image(systemName: kind.symbol).font(.system(size: 18, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .frame(width: 40, height: 40)
                .background((granted ? Color.green : Color.accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.title).font(.system(size: 13, weight: .semibold))
                    Text(kind.isRequired ? "必需" : "推荐").font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .foregroundStyle(kind.isRequired ? Color.accentColor : .secondary)
                        .background((kind.isRequired ? Color.accentColor : Color.secondary).opacity(0.12), in: Capsule())
                }
                Text(kind.purpose).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else if status.states[kind] == .grantedNeedsRelaunch {
                Button("重新打开以生效") { AppRelauncher.relaunch() }
                    .controlSize(.regular).buttonStyle(.borderedProminent)
                    .help("已在系统设置中授权；屏幕录制在重新打开 niko-shot 后生效")
            } else {
                Button("授权…") { authorize(kind) }.controlSize(.regular)
                    .accessibilityLabel("授权\(kind.title)")
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.2), value: granted)
    }
}
