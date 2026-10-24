// The settings window: toolbar tabs over native grouped forms, the way macOS apps present preferences.
import AppKit
import SwiftUI

/// Builds the settings window and keeps it sized to the selected pane.
@MainActor
enum SettingsWindowFactory {
  static func makeWindow(settings: AppSettings = .shared, hotkeys: HotkeyCenter,
                         onShowWizard: @escaping () -> Void) -> UtilityWindow {
    let tabs = SettingsTabController()
    let drafts = TranslationSettingsDrafts()
    for pane in SettingsPane.allCases {
      let root: AnyView = switch pane {
      case .general: AnyView(GeneralPane(settings: settings, onShowWizard: onShowWizard))
      case .capture: AnyView(CapturePane(settings: settings))
      case .hotkeys: AnyView(HotkeysPane(hotkeys: hotkeys))
      case .ocr: AnyView(OCRPane(settings: settings))
      case .translation: AnyView(TranslationSettingsView(settings: settings, drafts: drafts))
      case .recording: AnyView(RecordingPane(settings: settings))
      }
      let host = NSHostingController(rootView: root.frame(width: pane.size.width, height: pane.size.height)
        .tint(NikoTheme.accent))
      // The tab controller resizes the window itself; SwiftUI must not push sizes back.
      host.sizingOptions = []
      host.title = pane.title
      let item = NSTabViewItem(viewController: host)
      item.label = pane.title
      item.identifier = pane.rawValue
      item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
      tabs.addTabViewItem(item)
    }
    tabs.onClose = { drafts.clearSensitiveInputs() }
    let window = UtilityWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("NikoSettings")
    let saved = UserDefaults.standard.string(forKey: SettingsTabController.selectedKey)
    tabs.select(SettingsPane(rawValue: saved ?? "") ?? .general, animated: false)
    window.center()
    window.setFrameUsingName("NikoSettings")
    return window
  }
}

enum SettingsPane: String, CaseIterable {
  case general, capture, hotkeys, ocr, translation, recording
  var title: String {
    switch self {
    case .general: "通用"
    case .capture: "截图"
    case .hotkeys: "快捷键"
    case .ocr: "文字识别"
    case .translation: "翻译"
    case .recording: "录屏"
    }
  }
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .capture: "camera.viewfinder"
    case .hotkeys: "command"
    case .ocr: "text.viewfinder"
    case .translation: "translate"
    case .recording: "record.circle"
    }
  }
  var size: CGSize {
    switch self {
    case .general: CGSize(width: 560, height: 470)
    case .capture: CGSize(width: 560, height: 690)
    case .hotkeys: CGSize(width: 560, height: 450)
    case .ocr: CGSize(width: 560, height: 200)
    case .translation: CGSize(width: 620, height: 600)
    case .recording: CGSize(width: 560, height: 520)
    }
  }
}

@MainActor
final class SettingsTabController: NSTabViewController {
  static let selectedKey = "settingsSelectedPane"
  var onClose: (() -> Void)?

  override init(nibName: NSNib.Name?, bundle: Bundle?) {
    super.init(nibName: nibName, bundle: bundle)
    tabStyle = .toolbar
    transitionOptions = [.allowUserInteraction]
  }
  required init?(coder: NSCoder) { nil }

  func select(_ pane: SettingsPane, animated: Bool) {
    guard let index = tabViewItems.firstIndex(where: { $0.identifier as? String == pane.rawValue }) else { return }
    if selectedTabViewItemIndex != index { selectedTabViewItemIndex = index }
    fitWindow(animated: animated)
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    fitWindow(animated: false)
  }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    onClose?()
  }

  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    if let id = tabViewItem?.identifier as? String { UserDefaults.standard.set(id, forKey: Self.selectedKey) }
    fitWindow(animated: true)
  }

  /// Keeps the title bar where it is and grows or shrinks the window downward, like System Settings did.
  private func fitWindow(animated: Bool) {
    guard tabViewItems.indices.contains(selectedTabViewItemIndex),
          let id = tabViewItems[selectedTabViewItemIndex].identifier as? String,
          let pane = SettingsPane(rawValue: id), let window = view.window,
          let content = window.contentView else { return }
    let delta = CGSize(width: pane.size.width - content.frame.width, height: pane.size.height - content.frame.height)
    guard delta != .zero else { return }
    var frame = window.frame
    frame.size.width += delta.width
    frame.size.height += delta.height
    frame.origin.y -= delta.height
    window.setFrame(frame, display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
  }
}

// MARK: - Panes

