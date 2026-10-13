// Displays pinned captures in an adaptive native grid with file promises and window actions.
import AppKit
import ImageIO
import SwiftUI

/// A live library of the pin manager's captures.
@MainActor
struct PinLibraryView: View {
    @Bindable private var manager: PinWindowManager
    private let columns = [GridItem(.adaptive(minimum: 176, maximum: 244), spacing: 20, alignment: .top)]
    @State private var selectedID: UUID?

    /// Shares the application's observable pin manager rather than creating a second pin store.
    init(manager: PinWindowManager) { self.manager = manager }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if manager.pins.isEmpty {
                    ContentUnavailableView("贴图库为空", systemImage: "pin",
                                           description: Text("截图后选择“贴图”，即可将图片悬浮在其他窗口上。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(manager.pins) { pin in
                                PinLibraryTile(pin: pin, selected: selectedID == pin.id,
                                               onSelect: { selectedID = pin.id },
                                               onShow: { manager.show(id: pin.id) },
                                               onRemove: { manager.remove(id: pin.id) })
                            }
                        }.padding(20)
                    }
                }
                Divider()
                HStack(spacing: 12) {
                    Text("\(manager.pins.count) 张贴图").monospacedDigit()
                    if let selectedPin {
                        Text(selectedPin.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else { Spacer() }
                    Text("双击显示 · 拖出文件")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .navigationTitle("贴图库")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("显示贴图", systemImage: "arrow.up.forward.square") {
                        if let selectedPin { manager.show(id: selectedPin.id) }
                    }.disabled(selectedPin == nil).help("显示选中的贴图")
                    Button("在 Finder 中显示", systemImage: "folder") {
                        if let selectedPin { NSWorkspace.shared.activateFileViewerSelecting([selectedPin.url]) }
                    }.disabled(selectedPin == nil).help("在 Finder 中显示选中的文件")
                    Button(role: .destructive) {
                        if let selectedPin { manager.remove(id: selectedPin.id) }
                    } label: { Label("删除贴图", systemImage: "trash") }
                        .disabled(selectedPin == nil).help("删除选中的贴图")
                }
                ToolbarItem(placement: .automatic) {
                    Button("显示 / 隐藏全部", systemImage: "eye") { manager.toggleVisibility() }
                        .disabled(manager.pins.isEmpty)
                        .help("显示或隐藏全部贴图 · ⌥⌘T")
                        .accessibilityLabel("显示或隐藏全部贴图")
                }
            }
            .onChange(of: manager.pins.map(\.id)) { _, ids in
                if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
            }
        }
        .font(.system(size: 13))
        .background(NikoTheme.canvas)
        .frame(minWidth: 600, minHeight: 440)
    }

    private var selectedPin: PinEntry? { manager.pins.first { $0.id == selectedID } }
}

@MainActor
private struct PinLibraryTile: View {
    let pin: PinEntry
    let selected: Bool
    let onSelect: () -> Void
    let onShow: () -> Void
    let onRemove: () -> Void
    @State private var thumbnail: NSImage?
    @State private var metadata: PinLibraryMetadata?
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let thumbnail {
                    FileDragPreview(url: pin.url, image: thumbnail)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 142)
            .background(selected ? Color.accentColor.opacity(0.06) : NikoTheme.surface,
                        in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected || focused ? Color.accentColor : NikoTheme.separator.opacity(hovering ? 0.9 : 0.45),
                                  lineWidth: selected || focused ? 2 : 0.5)
            }
            .help("双击显示贴图，或拖入 Finder 和其他应用")
            .accessibilityLabel("贴图缩略图，可拖出文件")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(metadata?.dimensions ?? "贴图").font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    if let date = metadata?.date {
                        Text(date, format: .dateTime.year().month().day().hour().minute())
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().help("文件日期")
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu { tileActions } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("贴图操作：显示、在 Finder 中查看或删除")
            }.padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onSelect(); onShow() }
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
        .focusable().focused($focused)
        .onChange(of: focused) { _, focused in if focused { onSelect() } }
        .onKeyPress(.return) { onShow(); return .handled }
        .onKeyPress(.space) { onSelect(); return .handled }
        .contextMenu { tileActions }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("贴图，\(metadata?.dimensions ?? pin.url.lastPathComponent)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text("选择贴图"), onSelect)
        .accessibilityAction(named: Text("显示贴图"), onShow)
        .help(pin.url.lastPathComponent)
        .task(id: pin.id) {
            thumbnail = NSImage(data: pin.thumbnail)
            do {
                let value = try await PinLibraryMetadataReader.shared.read(pin.url)
                try Task.checkCancellation()
                metadata = value
            } catch is CancellationError {
            } catch {
                metadata = nil
            }
        }
    }

    @ViewBuilder private var tileActions: some View {
        Button("显示贴图", systemImage: "arrow.up.forward.square", action: onShow)
        Button("在 Finder 中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([pin.url]) }
        Divider()
        Button("删除贴图", systemImage: "trash", role: .destructive, action: onRemove)
    }
}

private struct PinLibraryMetadata: Sendable {
    let width: Int?
    let height: Int?
    let date: Date?
    var dimensions: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) × \(height) px"
    }
}

/// Reads image headers and file dates on an actor; viewing the library never decodes full captures.
private actor PinLibraryMetadataReader {
    static let shared = PinLibraryMetadataReader()

    func read(_ url: URL) throws -> PinLibraryMetadata {
        try Task.checkCancellation()
        let metadata = autoreleasepool { () -> PinLibraryMetadata in
            let file = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            let source = CGImageSourceCreateWithURL(url as CFURL, options)
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, options) } as? [CFString: Any]
            return PinLibraryMetadata(width: (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                                      height: (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                                      date: file?.creationDate ?? file?.contentModificationDate)
        }
        try Task.checkCancellation()
        return metadata
    }
}
