// Edits Vision text in a native inspector beside the source and translation document.
import SwiftUI

@MainActor
struct OCRView: View {
    @Bindable private var model: OCRViewModel
    private let settings: AppSettings
    @State private var showsBlocks = true
    @State private var formattingExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: OCRViewModel, settings: AppSettings = .shared) {
        self.model = model
        self.settings = settings
    }

    var body: some View {
        NavigationStack {
            HSplitView {
                if showsBlocks {
                    recognitionPane.frame(minWidth: 240, idealWidth: 260, maxWidth: 340)
                }
                TranslationPane(text: model.selectedText, isRecognizing: model.isRecognizing, settings: settings)
                    .frame(minWidth: 580)
            }
            .navigationTitle("识别与翻译")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { showsBlocks.toggle() }
                    } label: { Label(showsBlocks ? "隐藏文字区块" : "显示文字区块", systemImage: "sidebar.left") }
                    .help(showsBlocks ? "隐藏文字区块，展开原文与译文" : "显示文字区块，勾选或编辑识别结果")
                }
                ToolbarItem(placement: .status) {
                    Text("\(selectedCount) 段 · \(model.selectedText.count) 字")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("复制文字", systemImage: "doc.on.clipboard") { model.copySelected() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.selectedText.isEmpty || model.isRecognizing)
                        .help("复制所有勾选区块 · ⌘↩")
                }
            }
        }
        .background(NikoTheme.canvas)
        .tint(NikoTheme.accent)
        .frame(minWidth: 920, minHeight: 560)
    }

    private var selectedCount: Int { model.blocks.filter(\.selected).count }
    private var allSelected: Bool { !model.blocks.isEmpty && selectedCount == model.blocks.count }

    private var recognitionPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("文字区块").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(allSelected ? "取消全选" : "全选") {
                    let selected = !allSelected
                    for index in model.blocks.indices { model.blocks[index].selected = selected }
                }
                .buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(NikoTheme.accent)
                .disabled(model.blocks.isEmpty || model.isRecognizing)
            }.padding(.horizontal, 14).frame(height: 42)
            Divider()
            if let error = model.errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                    Text(error).textSelection(.enabled)
                }
                .font(.callout).foregroundStyle(.red).padding(12)
            }
            if model.blocks.isEmpty {
                VStack(spacing: 12) {
                    if model.isRecognizing { ProgressView().controlSize(.small) }
                    Image(systemName: "text.viewfinder").font(.system(size: 24, weight: .light))
                        .foregroundStyle(NikoTheme.accent.opacity(0.6))
                    Text(model.isRecognizing ? "正在识别文字…" : "没有识别出文字")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    if !model.isRecognizing {
                        Text("重新选择文字清晰的区域。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach($model.blocks) { $block in
                            OCRBlockEditor(block: $block,
                                number: (model.blocks.firstIndex(where: { $0.id == block.id }) ?? 0) + 1,
                                onCopy: { model.copy(blockID: block.id) })
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }
            }
            Divider()
            DisclosureGroup(isExpanded: $formattingExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("合并段落", isOn: $model.mergeParagraphs)
                    Toggle("去掉换行", isOn: $model.stripLineBreaks)
                    Toggle("中文标点转英文", isOn: $model.englishPunctuation)
                }.toggleStyle(.checkbox).font(.system(size: 12)).padding(.top, 10)
            } label: { Text("文字整理").font(.system(size: 12, weight: .medium)) }
                .padding(14)
        }.background(NikoTheme.canvas)
    }
}

@MainActor
private struct OCRBlockEditor: View {
    @Binding var block: OCRBlock
    let number: Int
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("选择第 \(number) 个文字区块", isOn: $block.selected).toggleStyle(.checkbox).labelsHidden()
                Text(number.formatted(.number.precision(.integerLength(2))))
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer()
                Text(Double(block.confidence), format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                    .help("Vision 识别置信度")
                Button(action: onCopy) { Label("复制第 \(number) 个文字区块", systemImage: "doc.on.doc").labelStyle(.iconOnly).frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).help("复制这段文字")
                    .disabled(block.text.isEmpty)
            }
            NativeTextEditor(text: $block.text, accessibilityLabel: "编辑第 \(number) 个文字区块")
                .padding(.horizontal, -4).frame(height: editorHeight)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(block.selected ? NikoTheme.selection.opacity(0.5) : .clear)
        .overlay(alignment: .leading) {
            if block.selected { Rectangle().fill(NikoTheme.accent).frame(width: 2) }
        }
    }

    private var editorHeight: CGFloat {
        let estimatedLines = block.text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 28))) }
        return min(180, max(44, CGFloat(estimatedLines) * 20 + 8))
    }
}
