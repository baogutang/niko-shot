// Separates active translation selection, provider setup and private unsaved credential drafts.
import AppKit
import Observation
import SwiftUI

/// Ephemeral editor state retained while the settings window stays open; never stores saved secrets.
@MainActor
@Observable
final class TranslationSettingsDrafts {
    var editingProvider: TranslationProviderID?
    var editingCustomID: UUID?
    var pendingCredentials: [String: String] = [:]
    var configuredAccounts: Set<String> = []
    var customDrafts: [UUID: CustomRESTConfiguration] = [:]
    var customHeaders: [UUID: String] = [:]

    /// Discards user-entered secret drafts when the hosting settings window closes.
    func clearSensitiveInputs() { pendingCredentials.removeAll() }
}

/// Five peer service choices with one readable configuration workspace and inline connection tests.
@MainActor
struct TranslationSettingsView: View {
    @Bindable private var settings: AppSettings
    @State private var drafts: TranslationSettingsDrafts
    @State private var configurationError: String?
    @State private var guideProvider: TranslationProviderID?

    /// Keeps service editing independent from the live provider selection.
    init(settings: AppSettings = .shared, drafts: TranslationSettingsDrafts = TranslationSettingsDrafts()) {
        self.settings = settings
        self._drafts = State(initialValue: drafts)
    }

