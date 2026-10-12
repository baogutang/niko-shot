// Edits and selects Vision text blocks with a live original-text preview and a translation pane.
import SwiftUI

/// Native OCR workspace using the coordinator's observable recognition model.
@MainActor
struct OCRView: View {
    @Bindable private var model: OCRViewModel

    /// Shares the recognition model so block edits and copy options stay synchronized.
    init(model: OCRViewModel) { self.model = model }

    var body: some View {
        NavigationStack {
            HSplitView {
                recognitionPane.frame(minWidth: 390, idealWidth: 510)
                previewPane.frame(minWidth: 280, idealWidth: 340)
            }
            .navigationTitle("文字识别")
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
        .frame(minWidth: 740, minHeight: 520)
    }

    private var allSelected: Bool { !model.blocks.isEmpty && model.blocks.allSatisfy(\.selected) }

    private var recognitionPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("识别区块").font(.headline)
                Text("\(model.blocks.filter(\.selected).count) / \(model.blocks.count)")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel("已选择 \(model.blocks.filter(\.selected).count) 个，共 \(model.blocks.count) 个区块")
                Spacer()
                if model.isRecognizing {
                    ProgressView().controlSize(.small)
                    Text("正在识别…").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(18)
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
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach($model.blocks) { $block in
                            OCRBlockEditor(block: $block,
                                           number: (model.blocks.firstIndex(where: { $0.id == block.id }) ?? 0) + 1,
                                           onCopy: { model.copy(blockID: block.id) })
                        }
                    }.padding(16)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("复制时整理文字").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    Toggle("合并段落", isOn: $model.mergeParagraphs)
                        .accessibilityLabel("复制时合并段落")
                    Toggle("去掉换行", isOn: $model.stripLineBreaks)
                        .accessibilityLabel("复制时去掉多余换行")
                }.toggleStyle(.checkbox)
                Toggle("中文标点转英文", isOn: $model.englishPunctuation)
                    .toggleStyle(.checkbox).accessibilityLabel("复制时将中文标点转换为英文标点")
            }.padding(16)
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("原文与译文", systemImage: "character.bubble").font(.headline).padding(18)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    ScrollView {
                        Text(model.selectedText.isEmpty ? "勾选左侧区块以预览原文" : model.selectedText)
                            .font(.body)
                            .foregroundStyle(model.selectedText.isEmpty ? Color.secondary : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(8)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("所选文字原文预览")
                } label: {
                    Label("原文", systemImage: "text.alignleft")
                }
                translationPane
            }.padding(16)
        }
    }

    // B6 replaces this empty pane with actual provider controls and returned translation text.
    private var translationPane: some View {
        GroupBox {
            VStack(spacing: 10) {
                Image(systemName: "character.bubble").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text("尚无译文").font(.headline).foregroundStyle(.secondary)
                Text("翻译结果将在这里显示。").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .accessibilityElement(children: .combine)
        } label: {
            Label("译文", systemImage: "globe")
        }
    }
}

@MainActor
private struct OCRBlockEditor: View {
    @Binding var block: OCRBlock
    let number: Int
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("区块 \(number)", isOn: $block.selected)
                    .toggleStyle(.checkbox).font(.callout.weight(.medium))
                    .accessibilityLabel("选择第 \(number) 个文字区块")
                Spacer()
                Text(Double(block.confidence), format: .percent.precision(.fractionLength(0)))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .help("文字识别置信度")
                    .accessibilityLabel("识别置信度 \(Int(block.confidence * 100))%")
                Button("复制", systemImage: "doc.on.doc", action: onCopy)
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(block.text.isEmpty)
                    .accessibilityLabel("复制第 \(number) 个文字区块")
            }
            TextEditor(text: $block.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: editorHeight)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1) }
                .accessibilityLabel("编辑第 \(number) 个文字区块")
            Text(coordinateDescription).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                .accessibilityLabel("第 \(number) 个区块在图片中的归一化坐标：\(coordinateDescription)")
        }
        .padding(12)
        .background(.quaternary.opacity(block.selected ? 0.35 : 0.15), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1) }
    }

    private var editorHeight: CGFloat {
        let estimatedLines = block.text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 46))) }
        return min(180, max(72, CGFloat(estimatedLines) * 18 + 16))
    }

    private var coordinateDescription: String {
        let box = block.boundingBox
        return String(format: "x %.1f%%  ·  y %.1f%%  ·  %.1f%% × %.1f%%", box.minX * 100, box.minY * 100, box.width * 100, box.height * 100)
    }
}
