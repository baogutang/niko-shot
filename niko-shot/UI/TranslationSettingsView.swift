// Configures five peer REST translators with masked Keychain credentials and inline connection tests.
import AppKit
import SwiftUI

/// Native provider cards suitable for embedding in the OCR settings form.
@MainActor
struct TranslationSettingsView: View {
    @Bindable private var settings: AppSettings
    @State private var configurationError: String?

    /// Uses persisted preferences; credential values are never bound to this settings object.
    init(settings: AppSettings = .shared) { self.settings = settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TranslationServicePicker(settings: settings)
            Toggle("OCR 完成后自动翻译", isOn: $settings.automaticTranslation)
                .toggleStyle(.checkbox).accessibilityLabel("文字识别完成后自动翻译")
            Text("各服务独立配置，翻译仅使用当前选择的服务。密钥保存到系统钥匙串。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach([TranslationProviderID.baidu, .google, .youdao, .deepl], id: \.rawValue) { provider in
                GroupBox {
                    ProviderCredentialEditor(provider: provider, fields: CredentialField.fields(for: provider))
                        .padding(8)
                } label: {
                    Label(provider.displayName, systemImage: "globe")
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Text("使用 $KEY、$TEXT、$SOURCE 和 $TARGET 配置 REST 请求。密钥单独保存到钥匙串。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(CustomRESTConfiguration.presets) { preset in
                            Button("添加\(preset.name)") { add(preset) }
                                .accessibilityLabel("创建\(preset.name)翻译服务预设")
                        }
                        Button("添加通用服务", systemImage: "plus") {
                            add(CustomRESTConfiguration(name: "自定义服务 \(settings.customTranslationServices.count + 1)",
                                                        urlTemplate: "https://",
                                                        headers: ["Authorization": "Bearer $KEY"],
                                                        bodyTemplate: "{\"q\":\"$TEXT\",\"source\":\"$SOURCE\",\"target\":\"$TARGET\"}",
                                                        responsePath: "data.translation"))
                        }.accessibilityLabel("创建通用 REST 翻译服务")
                    }
                    if let configurationError {
                        Label(configurationError, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if settings.customTranslationServices.isEmpty {
                        Text("尚未添加服务。选择预设或创建一个通用 REST 配置。")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach($settings.customTranslationServices) { $configuration in
                        Divider()
                        CustomTranslationCard(configuration: $configuration) { remove(configuration) }
                    }
                }.padding(8)
            } label: {
                Label(TranslationProviderID.custom.displayName, systemImage: "slider.horizontal.3")
            }
        }
    }

    private func add(_ preset: CustomRESTConfiguration) {
        var configuration = preset
        configuration.id = UUID()
        settings.customTranslationServices.append(configuration)
        settings.translationProvider = .custom
        settings.selectedCustomTranslationID = configuration.id
        configurationError = nil
    }

    private func remove(_ configuration: CustomRESTConfiguration) {
        do {
            try KeychainStore().set("", account: configuration.keyAccount)
            settings.customTranslationServices.removeAll { $0.id == configuration.id }
            if settings.selectedCustomTranslationID == configuration.id { settings.selectedCustomTranslationID = nil }
            configurationError = nil
            Task { await TranslationRouter.shared.invalidateCache() }
        } catch {
            configurationError = "无法删除服务密钥：\(error.localizedDescription)"
        }
    }
}

private struct CredentialField: Identifiable {
    let account: String
    let title: String
    var id: String { account }

    static func fields(for provider: TranslationProviderID) -> [Self] {
        switch provider {
        case .baidu: [Self(account: "baidu.appid", title: "应用 ID"), Self(account: "baidu.secret", title: "密钥")]
        case .google: [Self(account: "google.key", title: "API Key")]
        case .youdao: [Self(account: "youdao.appKey", title: "应用 ID"), Self(account: "youdao.appSecret", title: "应用密钥")]
        case .deepl: [Self(account: "deepl.key", title: "Auth Key")]
        case .custom: []
        }
    }
}

@MainActor
private struct ProviderCredentialEditor: View {
    let provider: TranslationProviderID
    let fields: [CredentialField]
    var custom: CustomRESTConfiguration?
    var allowsTesting = true
    @State private var pending: [String: String] = [:]
    @State private var configured: Set<String> = []
    @State private var credentialFeedback: String?
    @State private var credentialError: String?
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?
    @State private var testGeneration = UUID()

