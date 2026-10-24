// The status-bar menu: a plain NSMenu, so it behaves exactly like every other menu-bar extra.
import AppKit

@MainActor
final class MenuModel {
    var recents: [HistoryRecord] = [] { didSet { onChange?() } }
    var onOpen: (() -> Void)?
    fileprivate var onChange: (() -> Void)?
}

@MainActor
final class MainMenuExtra: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let recentsMenu = NSMenu()
    private let recentsItem = NSMenuItem(title: "最近截图", action: nil, keyEquivalent: "")
    private let performAction: (String) -> Void
    private let showSettings: () -> Void
    private let openRecent: (HistoryRecord, Bool) -> Void
    private let model: MenuModel
    private let hotkeys: HotkeyCenter?
    private var closed = false
    private var thumbnails: [UUID: NSImage] = [:]
    private static let launchers: [[CaptureAction]] = [
        [.region, .window, .fullscreen, .scroll], [.record, .ocr], [.repeatRegion, .pins, .togglePins]
    ]

    init(model: MenuModel, hotkeys: HotkeyCenter? = nil, action: @escaping (String) -> Void,
         settings: @escaping () -> Void, openRecent: @escaping (HistoryRecord, Bool) -> Void = { _, _ in }) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        performAction = action
        showSettings = settings
        self.openRecent = openRecent
        self.model = model
        self.hotkeys = hotkeys
        super.init()
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "niko-shot")
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        recentsItem.submenu = recentsMenu
        model.onChange = { [weak self] in self?.rebuildRecents() }
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu, !closed else { return }
        model.onOpen?()
        rebuild()
    }

    /// Shortcuts can change in Settings at any time; the menu reads them each time it opens.
    private func rebuild() {
        menu.removeAllItems()
        for (index, group) in Self.launchers.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for action in group { menu.addItem(launcher(action)) }
        }
        menu.addItem(.separator())
        menu.addItem(recentsItem)
        menu.addItem(command("截图历史…") { [weak self] in self?.performAction("history") })
        menu.addItem(.separator())
        let settings = command("设置…") { [weak self] in self?.showSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(command("关于 niko-shot") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 niko-shot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        rebuildRecents()
    }

    private func launcher(_ action: CaptureAction) -> NSMenuItem {
        let item = command(action.title) { [weak self] in self?.performAction(action.rawValue) }
        item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        if let key = hotkeys?.shortcut(for: action)?.menuKeyEquivalent {
            item.keyEquivalent = key.key
            item.keyEquivalentModifierMask = key.modifiers
        }
        return item
    }

    private func rebuildRecents() {
        recentsMenu.removeAllItems()
        guard !model.recents.isEmpty else {
            let empty = NSMenuItem(title: "还没有截图", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentsMenu.addItem(empty)
            return
        }
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        for record in model.recents.prefix(5) {
            let title = "\(record.width) × \(record.height)　\(record.createdAt.formatted(time))"
            let edit = command(title) { [weak self] in self?.openRecent(record, false) }
            edit.image = thumbnail(for: record)
            edit.toolTip = "编辑"
            recentsMenu.addItem(edit)
            // Holding ⌥ swaps the row to its pin action, the standard alternate-item pattern.
            let pin = command(title) { [weak self] in self?.openRecent(record, true) }
            pin.image = edit.image
            pin.toolTip = "贴到屏幕"
            pin.isAlternate = true
            pin.keyEquivalentModifierMask = .option
            recentsMenu.addItem(pin)
        }
        recentsMenu.addItem(.separator())
        let hint = NSMenuItem(title: "按住 ⌥ 贴到屏幕", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        recentsMenu.addItem(hint)
        thumbnails = thumbnails.filter { id, _ in model.recents.contains { $0.id == id } }
    }

    private func thumbnail(for record: HistoryRecord) -> NSImage? {
        if let cached = thumbnails[record.id] { return cached }
        guard let source = NSImage(data: record.thumbnail), source.size.width > 0, source.size.height > 0 else { return nil }
        let height: CGFloat = 32
        let width = min(64, max(24, (height * source.size.width / source.size.height).rounded()))
        let image = NSImage(size: CGSize(width: width, height: height), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.addClip()
            source.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        thumbnails[record.id] = image
        return image
    }

    private func command(_ title: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuCommand.run(_:)), keyEquivalent: "")
        let target = MenuCommand(run)
        item.target = target
        item.representedObject = target
        return item
    }

    /// Releases the status item when the app exits.
    func close() {
        guard !closed else { return }
        closed = true
        menu.delegate = nil
        model.onChange = nil
        menu.removeAllItems(); recentsMenu.removeAllItems()
        NSStatusBar.system.removeStatusItem(item)
    }
}

/// NSMenuItem holds its target weakly; the item's representedObject keeps this alive.
@MainActor
private final class MenuCommand: NSObject {
    private let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) {
        // Let the menu finish closing before a capture freezes the screen.
        let action = action
        DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
    }
}
