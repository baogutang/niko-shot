// Presents a compact native menu bar popover and recent-capture strip.
import AppKit
import SwiftUI

@MainActor
final class MainMenuExtra: NSObject {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let performAction: (String) -> Void
    private let showSettings: () -> Void

    init(action: @escaping (String) -> Void, settings: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        performAction = action
        showSettings = settings
        super.init()
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "niko-shot")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView: MenuContent(action: { [weak self] id in
                self?.popover.performClose(nil)
                self?.performAction(id)
            }, settings: { [weak self] in self?.popover.performClose(nil); self?.showSettings() }))
        }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
}

private struct MenuContent: View {
    let action: (String) -> Void
    let settings: () -> Void
    private let entries = [("region", "区域截图", "crop", "⇧⌘A"), ("window", "窗口截图", "macwindow", "⇧⌘W"), ("fullscreen", "全屏截图", "rectangle.inset.filled", "⇧⌘F"), ("record", "录屏", "record.circle", "⇧⌘V"), ("ocr", "识别文字", "text.viewfinder", "⇧⌘O"), ("scroll", "滚动长截图", "scroll", "⇧⌘L"), ("repeatRegion", "上次区域", "arrow.counterclockwise", "⇧⌘R"), ("pins", "贴图库", "pin", "⇧⌘P")]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Image(systemName: "camera.viewfinder").font(.title2); Text("niko-shot").font(.headline); Spacer(); Text("⌘").foregroundStyle(.tertiary) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(entries, id: \.0) { entry in
                    Button { action(entry.0) } label: {
                        HStack { Image(systemName: entry.2).frame(width: 22); VStack(alignment: .leading, spacing: 3) { Text(entry.1); Text(entry.3).font(.caption).foregroundStyle(.secondary) }; Spacer() }
                            .frame(maxWidth: .infinity, minHeight: 44).padding(8)
                    }.buttonStyle(.borderless).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9)).accessibilityLabel(entry.1)
                }
            }
            Divider()
            HStack { Button("设置…", systemImage: "gearshape", action: settings); Spacer(); Button("退出") { NSApp.terminate(nil) } }.buttonStyle(.borderless)
        }.padding(18).frame(width: 336)
    }
}
