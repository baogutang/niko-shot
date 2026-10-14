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
    private enum Command { case capture(String), settings }
    private var pendingCommand: Command?
    private var commandTask: Task<Void, Never>?

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
        NotificationCenter.default.addObserver(self, selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
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
        if popover.isShown { popover.performClose(nil); return }
        model.onOpen?()
        // 菜单栏可以出现在副屏；键盘焦点所在的 NSScreen.main 不能决定这里的高度。
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? button.window?.screen ?? NSScreen.screens.first else { return }
        let safeFrame = MenuPopupLayout.safeFrame(screen: screen.frame, visible: screen.visibleFrame,
            safeTop: screen.safeAreaInsets.top)
        let size = MenuPopupLayout.contentSize(in: safeFrame)
        let controller = NSHostingController(rootView: MenuContent(model: model, hotkeys: hotkeys, action: { [weak self] id in
                self?.dismissThenPerform(.capture(id))
            }, settings: { [weak self] in self?.dismissThenPerform(.settings) }, presentationSize: size))
        // 横向最近截图的 ScrollView 不应把宿主的首选高度扩张到整个副屏。
        controller.sizingOptions = []
        controller.preferredContentSize = size
        popover.contentViewController = controller
        popover.contentSize = size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = controller.view.window {
            let frame = MenuPopupLayout.clampedFrame(window.frame, within: safeFrame)
            if frame.origin != window.frame.origin { window.setFrameOrigin(frame.origin) }
        }
    }

    @objc private func screenConfigurationChanged() { popover?.performClose(nil) }

    private func dismissThenPerform(_ command: Command) {
        pendingCommand = command
        popover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil
        guard let command = pendingCommand else { return }
        pendingCommand = nil
        commandTask?.cancel()
        // 原生 popover 先归还键盘会话，再开始框选；避免关闭动画覆盖新截图的焦点。
        commandTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.closed, !Task.isCancelled else { return }
            self.commandTask = nil
            switch command {
            case .capture(let id): self.performAction(id)
            case .settings: self.showSettings()
            }
        }
    }

    /// Releases the status item and native popover when the app exits.
    func close() {
        guard !closed else { return }
        closed = true; pendingCommand = nil; commandTask?.cancel(); commandTask = nil
        popover?.close(); popover?.contentViewController = nil
        NotificationCenter.default.removeObserver(self)
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
    var presentationSize = CGSize(width: 344, height: 544)
    private let utilities: [CaptureAction] = [.window, .scroll, .fullscreen, .record, .ocr, .pins]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image("NikoMark")
                    .resizable().scaledToFit().frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text("niko-shot").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("截图与录制").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).frame(height: 44)
            Divider()
            ScrollView(.vertical) {
              VStack(alignment: .leading, spacing: 8) {
            Button { action(CaptureAction.region.rawValue) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "crop").font(.system(size: 20, weight: .medium)).foregroundStyle(.tint)
                        .frame(width: 26).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("区域截图").font(.system(size: 14, weight: .semibold))
                        Text("框选后标注、复制或长截图").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    NikoShortcutHint(text: shortcut(.region))
                }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            }
            .buttonStyle(NikoActionButtonStyle(prominent: true)).accessibilityLabel("区域截图")
            .help("区域截图 · \(shortcut(.region))")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(utilities) { launcher($0) }
            }
            Divider().padding(.top, 2)
            HStack {
                Text("最近截图").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { action(CaptureAction.repeatRegion.rawValue) } label: {
                    Label("重复上次", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11)).padding(.horizontal, 6).frame(height: 32)
                }.buttonStyle(NikoActionButtonStyle()).accessibilityLabel("重复上次区域截图")
                    .help("重复上次区域 · \(shortcut(.repeatRegion))")
                Button { action("history") } label: {
                    HStack(spacing: 4) {
                        Text("查看全部").font(.system(size: 11))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }.padding(.horizontal, 6).frame(height: 32)
                }.buttonStyle(NikoActionButtonStyle()).accessibilityLabel("截图历史")
            }
            if model.recents.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 16, weight: .regular))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("还没有截图").font(.system(size: 12))
                        Text("截完后在这里查看，或直接拖出图片。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.recents.prefix(3)) { record in
                            MenuRecentCapture(record: record)
                        }
                    }
                }.scrollIndicators(.hidden).frame(height: 84)
            }
              }.padding(.horizontal, 12).padding(.vertical, 10)
            }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button(action: settings) {
                    Label("设置", systemImage: "gearshape")
                        .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 36)
                }.buttonStyle(NikoActionButtonStyle()).accessibilityLabel("打开设置")
                    .help("设置 · ⌘,").keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    HStack(spacing: 8) {
                        Text("退出").font(.system(size: 12))
                        Text("⌘Q").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
                    }.padding(.horizontal, 8).frame(height: 36)
                }.buttonStyle(NikoActionButtonStyle())
                    .accessibilityLabel("退出 niko-shot").keyboardShortcut("q", modifiers: .command)
            }.padding(.horizontal, 8).padding(.vertical, 2)
        }.frame(width: presentationSize.width, height: presentationSize.height)
            .tint(NikoTheme.accent)
    }

    private func shortcut(_ entry: CaptureAction) -> String {
        (hotkeys?.shortcut(for: entry) ?? entry.defaultShortcut).displayString
    }

    private func launcher(_ entry: CaptureAction) -> some View {
        Button { action(entry.rawValue) } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.symbol).font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry == .ocr ? "识别文字" : entry.title).font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(shortcut(entry)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.buttonStyle(NikoActionButtonStyle()).accessibilityLabel(entry.title).help("\(entry.title) · \(shortcut(entry))")
    }
}

@MainActor
private struct MenuRecentCapture: View {
    let record: HistoryRecord
    @State private var thumbnail: NSImage?
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .frame(width: 108, height: 66).background(NikoTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(hovered ? Color.accentColor.opacity(0.65) : NikoTheme.separator.opacity(0.4), lineWidth: hovered ? 1 : 0.5)
            }
            .accessibilityLabel("最近截图，可拖出文件")
            Text("\(record.width) × \(record.height)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: hovered)
        .help("\(URL(fileURLWithPath: record.path).lastPathComponent) · 拖入 Finder 或其他应用")
        .task(id: record.id) { thumbnail = NSImage(data: record.thumbnail) }
    }
}
