// Presents peer-provider selection and side-by-side source/result text without web UI.
import AppKit
import SwiftUI

/// The OCR window's native translation workspace.
@MainActor
struct TranslationPane: View {
    let text: String
    let isRecognizing: Bool
    @Bindable private var settings: AppSettings
    @State private var model = TranslationViewModel()
    @State private var recognitionGeneration = 0
    @State private var automaticGeneration: Int?
    @State private var showsSetupGuide = false

    /// Shows a snapshot-aware translation pane sharing persisted provider preferences.
    init(text: String, isRecognizing: Bool, settings: AppSettings = .shared) {
        self.text = text
        self.isRecognizing = isRecognizing
        self.settings = settings
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "globe").foregroundStyle(.secondary).accessibilityHidden(true)
                TranslationServicePicker(settings: settings).labelsHidden().frame(maxWidth: 210)
                Button(action: openTranslationSettings) { Image(systemName: "slider.horizontal.3").frame(width: 26, height: 26) }
                    .buttonStyle(.borderless).help("配置翻译服务").accessibilityLabel("配置当前翻译服务")
                Spacer(minLength: 10)
                Toggle("自动翻译", isOn: $settings.automaticTranslation)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12)).fixedSize()
                    .accessibilityLabel("文字识别完成后自动翻译")
                Button { showsSetupGuide = true } label: { Image(systemName: "questionmark.circle").frame(width: 26, height: 26) }
                    .buttonStyle(.borderless).help("当前服务的申请步骤与官方入口")
                    .accessibilityLabel("打开申请与接入指南")
            }
            .padding(.horizontal, 16).frame(height: 48).background(NikoTheme.canvas)
            Divider()
            HSplitView {
                textPanel(title: "原文", content: text,
                    placeholder: isRecognizing ? "正在读取图中文字…" : "选择需要的文字区块。", isResult: false)
                    .frame(minWidth: 235)
                textPanel(title: "译文", content: model.translatedText,
                    placeholder: model.isTranslating ? "正在翻译…" : "选择目标语言，然后开始翻译。", isResult: true)
                    .frame(minWidth: 235)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let reason = model.unsupportedReason(settings: settings) {
                    Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.errorMessage {
                    HStack(alignment: .top, spacing: 12) {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityLabel("翻译错误：\(error)")
                        Spacer(minLength: 0)
                        Button("查看配置", action: openTranslationSettings).buttonStyle(.borderless).font(.system(size: 12))
                    }
                } else if let message = model.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if model.isTranslating {
                        ProgressView().controlSize(.small)
                        Text("正在翻译…").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if let detected = model.detectedSource {
                        Text("检测为\(detected.displayName)").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text("\(text.count) 字").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    if model.isTranslating {
                        Button("取消翻译") { model.cancel() }.accessibilityLabel("取消当前翻译")
                    } else {
                        Button("翻译", systemImage: "character.bubble") { model.translate(text: text, settings: settings) }
                            .buttonStyle(.borderedProminent)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRecognizing || model.unsupportedReason(settings: settings) != nil)
                            .accessibilityLabel("使用当前服务翻译所选文字")
                    }
                }.frame(minHeight: 28)
            }.padding(.horizontal, 16).padding(.vertical, 10).background(NikoTheme.canvas)
        }
        .sheet(isPresented: $showsSetupGuide) { ProviderSetupGuideView(provider: settings.translationProvider) }
        .onAppear { automaticTranslateIfReady() }
        .onChange(of: isRecognizing) { old, new in
            if new {
                recognitionGeneration += 1
                automaticGeneration = nil
                model.invalidate()
            } else if old { automaticTranslateIfReady() }
        }
        .onChange(of: text) { _, new in model.originalTextChanged(new) }
        .onChange(of: settings.automaticTranslation) { _, enabled in if enabled { automaticTranslateIfReady() } }
        .onChange(of: settings.translationProvider) { _, _ in model.invalidate() }
        .onChange(of: settings.selectedCustomTranslationID) { _, _ in model.invalidate() }
        .onChange(of: settings.customTranslationServices) { _, _ in
            if settings.translationProvider == .custom { model.invalidate() }
        }
        .onChange(of: model.source) { _, _ in model.invalidate() }
        .onChange(of: model.target) { _, _ in model.invalidate() }
        .onDisappear { model.cancel() }
    }

    private func automaticTranslateIfReady() {
        guard settings.automaticTranslation, !isRecognizing,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              automaticGeneration != recognitionGeneration else { return }
        automaticGeneration = recognitionGeneration
        model.translate(text: text, settings: settings)
    }

    private func supports(_ language: Language, asSource: Bool) -> Bool {
        if settings.translationProvider == .custom,
           let configuration = settings.customTranslationServices.first(where: { $0.id == settings.selectedCustomTranslationID }) {
            return configuration.unsupportedReason(source: asSource ? language : model.source, target: asSource ? model.target : language) == nil
        }
        return language.supports(provider: settings.translationProvider, asSource: asSource)
    }

    private func openTranslationSettings() { (NSApp.delegate as? AppDelegate)?.showTranslationSettings() }

    private var sourcePicker: some View {
        @Bindable var translation = model
        return Picker("原文语言", selection: $translation.source) {
            Text("自动检测").tag(Optional<Language>.none)
            ForEach(Language.allCases, id: \.self) { language in
                Text(language.displayName).tag(Optional(language))
                    .disabled(!supports(language, asSource: true))
                    .help(supports(language, asSource: true) ? language.displayName : "当前服务不支持此原文语言")
            }
        }.labelsHidden().accessibilityLabel("原文语言")
    }

    private var targetPicker: some View {
        @Bindable var translation = model
        return Picker("译文语言", selection: $translation.target) {
            ForEach(Language.allCases, id: \.self) { language in
                Text(language.displayName).tag(language)
                    .disabled(!supports(language, asSource: false))
                    .help(supports(language, asSource: false) ? language.displayName : "当前服务不支持此译文语言")
            }
        }.labelsHidden().accessibilityLabel("译文语言")
    }

    private func textPanel(title: String, content: String, placeholder: String, isResult: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                if isResult { targetPicker.frame(maxWidth: 160) }
                else { sourcePicker.frame(maxWidth: 160) }
                Spacer(minLength: 0)
                if isResult {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).disabled(content.isEmpty)
                    .help("复制译文").accessibilityLabel("复制译文")
                }
            }.padding(.horizontal, 16).frame(height: 42)
            Divider()
            ScrollView {
                if content.isEmpty {
                    VStack(spacing: 12) {
                        if model.isTranslating && isResult { ProgressView().controlSize(.small) }
                        Image(systemName: isResult ? "character.bubble" : "text.alignleft")
                            .font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                        Text(placeholder).font(.system(size: 13)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, minHeight: 240).padding(24)
                } else {
                    Text(content).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(isResult ? "翻译结果" : "原文预览")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

}

/// Shared provider picker listing the five peer types and each configured custom instance.
@MainActor
struct TranslationServicePicker: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Picker("当前翻译服务", selection: selection) {
            ForEach(TranslationProviderID.allCases, id: \.rawValue) { provider in
                Text(provider.displayName).tag(provider.rawValue)
            }
            if !settings.customTranslationServices.isEmpty { Divider() }
            ForEach(settings.customTranslationServices) { configuration in
                Text(configuration.name).tag("instance.\(configuration.id.uuidString)")
            }
        }.accessibilityLabel("当前翻译服务")
    }

    private var selection: Binding<String> {
        Binding(get: {
            if settings.translationProvider == .custom,
               let id = settings.selectedCustomTranslationID,
               settings.customTranslationServices.contains(where: { $0.id == id }) {
                return "instance.\(id.uuidString)"
            }
            return settings.translationProvider.rawValue
        }, set: { value in
            if value.hasPrefix("instance."), let id = UUID(uuidString: String(value.dropFirst("instance.".count))) {
                settings.translationProvider = .custom
                settings.selectedCustomTranslationID = id
            } else if let provider = TranslationProviderID(rawValue: value) {
                settings.translationProvider = provider
                if provider == .custom { settings.selectedCustomTranslationID = nil }
            }
        })
    }
}