/// Grouped-form footers on macOS render at body size; System Settings uses small secondary text.
@MainActor
private struct SettingsFooter: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
  }
}

@MainActor
private struct GeneralPane: View {
  @Bindable var settings: AppSettings
  let onShowWizard: () -> Void
  @State private var launchAtLogin = LaunchAtLogin()
  @State private var screenCapture = PermissionState.notGranted
  @State private var accessibility = PermissionState.notGranted

  var body: some View {
    Form {
      Section {
        Toggle("登录时打开", isOn: Binding(
          get: { launchAtLogin.isEnabled },
          set: { enabled in Task { await launchAtLogin.setEnabled(enabled) } }))
          .disabled(launchAtLogin.isUpdating)
        if launchAtLogin.requiresApproval {
          LabeledContent("需要在系统设置中允许") {
            Button("打开登录项…") { launchAtLogin.openSettings() }
          }.foregroundStyle(.secondary)
        }
        if let error = launchAtLogin.errorMessage {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
      }
      Section {
        permissionRow(.screenRecording, state: screenCapture)
        permissionRow(.accessibility, state: accessibility)
      } header: {
        Text("权限")
      } footer: {
        HStack {
          Spacer()
          Button("打开欢迎向导…", action: onShowWizard).buttonStyle(.link).font(.system(size: 11))
        }
      }
      Section {
        Toggle("允许命令行静默截图", isOn: $settings.allowsSilentAutomation)
      } header: {
        Text("自动化")
      } footer: {
        SettingsFooter("开启后，本机其他程序可以通过 niko-shot 命令行直接截取全屏或读取最近识别的文字，不会出现任何界面。")
      }
      Section {
        LabeledContent("版本", value: Self.version)
      }
    }
    .formStyle(.grouped)
    .onAppear { launchAtLogin.refresh() }
    // Settings can stay open beside System Settings; reflect a grant as soon as it happens.
    .task {
      while !Task.isCancelled {
        screenCapture = PermissionKind.screenRecording.state
        accessibility = PermissionKind.accessibility.state
        try? await Task.sleep(for: .seconds(1.5))
      }
    }
  }

  private static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "—"
    return short
  }

  private func permissionRow(_ kind: PermissionKind, state: PermissionState) -> some View {
    LabeledContent {
      switch state {
      case .granted:
        Label("已允许", systemImage: "checkmark.circle.fill")
          .labelStyle(.titleAndIcon).foregroundStyle(.secondary)
          .symbolRenderingMode(.multicolor)
      case .grantedNeedsRelaunch:
        Button("重新打开") { AppRelauncher.relaunch() }
          .help("屏幕录制权限在重新打开 niko-shot 后生效")
      case .notGranted:
        Button("去授权…") { PermissionGuide.shared.present(kind) }
      }
    } label: {
      Text(kind.title)
      Text(kind.purpose)
    }
  }
}

@MainActor
private struct CapturePane: View {
  @Bindable var settings: AppSettings
  @State private var presetName = ""
  @State private var presetWidth = 1280
  @State private var presetHeight = 720

