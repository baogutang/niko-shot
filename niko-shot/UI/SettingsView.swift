// Presents a compact native preference workspace and preserves local shortcut recording.
import AppKit
import ApplicationServices
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
  @State private var screenCaptureAllowed = false
  @State private var accessibilityAllowed = false
  private let onShowWizard: () -> Void

  /// Shares live preferences and hotkeys; opening a guide keeps unsaved translation input.
  public init(
    settings: AppSettings = .shared, hotkeys: HotkeyCenter,
    onShowWizard: @escaping () -> Void = {}
  ) {
    self.settings = settings
    self.hotkeys = hotkeys
    self.onShowWizard = onShowWizard
  }

  public var body: some View {
    NavigationSplitView {
      List(selection: $section) {
        ForEach(SettingsCategory.allCases) { category in
          Section(category.title) {
            ForEach(category.sections) { item in
              HStack(spacing: 8) {
                NikoSymbolBadge(
                  symbol: item.symbol, tint: currentSection == item ? NikoTheme.accent : .secondary,
                  size: 22)
                Text(item.title).font(.system(size: 13))
                Spacer(minLength: 0)
              }
              .frame(minHeight: 28)
              .tag(item)
              .accessibilityLabel(item.title)
            }
          }
        }
      }
      .listStyle(.sidebar)
      .tint(NikoTheme.accent)
      .accessibilityLabel("设置分类")
      .navigationSplitViewColumnWidth(min: 166, ideal: 180, max: 200)
      .safeAreaInset(edge: .top) {
        HStack(spacing: 8) {
          Image("NikoMark").resizable().scaledToFit().frame(width: 24, height: 24)
            .accessibilityHidden(true)
          Text("NIKO SHOT").font(.system(size: 12, weight: .semibold)).tracking(1)
          Spacer(minLength: 0)
        }.padding(.horizontal, 16).padding(.vertical, 12)
      }
      .safeAreaInset(edge: .bottom) {
        Text("niko-shot \(version)").font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16).padding(.vertical, 8)
      }
    } detail: {
      VStack(alignment: .leading, spacing: 0) {
        NikoPageHeader(
          title: currentSection.title, subtitle: currentSection.subtitle,
          symbol: currentSection.symbol
        )
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
        if currentSection == .ocrTranslation {
          ocrContent
        } else {
          Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .controlSize(.small)
        }
      }
      .font(.system(size: 13))
      .frame(maxWidth: 660, maxHeight: .infinity, alignment: .topLeading)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(NikoTheme.canvas)
    }
    .navigationSplitViewStyle(.balanced)
    .tint(NikoTheme.accent)
    .frame(minWidth: 780, minHeight: 540)
    .onAppear {
      launchAtLogin.refresh()
      refreshPermissions()
      consumeNavigation()
    }
    .onChange(of: navigation.opensTranslation) { _, requested in
      if requested { consumeNavigation() }
    }
    .onDisappear { translationDrafts.clearSensitiveInputs() }
  }

  private var currentSection: SettingsSection { section ?? .general }
  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
  }

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
            Text("7 天").tag(7)
            Text("30 天").tag(30)
            Text("90 天").tag(90)
          }.labelsHidden().frame(width: 180).accessibilityLabel("历史保留时间")
        }
      }
    case .about: aboutContent
    }
  }

  private var generalContent: some View {
    Group {
      SettingsGroup(title: "启动", caption: "菜单栏常驻 · 外观跟随系统") {
        VStack(alignment: .leading, spacing: 6) {
          Toggle(
            "登录时打开 niko-shot",
            isOn: Binding(
              get: { launchAtLogin.isEnabled },
              set: { enabled in Task { await launchAtLogin.setEnabled(enabled) } }
            )
          )
          .toggleStyle(.switch).disabled(launchAtLogin.isUpdating)
          .accessibilityLabel("登录时自动打开 niko-shot")
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            if launchAtLogin.requiresApproval {
              Label("等待系统批准", systemImage: "clock")
                .font(.caption).foregroundStyle(NikoTheme.accent)
            } else {
              Text(launchAtLogin.isEnabled ? "已开启" : "已关闭")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("登录项设置…") { launchAtLogin.openSettings() }
              .accessibilityLabel("打开系统设置中的登录项")
            Button { launchAtLogin.refresh() } label: {
              Image(systemName: "arrow.clockwise")
            }.disabled(launchAtLogin.isUpdating)
              .help("刷新登录启动状态").accessibilityLabel("刷新登录启动状态")
          }.controlSize(.small)
          if launchAtLogin.isUpdating {
            ProgressView("正在更新登录项…").controlSize(.small)
              .accessibilityLabel("正在更新登录启动设置")
          }
          if let error = launchAtLogin.errorMessage {
            Label(error, systemImage: "exclamationmark.circle")
              .font(.caption).foregroundStyle(.red).textSelection(.enabled)
          }
        }
      }
      SettingsGroup(
        title: "权限",
        caption: "麦克风与摄像头按录制选项授权。截图中按 Esc 取消、↩ 复制。"
      ) {
        permissionRow(
          title: "屏幕录制", detail: "截图与录屏", allowed: screenCaptureAllowed,
          pane: "Privacy_ScreenCapture")
        permissionRow(
          title: "辅助功能",
          detail: accessibilityAllowed ? "自动滚动长截图" : "自动滚动需要；手动滚动无需授权",
          allowed: accessibilityAllowed, pane: "Privacy_Accessibility")
        HStack(spacing: 10) {
          Button("打开使用向导…", action: onShowWizard)
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .accessibilityLabel("打开三步使用和权限向导")
          Spacer(minLength: 8)
          Button("刷新权限状态") { refreshPermissions() }
            .help("重新读取系统授权状态，不请求新权限")
        }.controlSize(.small)
      }
    }
  }

  private func permissionRow(
    title: String, detail: String, allowed: Bool, pane: String
  ) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Label(allowed ? "已授权" : "未授权", systemImage: allowed ? "checkmark.circle.fill" : "circle")
        .font(.caption).foregroundStyle(allowed ? Color.green : Color.secondary)
        .fixedSize()
      Button("设置…") { openPrivacySettings(pane) }
        .accessibilityLabel("打开\(title)权限系统设置")
    }.controlSize(.small)
  }

  private func refreshPermissions() {
    screenCaptureAllowed = CGPreflightScreenCaptureAccess()
    accessibilityAllowed = AXIsProcessTrusted()
  }

  private var hotkeyContent: some View {
    Group {
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
              }.frame(width: 150, height: 32)
            }.frame(minHeight: 32)
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
        }
      }
      Button("恢复默认快捷键") { hotkeys.resetDefaults() }
        .accessibilityLabel("恢复全部默认快捷键")
    }
  }

  private var captureContent: some View {
    Group {
      SettingsGroup(title: "框选行为") {
        PreferenceRow(title: "默认延时") {
          Picker("默认延时", selection: $settings.captureDelay) {
            Text("立即").tag(0)
            ForEach(1...10, id: \.self) { Text("\($0) 秒").tag($0) }
          }.labelsHidden().frame(width: 150).accessibilityLabel("截图延时")
        }
        VStack(alignment: .leading, spacing: 8) {
          Toggle("显示实际像素尺寸", isOn: $settings.showsPixels)
            .toggleStyle(.switch).frame(minHeight: 30)
            .accessibilityLabel("框选时显示实际像素尺寸")
          Text("关闭后显示屏幕点数；导出始终按屏幕实际缩放倍率计算。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      SettingsGroup(title: "长截图", caption: "兼容选项在下一次长截图时生效。") {
        Toggle("使用旧版长截图引擎", isOn: $settings.useLegacyScrollEngine)
          .toggleStyle(.switch).accessibilityLabel("使用旧版长截图引擎")
      }
      SettingsGroup(title: "预设尺寸", caption: "框选时可选择预设，尺寸以屏幕点数计算。") {
        ForEach(settings.presetSizes) { preset in
          HStack {
            Text(preset.name)
            Spacer()
            Text("\(Int(preset.width)) × \(Int(preset.height)) pt")
              .monospacedDigit().foregroundStyle(.secondary)
            Button {
              settings.presetSizes.removeAll { $0.id == preset.id }
            } label: {
              Image(systemName: "minus.circle").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless).help("删除\(preset.name)")
            .accessibilityLabel("删除截图尺寸预设\(preset.name)")
          }.frame(minHeight: 30)
        }
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
              settings.presetSizes.append(
                CaptureSizePreset(
                  name: presetName.trimmingCharacters(in: .whitespacesAndNewlines),
                  width: Double(presetWidth), height: Double(presetHeight)))
            }
            .disabled(
              presetWidth <= 0 || presetHeight <= 0
                || presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .keyboardShortcut(.return, modifiers: .command).accessibilityLabel("添加截图尺寸预设")
          }
        }
      }
    }
  }

  private var annotationContent: some View {
    Group {
      SettingsGroup(title: "标注工具") {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading,
          spacing: 16
        ) {
          ForEach(AnnotationTool.allCases, id: \.self) { tool in
            Label(tool.title, systemImage: tool.symbol).font(.callout)
              .accessibilityLabel(tool.title)
          }
        }.padding(.vertical, 4)
      }
      SettingsGroup(title: "画布操作") {
        PreferenceRow(title: "撤销") { NikoShortcutHint(text: "⌘Z") }
          .accessibilityElement(children: .ignore).accessibilityLabel("撤销，Command Z")
        PreferenceRow(title: "重做") { NikoShortcutHint(text: "⇧⌘Z") }
          .accessibilityElement(children: .ignore).accessibilityLabel("重做，Shift Command Z")
        PreferenceRow(title: "切换框选与标注") { NikoShortcutHint(text: "Tab") }
          .accessibilityElement(children: .ignore).accessibilityLabel("切换框选与标注，Tab")
      }
    }
  }

  private var outputContent: some View {
    SettingsGroup(title: "图片导出") {
      PreferenceRow(title: "默认格式") {
        Picker("默认格式", selection: $settings.exportFormatRaw) {
          Text("PNG").tag("png")
          Text("JPEG").tag("jpeg")
          Text("HEIF").tag("heif")
          Text("TIFF").tag("tiff")
        }.labelsHidden().frame(width: 170).accessibilityLabel("默认图片格式")
      }
      if settings.exportFormatRaw == "jpeg" {
        PreferenceRow(title: "JPEG 质量") {
          Slider(value: $settings.jpegQuality, in: 0...1).frame(width: 180).accessibilityLabel(
            "JPEG 质量")
          Text(settings.jpegQuality, format: .percent.precision(.fractionLength(0)))
            .monospacedDigit().frame(width: 42)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        PreferenceRow(title: "文件名模板") {
          TextField("文件名模板", text: $settings.filenameTemplate).labelsHidden()
            .textFieldStyle(.roundedBorder).accessibilityLabel("截图文件名模板")
        }
        Text("可使用 {date}、{time} 和 {n}；扩展名随输出格式自动添加。")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var ocrContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      Picker("文字识别与翻译设置", selection: $showsTranslationSettings) {
        Text("文字识别").tag(false)
        Text("翻译服务").tag(true)
      }
      .pickerStyle(.segmented).labelsHidden().frame(width: 240)
      .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
      .accessibilityLabel("文字识别与翻译设置子页")
      if showsTranslationSettings {
        TranslationSettingsView(settings: settings, drafts: translationDrafts)
      } else {
        Form {
          ocrRecognitionContent
        }.formStyle(.grouped).scrollContentBackground(.hidden)
      }
    }
  }

  private var ocrRecognitionContent: some View {
    SettingsGroup(title: "文字识别") {
      Toggle("自动识别截图，用于历史搜索", isOn: $settings.autoOCR)
        .toggleStyle(.switch).frame(minHeight: 30)
        .accessibilityLabel("自动识别截图文字，用于历史搜索")
      VStack(alignment: .leading, spacing: 8) {
        Toggle("精确识别", isOn: $settings.accurateOCR)
          .toggleStyle(.switch).frame(minHeight: 30).accessibilityLabel("使用精确文字识别")
        Text("快速模式适用于系统支持的拉丁语言；中文或日文仍使用精确识别。")
          .font(.caption).foregroundStyle(.secondary)
      }
      PreferenceRow(title: "识别语言") {
        HStack(spacing: 12) {
          ForEach([("zh-Hans", "简体中文"), ("en-US", "英语"), ("ja-JP", "日语")], id: \.0) { code, name in
            Toggle(name, isOn: ocrLanguageBinding(code)).toggleStyle(.checkbox)
              .disabled(settings.ocrLanguages.count == 1 && settings.ocrLanguages.contains(code))
              .accessibilityLabel("识别语言：\(name)").help("至少保留一种文字识别语言")
          }
        }.frame(minHeight: 32)
      }
    }
  }

  private var recordingContent: some View {
    Group {
      SettingsGroup(title: "视频") {
        PreferenceRow(title: "帧率") {
          Picker("帧率", selection: $settings.recordingFPS) {
            ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
          }.labelsHidden().frame(width: 140).accessibilityLabel("录屏帧率")
        }
        PreferenceRow(title: "编码") {
          Picker("编码", selection: $settings.recordingCodec) {
            Text("HEVC · 更小体积").tag("hevc")
            Text("H.264 · 广泛兼容").tag("h264")
          }.labelsHidden().frame(width: 200).accessibilityLabel("视频编码")
        }
        PreferenceRow(title: "编码质量") {
          Slider(value: $settings.recordingQuality, in: 0...1).frame(width: 180)
            .accessibilityLabel("录屏编码质量")
          Text(settings.recordingQuality, format: .percent.precision(.fractionLength(0)))
            .monospacedDigit().frame(width: 42)
        }
        Toggle("显示光标", isOn: $settings.showsCursor).toggleStyle(.switch).frame(minHeight: 30)
          .accessibilityLabel("在录制视频中显示光标")
        Toggle("摄像头画中画", isOn: $settings.recordingCamera).toggleStyle(.switch).frame(minHeight: 30)
          .accessibilityLabel("录制摄像头画中画")
      }
      SettingsGroup(title: "GIF", caption: "默认最大 800 px、15 fps；导出时显示预估体积。") {
        PreferenceRow(title: "最大宽度", detail: "像素") {
          TextField("最大宽度", value: $settings.gifWidth, format: .number)
            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 100)
            .accessibilityLabel("GIF 最大宽度，单位像素")
        }
        PreferenceRow(title: "采样帧率") {
          Picker("采样帧率", selection: $settings.gifFPS) {
            ForEach([5, 10, 15, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
          }.labelsHidden().frame(width: 140).accessibilityLabel("GIF 采样帧率")
        }
      }
      SettingsGroup(title: "音频", caption: "仅在开启麦克风录制时请求麦克风权限。") {
        Toggle("录制系统声音", isOn: $settings.systemAudio).toggleStyle(.switch).frame(minHeight: 30)
          .accessibilityLabel("在录屏中包含系统声音")
        Toggle("录制麦克风", isOn: $settings.microphone).toggleStyle(.switch).frame(minHeight: 30)
          .accessibilityLabel("在录屏中包含麦克风声音")
      }
    }
  }

  private var aboutContent: some View {
    SettingsGroup(title: "版本信息", caption: "原生截图、录屏与文字工具。") {
      PreferenceRow(title: "应用版本") { Text(version).monospacedDigit() }
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
    Binding(
      get: { settings.ocrLanguages.contains(code) },
      set: { enabled in
        if enabled, !settings.ocrLanguages.contains(code) {
          settings.ocrLanguages.append(code)
        } else if !enabled, settings.ocrLanguages.count > 1 {
          settings.ocrLanguages.removeAll { $0 == code }
        }
      })
  }

  private func openPrivacySettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
      NSWorkspace.shared.open(url)
    }
  }
}

@MainActor
private struct SettingsGroup<Content: View>: View {
  let title: String
  let caption: String?
  private let content: Content

  init(title: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.caption = caption
    self.content = content()
  }

  var body: some View {
    NikoSection(title: title, footer: caption) { content }
  }
}

@MainActor
private struct PreferenceRow<Content: View>: View {
  let title: String
  let detail: String?
  private let content: Content

  init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.detail = detail
    self.content = content()
  }

  var body: some View {
    NikoPreferenceRow(title: title, detail: detail) { content }
  }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
  case application, captureAndProcessing, dataAndInformation
  var id: String { rawValue }
  var title: String {
    switch self {
    case .application: "应用"
    case .captureAndProcessing: "捕获与处理"
    case .dataAndInformation: "数据与信息"
    }
  }
  var sections: [SettingsSection] {
    switch self {
    case .application: [.general, .hotkeys]
    case .captureAndProcessing: [.capture, .annotation, .output, .ocrTranslation, .recording]
    case .dataAndInformation: [.history, .about]
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
  var subtitle: String {
    switch self {
    case .general: "启动、权限与使用向导"
    case .hotkeys: "常用动作的全局快捷键"
    case .capture: "框选、延时与预设尺寸"
    case .annotation: "工具与画布操作"
    case .output: "格式、质量与文件名"
    case .ocrTranslation: "文字识别与翻译服务"
    case .recording: "视频、GIF 与音频"
    case .history: "截图历史的保留时间"
    case .about: "版本与系统信息"
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
    if isRecording {
      stopRecording()
      return
    }
    isRecording = true
    title = "按下组合键…"
    window?.makeFirstResponder(self)
    monitor = NSEvent.addLocalMonitorForEvents(matching: [
      .keyDown, .leftMouseDown, .rightMouseDown,
    ]) { [weak self] event in
      // AppKit invokes local event monitors synchronously on the main event loop.
      var result: NSEvent? = event
      MainActor.assumeIsolated { () -> Void in
        if let self { result = self.record(event) }
      }
      return result
    }
    if let window {
      for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
        let observer = NotificationCenter.default.addObserver(
          forName: name, object: window, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.stopRecording() }
        }
        windowObservers.append(observer)
      }
    }
  }

  private func record(_ event: NSEvent) -> NSEvent? {
    guard isRecording else { return event }
    guard event.window === window else {
      stopRecording()
      return event
    }
    guard event.type == .keyDown else {
      stopRecording()
      return event
    }
    if event.keyCode == 53 {
      stopRecording()
      return nil
    }
    let candidate = HotkeyShortcut(
      keyCode: UInt32(event.keyCode),
      modifiers: HotkeyShortcut.carbonModifiers(from: event.modifierFlags))
    guard candidate.isValid else {
      title = "请加入 ⌘ / ⌥ / ⌃"
      return nil
    }
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
