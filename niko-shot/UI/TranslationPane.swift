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

    /// Shows a snapshot-aware translation pane sharing persisted provider preferences.
    init(text: String, isRecognizing: Bool, settings: AppSettings = .shared) {
        self.text = text
        self.isRecognizing = isRecognizing
        self.settings = settings
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            TranslationServicePicker(settings: settings)
            HStack(spacing: 10) {
                Picker("原文语言", selection: $model.source) {
                    Text("自动检测").tag(Optional<Language>.none)
                    ForEach(Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(Optional(language))
                            .disabled(!supports(language, asSource: true))
                            .help(supports(language, asSource: true) ? language.displayName : "当前服务不支持此原文语言")
                    }
                }.accessibilityLabel("原文语言")
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                Picker("译文语言", selection: $model.target) {
                    ForEach(Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                            .disabled(!supports(language, asSource: false))
                            .help(supports(language, asSource: false) ? language.displayName : "当前服务不支持此译文语言")
                    }
                }.accessibilityLabel("译文语言")
            }.labelsHidden()
            HStack(spacing: 12) {
                Toggle("OCR 完成后自动翻译", isOn: $settings.automaticTranslation)
                    .toggleStyle(.checkbox).font(.callout)
                    .accessibilityLabel("文字识别完成后自动翻译")
                Spacer()
                if model.isTranslating {
                    ProgressView().controlSize(.small)
                    Button("取消") { model.cancel() }.accessibilityLabel("取消当前翻译")
                } else {
                    Button("翻译", systemImage: "character.bubble") { model.translate(text: text, settings: settings) }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRecognizing || model.unsupportedReason(settings: settings) != nil)
                        .accessibilityLabel("使用当前服务翻译所选文字")
                }
            }
            if let reason = model.unsupportedReason(settings: settings) {
                Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityLabel("翻译错误：\(error)")
            } else if let message = model.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                textPanel(title: "原文", text: text, placeholder: "勾选左侧文字区块", symbol: "text.alignleft")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("译文", systemImage: "globe").font(.callout.weight(.semibold))
                        Spacer()
                        Button("复制", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.translatedText, forType: .string)
                        }
                        .buttonStyle(.borderless).font(.caption)
                        .disabled(model.translatedText.isEmpty)
                        .accessibilityLabel("复制译文")
                    }
                    ScrollView {
                        Text(model.translatedText.isEmpty ? (model.isTranslating ? "正在翻译…" : "译文将在这里显示") : model.translatedText)
                            .foregroundStyle(model.translatedText.isEmpty ? Color.secondary : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1) }
                    .accessibilityLabel("翻译结果")
                    if let detected = model.detectedSource {
                        Text("检测语言：\(detected.displayName)").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("当前服务不支持的语种已停用。密钥可在设置中配置。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
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

    private func textPanel(title: String, text: String, placeholder: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.callout.weight(.semibold))
            ScrollView {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1) }
            .accessibilityLabel("原文预览")
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
