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
    @State private var selectedID: UUID?

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
                if let errorMessage {
                    HStack(spacing: 10) {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red).textSelection(.enabled)
                        Spacer()
                        Button("重试") { Task { await reload() } }
                            .accessibilityLabel("重新载入截图历史")
                    }.padding(.horizontal, 20).padding(.vertical, 12)
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
                    List(selection: $selectedID) {
                        ForEach(records) { record in
                            HistoryRow(record: record, selected: selectedID == record.id, deleting: deleting.contains(record.id),
                                       onOCR: { onOCR(record) }, onPin: { onPin(record) },
                                       onEdit: { onEdit(record) }, onDelete: { Task { await remove(record) } })
                                .tag(record.id)
                                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        }
                        if hasMore {
                            HStack(spacing: 10) {
                                Spacer()
                                if loadingMore { ProgressView().controlSize(.small) }
                                Button("载入更多") { Task { await loadNextPage() } }
                                    .disabled(loadingMore)
                                    .accessibilityLabel("载入下一页截图历史")
                                Spacer()
                            }
                            .padding(.vertical, 12).listRowSeparator(.hidden)
                            .task(id: records.last?.id) { await loadNextPage() }
                        }
                    }
                    .listStyle(.inset)
                    .accessibilityLabel("截图历史，可使用方向键选择")
                }
                Divider()
                HStack(spacing: 12) {
                    Text("已载入 \(records.count) 张").monospacedDigit()
                        .accessibilityLabel("已载入 \(records.count) 张截图")
                    if let selectedRecord {
                        Text(URL(fileURLWithPath: selectedRecord.path).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else { Spacer() }
                    Text("双击编辑 · 拖出文件")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .navigationTitle("截图历史")
            .searchable(text: $query, placement: .toolbar, prompt: "搜索截图或识别文字")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("编辑标注", systemImage: "pencil.tip") {
                        if let selectedRecord { onEdit(selectedRecord) }
                    }.disabled(selectedRecord == nil).help("编辑选中的截图")
                    Button("识别文字", systemImage: "text.viewfinder") {
                        if let selectedRecord { onOCR(selectedRecord) }
                    }.disabled(selectedRecord == nil).help("识别选中截图的文字")
                    Button("贴图", systemImage: "pin") {
                        if let selectedRecord { onPin(selectedRecord) }
                    }.disabled(selectedRecord == nil).help("将选中的截图贴到桌面")
                    Button(role: .destructive) {
                        if let selectedRecord { Task { await remove(selectedRecord) } }
                    } label: { Label("删除", systemImage: "trash") }
                        .disabled(selectedRecord == nil || selectionIsDeleting).help("删除选中的截图历史")
                }
                ToolbarItem(placement: .automatic) {
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await reload() } }
                        .disabled(loading).help("刷新截图历史").accessibilityLabel("刷新截图历史")
                }
            }
            .task(id: query) { await reload() }
            .onChange(of: loading) { _, loading in
                if !loading, selectedRecord == nil { selectedID = nil }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .captureHistoryChanged)) { _ in Task { await reload() } }
        .font(.system(size: 13))
        .background(NikoTheme.canvas)
        .frame(minWidth: 760, minHeight: 500)
    }

    private var selectedRecord: HistoryRecord? { records.first { $0.id == selectedID } }
    private var selectionIsDeleting: Bool { selectedID.map { deleting.contains($0) } ?? false }

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
    let selected: Bool
    let deleting: Bool
    let onOCR: () -> Void
    let onPin: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    private var fileURL: URL { URL(fileURLWithPath: record.path) }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    FileDragPreview(url: fileURL, image: thumbnail)
                } else {
                    Image(systemName: "photo").font(.title).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 112, height: 72)
            .background(NikoTheme.surface, in: RoundedRectangle(cornerRadius: 5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(NikoTheme.separator.opacity(0.4), lineWidth: 0.5) }
            .help("拖入 Finder 或其他应用")
            .accessibilityLabel("截图缩略图，可拖出文件")
            VStack(alignment: .leading, spacing: 5) {
                Text(captureName).font(.system(size: 13, weight: .medium))
                HStack(spacing: 12) {
                    Text(record.createdAt, format: .dateTime.year().month().day().hour().minute())
                    Text("\(record.width) × \(record.height) px")
                }.font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                if !record.ocrText.isEmpty {
                    Text(record.ocrText).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).help(fileURL.lastPathComponent)
            if deleting {
                ProgressView().controlSize(.small).accessibilityLabel("正在删除截图")
            }
            Menu {
                rowActions
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                .help("截图操作").accessibilityLabel("截图操作：识别文字、贴图、编辑或删除")
        }
        .contentShape(Rectangle())
        .background(Color.primary.opacity(hovering && !selected ? 0.025 : 0), in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu { rowActions }
        .task(id: record.id) { thumbnail = NSImage(data: record.thumbnail) }
    }

    @ViewBuilder private var rowActions: some View {
        Button("重新识别文字", systemImage: "text.viewfinder", action: onOCR)
        Button("贴图", systemImage: "pin", action: onPin)
        Button("编辑标注", systemImage: "pencil.tip", action: onEdit)
        Button("在 Finder 中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        Divider()
        Button("删除", systemImage: "trash", role: .destructive, action: onDelete).disabled(deleting)
    }

    private var captureName: String {
        switch record.captureKind {
        case "window": "窗口截图"
        case "fullscreen": "全屏截图"
        case "scroll": "长截图"
        case "ocr": "文字识别"
        default: "区域截图"
        }
    }
}
