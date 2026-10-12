// Displays pinned captures in an adaptive native grid with file promises and window actions.
import AppKit
import SwiftUI

/// A live library of the pin manager's captures.
@MainActor
struct PinLibraryView: View {
    @Bindable private var manager: PinWindowManager
    private let columns = [GridItem(.adaptive(minimum: 184, maximum: 260), spacing: 16, alignment: .top)]

    /// Shares the application's observable pin manager rather than creating a second pin store.
    init(manager: PinWindowManager) { self.manager = manager }

    var body: some View {
        NavigationStack {
            Group {
                if manager.pins.isEmpty {
                    ContentUnavailableView("贴图库为空", systemImage: "pin",
                                           description: Text("截图后选择“贴图”，即可将图片悬浮在其他窗口上。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(manager.pins) { pin in
                                PinCard(pin: pin, onShow: { manager.show(id: pin.id) },
                                        onRemove: { manager.remove(id: pin.id) })
                            }
                        }.padding(20)
                    }
                }
            }
            .navigationTitle("贴图库")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Text("\(manager.pins.count) 张").foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityLabel("\(manager.pins.count) 张贴图")
                }
                ToolbarItem(placement: .automatic) {
                    Button("显示 / 隐藏全部", systemImage: "eye") { manager.toggleVisibility() }
                        .disabled(manager.pins.isEmpty)
                        .help("显示或隐藏全部贴图 · ⌥⌘T")
                        .accessibilityLabel("显示或隐藏全部贴图")
                }
            }
        }
        .frame(minWidth: 600, minHeight: 440)
    }
}

@MainActor
private struct PinCard: View {
    let pin: PinEntry
    let onShow: () -> Void
    let onRemove: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let thumbnail {
                    FileDragPreview(url: pin.url, image: thumbnail)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 148)
            .background(.quaternary.opacity(0.4))
            .help("双击显示贴图，或拖入 Finder 和其他应用")
            .accessibilityLabel("贴图缩略图，可拖出文件")
            Divider()
            HStack(spacing: 8) {
                Text(pin.url.lastPathComponent).font(.caption.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onShow) { Image(systemName: "arrow.up.forward.square").frame(width: 24, height: 28) }
                    .buttonStyle(.borderless).help("显示贴图").accessibilityLabel("显示贴图")
                Button(role: .destructive, action: onRemove) { Image(systemName: "trash").frame(width: 24, height: 28) }
                    .buttonStyle(.borderless).help("删除贴图").accessibilityLabel("删除贴图")
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1) }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2, perform: onShow)
        .contextMenu {
            Button("显示贴图", systemImage: "arrow.up.forward.square", action: onShow)
            Button("在 Finder 中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([pin.url]) }
            Divider()
            Button("删除贴图", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .task(id: pin.id) { thumbnail = NSImage(data: pin.thumbnail) }
    }
}
