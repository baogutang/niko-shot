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

/// Compact native preflight panels; the coordinator owns selection, authorization and countdown.
@MainActor
struct RecordingSetupView: View {
    @Bindable private var settings: AppSettings
    @State private var mode: RecordingSelectionMode = .region
    private let onStart: (RecordingSelectionMode) -> Void
    private let onCancel: () -> Void

    /// Creates a recording setup form without requesting permissions during preference editing.
    init(settings: AppSettings = .shared, onStart: @escaping (RecordingSelectionMode) -> Void, onCancel: @escaping () -> Void, initialMode: RecordingSelectionMode = .region) {
        self.settings = settings
        _mode = State(initialValue: initialMode)
        self.onStart = onStart
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            NikoPageHeader(title: "开始录屏", subtitle: "选定范围，倒计时 3 秒后开始录制。", symbol: "record.circle")
                .padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    NikoPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("录制范围").font(.headline).accessibilityAddTraits(.isHeader)
                            Picker("范围", selection: $mode) {
                                ForEach(RecordingSelectionMode.allCases) { item in
                                    Label(item.title, systemImage: item.symbol).tag(item)
                                }
                            }.pickerStyle(.segmented).accessibilityLabel("录制范围")
                            Text(scopeDescription).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    videoPanel
                    sourcesPanel
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
            Divider()
            HStack(spacing: 12) {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("取消录屏设置")
                Spacer()
                Label("3 秒", systemImage: "timer").font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("录制开始前倒计时 3 秒")
                Button(startTitle) { onStart(mode) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .accessibilityLabel(startTitle)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .background(NikoTheme.canvas)
        .frame(minWidth: 470, idealWidth: 500, minHeight: 570, idealHeight: 620)
    }

    private var videoPanel: some View {
        NikoPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("视频").font(.headline).accessibilityAddTraits(.isHeader)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("帧率").font(.caption).foregroundStyle(.secondary)
                        Picker("帧率", selection: $settings.recordingFPS) {
                            ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                        }.labelsHidden().accessibilityLabel("录屏帧率")
                    }.frame(width: 110)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("编码").font(.caption).foregroundStyle(.secondary)
                        Picker("编码", selection: $settings.recordingCodec) {
                            Text("HEVC · 更小体积").tag("hevc")
                            Text("H.264 · 广泛兼容").tag("h264")
                        }.labelsHidden().accessibilityLabel("视频编码")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                LabeledContent("质量") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.recordingQuality, in: 0...1)
                            .frame(width: 160).accessibilityLabel("录屏质量")
                        Text(settings.recordingQuality, format: .percent.precision(.fractionLength(0)))
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                    }
                }.frame(minHeight: 28)
                Toggle("显示光标", isOn: $settings.showsCursor)
                    .toggleStyle(.switch).controlSize(.small).frame(minHeight: 28)
                    .accessibilityLabel("录制鼠标光标")
            }
        }
    }

    private var sourcesPanel: some View {
        NikoPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("声音与摄像头").font(.headline).accessibilityAddTraits(.isHeader)
                HStack(spacing: 16) {
                    Toggle("系统声音", isOn: $settings.systemAudio)
                        .accessibilityLabel("录制系统声音")
                    Divider().frame(height: 20)
                    Toggle("麦克风", isOn: $settings.microphone)
                        .accessibilityLabel("录制麦克风声音")
                }.toggleStyle(.switch).controlSize(.small).frame(minHeight: 28)
                Toggle("摄像头画中画", isOn: $settings.recordingCamera)
                    .toggleStyle(.switch).controlSize(.small).frame(minHeight: 28)
                    .accessibilityLabel("在视频中加入摄像头画中画")
                Text("麦克风和摄像头在开始录制时按需授权。摄像头画面会同时出现在悬浮窗和导出视频中。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
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
