// Browses searchable, paginated screenshot history with native file-promise thumbnails.
import AppKit
import SwiftUI

/// A lazy history browser backed by the SQLite store and coordinator callbacks.
@MainActor
struct HistoryView: View {
    private let store: HistoryStore
    private let onOCR: (HistoryRecord) -> Void
    private let onPin: (HistoryRecord) -> Void
    private let onEdit: (HistoryRecord) -> Void
    private let pageSize = 50
    @State private var query = ""
    @State private var records: [HistoryRecord] = []
    @State private var loading = false
    @State private var loadingMore = false
    @State private var hasMore = false
    @State private var requestID = UUID()
    @State private var errorMessage: String?
    @State private var deleting: Set<UUID> = []

    /// Connects history actions without embedding OCR, pin or editor implementations.
    init(store: HistoryStore, onOCR: @escaping (HistoryRecord) -> Void,
         onPin: @escaping (HistoryRecord) -> Void, onEdit: @escaping (HistoryRecord) -> Void) {
        self.store = store
        self.onOCR = onOCR
        self.onPin = onPin
        self.onEdit = onEdit
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    NikoSymbolBadge(symbol: "photo.on.rectangle.angled", size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("截图历史").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Text("搜索、编辑，或把截图拖到其他应用。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(20)
                Divider()
                if let errorMessage {
                    HStack(spacing: 10) {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        Spacer()
                        Button("重试") { Task { await reload() } }
                            .accessibilityLabel("重新载入截图历史")
                    }.padding(14)
                    Divider()
                }
                if loading && records.isEmpty {
                    ProgressView("正在载入截图…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if records.isEmpty {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView("尚无截图历史", systemImage: "photo.on.rectangle.angled",
                                               description: Text("完成截图后，可以在这里查找、编辑或重新识别文字。"))
                    } else {
                        ContentUnavailableView("没有找到截图", systemImage: "magnifyingglass",
                                               description: Text("试试其他关键词。已识别的文字也可以搜索。"))
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(records) { record in
                                HistoryRow(record: record, deleting: deleting.contains(record.id),
                                           onOCR: { onOCR(record) }, onPin: { onPin(record) },
                                           onEdit: { onEdit(record) }, onDelete: { Task { await remove(record) } })
                                Divider().padding(.leading, 180)
                            }
                            if hasMore {
                                VStack(spacing: 8) {
                                    if loadingMore { ProgressView().controlSize(.small) }
                                    Button("载入更多") { Task { await loadNextPage() } }
                                        .disabled(loadingMore)
                                        .accessibilityLabel("载入下一页截图历史")
                                }
                                .padding(18)
                                .frame(maxWidth: .infinity)
                                .task(id: records.last?.id) { await loadNextPage() }
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("截图历史")
            .searchable(text: $query, placement: .toolbar, prompt: "搜索截图或识别文字")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Text("\(records.count) 张").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityLabel("已载入 \(records.count) 张截图")
                }
                ToolbarItem(placement: .automatic) {
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await reload() } }
                        .disabled(loading).help("刷新截图历史").accessibilityLabel("刷新截图历史")
                }
            }
            .task(id: query) { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .captureHistoryChanged)) { _ in Task { await reload() } }
        .background(NikoTheme.canvas)
        .frame(minWidth: 760, minHeight: 500)
    }

    private func reload() async {
        let currentID = UUID()
        requestID = currentID
        loading = true
        loadingMore = false
        hasMore = false
        errorMessage = nil
        records = []
        defer { if requestID == currentID { loading = false } }
        do {
            let page = try await store.list(query: query.trimmingCharacters(in: .whitespacesAndNewlines), limit: pageSize, offset: 0)
            try Task.checkCancellation()
            guard requestID == currentID else { return }
            records = page
            hasMore = page.count == pageSize
        } catch is CancellationError {
            // SwiftUI cancels the previous search task as its query changes.
        } catch {
            guard requestID == currentID else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadNextPage() async {
        guard hasMore, !loading, !loadingMore else { return }
        let currentID = requestID
        loadingMore = true
        defer { if requestID == currentID { loadingMore = false } }
        do {
            let page = try await store.list(query: query.trimmingCharacters(in: .whitespacesAndNewlines), limit: pageSize, offset: records.count)
            try Task.checkCancellation()
            guard requestID == currentID else { return }
            let existingIDs = Set(records.map(\.id))
            records.append(contentsOf: page.filter { !existingIDs.contains($0.id) })
            hasMore = page.count == pageSize
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard requestID == currentID else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ record: HistoryRecord) async {
        guard deleting.insert(record.id).inserted else { return }
        defer { deleting.remove(record.id) }
        do {
            try await store.delete(id: record.id)
            // Re-query after deletion so an in-flight offset page cannot skip a row.
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct HistoryRow: View {
    let record: HistoryRecord
    let deleting: Bool
    let onOCR: () -> Void
    let onPin: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    private var fileURL: URL { URL(fileURLWithPath: record.path) }

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let thumbnail {
                    FileDragPreview(url: fileURL, image: thumbnail)
                } else {
                    Image(systemName: "photo").font(.title).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 156, height: 100)
            .background(NikoTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(NikoTheme.separator.opacity(0.35), lineWidth: 0.5) }
            .help("拖入 Finder 或其他应用")
            .accessibilityLabel("截图缩略图，可拖出文件")
            VStack(alignment: .leading, spacing: 7) {
                Text(captureName).font(.system(size: 14, weight: .semibold))
                Text(record.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Text("\(record.width) × \(record.height) 像素")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                if !record.ocrText.isEmpty {
                    Text(record.ocrText).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).help(fileURL.lastPathComponent)
            HStack(spacing: 6) {
                rowButton("重新识别文字", symbol: "text.viewfinder", action: onOCR)
                rowButton("贴图", symbol: "pin", action: onPin)
                rowButton("编辑标注", symbol: "pencil.tip", action: onEdit)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash").frame(width: 32, height: 36) }
                    .buttonStyle(NikoActionButtonStyle()).help("删除截图历史").accessibilityLabel("删除截图历史")
                    .disabled(deleting)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(hovering ? 0.025 : 0), in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("重新识别文字", systemImage: "text.viewfinder", action: onOCR)
            Button("贴图", systemImage: "pin", action: onPin)
            Button("编辑标注", systemImage: "pencil.tip", action: onEdit)
            Button("在 Finder 中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
            Divider()
            Button("删除", systemImage: "trash", role: .destructive, action: onDelete).disabled(deleting)
        }
        .task(id: record.id) { thumbnail = NSImage(data: record.thumbnail) }
    }

    private var captureName: String {
        switch record.captureKind {
        case "window": "窗口"
        case "fullscreen": "全屏"
        case "scroll": "长截图"
        case "ocr": "文字识别"
        default: "区域"
        }
    }

    private func rowButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 32, height: 36) }
            .buttonStyle(NikoActionButtonStyle()).help(title).accessibilityLabel(title)
    }
}