    private var editingProvider: TranslationProviderID { drafts.editingProvider ?? settings.translationProvider }
    private var editingCustom: CustomRESTConfiguration? {
        settings.customTranslationServices.first { $0.id == drafts.editingCustomID }
    }
    private var isEditingCurrent: Bool {
        guard settings.translationProvider == editingProvider else { return false }
        return editingProvider != .custom || (editingCustom != nil && settings.selectedCustomTranslationID == drafts.editingCustomID)
    }
    private var currentName: String {
        if settings.translationProvider == .custom {
            return settings.customTranslationServices.first { $0.id == settings.selectedCustomTranslationID }?.name ?? "自定义 REST · 未选择实例"
        }
        return settings.translationProvider.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("翻译服务").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { guideProvider = editingProvider } label: {
                    Label("申请与接入指南", systemImage: "book.closed")
                }.accessibilityLabel("查看\(editingProvider.displayName)的官方申请与接入指南")
            }
            NikoPanel {
                HStack(spacing: 12) {
                    Text("当前使用").font(.callout).foregroundStyle(.secondary)
                    TranslationServicePicker(settings: settings)
                        .labelsHidden().frame(maxWidth: 235)
                        .accessibilityLabel("当前使用的翻译服务：\(currentName)")
                    Spacer(minLength: 12)
                    Divider()
                        .frame(height: 22)
                    Toggle("自动翻译", isOn: $settings.automaticTranslation)
                        .toggleStyle(.switch).controlSize(.small).fixedSize()
                        .accessibilityLabel("文字识别完成后自动翻译")
                        .help("OCR 完成后自动使用当前服务翻译")
                }.frame(minHeight: 32)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(TranslationProviderID.allCases) { provider in providerCard(provider) }
            }
            configurationWorkspace
            if let configurationError {
                Label(configurationError, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onAppear {
            if drafts.editingProvider == nil { drafts.editingProvider = settings.translationProvider }
            if drafts.editingCustomID == nil {
                drafts.editingCustomID = settings.selectedCustomTranslationID ?? settings.customTranslationServices.first?.id
            }
            refreshCredentialStatus()
        }
        .sheet(item: $guideProvider) { provider in ProviderSetupGuideView(provider: provider) }
    }

    private func providerCard(_ provider: TranslationProviderID) -> some View {
        let isEditing = provider == editingProvider
        let isCurrent = provider == settings.translationProvider
        return Button { drafts.editingProvider = provider } label: {
            VStack(spacing: 6) {
                Image(systemName: provider == .custom ? "slider.horizontal.3" : "globe")
                    .font(.system(size: 22, weight: .medium)).frame(width: 24, height: 24)
                    .foregroundStyle(isEditing ? Color.accentColor : .secondary)
                Text(provider.displayName).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.9)
                Text(shortProduct(provider)).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.9)
                Text(isCurrent ? "当前使用" : isConfigured(provider) ? "已配置" : "待配置")
                    .font(.caption).foregroundStyle(isCurrent ? Color.accentColor : isConfigured(provider) ? .green : .secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 104)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(isEditing ? Color.accentColor.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isEditing ? Color.accentColor.opacity(0.55) : NikoTheme.separator.opacity(0.25), lineWidth: 0.5)
            }
        }
        .buttonStyle(NikoActionButtonStyle())
        .help("\(provider.displayName)：\(descriptor(provider))。点击切换配置工作区。")
        .accessibilityLabel("配置\(provider.displayName)，\(descriptor(provider))\(isCurrent ? "，当前使用" : "")\(isEditing ? "，正在配置" : "")")
        .accessibilityAddTraits(isEditing ? .isSelected : [])
    }

    private func shortProduct(_ provider: TranslationProviderID) -> String {
        switch provider {
        case .baidu: "通用翻译"
        case .google: "Basic v2"
        case .youdao: "文本翻译"
        case .deepl: "API"
        case .custom: "通用 REST"
        }
    }

    private func isConfigured(_ provider: TranslationProviderID) -> Bool {
        if provider == .custom {
            return settings.customTranslationServices.contains {
                !$0.requiresAPIKey || drafts.configuredAccounts.contains($0.keyAccount)
            }
        }
        return CredentialField.fields(for: provider).allSatisfy { drafts.configuredAccounts.contains($0.account) }
    }

    @ViewBuilder private var configurationWorkspace: some View {
        NikoPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("正在配置 · \(editingProvider.displayName)").font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text(isEditingCurrent ? "此服务正用于翻译" : "配置完成后，可将此服务设为当前使用")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(isEditingCurrent ? "当前使用" : "设为当前服务") { useEditingService() }
                        .disabled(isEditingCurrent || (editingProvider == .custom && editingCustom == nil))
                        .accessibilityLabel("将\(editingCustom?.name ?? editingProvider.displayName)设为当前翻译服务")
                }
                Divider()
                if editingProvider == .custom {
                    customWorkspace
                } else {
                    ProviderCredentialEditor(provider: editingProvider,
                                             fields: CredentialField.fields(for: editingProvider), drafts: drafts)
                        .id(editingProvider.rawValue)
                }
            }
        }
    }

    private var customWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("从预设开始，或创建自己的 REST 服务。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(CustomRESTConfiguration.presets) { preset in
                        Button(preset.name) { add(preset) }
                            .accessibilityLabel("创建\(preset.name)翻译服务预设")
                    }
                    Button("新建通用服务", systemImage: "plus") {
                        add(CustomRESTConfiguration(name: "自定义服务 \(settings.customTranslationServices.count + 1)",
                                                    urlTemplate: "https://",
                                                    headers: ["Authorization": "Bearer $KEY"],
                                                    bodyTemplate: "{\"q\":\"$TEXT\",\"source\":\"$SOURCE\",\"target\":\"$TARGET\"}",
                                                    responsePath: "data.translation"))
                    }.accessibilityLabel("创建通用 REST 翻译服务")
                }
            }
            if settings.customTranslationServices.isEmpty {
                Label("尚未添加自定义服务", systemImage: "plus.square.dashed")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                HStack {
                    Text("配置实例").font(.subheadline.weight(.medium))
                    Spacer()
                    Picker("配置实例", selection: $drafts.editingCustomID) {
                        Text("选择一个实例").tag(Optional<UUID>.none)
                        ForEach(settings.customTranslationServices) { configuration in
                            Text(configuration.name).tag(Optional(configuration.id))
                        }
                    }.labelsHidden().frame(maxWidth: 280)
                        .accessibilityLabel("正在编辑的自定义服务实例，不改变当前翻译服务")
                }.frame(minHeight: 40)
                ForEach($settings.customTranslationServices) { $configuration in
                    if configuration.id == drafts.editingCustomID {
                        CustomTranslationCard(configuration: $configuration, drafts: drafts) { remove(configuration) }
                            .id(configuration.id)
                    }
                }
            }
        }
    }

    private func descriptor(_ provider: TranslationProviderID) -> String {
        switch provider {
        case .custom:
            let count = settings.customTranslationServices.count
            return count == 0 ? "通用 REST · 可创建彩云和 LibreTranslate 预设" : "通用 REST · \(count) 个配置实例"
        default:
            let ready = CredentialField.fields(for: provider).allSatisfy { drafts.configuredAccounts.contains($0.account) }
            let kind: String
            switch provider {
            case .baidu: kind = "通用文本翻译 API"
            case .google: kind = "Cloud Translation · Basic v2"
            case .youdao: kind = "智云文本翻译 API"
            case .deepl: kind = "DeepL API"
            case .custom: kind = "通用 REST"
            }
            return kind + " · " + (ready ? "已配置" : "待配置")
        }
    }

    private func useEditingService() {
        if editingProvider == .custom {
            guard let custom = editingCustom else { return }
            settings.translationProvider = .custom
            settings.selectedCustomTranslationID = custom.id
        } else {
            settings.translationProvider = editingProvider
        }
    }

    private func add(_ preset: CustomRESTConfiguration) {
        var configuration = preset
        configuration.id = UUID()
        settings.customTranslationServices.append(configuration)
        drafts.editingCustomID = configuration.id
        configurationError = nil
    }

    private func remove(_ configuration: CustomRESTConfiguration) {
        do {
            try KeychainStore().set("", account: configuration.keyAccount)
            settings.customTranslationServices.removeAll { $0.id == configuration.id }
            if settings.selectedCustomTranslationID == configuration.id { settings.selectedCustomTranslationID = nil }
            if drafts.editingCustomID == configuration.id { drafts.editingCustomID = settings.customTranslationServices.first?.id }
            drafts.pendingCredentials[configuration.keyAccount] = nil
            drafts.configuredAccounts.remove(configuration.keyAccount)
            drafts.customDrafts[configuration.id] = nil
            drafts.customHeaders[configuration.id] = nil
            configurationError = nil
            Task { await TranslationRouter.shared.invalidateCache() }
        } catch {
            configurationError = "无法删除服务密钥：\(error.localizedDescription)"
        }
    }

    private func refreshCredentialStatus() {
        let keychain = KeychainStore()
        let accounts = TranslationProviderID.allCases.flatMap(CredentialField.fields).map(\.account)
            + settings.customTranslationServices.map(\.keyAccount)
        drafts.configuredAccounts = Set(accounts.filter { !(keychain.get($0) ?? "").isEmpty })
    }
}

