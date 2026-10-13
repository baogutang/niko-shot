// Embeds editable OCR and automatic translation beneath the active screenshot toolbar.
import AppKit
import SwiftUI

/// An inline text result which keeps the screenshot and its annotation controls on screen.
@MainActor
final class ScreenshotTextController: NSViewController {
    let preferredHeight: CGFloat = 280
    var onDismiss: (() -> Void)?
    var onExpand: ((OCRViewModel) -> Void)?
    var onRecognizedText: ((String) -> Void)?
    var onRetrySnapshot: (() -> Void)?
    let model: ScreenshotTextModel

    var isWorking: Bool { model.isWorking }
    var resourceCounts: ScreenshotTextResourceCounts { model.resourceCounts }
    var translationModel: TranslationViewModel { model.translation }

    /// Uses the same preferences and native recognition/translation models as the expanded workspace.
    init(settings: AppSettings = .shared, recognition: ScreenshotTextModel.RecognitionOperation? = nil,
         translationOperation: ScreenshotTextModel.TranslationOperation? = nil) {
        model = ScreenshotTextModel(settings: settings, recognition: recognition,
            translationOperation: translationOperation)
        super.init(nibName: nil, bundle: nil)
        model.onRecognizedText = { [weak self] text in self?.onRecognizedText?(text) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let content = ScreenshotTextView(model: model,
            dismiss: { [weak self] in self?.dismissCard() },
            expand: { [weak self] in self?.expandWorkspace() },
            retry: { [weak self] in self?.retryRecognition() })
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: .darkAqua)
        view = hosting
    }

    func prepareSnapshot(translateAfterRecognition: Bool) {
        model.prepareSnapshot(translateAfterRecognition: translateAfterRecognition)
    }

    func recognize(_ image: CGImage, translateAfterRecognition: Bool) {
        model.recognize(image, translateAfterRecognition: translateAfterRecognition)
    }

    func requestTranslation() { model.requestTranslation() }
    func showError(_ error: any Error) { model.showError(error) }
    func cancel() { model.cancel() }
    func finishAndDrain() async { await model.finishAndDrain() }

    private func dismissCard() {
        guard model.isActive else { return }
        model.cancel()
        onDismiss?()
    }

    func expandWorkspace() {
        guard model.isActive, !model.ocr.isRecognizing, !model.originalText.isEmpty else { return }
        model.transferTranslationOwnership()
        onExpand?(model.ocr)
    }

    private func retryRecognition() {
        guard model.isActive else { return }
        if !model.retryRecognition() { onRetrySnapshot?() }
    }
}