    private var isReady: Bool { !fields.isEmpty && fields.allSatisfy { configured.contains($0.account) } }
    private var hasPending: Bool { fields.contains { !(pending[$0.account] ?? "").isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(isReady ? Color.green : Color.secondary).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(isReady ? "已配置" : "未配置").font(.caption).foregroundStyle(.secondary)
                if provider == .deepl {
                    Text("密钥以 :fx 结尾时使用 Free API").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityElement(children: .combine)
            ForEach(fields) { field in
                HStack(spacing: 8) {
                    SecureField(field.title, text: pendingBinding(for: field.account),
                                prompt: Text(configured.contains(field.account) ? "••••" : "输入\(field.title)"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(provider.displayName)\(field.title)，留空保留现有值")
                    Button("复制", systemImage: "doc.on.doc") { copy(field) }
                        .labelStyle(.iconOnly).help("复制已保存的\(field.title)")
                        .disabled(!configured.contains(field.account))
                        .accessibilityLabel("复制\(provider.displayName)已保存的\(field.title)")
                    Button("移除", systemImage: "trash", role: .destructive) { remove(field) }
                        .labelStyle(.iconOnly).help("移除已保存的\(field.title)")
                        .disabled(!configured.contains(field.account))
                        .accessibilityLabel("移除\(provider.displayName)已保存的\(field.title)")
                }
            }
            HStack(spacing: 10) {
                Button("保存凭据") { save() }.disabled(!hasPending)
                    .accessibilityLabel("将\(provider.displayName)凭据保存到钥匙串")
                Button("测试连接") { test() }
                    .disabled(!isReady || hasPending || isTesting || !allowsTesting)
                    .accessibilityLabel("测试\(provider.displayName)连接，将 Hello, world! 翻译为简体中文")
                if isTesting {
                    ProgressView().controlSize(.small)
                    Button("取消") { cancelTest() }.accessibilityLabel("取消连接测试")
                }
                Spacer()
            }
            if hasPending {
                Text("保存后测试连接；空字段保留现有凭据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = credentialError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if let feedback = credentialFeedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
            }
            if let testResult {
                Label(testResult, systemImage: testSucceeded ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.callout).foregroundStyle(testSucceeded ? Color.green : Color.red)
                    .textSelection(.enabled)
            }
        }
        .task { refreshStatus() }
        .onChange(of: custom) { _, _ in cancelTest(); testResult = nil }
        .onChange(of: allowsTesting) { _, allowed in
            if !allowed { cancelTest(); testResult = nil }
        }
        .onDisappear { cancelTest(); pending.removeAll() }
    }

    private func pendingBinding(for account: String) -> Binding<String> {
        Binding(get: { pending[account] ?? "" }, set: {
            pending[account] = $0
            cancelTest()
            testResult = nil
        })
    }

    private func refreshStatus() {
        let keychain = KeychainStore()
        configured = Set(fields.compactMap { field in
            guard let value = keychain.get(field.account), !value.isEmpty else { return nil }
            return field.account
        })
    }

    private func save() {
        cancelTest()
        credentialError = nil
        credentialFeedback = nil
        testResult = nil
        do {
            let keychain = KeychainStore()
            for field in fields {
                guard let raw = pending[field.account], !raw.isEmpty else { continue }
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                try keychain.set(value, account: field.account)
                pending[field.account] = ""
            }
            credentialFeedback = "凭据已保存到钥匙串。"
            Task { await TranslationRouter.shared.invalidateCache() }
        } catch {
            credentialError = "无法保存凭据：\(error.localizedDescription)"
        }
        refreshStatus()
    }

    private func copy(_ field: CredentialField) {
        guard let value = KeychainStore().get(field.account), !value.isEmpty else { refreshStatus(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        credentialFeedback = "已复制\(field.title)至剪贴板。"
        credentialError = nil
    }

    private func remove(_ field: CredentialField) {
        cancelTest()
        testResult = nil
        do {
            try KeychainStore().set("", account: field.account)
            pending[field.account] = ""
            credentialFeedback = "已移除\(field.title)。"
            credentialError = nil
            Task { await TranslationRouter.shared.invalidateCache() }
        } catch {
            credentialError = "无法移除凭据：\(error.localizedDescription)"
        }
        refreshStatus()
    }

    private func test() {
        cancelTest()
        let generation = UUID()
        testGeneration = generation
        isTesting = true
        testResult = nil
        testTask = Task {
            do {
                let result = try await TranslationRouter.shared.translate(TranslationRequest(text: "Hello, world!", source: .english, target: .simplifiedChinese),
                                                                           provider: provider, custom: custom, useCache: false)
                try Task.checkCancellation()
                guard testGeneration == generation else { return }
                testResult = "连接成功：\(result.text)"
                testSucceeded = true
            } catch {
                guard testGeneration == generation else { return }
                if error is CancellationError { isTesting = false; testTask = nil; return }
                if case TranslationError.cancelled = error { isTesting = false; testTask = nil; return }
                testResult = TranslationViewModel.describe(error, provider: provider)
                testSucceeded = false
            }
            guard testGeneration == generation else { return }
            isTesting = false
            testTask = nil
        }
    }

    private func cancelTest() {
        testGeneration = UUID()
        testTask?.cancel()
        testTask = nil
        isTesting = false
    }
}

@MainActor
private struct CustomTranslationCard: View {
    @Binding var configuration: CustomRESTConfiguration
    let onRemove: () -> Void
    @State private var draft: CustomRESTConfiguration
    @State private var headersText: String
    @State private var feedback: String?
    @State private var errorMessage: String?

    init(configuration: Binding<CustomRESTConfiguration>, onRemove: @escaping () -> Void) {
        self._configuration = configuration
        self.onRemove = onRemove
        self._draft = State(initialValue: configuration.wrappedValue)
        self._headersText = State(initialValue: Self.headersJSON(configuration.wrappedValue.headers))
    }

    private var hasUnsavedChanges: Bool {
        Self.configurationData(draft) != Self.configurationData(configuration) || headersText != Self.headersJSON(configuration.headers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(configuration.name).font(.headline)
                Spacer()
                Button("删除服务", systemImage: "trash", role: .destructive, action: onRemove)
                    .accessibilityLabel("删除\(configuration.name)及其密钥")
            }
            TextField("服务名称", text: $draft.name).textFieldStyle(.roundedBorder).accessibilityLabel("自定义服务名称")
            HStack(spacing: 8) {
                Picker("请求方法", selection: $draft.method) {
                    ForEach(["POST", "GET", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 125).accessibilityLabel("REST 请求方法")
                TextField("URL 模板", text: $draft.urlTemplate).textFieldStyle(.roundedBorder).accessibilityLabel("REST URL 模板")
            }
            templateEditor("Header 模板（JSON）", text: $headersText, height: 72)
            Picker("Body 格式", selection: $draft.bodyFormat) {
                ForEach(CustomRESTConfiguration.BodyFormat.allCases, id: \.self) { format in Text(format.displayName).tag(format) }
            }.accessibilityLabel("REST 请求 Body 格式")
            templateEditor("Body 模板", text: $draft.bodyTemplate, height: 96)
            TextField("译文提取路径", text: $draft.responsePath,
                      prompt: Text("例如 translations.0.text"))
                .textFieldStyle(.roundedBorder).accessibilityLabel("响应 JSON 中的译文路径")
            Text("模板可使用 $TEXT、$SOURCE、$TARGET 和 $KEY；响应路径使用点号与数组下标。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("保存服务配置", systemImage: "checkmark") { saveConfiguration() }
                    .accessibilityLabel("保存\(configuration.name)的 REST 配置")
                if hasUnsavedChanges { Text("保存配置后测试连接").font(.caption).foregroundStyle(.secondary) }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
            } else if let feedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
            }
            ProviderCredentialEditor(provider: .custom,
                                     fields: [CredentialField(account: configuration.keyAccount, title: "API Key")],
                                     custom: configuration, allowsTesting: !hasUnsavedChanges)
        }
    }

    private func templateEditor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text).font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden).padding(4).frame(height: height)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1) }
                .accessibilityLabel(title)
        }
    }

    private func saveConfiguration() {
        do {
            guard let components = URLComponents(string: draft.urlTemplate),
                  let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  components.host?.isEmpty == false else {
                throw ConfigurationInputError(message: "请填写有效的 HTTP 或 HTTPS URL 模板。")
            }
            let headers = try JSONDecoder().decode([String: String].self, from: Data(headersText.utf8))
            if draft.bodyFormat == .json, !draft.bodyTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try JSONSerialization.jsonObject(with: Data(draft.bodyTemplate.utf8), options: [.fragmentsAllowed])
            }
            var saved = draft
            saved.headers = headers
            saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !saved.name.isEmpty else { throw ConfigurationInputError(message: "请填写服务名称。") }
            configuration = saved
            draft = saved
            headersText = Self.headersJSON(headers)
            errorMessage = nil
            feedback = "服务配置已保存。"
            Task { await TranslationRouter.shared.invalidateCache() }
        } catch {
            errorMessage = "配置未保存：\(error.localizedDescription)"
            feedback = nil
        }
    }

    private static func headersJSON(_ headers: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(headers) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func configurationData(_ configuration: CustomRESTConfiguration) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(configuration)
    }
}

private struct ConfigurationInputError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
