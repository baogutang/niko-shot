// Presents system-style preference sections and a local-only native shortcut recorder.
import AppKit
import SwiftUI

/// Native preference navigation with observable settings and shortcut feedback.
@MainActor
public struct SettingsView: View {
    @Bindable private var settings: AppSettings
    @Bindable private var hotkeys: HotkeyCenter
    @State private var section: SettingsSection? = .general
    @State private var presetName = "自定义"
    @State private var presetWidth = 800
    @State private var presetHeight = 600

    /// Creates a settings shell sharing the application's live preferences and hotkeys.
    public init(settings: AppSettings = .shared, hotkeys: HotkeyCenter) {
        self.settings = settings
        self.hotkeys = hotkeys
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
                    .accessibilityLabel(item.title)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 165, ideal: 180, max: 220)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Label("niko-shot", systemImage: "camera.viewfinder").font(.headline)
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Text((section ?? .general).title).font(.largeTitle.weight(.semibold))
                    .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 8)
                content.formStyle(.grouped)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    @ViewBuilder private var content: some View {
        switch section ?? .general {
        case .general:
            Form {
                Section("niko-shot") {
                    LabeledContent("运行方式", value: "菜单栏常驻 · 键盘优先")
                    LabeledContent("外观", value: "跟随系统")
                    Text("从菜单栏或全局快捷键开始。截图过程中按 Esc 取消，按 Enter 复制。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        case .hotkeys:
            hotkeyForm
        case .capture:
            Form {
                Section("框选") {
                    Picker("默认延时", selection: $settings.captureDelay) {
                        Text("立即").tag(0)
                        ForEach(1...10, id: \.self) { Text("\($0) 秒").tag($0) }
                    }.accessibilityLabel("截图延时")
                    Toggle("显示像素尺寸", isOn: $settings.showsPixels)
                    Text("关闭后以屏幕点数显示；导出按屏幕实际缩放倍率计算。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("预设尺寸") {
                    ForEach(settings.presetSizes) { preset in
                        HStack { LabeledContent(preset.name, value: "\(Int(preset.width)) × \(Int(preset.height)) pt").monospacedDigit(); Button("删除", systemImage: "minus.circle") { settings.presetSizes.removeAll { $0.id == preset.id } }.labelStyle(.iconOnly).accessibilityLabel("删除\(preset.name)") }
                    }
                    TextField("名称", text: $presetName)
                    HStack { TextField("宽", value: $presetWidth, format: .number); Text("×"); TextField("高", value: $presetHeight, format: .number); Button("添加") { settings.presetSizes.append(CaptureSizePreset(name: presetName, width: Double(presetWidth), height: Double(presetHeight))) }.disabled(presetWidth <= 0 || presetHeight <= 0 || presetName.isEmpty) }
                }
            }
        case .annotation:
            Form {
                Section("标注工作区") {
                    Label("矩形、椭圆、箭头、画笔、文字、马赛克等工具", systemImage: "pencil.tip.crop.circle")
                    LabeledContent("撤销 / 重做", value: "⌘Z / ⇧⌘Z")
                    LabeledContent("切换框选与标注", value: "Tab")
                }
            }
        case .output:
            Form {
                Section("默认输出") {
                    Picker("格式", selection: $settings.exportFormatRaw) {
                        Text("PNG").tag("png"); Text("JPEG").tag("jpeg")
                        Text("HEIF").tag("heif"); Text("TIFF").tag("tiff")
                    }.accessibilityLabel("默认图片格式")
                    if settings.exportFormatRaw == "jpeg" {
                        LabeledContent("JPEG 质量") {
                            Slider(value: $settings.jpegQuality, in: 0...1).frame(width: 170)
                                .accessibilityLabel("JPEG 质量")
                            Text(settings.jpegQuality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 42)
                        }
                    }
                    TextField("文件名模板", text: $settings.filenameTemplate)
                        .accessibilityLabel("截图文件名模板")
                    Text("可使用 {date}、{time} 和 {n}。扩展名随输出格式自动添加。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .ocrTranslation:
            Form {
                Section("文字识别") {
                    Toggle("自动识别截图以供历史搜索", isOn: $settings.autoOCR)
                    Toggle("精确识别", isOn: $settings.accurateOCR)
                    ForEach([("zh-Hans", "简体中文"), ("en-US", "英语"), ("ja-JP", "日语")], id: \.0) { code, name in
                        Toggle(name, isOn: Binding(get: { settings.ocrLanguages.contains(code) }, set: { selected in if selected { if !settings.ocrLanguages.contains(code) { settings.ocrLanguages.append(code) } } else if settings.ocrLanguages.count > 1 { settings.ocrLanguages.removeAll { $0 == code } } }))
                    }
                }
                TranslationSettingsView(settings: settings)
            }
        case .recording:
            Form {
                Section("视频") {
                    Picker("帧率", selection: $settings.recordingFPS) {
                        ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }.accessibilityLabel("录屏帧率")
                    Picker("编码", selection: $settings.recordingCodec) {
                        Text("HEVC · 更小体积").tag("hevc")
                        Text("H.264 · 广泛兼容").tag("h264")
                    }.accessibilityLabel("视频编码")
                    Slider(value: $settings.recordingQuality, in: 0...1) { Text("编码质量") }.accessibilityLabel("录屏编码质量")
                    Toggle("显示光标", isOn: $settings.showsCursor)
                    Toggle("摄像头画中画", isOn: $settings.recordingCamera)
                }
                Section("GIF") {
                    TextField("最大宽度（像素）", value: $settings.gifWidth, format: .number)
                    Picker("采样帧率", selection: $settings.gifFPS) { ForEach([5, 10, 15, 24, 30], id: \.self) { Text("\($0) fps").tag($0) } }
                    Text("默认最多 800px、15fps；导出面板显示预估体积。").font(.caption).foregroundStyle(.secondary)
                }
                Section("音频") {
                    Toggle("录制系统声音", isOn: $settings.systemAudio)
                    Toggle("录制麦克风", isOn: $settings.microphone)
                    Text("仅在开启麦克风录制时请求麦克风权限。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .history:
            Form {
                Section("保留时间") {
                    Picker("截图历史", selection: $settings.historyRetention) {
                        Text("直到手动删除").tag(0); Text("7 天").tag(7)
                        Text("30 天").tag(30); Text("90 天").tag(90)
                    }.accessibilityLabel("历史保留时间")
                }
            }
        case .about:
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "camera.viewfinder").font(.system(size: 42)).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("niko-shot").font(.title2.weight(.semibold))
                            Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                                .foregroundStyle(.secondary)
                            Text("原生截图、录屏与文字工具").font(.callout)
                        }
                    }.padding(.vertical, 12)
                    LabeledContent("系统要求", value: "macOS 14 或更新版本")
                    Text("Swift · AppKit · SwiftUI · ScreenCaptureKit")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var hotkeyForm: some View {
        Form {
            Section {
                ForEach(CaptureAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label(action.title, systemImage: action.symbol)
                            Spacer()
                            HotkeyRecorder(shortcut: hotkeys.shortcut(for: action), actionTitle: action.title) {
                                hotkeys.setShortcut($0, for: action)
                            }.frame(width: 150, height: 26)
                        }
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
                    }.padding(.vertical, 3)
                }
            } footer: {
                Text("点击组合键开始录制，按 Esc 取消。热键无需输入监控权限。替代键仍会接受系统冲突检查。")
            }
            Section {
                Button("恢复默认快捷键") { hotkeys.resetDefaults() }
                    .accessibilityLabel("恢复全部默认快捷键")
            }
        }
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
