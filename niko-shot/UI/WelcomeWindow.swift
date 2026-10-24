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
        let window = UtilityWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 480),
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
        NSApp.activate()
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
            VStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable().frame(width: 72, height: 72).accessibilityHidden(true)
                Text("欢迎使用 niko-shot").font(.system(size: 22, weight: .semibold))
                Text(intro).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 48)
            }
            .padding(.top, 40).padding(.bottom, 8)

            Form {
                Section {
                    ForEach(PermissionKind.allCases) { kind in permissionRow(kind) }
                } footer: {
                    Text("麦克风和摄像头只在录屏时打开对应选项才会询问。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped).scrollDisabled(true).scrollContentBackground(.hidden)
            .frame(height: 190)

            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 10) {
                Button("试截一张", action: demo)
                    .disabled(status.granted[.screenRecording] != true)
                    .help(status.granted[.screenRecording] == true ? "框选一块区域，按 ↩ 复制" : "先允许屏幕录制")
                Spacer()
                Button("完成", action: finish).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 520, height: 480)
        .tint(NikoTheme.accent)
    }

    private var intro: String {
        if let region = shortcuts.first(where: { $0.0 == CaptureAction.region.title }) {
            return "按 \(region.1) 框选截图。其他功能都在菜单栏图标里，也可以在设置中为它们指定快捷键。"
        }
        return "点按菜单栏图标开始截图。可以在设置中为常用功能指定快捷键。"
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let granted = status.granted[kind] == true
        return LabeledContent {
            if granted {
                Label("已允许", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary).symbolRenderingMode(.multicolor)
            } else if status.states[kind] == .grantedNeedsRelaunch {
                Button("重新打开") { AppRelauncher.relaunch() }
                    .help("屏幕录制权限在重新打开 niko-shot 后生效")
            } else {
                Button("去授权…") { authorize(kind) }
            }
        } label: {
            Text(kind.isRequired ? kind.title : "\(kind.title)（可选）")
            Text(kind.purpose)
        }
        .animation(.easeOut(duration: 0.2), value: granted)
    }
}