  var body: some View {
    Form {
      Section {
        Picker("延时", selection: $settings.captureDelay) {
          Text("无").tag(0)
          ForEach(Array(Set([1, 2, 3, 5, 10, settings.captureDelay])).filter { $0 > 0 }.sorted(), id: \.self) {
            Text("\($0) 秒").tag($0)
          }
        }
        Toggle("尺寸显示为像素", isOn: $settings.showsPixels)
        Toggle("截图提示音", isOn: $settings.playsCaptureSound)
        Toggle("截图后显示缩略图", isOn: $settings.showsCapturePreview)
      }
      Section {
        Picker("格式", selection: $settings.exportFormatRaw) {
          Text("PNG").tag("png")
          Text("JPEG").tag("jpeg")
          Text("HEIF").tag("heif")
          Text("TIFF").tag("tiff")
        }
        if settings.exportFormatRaw == "jpeg" {
          LabeledContent("JPEG 质量") {
            HStack {
              Slider(value: $settings.jpegQuality, in: 0.3...1).frame(width: 160)
              Text(settings.jpegQuality, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
          }
        }
        Toggle("自动保存到文件夹", isOn: Binding(
          get: { !settings.autoSaveFolder.isEmpty },
          set: { on in settings.autoSaveFolder = on ? Self.desktop : "" }))
        if !settings.autoSaveFolder.isEmpty {
          LabeledContent("文件夹") {
            HStack(spacing: 8) {
              Image(nsImage: NSWorkspace.shared.icon(forFile: settings.autoSaveFolder))
                .resizable().frame(width: 16, height: 16).accessibilityHidden(true)
              Text(FileManager.default.displayName(atPath: settings.autoSaveFolder)).lineLimit(1).truncationMode(.middle)
                .help(settings.autoSaveFolder)
              Button("选择…", action: chooseFolder)
            }
          }
        }
        TextField("文件名", text: $settings.filenameTemplate, prompt: Text("niko-shot {date} {time}"))
        Picker("历史保留", selection: $settings.historyRetention) {
          Text("永久").tag(0)
          Text("7 天").tag(7)
          Text("30 天").tag(30)
          Text("90 天").tag(90)
        }
      } header: {
        Text("保存")
      } footer: {
        SettingsFooter(settings.autoSaveFolder.isEmpty ? "文件名可用 {date}、{time}、{n}。"
          : "每张截图在复制的同时，也会存一份到这个文件夹，不会覆盖同名文件。文件名可用 {date}、{time}、{n}。")
      }
      Section("预设尺寸") {
        ForEach(settings.presetSizes) { preset in
          LabeledContent(preset.name) {
            HStack(spacing: 8) {
              Text(verbatim: "\(Int(preset.width)) × \(Int(preset.height))").monospacedDigit().foregroundStyle(.secondary)
              Button {
                settings.presetSizes.removeAll { $0.id == preset.id }
              } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Color(nsColor: .tertiaryLabelColor)) }
                .buttonStyle(.borderless).help("删除").accessibilityLabel("删除预设\(preset.name)")
            }
          }
        }
        HStack(spacing: 6) {
          TextField("名称", text: $presetName, prompt: Text("新预设名称")).labelsHidden()
            .textFieldStyle(.roundedBorder)
          TextField("宽", value: $presetWidth, format: .number.grouping(.never)).labelsHidden().frame(width: 60)
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).accessibilityLabel("宽度")
          Text(verbatim: "×").foregroundStyle(.secondary)
          TextField("高", value: $presetHeight, format: .number.grouping(.never)).labelsHidden().frame(width: 60)
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).accessibilityLabel("高度")
          Button("添加") {
            settings.presetSizes.append(CaptureSizePreset(
              name: presetName.trimmingCharacters(in: .whitespacesAndNewlines),
              width: Double(presetWidth), height: Double(presetHeight)))
            presetName = ""
          }
          .disabled(presetWidth <= 0 || presetHeight <= 0
            || presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .formStyle(.grouped)
  }

  private static var desktop: String {
    FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "选择"
    panel.directoryURL = URL(fileURLWithPath: settings.autoSaveFolder, isDirectory: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    settings.autoSaveFolder = url.path
  }
}

@MainActor
private struct HotkeysPane: View {
  @Bindable var hotkeys: HotkeyCenter

  var body: some View {
    Form {
      Section {
        ForEach(CaptureAction.allCases) { action in
          LabeledContent {
            HStack(spacing: 4) {
              HotkeyRecorder(shortcut: hotkeys.shortcut(for: action), actionTitle: action.title,
                onChange: { hotkeys.setShortcut($0, for: action) },
                onClear: { hotkeys.clearShortcut(for: action) }
              ).frame(width: 120, height: 24)
              Button { hotkeys.clearShortcut(for: action) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color(nsColor: .tertiaryLabelColor))
              }
              .buttonStyle(.borderless).help("移除快捷键")
              .opacity(hotkeys.shortcut(for: action) == nil ? 0 : 1)
              .disabled(hotkeys.shortcut(for: action) == nil)
              .accessibilityLabel("移除\(action.title)的快捷键")
            }
          } label: {
            Text(action.title)
            if let issue = hotkeys.registrationErrors[action] {
              HStack(spacing: 6) {
                Text(issue.message).foregroundStyle(.red)
                ForEach(hotkeys.suggestions(for: action).prefix(2), id: \.self) { shortcut in
                  Button("改用 \(shortcut.displayString)") { hotkeys.setShortcut(shortcut, for: action) }
                    .buttonStyle(.link)
                }
              }
            }
          }
        }
      } footer: {
        HStack(alignment: .firstTextBaseline) {
          SettingsFooter("点按后输入新的组合键，按 Delete 移除。与其他应用冲突时，移除或换一个即可。")
          Spacer(minLength: 12)
          Button("恢复默认") { hotkeys.resetDefaults() }.controlSize(.small)
        }
      }
    }
    .formStyle(.grouped)
  }
}

@MainActor
private struct OCRPane: View {
  @Bindable var settings: AppSettings
  private static let languages = [("zh-Hans", "简体中文"), ("en-US", "英语"), ("ja-JP", "日语")]

  var body: some View {
    Form {
      Section {
        Toggle("自动识别截图文字", isOn: $settings.autoOCR)
          .help("识别结果用于在截图历史中搜索")
        Toggle("精确识别", isOn: $settings.accurateOCR)
        LabeledContent("语言") {
          HStack(spacing: 14) {
            ForEach(Self.languages, id: \.0) { code, name in
              Toggle(name, isOn: language(code)).toggleStyle(.checkbox)
                .disabled(settings.ocrLanguages == [code])
            }
          }
        }
      } footer: {
        SettingsFooter("自动识别的文字可在截图历史中搜索。中文和日文始终使用精确识别。")
      }
    }
    .formStyle(.grouped)
  }

  private func language(_ code: String) -> Binding<Bool> {
    Binding(
      get: { settings.ocrLanguages.contains(code) },
      set: { enabled in
        if enabled, !settings.ocrLanguages.contains(code) { settings.ocrLanguages.append(code) }
        else if !enabled, settings.ocrLanguages.count > 1 { settings.ocrLanguages.removeAll { $0 == code } }
      })
  }
}

@MainActor
private struct RecordingPane: View {
  @Bindable var settings: AppSettings

  var body: some View {
    Form {
      Section("视频") {
        Picker("帧率", selection: $settings.recordingFPS) {
          ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
        }
        Picker("编码", selection: $settings.recordingCodec) {
          Text("HEVC（体积更小）").tag("hevc")
          Text("H.264（兼容更好）").tag("h264")
        }
        LabeledContent("画质") {
          HStack {
            Slider(value: $settings.recordingQuality, in: 0.2...1).frame(width: 160)
            Text(settings.recordingQuality, format: .percent.precision(.fractionLength(0)))
              .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
          }
        }
        Toggle("显示光标", isOn: $settings.showsCursor)
        Toggle("摄像头画中画", isOn: $settings.recordingCamera)
      }
      Section("声音") {
        Toggle("系统声音", isOn: $settings.systemAudio)
        Toggle("麦克风", isOn: $settings.microphone)
      }
      Section("GIF") {
        LabeledContent("最大宽度") {
          HStack(spacing: 6) {
            TextField("最大宽度", value: $settings.gifWidth, format: .number.grouping(.never)).labelsHidden()
              .multilineTextAlignment(.trailing).frame(width: 70)
            Text("px").foregroundStyle(.secondary)
          }
        }
        Picker("帧率", selection: $settings.gifFPS) {
          ForEach([5, 10, 15, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
        }
      }
    }
    .formStyle(.grouped)
  }
}

@MainActor
private struct HotkeyRecorder: NSViewRepresentable {
  let shortcut: HotkeyShortcut?
  let actionTitle: String
  let onChange: (HotkeyShortcut) -> Void
  let onClear: () -> Void

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
    button.onClear = onClear
    button.setAccessibilityLabel("\(actionTitle)快捷键：\(shortcut?.displayString ?? "未设置")，点击录制")
    if !button.isRecording { button.showShortcut() }
  }

  static func dismantleNSView(_ button: HotkeyRecorderButton, coordinator: ()) {
    button.stopRecording()
  }
}

@MainActor
private final class HotkeyRecorderButton: NSButton {
  var shortcut: HotkeyShortcut?
  var onChange: ((HotkeyShortcut) -> Void)?
  var onClear: (() -> Void)?
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
    title = "按下快捷键"
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
    // Delete or Forward Delete without modifiers removes the shortcut, as in system recorders.
    if event.keyCode == 51 || event.keyCode == 117,
      HotkeyShortcut.carbonModifiers(from: event.modifierFlags) == 0 {
      stopRecording()
      onClear?()
      return nil
    }
    let candidate = HotkeyShortcut(
      keyCode: UInt32(event.keyCode),
      modifiers: HotkeyShortcut.carbonModifiers(from: event.modifierFlags))
    guard candidate.isValid else {
      title = "需含 ⌘ ⌥ 或 ⌃"
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
    showShortcut()
  }

  /// The assigned combination, or a quiet placeholder when there is none.
  func showShortcut() {
    if let shortcut {
      attributedTitle = NSAttributedString(string: shortcut.displayString, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor,
      ])
    } else {
      attributedTitle = NSAttributedString(string: "未设置", attributes: [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor,
      ])
    }
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
