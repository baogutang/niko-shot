// Presents a compact native menu bar popover and recent-capture strip.
import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class MenuModel { var recents: [HistoryRecord] = []; var onOpen: (() -> Void)? }

@MainActor
final class MainMenuExtra: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private var popover: NSPopover?
    private let performAction: (String) -> Void
    private let showSettings: () -> Void
    private let model: MenuModel
    private let hotkeys: HotkeyCenter?
    private var closed = false

    init(model: MenuModel, hotkeys: HotkeyCenter? = nil, action: @escaping (String) -> Void, settings: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        performAction = action
        showSettings = settings
        self.model = model
        self.hotkeys = hotkeys
        super.init()
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "niko-shot")
        item.button?.target = self
        item.button?.action = #selector(toggle)
    }

    @objc private func toggle() {
        guard !closed, let button = item.button else { return }
        let popover: NSPopover
        if let existing = self.popover { popover = existing }
        else {
            popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            self.popover = popover
        }
        if !popover.isShown { model.onOpen?() }
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView: MenuContent(model: model, hotkeys: hotkeys, action: { [weak self] id in
                self?.popover?.performClose(nil)
                self?.performAction(id)
            }, settings: { [weak self] in self?.popover?.performClose(nil); self?.showSettings() }))
        }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    func popoverDidClose(_ notification: Notification) { popover?.contentViewController = nil }

    /// Releases the status item and native popover when the app exits.
    func close() {
        guard !closed else { return }
        closed = true; popover?.close(); popover?.contentViewController = nil
        popover?.delegate = nil; popover = nil; item.button?.target = nil
        NSStatusBar.system.removeStatusItem(item)
    }
}

private struct MenuContent: View {
    @Bindable var model: MenuModel
    let hotkeys: HotkeyCenter?
    let action: (String) -> Void
    let settings: () -> Void
    private let entries: [CaptureAction] = [.region, .window, .fullscreen, .record, .ocr, .scroll, .repeatRegion, .pins]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Image(systemName: "camera.viewfinder").font(.title2); Text("niko-shot").font(.headline); Spacer(); Text("⌘").foregroundStyle(.tertiary) }
            if !model.recents.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(model.recents) { record in
                    if let image = NSImage(data: record.thumbnail) { FileDragPreview(url: URL(fileURLWithPath: record.path), image: image).frame(width: 90, height: 64).clipShape(RoundedRectangle(cornerRadius: 6)).help("最近截图，可拖出文件") }
                } } }.scrollIndicators(.hidden)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(entries) { entry in
                    Button { action(entry.rawValue) } label: {
                        HStack { Image(systemName: entry.symbol).frame(width: 22); VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title)
                            Text((hotkeys?.shortcut(for: entry) ?? entry.defaultShortcut).displayString).font(.caption).foregroundStyle(.secondary)
                        }; Spacer() }
                            .frame(maxWidth: .infinity, minHeight: 44).padding(8)
                    }.buttonStyle(.borderless).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9)).accessibilityLabel(entry.title)
                }
            }
            Divider()
            HStack {
                Button("历史", systemImage: "clock") { action("history") }.accessibilityLabel("截图历史")
                Button("设置…", systemImage: "gearshape", action: settings).accessibilityLabel("打开设置")
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.accessibilityLabel("退出 niko-shot").keyboardShortcut("q", modifiers: .command)
            }.buttonStyle(.borderless)
        }.padding(18).frame(width: 336)
    }
}
