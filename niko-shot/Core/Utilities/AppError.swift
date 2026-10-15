// Centralizes actionable errors without hiding the originating service's details.
import AppKit

enum AppError: LocalizedError, Sendable {
    case permission(String)
    case invalidSelection
    case imageCreation
    case file(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .permission(let name): "请在系统设置中允许\(name)，然后重试。"
        case .invalidSelection: "请选择至少 1 × 1 像素的区域。"
        case .imageCreation: "无法创建图像。"
        case .file(let reason): reason
        case .busy: "当前会话尚未结束。"
        }
    }
}

@MainActor
enum ErrorPresenter {
    /// Presents an error on the main actor, preserving its original message.
    static func show(_ error: any Error) {
        // 屏幕录制与辅助功能可以把应用拖进系统列表授权：直接打开引导，而不是再弹一层警告。
        let deniedName: String?
        if let native = error as? AppError, case .permission(let name) = native { deniedName = name }
        else if let recording = error as? RecordingError, case .permission(let name) = recording { deniedName = name }
        else { deniedName = nil }
        if let deniedName, let kind = PermissionKind.matching(deniedName) {
            PermissionGuide.shared.present(kind)
            return
        }
        let alert = NSAlert()
        alert.messageText = "niko-shot"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        let permission: String?
        if let native = error as? AppError, case .permission(let name) = native { permission = name }
        else if let recording = error as? RecordingError, case .permission(let name) = recording { permission = name }
        else { permission = nil }
        if permission != nil { alert.addButton(withTitle: "打开系统设置") }
        if alert.runModal() == .alertSecondButtonReturn, let permission {
            let pane = permission.contains("摄像头") ? "Camera" : permission.contains("麦克风") ? "Microphone" : permission.contains("辅助功能") ? "Accessibility" : "ScreenCapture"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(url) }
        }
    }
}