private struct CredentialField: Identifiable {
    let account: String
    let title: String
    var isSecret = true
    var id: String { account }

    static func fields(for provider: TranslationProviderID) -> [Self] {
        switch provider {
        case .baidu: [Self(account: "baidu.appid", title: "APP ID", isSecret: false), Self(account: "baidu.secret", title: "密钥")]
        case .google: [Self(account: "google.key", title: "API Key")]
        case .youdao: [Self(account: "youdao.appKey", title: "应用 ID", isSecret: false), Self(account: "youdao.appSecret", title: "应用密钥")]
        case .deepl: [Self(account: "deepl.key", title: "Auth Key")]
        case .custom: []
        }
    }
}

@MainActor
private struct ProviderCredentialEditor: View {
    let provider: TranslationProviderID
    let fields: [CredentialField]
    @Bindable var drafts: TranslationSettingsDrafts
    var custom: CustomRESTConfiguration?
    var allowsTesting = true
    @State private var credentialFeedback: String?
    @State private var credentialError: String?
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?
    @State private var testGeneration = UUID()

    private var requiresCredentials: Bool { provider != .custom || custom?.requiresAPIKey != false }
    private var isReady: Bool { !requiresCredentials || (!fields.isEmpty && fields.allSatisfy { drafts.configuredAccounts.contains($0.account) }) }
    private var hasPending: Bool { fields.contains { !(drafts.pendingCredentials[$0.account] ?? "").isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isReady ? Color.green : .secondary).accessibilityHidden(true)
                Text(!requiresCredentials ? "此模板无需 API Key" : isReady ? "凭据已配置" : "填写凭据以连接服务")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if hasPending { Text("有待保存的输入").font(.caption).foregroundStyle(.orange) }
            }
            if provider == .google {
                Text("此处使用 Google Cloud Translation Basic（v2）API Key。申请和启用 API 的步骤见接入指南。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if provider == .deepl {
                Text("请使用 DeepL API 凭据。现有 :fx 密钥使用 Free API 端点，申请方案与翻译器订阅区别见接入指南。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !requiresCredentials {
                Text("URL、Header 与 Body 均未引用 $KEY，可直接测试；如需认证，可编辑模板并在下方保存密钥。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(fields) { field in
                HStack(spacing: 10) {
                    Text(field.title + (!requiresCredentials ? "（可选）" : ""))
                        .font(.subheadline.weight(.medium))
                        .frame(width: requiresCredentials ? 84 : 100, alignment: .leading)
                    HStack(spacing: 8) {
                        credentialInput(field)
                        Button { copy(field) } label: {
                            Image(systemName: "doc.on.doc").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless).help("复制已保存的\(field.title)")
                        .disabled(!drafts.configuredAccounts.contains(field.account))
                        .accessibilityLabel("复制\(provider.displayName)已保存的\(field.title)")
                        Button(role: .destructive) { remove(field) } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless).help("移除已保存的\(field.title)")
                        .disabled(!drafts.configuredAccounts.contains(field.account))
                        .accessibilityLabel("移除\(provider.displayName)已保存的\(field.title)")
                    }
                }
            }
            Text("凭据仅保存到系统钥匙串。•••• 表示已有值；留空会保留，点击移除才删除。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("保存凭据") { save() }.buttonStyle(.borderedProminent).disabled(!hasPending)
                    .accessibilityLabel("将\(provider.displayName)凭据保存到钥匙串")
                Button("测试连接") { test() }
                    .disabled(!isReady || hasPending || isTesting || !allowsTesting)
                    .accessibilityLabel("测试\(provider.displayName)连接，将 Hello, world! 翻译为简体中文")
                if isTesting {
                    ProgressView().controlSize(.small).accessibilityLabel("正在测试连接")
                    Button("取消") { cancelTest() }.accessibilityLabel("取消连接测试")
                }
                Spacer(minLength: 0)
            }.frame(minHeight: 36)
            if hasPending {
                Text("输入尚未保存。保存后测试连接；切换配置时会保留这份输入。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = credentialError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if let feedback = credentialFeedback {
                Label(feedback, systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let testResult {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hello, world! → 简体中文").font(.caption).foregroundStyle(.secondary)
                    Label(testResult, systemImage: testSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.callout).foregroundStyle(testSucceeded ? Color.green : .red).textSelection(.enabled)
                }
            }
        }
        .onChange(of: custom) { _, _ in cancelTest(); testResult = nil }
        .onChange(of: allowsTesting) { _, allowed in if !allowed { cancelTest(); testResult = nil } }
        .onDisappear { cancelTest() }
    }

    @ViewBuilder private func credentialInput(_ field: CredentialField) -> some View {
        let prompt = Text(drafts.configuredAccounts.contains(field.account) ? "••••" : "输入\(field.title)")
        if field.isSecret {
            SecureField(field.title, text: pendingBinding(for: field.account), prompt: prompt)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(provider.displayName)\(field.title)，留空保留现有值")
        } else {
            TextField(field.title, text: pendingBinding(for: field.account), prompt: prompt)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(provider.displayName)\(field.title)，留空保留现有值")
        }
    }

    private func pendingBinding(for account: String) -> Binding<String> {
        Binding(get: { drafts.pendingCredentials[account] ?? "" }, set: {
            drafts.pendingCredentials[account] = $0
            cancelTest(); testResult = nil; credentialFeedback = nil; credentialError = nil
        })
    }

    private func refreshStatus() {
        let keychain = KeychainStore()
        for field in fields {
            if !(keychain.get(field.account) ?? "").isEmpty { drafts.configuredAccounts.insert(field.account) }
            else { drafts.configuredAccounts.remove(field.account) }
        }
    }

    private func save() {
        cancelTest(); credentialError = nil; credentialFeedback = nil; testResult = nil
        var savedCount = 0
        do {
            let keychain = KeychainStore()
            for field in fields {
                guard let raw = drafts.pendingCredentials[field.account], !raw.isEmpty else { continue }
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                try keychain.set(value, account: field.account)
                drafts.pendingCredentials[field.account] = nil
                savedCount += 1
            }
            if savedCount > 0 { credentialFeedback = "已将 \(savedCount) 项凭据保存到钥匙串。" }
            else { credentialError = "请输入有效凭据；空字段会保留原值。" }
        } catch {
            credentialError = "无法保存凭据：\(error.localizedDescription)"
        }
        if savedCount > 0 { Task { await TranslationRouter.shared.invalidateCache() } }
        refreshStatus()
    }

    private func copy(_ field: CredentialField) {
        guard let value = KeychainStore().get(field.account), !value.isEmpty else { refreshStatus(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        credentialFeedback = "已复制\(field.title)至剪贴板。"; credentialError = nil
    }

    private func remove(_ field: CredentialField) {
        cancelTest(); testResult = nil
        do {
            try KeychainStore().set("", account: field.account)
            drafts.pendingCredentials[field.account] = nil
            credentialFeedback = "已移除\(field.title)。"; credentialError = nil
            Task { await TranslationRouter.shared.invalidateCache() }
        } catch { credentialError = "无法移除凭据：\(error.localizedDescription)" }
        refreshStatus()
    }

    private func test() {
        cancelTest()
        let generation = UUID(); testGeneration = generation
        isTesting = true; testResult = nil
        testTask = Task {
            do {
                let result = try await TranslationRouter.shared.translate(
                    TranslationRequest(text: "Hello, world!", source: .english, target: .simplifiedChinese),
                    provider: provider, custom: custom, useCache: false)
                try Task.checkCancellation()
                guard testGeneration == generation else { return }
                testResult = "连接成功：\(result.text)"; testSucceeded = true
            } catch {
                guard testGeneration == generation else { return }
                if error is CancellationError { isTesting = false; testTask = nil; return }
                if case TranslationError.cancelled = error { isTesting = false; testTask = nil; return }
                testResult = TranslationViewModel.describe(error, provider: provider); testSucceeded = false
            }
            guard testGeneration == generation else { return }
            isTesting = false; testTask = nil
        }
    }

    private func cancelTest() {
        testGeneration = UUID(); testTask?.cancel(); testTask = nil; isTesting = false
    }
}

@MainActor
private struct CustomTranslationCard: View {
    @Binding var configuration: CustomRESTConfiguration
    @Bindable var drafts: TranslationSettingsDrafts
    let onRemove: () -> Void
    @State private var feedback: String?
    @State private var errorMessage: String?

    private var draft: CustomRESTConfiguration { drafts.customDrafts[configuration.id] ?? configuration }
    private var headersText: String { drafts.customHeaders[configuration.id] ?? Self.headersJSON(configuration.headers) }
    private var hasUnsavedChanges: Bool {
        Self.configurationData(draft) != Self.configurationData(configuration) || headersText != Self.headersJSON(configuration.headers)
    }
    private var draftBinding: Binding<CustomRESTConfiguration> {
        Binding(get: { draft }, set: { drafts.customDrafts[configuration.id] = $0; feedback = nil; errorMessage = nil })
    }
    private var headersBinding: Binding<String> {
        Binding(get: { headersText }, set: { drafts.customHeaders[configuration.id] = $0; feedback = nil; errorMessage = nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            HStack {
                Text(configuration.name).font(.subheadline.weight(.semibold))
                if hasUnsavedChanges { Text("未保存").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("删除服务", systemImage: "trash", role: .destructive, action: onRemove)
                    .accessibilityLabel("删除\(configuration.name)及其密钥")
            }.frame(minHeight: 32)
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("服务名称")
                TextField("服务名称", text: draftBinding.name).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("自定义服务名称")
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("方法")
                    Picker("请求方法", selection: draftBinding.method) {
                        ForEach(["POST", "GET", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().accessibilityLabel("REST 请求方法")
                }.frame(width: 110)
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("URL 模板")
                    TextField("https://…", text: draftBinding.urlTemplate).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("REST URL 模板")
                }
            }
            templateEditor("Header 模板（JSON）", text: headersBinding, height: 86)
            HStack {
                fieldLabel("Body 格式")
                Spacer()
                Picker("Body 格式", selection: draftBinding.bodyFormat) {
                    ForEach(CustomRESTConfiguration.BodyFormat.allCases, id: \.self) { format in Text(format.displayName).tag(format) }
                }.labelsHidden().frame(width: 160).accessibilityLabel("REST 请求 Body 格式")
            }
            templateEditor("Body 模板", text: draftBinding.bodyTemplate, height: 112)
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("译文提取路径")
                TextField("例如 translations.0.text", text: draftBinding.responsePath)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("响应 JSON 中的译文路径")
            }
            HStack {
                fieldLabel("语言映射")
                Spacer()
                Picker("语言映射", selection: draftBinding.languageStyle) {
                    Text("通用 · BCP-47").tag(CustomRESTConfiguration.LanguageStyle.generic)
                    Text("彩云小译").tag(CustomRESTConfiguration.LanguageStyle.caiyun)
                    Text("LibreTranslate").tag(CustomRESTConfiguration.LanguageStyle.libreTranslate)
                }.labelsHidden().frame(width: 210).accessibilityLabel("自定义翻译服务的语言代码映射")
            }
            Text("模板可使用 $TEXT、$SOURCE、$TARGET 和 $KEY。响应路径使用点号与数组下标；彩云和 LibreTranslate 映射保留各自中文语言码。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("保存服务配置", systemImage: "checkmark") { saveConfiguration() }
                    .disabled(!hasUnsavedChanges).accessibilityLabel("保存\(configuration.name)的 REST 配置")
                if hasUnsavedChanges { Text("保存配置后可测试连接").font(.caption).foregroundStyle(.orange) }
            }.frame(minHeight: 32)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if let feedback {
                Label(feedback, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("认证与连接测试").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ProviderCredentialEditor(provider: .custom,
                                     fields: [CredentialField(account: configuration.keyAccount, title: "API Key")],
                                     drafts: drafts, custom: configuration, allowsTesting: !hasUnsavedChanges)
        }
    }

    private func fieldLabel(_ title: String) -> some View { Text(title).font(.subheadline.weight(.medium)) }

    private func templateEditor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(title)
            TextEditor(text: text).font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden).padding(6).frame(height: height)
                .background(NikoTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(NikoTheme.separator.opacity(0.5), lineWidth: 0.5) }
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
            var saved = draft; saved.headers = headers
            saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !saved.name.isEmpty else { throw ConfigurationInputError(message: "请填写服务名称。") }
            configuration = saved
            drafts.customDrafts[configuration.id] = nil; drafts.customHeaders[configuration.id] = nil
            errorMessage = nil; feedback = "服务配置已保存。"
            Task { await TranslationRouter.shared.invalidateCache() }
        } catch { errorMessage = "配置未保存：\(error.localizedDescription)"; feedback = nil }
    }

    private static func headersJSON(_ headers: [String: String]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(headers) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func configurationData(_ configuration: CustomRESTConfiguration) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(configuration)
    }
}

private struct ConfigurationInputError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
