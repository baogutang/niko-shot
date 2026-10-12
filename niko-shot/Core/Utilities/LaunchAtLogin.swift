// Reads and changes the main application's login item only in response to settings UI actions.
import AppKit
import Observation
import ServiceManagement

/// The main application's login-item status, without a helper process or polling.
@MainActor @Observable
public final class LaunchAtLogin {
    /// The last status explicitly read from ServiceManagement.
    public private(set) var status: SMAppService.Status = .notRegistered
    /// Whether a user-requested registration change is in progress.
    public private(set) var isUpdating = false
    /// Registration failures are shown inline in the settings window.
    public private(set) var errorMessage: String?

    @ObservationIgnored private let service: SMAppService

    /// Creates the model without reading status or changing the login item.
    public init() { service = .mainApp }

    /// A pending approval still represents a requested login item.
    public var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    /// The user must enable this item in System Settings before it can run.
    public var requiresApproval: Bool { status == .requiresApproval }
    /// Human-readable status for the settings row and VoiceOver.
    public var statusDescription: String {
        switch status {
        case .enabled: "已启用，将在登录时打开 niko-shot。"
        case .requiresApproval: "等待批准。请在系统设置的登录项中允许 niko-shot。"
        case .notRegistered: "登录时不自动打开。"
        case .notFound: "系统未找到应用。请将 niko-shot 安装到应用程序文件夹后重试。"
        @unknown default: "暂时无法读取登录项状态。"
        }
    }

    /// Refreshes on window appearance or an explicit user action; no timer is installed.
    public func refresh() { status = service.status }

    /// Registers or unregisters the main application after the user changes the toggle.
    public func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer { refresh(); isUpdating = false }
        refresh()
        guard enabled != isEnabled else { return }
        do {
            if enabled { try service.register() }
            else { try await service.unregister() }
        } catch { errorMessage = "无法更改登录启动：\(error.localizedDescription)" }
    }

    /// Opens the system-managed login-items settings without granting approval automatically.
    public func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
