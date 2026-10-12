// Configures native recording scope and persisted encoder/audio preferences before the countdown.
import SwiftUI

/// The capture scope selected before a recording begins.
enum RecordingSelectionMode: String, CaseIterable, Identifiable, Sendable {
    case region, window, fullscreen
    var id: String { rawValue }

    /// Native recording mode label.
    var title: String {
        switch self {
        case .region: "区域"
        case .window: "窗口"
        case .fullscreen: "全屏"
        }
    }

    /// SF Symbol representing the recording scope.
    var symbol: String {
        switch self {
        case .region: "crop"
        case .window: "macwindow"
        case .fullscreen: "rectangle.inset.filled"
        }
    }
}

/// Native preflight form; the coordinator owns selection, authorization and countdown.
@MainActor
struct RecordingSetupView: View {
    @Bindable private var settings: AppSettings
    @State private var mode: RecordingSelectionMode = .region
    private let onStart: (RecordingSelectionMode) -> Void
    private let onCancel: () -> Void

    /// Creates a recording setup form without requesting permissions during preference editing.
    init(settings: AppSettings = .shared, onStart: @escaping (RecordingSelectionMode) -> Void, onCancel: @escaping () -> Void) {
        self.settings = settings
        self.onStart = onStart
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "record.circle").font(.system(size: 30)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始录屏").font(.title2.weight(.semibold))
                    Text("选定范围后，倒计时 3 秒开始录制。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Form {
                Section("录制范围") {
                    Picker("范围", selection: $mode) {
                        ForEach(RecordingSelectionMode.allCases) { item in
                            Label(item.title, systemImage: item.symbol).tag(item)
                        }
                    }.pickerStyle(.segmented).accessibilityLabel("录制范围")
                    Text(scopeDescription).font(.caption).foregroundStyle(.secondary)
                }
                Section("视频") {
                    Picker("帧率", selection: $settings.recordingFPS) {
                        ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }.accessibilityLabel("录屏帧率")
                    Picker("编码", selection: $settings.recordingCodec) {
                        Text("HEVC · 更小体积").tag("hevc")
                        Text("H.264 · 广泛兼容").tag("h264")
                    }.accessibilityLabel("视频编码")
                    LabeledContent("质量") {
                        Slider(value: $settings.recordingQuality, in: 0...1).frame(width: 160)
                            .accessibilityLabel("录屏质量")
                        Text(settings.recordingQuality, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().frame(width: 42)
                    }
                    Toggle("显示光标", isOn: $settings.showsCursor).accessibilityLabel("录制鼠标光标")
                }
                Section("声音与摄像头") {
                    Toggle("录制系统声音", isOn: $settings.systemAudio).accessibilityLabel("录制系统声音")
                    Toggle("录制麦克风", isOn: $settings.microphone).accessibilityLabel("录制麦克风声音")
                    Toggle("摄像头画中画", isOn: $settings.recordingCamera).accessibilityLabel("在视频中加入摄像头画中画")
                    Text("麦克风和摄像头只在开启录制时请求权限。摄像头画面会同时显示在悬浮窗和导出视频中。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction).accessibilityLabel("取消录屏设置")
                Spacer()
                Label("3 秒倒计时", systemImage: "timer").font(.callout).foregroundStyle(.secondary)
                Button(startTitle) { onStart(mode) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityLabel(startTitle)
            }.padding(20)
        }
        .frame(minWidth: 470, idealWidth: 500, minHeight: 570, idealHeight: 620)
    }

    private var scopeDescription: String {
        switch mode {
        case .region: "下一步拖动选择需要录制的区域。"
        case .window: "下一步选择一个窗口，录制该窗口的内容。"
        case .fullscreen: "录制当前屏幕的完整画面。"
        }
    }

    private var startTitle: String {
        switch mode {
        case .region: "选择区域并开始"
        case .window: "选择窗口并开始"
        case .fullscreen: "开始全屏录制"
        }
    }
}