/// Compact native controls and one scrollable text area, suitable for narrow or height-constrained HUDs.
@MainActor
private struct ScreenshotTextView: View {
    @Bindable var model: ScreenshotTextModel
    let dismiss: () -> Void
    let expand: () -> Void
    let retry: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("识别与翻译").font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Picker("显示文字", selection: $model.section) {
                    ForEach(ScreenshotTextModel.Section.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 132)
                Button(action: dismiss) {
                    Label("关闭文字结果", systemImage: "xmark").labelStyle(.iconOnly)
                        .frame(width: 26, height: 26)
                }.buttonStyle(.borderless).help("关闭文字结果，继续标注截图")
            }.padding(.horizontal, 12).frame(height: 38)

            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.secondary).accessibilityHidden(true)
                Picker("翻译服务", selection: Binding(get: { model.providerSelection }, set: { model.selectProvider($0) })) {
                    ForEach(TranslationProviderID.allCases, id: \.rawValue) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                    if !model.settings.customTranslationServices.isEmpty { Divider() }
                    ForEach(model.settings.customTranslationServices) { configuration in
                        Text(configuration.name).tag("instance.\(configuration.id.uuidString)")
                    }
                }.labelsHidden().frame(maxWidth: 210)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                Picker("目标语言", selection: Binding(get: { model.translation.target }, set: { model.selectTarget($0) })) {
                    ForEach(Language.allCases) { language in
                        Text(language.displayName).tag(language).disabled(!model.supportsTarget(language))
                    }
                }.labelsHidden().frame(maxWidth: 150)
                Spacer(minLength: 0)
                Text("\(model.originalText.count) 字").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }.controlSize(.small).padding(.horizontal, 12).frame(height: 30)
            Divider()
            textArea.frame(maxWidth: .infinity, maxHeight: .infinity)
            statusArea
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { mainActions; Spacer(minLength: 4); expandAction }
                VStack(spacing: 5) {
                    HStack(spacing: 8) { mainActions; Spacer(minLength: 0) }
                    HStack { Spacer(minLength: 0); expandAction }
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .font(.system(size: 12))
        .tint(NikoTheme.accent)
        .background(reduceTransparency ? NikoTheme.canvas : Color.clear)
        .preferredColorScheme(.dark)
        .onChange(of: model.settings.translationProvider) { _, _ in model.providerConfigurationChanged() }
        .onChange(of: model.settings.selectedCustomTranslationID) { _, _ in model.providerConfigurationChanged() }
        .onChange(of: model.settings.customTranslationServices) { _, _ in model.providerConfigurationChanged() }
        .onChange(of: model.settings.automaticTranslation) { _, _ in model.automaticTranslationChanged() }
    }

    @ViewBuilder private var textArea: some View {
        if model.ocr.isRecognizing || (model.section == .translation && (model.translation.isTranslating || model.isAwaitingTranslation)) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.ocr.isRecognizing ? "正在识别文字…" : "正在翻译…").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.section == .original {
            if !model.hasRecognizedResult {
                placeholder(model.ocr.errorMessage == nil ? "没有识别出文字，可重新选择清晰区域。" : "识别未完成，请重试。")
            } else {
                ScreenshotTextEditor(text: Binding(get: { model.originalText }, set: { model.editOriginal($0) }), editable: true)
            }
        } else if model.translation.translatedText.isEmpty {
            placeholder(model.originalText.isEmpty ? "识别完成后在这里显示译文。" : model.settings.automaticTranslation ?
                "译文将显示在这里；可检查当前服务配置或重试。" : "点击翻译，将原文发送到当前服务。")
        } else {
            ScreenshotTextEditor(text: .constant(model.translation.translatedText), editable: false)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var statusArea: some View {
        if let error = model.ocr.errorMessage ?? model.translation.errorMessage {
            HStack(alignment: .top, spacing: 8) {
                ScrollView {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 44)
                if model.canRetryRecognition { Button("重试", action: retry).buttonStyle(.borderless) }
            }.padding(.horizontal, 12).padding(.vertical, 5)
        } else if let reason = model.translation.unsupportedReason(settings: model.settings) {
            Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 5)
        } else if let feedback = model.feedback ?? model.translation.statusMessage {
            Text(feedback).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 5)
        }
    }

    @ViewBuilder private var mainActions: some View {
        if model.translation.isTranslating || model.isAwaitingTranslation {
            Button("取消翻译") { model.cancelTranslation() }
        } else if !model.settings.automaticTranslation || model.translation.errorMessage != nil ||
                    model.translation.translatedText.isEmpty && !model.ocr.isRecognizing && !model.originalText.isEmpty {
            Button(model.translation.errorMessage == nil ? (model.settings.automaticTranslation ? "重新翻译" : "翻译") : "重试翻译", systemImage: "character.bubble") {
                model.requestTranslation()
            }.buttonStyle(.borderedProminent).foregroundStyle(NikoTheme.onAccent)
                .disabled(!model.ocr.isRecognizing && model.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.translation.unsupportedReason(settings: model.settings) != nil)
        }
        Button("复制译文") { model.copy(.translation) }.disabled(model.translation.translatedText.isEmpty)
        Button("复制原文") { model.copy(.original) }.disabled(model.originalText.isEmpty || model.ocr.isRecognizing)
    }

    private var expandAction: some View {
        Button("展开工作区", systemImage: "arrow.up.left.and.arrow.down.right", action: expand)
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .disabled(model.originalText.isEmpty || model.ocr.isRecognizing)
    }
}

/// Uses AppKit's native text accessibility and selection rather than relabelling SwiftUI scroll containers.
@MainActor
private struct ScreenshotTextEditor: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let editor = NSTextView()
        editor.isRichText = false
        editor.isEditable = editable
        editor.isSelectable = true
        editor.allowsUndo = editable
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 12, height: 9)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(editable ? "原文，可编辑" : "译文")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = editable
        editor.allowsUndo = editable
        editor.setAccessibilityLabel(editable ? "原文，可编辑" : "译文")
        if editor.string != text { editor.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScreenshotTextEditor
        init(parent: ScreenshotTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard parent.editable, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
