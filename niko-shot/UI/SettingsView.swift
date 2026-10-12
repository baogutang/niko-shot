// Presents a compact native preference workspace and preserves local shortcut recording.
import AppKit
import Observation
import SwiftUI

/// Routes an existing or newly opened settings window to the translation workspace.
@MainActor
@Observable
public final class SettingsNavigation {
    /// Shared navigation intent consumed by the settings window.
    public static let shared = SettingsNavigation()
    /// Set to true to reveal OCR and translation without replacing the existing view.
    public var opensTranslation = false
    /// Creates an independent navigation state when needed by an embedding host.
    public init() {}
}

/// Native preference navigation with readable panels and inline shortcut feedback.
@MainActor
public struct SettingsView: View {
    @Bindable private var settings: AppSettings
    @Bindable private var hotkeys: HotkeyCenter
    @State private var section: SettingsSection? = .general
    @State private var presetName = "自定义"
    @State private var presetWidth = 800
    @State private var presetHeight = 600
    @State private var launchAtLogin = LaunchAtLogin()
    @State private var navigation = SettingsNavigation.shared
    @State private var translationDrafts = TranslationSettingsDrafts()
    @State private var showsTranslationSettings = true
    private let onShowWizard: () -> Void

    /// Shares live preferences and hotkeys; opening a guide keeps unsaved translation input.
    public init(settings: AppSettings = .shared, hotkeys: HotkeyCenter,
                onShowWizard: @escaping () -> Void = {}) {
        self.settings = settings
        self.hotkeys = hotkeys
        self.onShowWizard = onShowWizard
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                HStack(spacing: 10) {
                    NikoSymbolBadge(symbol: item.symbol, tint: item.tint, size: 27)
                    Text(item.title).font(.body)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 38)
                .tag(item)
                .accessibilityLabel(item.title)
            }
            .listStyle(.sidebar)
            .accessibilityLabel("设置分类")
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 6) {
                    Text("niko-shot").font(.caption.weight(.medium))
                    Spacer()
                    Text(version).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    NikoPageHeader(title: currentSection.title, subtitle: currentSection.subtitle,
                                   symbol: currentSection.symbol)
                    content
                }
                .frame(maxWidth: 650, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(NikoTheme.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 580)
        .onAppear { launchAtLogin.refresh(); consumeNavigation() }
        .onChange(of: navigation.opensTranslation) { _, requested in
            if requested { consumeNavigation() }
        }
        .onDisappear { translationDrafts.clearSensitiveInputs() }
    }

    private var currentSection: SettingsSection { section ?? .general }
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0" }

    @ViewBuilder private var content: some View {
        switch currentSection {
        case .general: generalContent
        case .hotkeys: hotkeyContent
        case .capture: captureContent
        case .annotation: annotationContent
        case .output: outputContent
        case .ocrTranslation: ocrContent
        case .recording: recordingContent
        case .history:
            SettingsGroup(title: "保留时间", caption: "历史记录可在历史窗口中搜索、拖出和手动删除。") {
                PreferenceRow(title: "截图历史") {
                    Picker("截图历史", selection: $settings.historyRetention) {
                        Text("直到手动删除").tag(0)
                        Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90)
                    }.labelsHidden().frame(width: 180).accessibilityLabel("历史保留时间")
                }
            }
        case .about: aboutContent
        }
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(title: "启动与外观") {
                PreferenceRow(title: "运行方式") { Text("菜单栏常驻").foregroundStyle(.secondary) }
                Divider()
                PreferenceRow(title: "外观") { Text("跟随系统").foregroundStyle(.secondary) }
                Divider()
                Toggle("登录时打开 niko-shot", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { enabled in Task { await launchAtLogin.setEnabled(enabled) } }
                ))
                .toggleStyle(.switch).frame(minHeight: 44).disabled(launchAtLogin.isUpdating)
                .accessibilityLabel("登录时自动打开 niko-shot")
                if launchAtLogin.isUpdating {
                    ProgressView("正在更新登录项…").controlSize(.small)
                        .accessibilityLabel("正在更新登录启动设置")
                }
                Label(launchAtLogin.statusDescription,
                      systemImage: launchAtLogin.requiresApproval ? "clock" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("登录启动状态：\(launchAtLogin.statusDescription)")
                if let error = launchAtLogin.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    Button("打开登录项设置") { launchAtLogin.openSettings() }
                        .accessibilityLabel("打开系统设置中的登录项")
                    Button("刷新状态") { launchAtLogin.refresh() }
                        .disabled(launchAtLogin.isUpdating).accessibilityLabel("刷新登录启动状态")
                }
            }
            SettingsGroup(title: "使用向导与权限",
                          caption: "截图与录屏需要屏幕录制权限。自动滚动使用辅助功能；手动滚动可直接使用。") {
                HStack {
                    Label("从第一张截图开始", systemImage: "sparkles")
                    Spacer()
                    Button("打开使用向导", action: onShowWizard)
                        .keyboardShortcut("h", modifiers: [.command, .shift])
                        .accessibilityLabel("打开三步使用和权限向导")
                }.frame(minHeight: 44)
                Divider()
                HStack(spacing: 10) {
                    Button("屏幕录制权限") { openPrivacySettings("Privacy_ScreenCapture") }
                        .accessibilityLabel("打开屏幕录制权限系统设置")
                    Button("辅助功能权限") { openPrivacySettings("Privacy_Accessibility") }
                        .accessibilityLabel("打开自动滚动使用的辅助功能权限系统设置")
                }
                Text("麦克风和摄像头仅在开启对应录制选项后按需授权。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                NikoShortcutHint(text: "Esc")
                Text("取消截图").font(.caption).foregroundStyle(.secondary)
                NikoShortcutHint(text: "↩")
                Text("复制截图").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var hotkeyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(title: "全局快捷键", caption: "点击组合键录制，按 Esc 取消。无需输入监控权限。") {
                ForEach(CaptureAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: action.symbol).foregroundStyle(.secondary)
                                .frame(width: 22).accessibilityHidden(true)
                            Text(action.title)
                            Spacer(minLength: 12)
                            HotkeyRecorder(shortcut: hotkeys.shortcut(for: action), actionTitle: action.title) {
                                hotkeys.setShortcut($0, for: action)
                            }.frame(width: 150, height: 44)
                        }.frame(minHeight: 44)
                        if let issue = hotkeys.registrationErrors[action] {
                            Label(issue.message, systemImage: "exclamationmark.circle.fill")
                                .font(.caption).foregroundStyle(.red)
                                .accessibilityLabel("热键冲突：\(issue.message)")
                            HStack(spacing: 8) {
                                Text("可尝试").font(.caption).foregroundStyle(.secondary)
                                ForEach(hotkeys.suggestions(for: action), id: \.self) { shortcut in
                                    Button(shortcut.displayString) { hotkeys.setShortcut(shortcut, for: action) }
                                        .font(.caption).accessibilityLabel("改用 \(shortcut.displayString)")
                                }
                            }
                        }
                    }
                    if action != CaptureAction.allCases.last { Divider() }
                }
            }
            Button("恢复默认快捷键") { hotkeys.resetDefaults() }
                .accessibilityLabel("恢复全部默认快捷键")
        }
    }

    private var captureContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(title: "框选行为") {
                PreferenceRow(title: "默认延时") {
                    Picker("默认延时", selection: $settings.captureDelay) {
                        Text("立即").tag(0)
                        ForEach(1...10, id: \.self) { Text("\($0) 秒").tag($0) }
                    }.labelsHidden().frame(width: 150).accessibilityLabel("截图延时")
                }
                Divider()
                Toggle("显示实际像素尺寸", isOn: $settings.showsPixels)
                    .toggleStyle(.switch).frame(minHeight: 44)
                    .accessibilityLabel("框选时显示实际像素尺寸")
                Text("关闭后显示屏幕点数；导出始终按屏幕实际缩放倍率计算。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsGroup(title: "预设尺寸", caption: "框选时可选择预设，尺寸以屏幕点数计算。") {
                ForEach(settings.presetSizes) { preset in
                    HStack {
                        Text(preset.name)
                        Spacer()
                        Text("\(Int(preset.width)) × \(Int(preset.height)) pt")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Button { settings.presetSizes.removeAll { $0.id == preset.id } } label: {
                            Image(systemName: "minus.circle").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless).help("删除\(preset.name)")
                        .accessibilityLabel("删除截图尺寸预设\(preset.name)")
                    }.frame(minHeight: 40)
                }
                if !settings.presetSizes.isEmpty { Divider() }
                VStack(alignment: .leading, spacing: 10) {
                    Text("添加预设").font(.subheadline.weight(.medium))
                    TextField("名称", text: $presetName).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("截图尺寸预设名称")
                    HStack(spacing: 10) {
                        TextField("宽度", value: $presetWidth, format: .number)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("预设宽度，单位屏幕点")
                        Text("×").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("高度", value: $presetHeight, format: .number)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("预设高度，单位屏幕点")
                        Text("pt").font(.caption).foregroundStyle(.secondary)
                        Button("添加") {
                            settings.presetSizes.append(CaptureSizePreset(name: presetName.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                          width: Double(presetWidth), height: Double(presetHeight)))
                        }
                        .disabled(presetWidth <= 0 || presetHeight <= 0 || presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command).accessibilityLabel("添加截图尺寸预设")
                    }
                }
            }
        }
    }

    private var annotationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(title: "标注工具") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 16) {
                    ForEach(AnnotationTool.allCases, id: \.self) { tool in
                        Label(tool.title, systemImage: tool.symbol).font(.callout)
                            .accessibilityLabel(tool.title)
                    }
                }.padding(.vertical, 4)
            }
            SettingsGroup(title: "画布操作") {
                PreferenceRow(title: "撤销") { NikoShortcutHint(text: "⌘Z") }
                    .accessibilityElement(children: .ignore).accessibilityLabel("撤销，Command Z")
                Divider()
                PreferenceRow(title: "重做") { NikoShortcutHint(text: "⇧⌘Z") }
                    .accessibilityElement(children: .ignore).accessibilityLabel("重做，Shift Command Z")
                Divider()
                PreferenceRow(title: "切换框选与标注") { NikoShortcutHint(text: "Tab") }
                    .accessibilityElement(children: .ignore).accessibilityLabel("切换框选与标注，Tab")
            }
        }
    }

    private var outputContent: some View {
        SettingsGroup(title: "图片导出") {
            PreferenceRow(title: "默认格式") {
                Picker("默认格式", selection: $settings.exportFormatRaw) {
                    Text("PNG").tag("png"); Text("JPEG").tag("jpeg")
                    Text("HEIF").tag("heif"); Text("TIFF").tag("tiff")
                }.labelsHidden().frame(width: 170).accessibilityLabel("默认图片格式")
            }
            if settings.exportFormatRaw == "jpeg" {
                Divider()
                PreferenceRow(title: "JPEG 质量") {
                    Slider(value: $settings.jpegQuality, in: 0...1).frame(width: 180).accessibilityLabel("JPEG 质量")
                    Text(settings.jpegQuality, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 42)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("文件名模板").font(.subheadline.weight(.medium))
                TextField("文件名模板", text: $settings.filenameTemplate).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("截图文件名模板")
                Text("可使用 {date}、{time} 和 {n}；扩展名随输出格式自动添加。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 4)
        }
    }

    private var ocrContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("文字识别与翻译设置", selection: $showsTranslationSettings) {
                Text("文字识别").tag(false)
                Text("翻译服务").tag(true)
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("文字识别与翻译设置子页")
            if showsTranslationSettings {
                TranslationSettingsView(settings: settings, drafts: translationDrafts)
            } else {
            SettingsGroup(title: "文字识别") {
                Toggle("自动识别截图，用于历史搜索", isOn: $settings.autoOCR)
                    .toggleStyle(.switch).frame(minHeight: 44)
                    .accessibilityLabel("自动识别截图文字，用于历史搜索")
                Divider()
                Toggle("精确识别", isOn: $settings.accurateOCR)
                    .toggleStyle(.switch).frame(minHeight: 44).accessibilityLabel("使用精确文字识别")
                Text("快速模式适用于系统支持的拉丁语言；中文或日文仍使用精确识别。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("识别语言").font(.subheadline.weight(.medium))
                    HStack(spacing: 20) {
                        ForEach([("zh-Hans", "简体中文"), ("en-US", "英语"), ("ja-JP", "日语")], id: \.0) { code, name in
                            Toggle(name, isOn: ocrLanguageBinding(code)).toggleStyle(.checkbox)
                                .disabled(settings.ocrLanguages.count == 1 && settings.ocrLanguages.contains(code))
                                .accessibilityLabel("识别语言：\(name)").help("至少保留一种文字识别语言")
                        }
                    }.frame(minHeight: 32)
                }
            }
            }
        }
    }

    private var recordingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(title: "视频") {
                PreferenceRow(title: "帧率") {
                    Picker("帧率", selection: $settings.recordingFPS) {
                        ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }.labelsHidden().frame(width: 140).accessibilityLabel("录屏帧率")
                }
                Divider()
                PreferenceRow(title: "编码") {
                    Picker("编码", selection: $settings.recordingCodec) {
                        Text("HEVC · 更小体积").tag("hevc"); Text("H.264 · 广泛兼容").tag("h264")
                    }.labelsHidden().frame(width: 200).accessibilityLabel("视频编码")
                }
                Divider()
                PreferenceRow(title: "编码质量") {
                    Slider(value: $settings.recordingQuality, in: 0...1).frame(width: 180)
                        .accessibilityLabel("录屏编码质量")
                    Text(settings.recordingQuality, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 42)
                }
                Divider()
                Toggle("显示光标", isOn: $settings.showsCursor).toggleStyle(.switch).frame(minHeight: 44)
                    .accessibilityLabel("在录制视频中显示光标")
                Divider()
                Toggle("摄像头画中画", isOn: $settings.recordingCamera).toggleStyle(.switch).frame(minHeight: 44)
                    .accessibilityLabel("录制摄像头画中画")
            }
            SettingsGroup(title: "GIF", caption: "默认最大 800 px、15 fps；导出时显示预估体积。") {
                PreferenceRow(title: "最大宽度", detail: "像素") {
                    TextField("最大宽度", value: $settings.gifWidth, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                        .accessibilityLabel("GIF 最大宽度，单位像素")
                }
                Divider()
                PreferenceRow(title: "采样帧率") {
                    Picker("采样帧率", selection: $settings.gifFPS) {
                        ForEach([5, 10, 15, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }.labelsHidden().frame(width: 140).accessibilityLabel("GIF 采样帧率")
                }
            }
            SettingsGroup(title: "音频", caption: "仅在开启麦克风录制时请求麦克风权限。") {
                Toggle("录制系统声音", isOn: $settings.systemAudio).toggleStyle(.switch).frame(minHeight: 44)
                    .accessibilityLabel("在录屏中包含系统声音")
                Divider()
                Toggle("录制麦克风", isOn: $settings.microphone).toggleStyle(.switch).frame(minHeight: 44)
                    .accessibilityLabel("在录屏中包含麦克风声音")
            }
        }
    }

    private var aboutContent: some View {
        SettingsGroup(title: "niko-shot") {
            HStack(spacing: 14) {
                NikoSymbolBadge(symbol: "camera.viewfinder", size: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text("版本 \(version)").font(.headline)
                    Text("原生截图、录屏与文字工具").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4)
            Divider()
            PreferenceRow(title: "系统要求") { Text("macOS 14 或更新版本").foregroundStyle(.secondary) }
            Text("Swift · AppKit · SwiftUI · ScreenCaptureKit").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func consumeNavigation() {
        guard navigation.opensTranslation else { return }
        section = .ocrTranslation
        showsTranslationSettings = true
        navigation.opensTranslation = false
    }

    private func ocrLanguageBinding(_ code: String) -> Binding<Bool> {
        Binding(get: { settings.ocrLanguages.contains(code) }, set: { enabled in
            if enabled, !settings.ocrLanguages.contains(code) { settings.ocrLanguages.append(code) }
            else if !enabled, settings.ocrLanguages.count > 1 { settings.ocrLanguages.removeAll { $0 == code } }
        })
    }

    private func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

@MainActor
private struct SettingsGroup<Content: View>: View {
    let title: String
    let caption: String?
    private let content: Content

    init(title: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.caption = caption; self.content = content()
    }

    var body: some View {
        NikoPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
                content
            }
        }
    }
}

@MainActor
private struct PreferenceRow<Content: View>: View {
    let title: String
    let detail: String?
    private let content: Content

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.detail = detail; self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 16)
            content
        }.frame(minHeight: 44)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, hotkeys, capture, annotation, output, ocrTranslation, recording, history, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "通用"
        case .hotkeys: "热键"
        case .capture: "截图"
        case .annotation: "标注"
        case .output: "输出"
        case .ocrTranslation: "OCR 与翻译"
        case .recording: "录屏"
        case .history: "历史"
        case .about: "关于"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "启动方式、权限和使用向导。"
        case .hotkeys: "为截图与常用动作设置快捷键。"
        case .capture: "调整框选提示、延时和常用尺寸。"
        case .annotation: "标注工具与画布快捷操作。"
        case .output: "选择默认格式、图片质量和文件名。"
        case .ocrTranslation: "识别文字，并接入你选择的翻译服务。"
        case .recording: "视频、GIF 与音频的默认录制选项。"
        case .history: "管理截图历史的保留时间。"
        case .about: "版本与系统信息。"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .hotkeys: "keyboard"
        case .capture: "crop"
        case .annotation: "pencil.tip"
        case .output: "square.and.arrow.up"
        case .ocrTranslation: "character.bubble"
        case .recording: "record.circle"
        case .history: "clock"
        case .about: "info.circle"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .hotkeys: .purple
        case .capture: .blue
        case .annotation: .orange
        case .output: .green
        case .ocrTranslation: .indigo
        case .recording: .red
        case .history: .teal
        case .about: .gray
        }
    }
}

