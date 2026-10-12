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
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                NikoSymbolBadge(symbol: "character.bubble", size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("翻译").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text("原文与译文并排，方便核对。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("申请与接入指南", systemImage: "questionmark.circle") { showsSetupGuide = true }
                    .buttonStyle(.borderless).font(.callout).help("查看当前服务的官方申请步骤和链接")
            }
            NikoPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        TranslationServicePicker(settings: settings)
                        Button("配置服务", systemImage: "slider.horizontal.3", action: openTranslationSettings)
                            .help("在设置中管理翻译凭据和自定义服务")
                    }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("原文语言").font(.caption).foregroundStyle(.secondary)
                            Picker("原文语言", selection: $model.source) {
                                Text("自动检测").tag(Optional<Language>.none)
                                ForEach(Language.allCases, id: \.self) { language in
                                    Text(language.displayName).tag(Optional(language))
                                        .disabled(!supports(language, asSource: true))
                                        .help(supports(language, asSource: true) ? language.displayName : "当前服务不支持此原文语言")
                                }
                            }.labelsHidden().accessibilityLabel("原文语言")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.top, 18).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("译文语言").font(.caption).foregroundStyle(.secondary)
                            Picker("译文语言", selection: $model.target) {
                                ForEach(Language.allCases, id: \.self) { language in
                                    Text(language.displayName).tag(language)
                                        .disabled(!supports(language, asSource: false))
                                        .help(supports(language, asSource: false) ? language.displayName : "当前服务不支持此译文语言")
                                }
                            }.labelsHidden().accessibilityLabel("译文语言")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                }
            }
            if let reason = model.unsupportedReason(settings: settings) {
                Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 12) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityLabel("翻译错误：\(error)")
                    Spacer(minLength: 0)
                    Button("查看配置", action: openTranslationSettings).buttonStyle(.borderless)
                }
            } else if let message = model.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                textPanel(title: "原文", content: text, placeholder: "勾选左侧文字区块，\n在这里核对原文。", symbol: "text.alignleft", isResult: false)
                textPanel(title: "译文", content: model.translatedText,
                          placeholder: model.isTranslating ? "正在翻译…" : "选择服务和目标语言，\n点击「翻译」开始。", symbol: "globe", isResult: true)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
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

    private func textPanel(title: String, content: String, placeholder: String, symbol: String, isResult: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol).font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                if isResult {
                    Button("复制", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                    }.buttonStyle(.borderless).font(.caption).disabled(content.isEmpty).accessibilityLabel("复制译文")
                } else {
                    Text("\(content.count) 字").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }.padding(14)
            Divider()
            ScrollView {
                if content.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                        Text(placeholder).font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                } else {
                    Text(content).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(isResult ? "翻译结果" : "原文预览")
            if isResult, let detected = model.detectedSource {
                Divider()
                Text("检测语言：\(detected.displayName)").font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NikoTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(NikoTheme.separator.opacity(0.35), lineWidth: 0.5) }
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
