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

/// Native preflight controls; the coordinator owns selection, authorization and countdown.
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("录制范围")
                        HStack(spacing: 8) {
                            ForEach(RecordingSelectionMode.allCases) { item in
                                Button { mode = item } label: {
                                    VStack(spacing: 7) {
                                        Image(systemName: item.symbol).font(.system(size: 20, weight: .regular))
                                        Text(item.title).font(.system(size: 13, weight: .medium))
                                    }
                                    .frame(maxWidth: .infinity).frame(height: 60)
                                }
                                .buttonStyle(RecordingScopeButtonStyle(selected: mode == item))
                                .accessibilityLabel("录制\(item.title)")
                                .accessibilityValue(mode == item ? "已选择" : "未选择")
                                .accessibilityAddTraits(mode == item ? .isSelected : [])
                            }
                        }
                        Text(scopeDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    videoControls
                    Divider()
                    sourceControls
                }
                .padding(20)
            }
            .background(NikoTheme.surface)
            Divider()
            HStack(spacing: 12) {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                    .accessibilityLabel("取消录屏设置")
                Spacer()
                Label("3 秒倒计时", systemImage: "timer").font(.system(size: 12)).foregroundStyle(NikoTheme.accent)
                    .accessibilityLabel("录制开始前倒计时 3 秒")
                Button(startTitle) { onStart(mode) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .foregroundStyle(NikoTheme.onAccent)
                    .accessibilityLabel(startTitle)
            }.padding(.horizontal, 20).padding(.vertical, 12)
                .background(NikoTheme.raisedSurface.opacity(0.35))
        }
        .font(.system(size: 13)).controlSize(.regular)
        .background(NikoTheme.canvas)
        .tint(NikoTheme.accent)
        .frame(minWidth: 470, idealWidth: 500, minHeight: 500, idealHeight: 560)
    }

    private var videoControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("视频")
            formRow("帧率") {
                Picker("帧率", selection: $settings.recordingFPS) {
                    ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }.labelsHidden().frame(width: 120).accessibilityLabel("录屏帧率")
            }
            formRow("编码") {
                Picker("编码", selection: $settings.recordingCodec) {
                    Text("HEVC（体积更小）").tag("hevc")
                    Text("H.264（兼容更好）").tag("h264")
                }.labelsHidden().frame(width: 224).accessibilityLabel("视频编码")
            }
            formRow("质量") {
                HStack(spacing: 12) {
                    Slider(value: $settings.recordingQuality, in: 0...1)
                        .accessibilityLabel("录屏质量")
                    Text(settings.recordingQuality, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            formRow("光标") {
                Toggle("显示光标", isOn: $settings.showsCursor)
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("录制鼠标光标")
            }
        }
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("声音与摄像头")
            formRow("声音") {
                HStack(spacing: 24) {
                    Toggle("系统声音", isOn: $settings.systemAudio).accessibilityLabel("录制系统声音")
                    Toggle("麦克风", isOn: $settings.microphone).accessibilityLabel("录制麦克风声音")
                }.toggleStyle(.checkbox)
            }
            formRow("摄像头") {
                Toggle("摄像头画中画", isOn: $settings.recordingCamera)
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("在视频中加入摄像头画中画")
            }
            Text(sourceDescription)
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
    }

    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 24)
    }

    private var sourceDescription: String {
        let audio = settings.systemAudio || settings.microphone ? "声音将写入视频。" : "本次无声音。"
        let camera = settings.recordingCamera ? "画中画将写入视频。" : ""
        return audio + camera + "权限在开始时按需请求。"
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

@MainActor
private struct RecordingScopeButtonStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? NikoTheme.accent : Color.primary)
            .background(selected ? NikoTheme.selection : NikoTheme.raisedSurface.opacity(hovering || configuration.isPressed ? 1 : 0.5),
                        in: RoundedRectangle(cornerRadius: NikoTheme.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: NikoTheme.cornerRadius)
                    .strokeBorder(selected || focused ? NikoTheme.accent : NikoTheme.separator.opacity(0.65),
                                  lineWidth: focused ? 2 : selected ? 1 : 0.5)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(NikoTheme.accent).padding(7).accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: NikoTheme.cornerRadius))
            .onHover { hovering = $0 }
    }
}