@MainActor
private struct HotkeyRecorder: NSViewRepresentable {
    let shortcut: HotkeyShortcut
    let actionTitle: String
    let onChange: (HotkeyShortcut) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderButton {
        let button = HotkeyRecorderButton()
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        button.target = button
        button.action = #selector(HotkeyRecorderButton.beginRecording)
        return button
    }

    func updateNSView(_ button: HotkeyRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.onChange = onChange
        button.setAccessibilityLabel("\(actionTitle)快捷键：\(shortcut.displayString)，点击录制")
        if !button.isRecording { button.title = shortcut.displayString }
    }

    static func dismantleNSView(_ button: HotkeyRecorderButton, coordinator: ()) {
        button.stopRecording()
    }
}

@MainActor
private final class HotkeyRecorderButton: NSButton {
    var shortcut = CaptureAction.region.defaultShortcut
    var onChange: ((HotkeyShortcut) -> Void)?
    private(set) var isRecording = false
    // AppKit detaches the view on MainActor; these tokens have synchronous fallback cleanup.
    nonisolated(unsafe) private var monitor: Any?
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

    @objc func beginRecording() {
        if isRecording { stopRecording(); return }
        isRecording = true
        title = "按下组合键…"
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            // AppKit invokes local event monitors synchronously on the main event loop.
            var result: NSEvent? = event
            MainActor.assumeIsolated { () -> Void in
                if let self { result = self.record(event) }
            }
            return result
        }
        if let window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stopRecording() }
                }
                windowObservers.append(observer)
            }
        }
    }

    private func record(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        guard event.window === window else { stopRecording(); return event }
        guard event.type == .keyDown else { stopRecording(); return event }
        if event.keyCode == 53 { stopRecording(); return nil }
        let candidate = HotkeyShortcut(keyCode: UInt32(event.keyCode), modifiers: HotkeyShortcut.carbonModifiers(from: event.modifierFlags))
        guard candidate.isValid else { title = "请加入 ⌘ / ⌥ / ⌃"; return nil }
        stopRecording()
        onChange?(candidate)
        return nil
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        isRecording = false
        title = shortcut.displayString
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }
}
