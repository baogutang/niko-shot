// Provides a lightweight three-step AppKit onboarding flow; only completion writes its persisted flag.
import AppKit
import CoreGraphics

/// Native first-run guidance with explicit, user-initiated permission actions.
@MainActor
public final class PermissionWizardController {
    static let completionKey = "permissionWizardCompleted"

    /// Whether the user has explicitly completed onboarding in the standard preference store.
    public static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completionKey) }
    /// Number of windows owned by this wizard, including an ordered-out demo window.
    public var windowCount: Int { window == nil ? 0 : 1 }

    nonisolated(unsafe) private var window: PermissionWizardWindow?
    private let defaults: UserDefaults
    private let onDemo: () -> Void
    private let onComplete: () -> Void
    private var step = 0
    private var permissionStatus: NSTextField?
    private var requestButton: NSButton?

    /// Creates guidance without showing a window or requesting system permission.
    public init(onDemo: @escaping () -> Void, onComplete: @escaping () -> Void,
                defaults: UserDefaults = .standard) {
        self.onDemo = onDemo
        self.onComplete = onComplete
        self.defaults = defaults
    }

    deinit {
        guard let remaining = window else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { remaining.onClose = nil; remaining.orderOut(nil); remaining.close() }
        } else {
            Task { @MainActor in remaining.onClose = nil; remaining.orderOut(nil); remaining.close() }
        }
    }

    /// Opens or revisits onboarding, with no automatic permission prompts.
    public func show() {
        if let window { window.makeKeyAndOrderFront(nil); refreshScreenStatus(); return }
        let window = PermissionWizardWindow(contentRect: CGRect(x: 0, y: 0, width: 540, height: 520),
                                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "欢迎使用 niko-shot"
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setAccessibilityLabel("niko-shot 首次使用向导")
        window.onClose = { [weak self] in self?.close() }
        self.window = window
        renderStep()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes guidance without persisting completion or affecting menu-bar actions.
    public func close() {
        let old = window
        window = nil
        permissionStatus = nil
        requestButton = nil
        old?.onClose = nil
        old?.orderOut(nil)
        old?.close()
    }

    private func renderStep() {
        guard let window else { return }
        permissionStatus = nil
        requestButton = nil
        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let count = label("第 \(step + 1) 步，共 3 步", size: 12, color: .secondaryLabelColor)
        count.setAccessibilityLabel("向导第 \(step + 1) 步，共三步")
        stack.addArrangedSubview(count)
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 3; progress.doubleValue = Double(step + 1)
        progress.setAccessibilityElement(false)
        stack.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 4).isActive = true

        let symbol = step == 0 ? "camera.viewfinder" : step == 1 ? "display" : "checkmark.viewfinder"
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.setAccessibilityElement(false)
        let badge = NSBox()
        badge.boxType = .custom; badge.titlePosition = .noTitle; badge.borderWidth = 0
        badge.fillColor = .controlAccentColor.withAlphaComponent(0.10)
        badge.cornerRadius = 14; badge.contentViewMargins = NSSize(width: 10, height: 10)
        badge.contentView = icon
        badge.widthAnchor.constraint(equalToConstant: 56).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 56).isActive = true
        badge.setAccessibilityElement(false)
        stack.addArrangedSubview(badge)

        switch step {
        case 0:
            stack.addArrangedSubview(label("把屏幕上的想法，留在手边。", size: 25, weight: .semibold))
            stack.addArrangedSubview(label("从菜单栏或全局快捷键开始截图、录屏、文字识别和翻译。所有工具都在这一个原生应用里。", size: 14))
            let shortcuts = NSBox()
            shortcuts.boxType = .custom; shortcuts.titlePosition = .noTitle
            shortcuts.fillColor = .controlBackgroundColor; shortcuts.borderColor = .separatorColor.withAlphaComponent(0.35)
            shortcuts.borderWidth = 0.5; shortcuts.cornerRadius = 12
            shortcuts.contentViewMargins = NSSize(width: 14, height: 12)
            shortcuts.contentView = label("拖动框选 · Enter 复制 · Tab 标注\n⌘S 保存 · Esc 随时取消", size: 13, color: .secondaryLabelColor)
            stack.addArrangedSubview(shortcuts)
            shortcuts.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            shortcuts.heightAnchor.constraint(equalToConstant: 68).isActive = true
            stack.addArrangedSubview(label("截图快捷键不需要输入监控权限。麦克风和摄像头只在你开启录制时询问授权。", size: 12, color: .secondaryLabelColor))
        case 1:
            stack.addArrangedSubview(label("允许读取屏幕内容", size: 25, weight: .semibold))
            stack.addArrangedSubview(label("截图和录屏需要 macOS 的屏幕录制权限。你可以现在授权，也可以稍后第一次截图时授权。", size: 14))
            let status = label("", size: 13)
            status.setAccessibilityLabel("屏幕录制授权状态")
            permissionStatus = status
            stack.addArrangedSubview(status)
            let request = button("请求授权", action: #selector(requestScreenAccess), identifier: "wizard.requestScreen")
            requestButton = request
            let system = button("打开系统设置", action: #selector(openScreenSettings), identifier: "wizard.screenSettings")
            let refresh = button("刷新状态", action: #selector(refreshScreenStatus), identifier: "wizard.refreshScreen")
            stack.addArrangedSubview(row([request, system, refresh]))
            stack.addArrangedSubview(label("在「隐私与安全性 → 屏幕录制」中启用 niko-shot。系统可能提示重新打开应用。", size: 12, color: .secondaryLabelColor))
        default:
            stack.addArrangedSubview(label("试着截取第一张图片", size: 25, weight: .semibold))
            stack.addArrangedSubview(label("点击下方按钮后拖动选择一块区域，按 Enter 复制；按 Esc 可取消，随后从菜单栏继续使用。", size: 14))
            stack.addArrangedSubview(button("试截一张", action: #selector(demo), identifier: "wizard.demo"))
            stack.addArrangedSubview(label("只有长截图的自动滚动模式需要辅助功能权限。未授权时会自动转为手动滚动，截图、OCR 和翻译仍可使用。", size: 13, color: .secondaryLabelColor))
            stack.addArrangedSubview(button("打开辅助功能设置", action: #selector(openAccessibilitySettings), identifier: "wizard.accessibilitySettings"))
        }

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        let later = button("稍后", action: #selector(dismiss), identifier: "wizard.later")
        later.keyEquivalent = "\u{1b}"
        footer.addArrangedSubview(later)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        if step > 0 { footer.addArrangedSubview(button("上一步", action: #selector(back), identifier: "wizard.back")) }
        let next = button(step == 2 ? "完成" : "继续", action: #selector(nextStep), identifier: "wizard.next")
        next.keyEquivalent = "\r"
        footer.addArrangedSubview(next)
        content.addSubview(footer)
        let divider = NSBox()
        divider.boxType = .separator; divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            footer.heightAnchor.constraint(equalToConstant: 44),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10)
        ])
        window.contentView = content
        window.defaultButtonCell = next.cell as? NSButtonCell
        window.initialFirstResponder = next
        window.makeFirstResponder(next)
        refreshScreenStatus()
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = 0
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(text)
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
        return field
    }

    private func button(_ title: String, action: Selector, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        return button
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    @objc private func dismiss() { close() }
    @objc private func back() { guard step > 0 else { return }; step -= 1; renderStep() }
    @objc private func nextStep() {
        guard window != nil else { return }
        if step < 2 { step += 1; renderStep(); return }
        defaults.set(true, forKey: Self.completionKey)
        close()
        onComplete()
    }
    @objc private func demo() { onDemo() }

    @objc private func refreshScreenStatus() {
        guard permissionStatus != nil else { return }
        let granted = CGPreflightScreenCaptureAccess()
        permissionStatus?.stringValue = granted ? "屏幕录制已授权" : "屏幕录制尚未授权"
        permissionStatus?.textColor = granted ? .systemGreen : .secondaryLabelColor
        permissionStatus?.setAccessibilityValue(granted ? "已授权" : "尚未授权")
        requestButton?.isEnabled = !granted
    }

    @objc private func requestScreenAccess() { _ = CGRequestScreenCaptureAccess(); refreshScreenStatus() }
    @objc private func openScreenSettings() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
    @objc private func openAccessibilitySettings() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
    private func open(_ value: String) { if let url = URL(string: value) { NSWorkspace.shared.open(url) } }
}

@MainActor
private final class PermissionWizardWindow: NSWindow {
    var onClose: (() -> Void)?
    override func close() {
        let callback = onClose
        onClose = nil
        super.close()
        contentView = nil
        callback?()
    }
}
