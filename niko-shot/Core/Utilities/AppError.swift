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
        let alert = NSAlert()
        alert.messageText = "niko-shot"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
