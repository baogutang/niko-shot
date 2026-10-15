// Describes the system privacy permissions niko-shot asks for, their purpose and live status.
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

/// Privacy permissions granted from System Settings lists (they accept a dragged application).
enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case screenRecording, accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "屏幕录制"
        case .accessibility: "辅助功能"
        }
    }

    /// The list's name in System Settings, which differs slightly from the short title on macOS 15+.
    var settingsListName: String {
        switch self {
        case .screenRecording: "录屏与系统录音"
        case .accessibility: "辅助功能"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: "截图、文字识别、长截图和录屏都需要读取屏幕画面。"
        case .accessibility: "长截图自动滚动，以及在窗口里精确定位可滚动的内容区域。"
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        }
    }

    var isRequired: Bool { self == .screenRecording }

    /// Screen capture consent is applied to a process at launch; macOS asks to reopen the app.
    var needsRelaunchAfterGrant: Bool { self == .screenRecording }

    var settingsURL: URL {
        let anchor = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Reads the current consent without showing any system prompt.
    @MainActor var isGranted: Bool {
        switch self {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        }
    }

    /// Opens the matching System Settings list.
    @MainActor func openSettings() { NSWorkspace.shared.open(settingsURL) }

    /// Maps a permission error name such as "屏幕录制" back to its kind.
    static func matching(_ name: String) -> PermissionKind? {
        if name.contains("辅助") { return .accessibility }
        if name.contains("屏幕") || name.contains("录屏") { return .screenRecording }
        return nil
    }
}

/// Restarts the app once the current process has exited (screen-recording consent applies to new processes).
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 等待当前进程退出后再打开，避免单实例锁把新进程拒之门外。
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path, String(pid)]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            ErrorPresenter.show(AppError.file("无法自动重新打开，请手动退出后再打开 niko-shot。"))
        }
    }
}
