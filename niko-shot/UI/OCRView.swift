// Edits and selects Vision text blocks with a live original-text preview and a translation pane.
import SwiftUI

/// Native OCR workspace using the coordinator's observable recognition model.
@MainActor
struct OCRView: View {
    @Bindable private var model: OCRViewModel
    private let settings: AppSettings
    @State private var formattingExpanded = false

    /// Shares the recognition model so block edits and copy options stay synchronized.
    init(model: OCRViewModel, settings: AppSettings = .shared) { self.model = model; self.settings = settings }

    var body: some View {
        NavigationStack {
            HSplitView {
                recognitionPane.frame(minWidth: 290, idealWidth: 340)
                TranslationPane(text: model.selectedText, isRecognizing: model.isRecognizing, settings: settings)
                    .frame(minWidth: 620, idealWidth: 850)
            }
            .navigationTitle("识别与翻译")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(allSelected ? "取消全选" : "全选", systemImage: allSelected ? "checkmark.square.fill" : "checkmark.square") {
                        let selected = !allSelected
                        for index in model.blocks.indices { model.blocks[index].selected = selected }
                    }
                    .disabled(model.blocks.isEmpty || model.isRecognizing)
                    .accessibilityLabel(allSelected ? "取消选择全部文字区块" : "选择全部文字区块")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("复制所选文字", systemImage: "doc.on.clipboard") { model.copySelected() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.selectedText.isEmpty || model.isRecognizing)
                        .help("复制所有勾选区块 · ⌘↩")
                        .accessibilityLabel("复制所有勾选的文字区块")
                }
            }
        }
        .background(NikoTheme.canvas)
        .frame(minWidth: 980, minHeight: 600)
    }

    private var allSelected: Bool { !model.blocks.isEmpty && model.blocks.allSatisfy(\.selected) }

    private var recognitionPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                NikoSymbolBadge(symbol: "text.viewfinder", size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("识别文字").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(model.isRecognizing ? "正在读取图中文字…" : "已选择 \(model.blocks.filter(\.selected).count) / \(model.blocks.count) 段")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityLabel("已选择 \(model.blocks.filter(\.selected).count) 个，共 \(model.blocks.count) 个区块")
                }
                Spacer()
                if model.isRecognizing { ProgressView().controlSize(.small) }
            }.padding(20)
            Divider()
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .padding(16).accessibilityLabel("识别错误：\(error)")
            }
            if model.blocks.isEmpty {
                if model.isRecognizing {
                    VStack(spacing: 12) {
                        Image(systemName: "text.viewfinder").font(.system(size: 36)).foregroundStyle(.tertiary)
                        Text("正在读取图中文字").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("没有识别出文字", systemImage: "text.viewfinder",
                                           description: Text("请选择文字清晰的区域，然后再次识别。"))
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach($model.blocks) { $block in
                            OCRBlockEditor(block: $block,
                                           number: (model.blocks.firstIndex(where: { $0.id == block.id }) ?? 0) + 1,
                                           onCopy: { model.copy(blockID: block.id) })
                        }
                    }.padding(16)
                }
            }
            Divider()
            DisclosureGroup(isExpanded: $formattingExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("合并段落", isOn: $model.mergeParagraphs).accessibilityLabel("复制时合并段落")
                    Toggle("去掉换行", isOn: $model.stripLineBreaks).accessibilityLabel("复制时去掉多余换行")
                    Toggle("中文标点转英文", isOn: $model.englishPunctuation)
                        .accessibilityLabel("复制时将中文标点转换为英文标点")
                }.toggleStyle(.checkbox).padding(.top, 12)
            } label: {
                Label("复制时整理文字", systemImage: "text.badge.checkmark").font(.callout)
            }.padding(16)
        }
    }

}

@MainActor
private struct OCRBlockEditor: View {
    @Binding var block: OCRBlock
    let number: Int
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Toggle("文本 \(number.formatted(.number.precision(.integerLength(2))))", isOn: $block.selected)
                    .toggleStyle(.checkbox).font(.callout.weight(.medium))
                    .accessibilityLabel("选择第 \(number) 个文字区块")
                Spacer()
                Text(Double(block.confidence), format: .percent.precision(.fractionLength(0)))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("文字识别置信度")
                    .accessibilityLabel("识别置信度 \(Int(block.confidence * 100))%")
                Button(action: onCopy) { Image(systemName: "doc.on.doc").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).help("复制这段文字")
                    .disabled(block.text.isEmpty)
                    .accessibilityLabel("复制第 \(number) 个文字区块")
            }
            TextEditor(text: $block.text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, -4)
                .frame(height: editorHeight)
                .accessibilityLabel("编辑第 \(number) 个文字区块")
        }
        .padding(14)
        .background(NikoTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(block.selected ? Color.accentColor.opacity(0.32) : NikoTheme.separator.opacity(0.25), lineWidth: block.selected ? 1 : 0.5)
        }
    }

    private var editorHeight: CGFloat {
        let estimatedLines = block.text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 46))) }
        return min(180, max(62, CGFloat(estimatedLines) * 20 + 12))
    }
}
