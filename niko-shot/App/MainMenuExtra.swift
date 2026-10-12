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

@MainActor
struct MenuContent: View {
    @Bindable var model: MenuModel
    let hotkeys: HotkeyCenter?
    let action: (String) -> Void
    let settings: () -> Void
    private let utilities: [CaptureAction] = [.record, .scroll, .ocr, .pins]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                NikoSymbolBadge(symbol: "camera.viewfinder", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("niko-shot").font(.system(size: 16, weight: .semibold))
                    Text("屏幕工具箱").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: settings) { Image(systemName: "gearshape").font(.system(size: 15)) }
                    .buttonStyle(.borderless).help("设置 · ⌘,").accessibilityLabel("打开设置")
            }
            Button { action(CaptureAction.region.rawValue) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "crop").font(.system(size: 23, weight: .medium)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("区域截图").font(.system(size: 15, weight: .semibold))
                        Text("拖动选择，随后复制或标注").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    NikoShortcutHint(text: shortcut(.region))
                }
                .padding(14).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            }.buttonStyle(NikoActionButtonStyle(prominent: true)).accessibilityLabel("区域截图")
            HStack(spacing: 8) {
                launcher(.window)
                launcher(.fullscreen)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(utilities) { launcher($0) }
            }
            Button { action(CaptureAction.repeatRegion.rawValue) } label: {
                HStack {
                    Label("重复上次区域", systemImage: "arrow.counterclockwise").font(.callout)
                    Spacer()
                    NikoShortcutHint(text: shortcut(.repeatRegion))
                }.padding(.horizontal, 10).frame(height: 36)
            }.buttonStyle(NikoActionButtonStyle()).accessibilityLabel("重复上次区域截图")
            Divider()
            HStack {
                Text("最近截图").font(.callout.weight(.semibold))
                Spacer()
                Button("查看全部", systemImage: "chevron.right") { action("history") }
                    .font(.caption).buttonStyle(.borderless).accessibilityLabel("截图历史")
            }
            if model.recents.isEmpty {
                Label("截图后可在这里快速取用，也能直接拖出文件。", systemImage: "photo.on.rectangle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.recents.prefix(3)) { record in
                            MenuRecentCapture(record: record)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            HStack(spacing: 12) {
                Text("Esc 取消 · Enter 复制 · Tab 标注").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.font(.caption).buttonStyle(.borderless)
                    .accessibilityLabel("退出 niko-shot").keyboardShortcut("q", modifiers: .command)
            }
        }.padding(18).frame(width: 392)
    }

    private func shortcut(_ entry: CaptureAction) -> String {
        (hotkeys?.shortcut(for: entry) ?? entry.defaultShortcut).displayString
    }

    private func launcher(_ entry: CaptureAction) -> some View {
        Button { action(entry.rawValue) } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.symbol).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 23)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry == .ocr ? "识别与翻译" : entry.title).font(.callout.weight(.medium))
                    Text(shortcut(entry)).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        }.buttonStyle(NikoActionButtonStyle()).accessibilityLabel(entry.title)
    }
}

@MainActor
private struct MenuRecentCapture: View {
    let record: HistoryRecord
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if let thumbnail {
                    FileDragPreview(url: URL(fileURLWithPath: record.path), image: thumbnail)
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 110, height: 68).background(NikoTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(NikoTheme.separator.opacity(0.35), lineWidth: 0.5) }
            .accessibilityLabel("最近截图，可拖出文件")
            Text("\(record.width) × \(record.height)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .help("\(URL(fileURLWithPath: record.path).lastPathComponent) · 拖入 Finder 或其他应用")
        .task(id: record.id) { thumbnail = NSImage(data: record.thumbnail) }
    }
}
