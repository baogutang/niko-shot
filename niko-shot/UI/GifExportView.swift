// Configures ImageIO GIF export with source-aware dimensions and an honest size estimate.
import Foundation
import SwiftUI

/// Native GIF options and optional coordinator-driven export progress.
@MainActor
struct GifExportView: View {
    @Bindable private var settings: AppSettings
    private let duration: Double
    private let sourceSize: CGSize
    private let isExporting: Bool
    private let progress: Double?
    private let onExport: (GifOptions) -> Void
    private let onCancel: () -> Void

    /// Creates an export form; the coordinator controls the destination and active task.
    init(settings: AppSettings = .shared, duration: Double, sourceSize: CGSize,
         isExporting: Bool = false, progress: Double? = nil,
         onExport: @escaping (GifOptions) -> Void, onCancel: @escaping () -> Void) {
        self.settings = settings
        self.duration = duration
        self.sourceSize = sourceSize
        self.isExporting = isExporting
        self.progress = progress
        self.onExport = onExport
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "photo.stack").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("导出 GIF").font(.title2.weight(.semibold))
                    Text("循环播放，可调整尺寸和帧率。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Form {
                Section("输出选项") {
                    LabeledContent("宽度") {
                        if maximumWidth > minimumWidth {
                            Slider(value: widthBinding, in: Double(minimumWidth)...Double(maximumWidth), step: 1)
                                .frame(width: 170).accessibilityLabel("GIF 输出宽度")
                        }
                        Text("\(outputWidth) px").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                    Picker("帧率", selection: $settings.gifFPS) {
                        ForEach([5, 10, 15, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }.accessibilityLabel("GIF 帧率")
                    Text("默认宽度不超过 800 px。较低帧率和更小尺寸可以明显减少体积。")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(isExporting)
                Section("预览信息") {
                    LabeledContent("输出尺寸", value: "\(outputWidth) × \(outputHeight) px").monospacedDigit()
                    LabeledContent("时长", value: "\(safeDuration.formatted(.number.precision(.fractionLength(1)))) 秒").monospacedDigit()
                    LabeledContent("预计帧数", value: "\(Int(ceil(safeDuration * Double(outputFPS))))").monospacedDigit()
                    LabeledContent("预计体积", value: sizeDescription).monospacedDigit()
                    Text("体积为估算值，实际大小取决于画面内容。GIF 将持续循环播放。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isExporting {
                    Section("正在导出") {
                        if let progress {
                            ProgressView(value: min(1, max(0, progress))).accessibilityLabel("GIF 导出进度")
                            Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        } else {
                            ProgressView("正在处理视频帧…").accessibilityLabel("正在导出 GIF")
                        }
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button(isExporting ? "取消导出" : "取消", action: onCancel)
                    .keyboardShortcut(.cancelAction).accessibilityLabel(isExporting ? "取消 GIF 导出" : "取消 GIF 设置")
                Spacer()
                Button("导出 GIF…") { onExport(GifOptions(width: outputWidth, fps: outputFPS)) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isExporting || safeDuration == 0).accessibilityLabel("选择保存位置并导出 GIF")
            }.padding(20)
        }
        .frame(minWidth: 480, idealWidth: 500, minHeight: 470)
    }

    private var safeDuration: Double { duration.isFinite ? max(0, duration) : 0 }
    private var maximumWidth: Int {
        guard sourceSize.width.isFinite, sourceSize.width > 0 else { return 800 }
        return Int(min(4096, max(1, sourceSize.width.rounded())))
    }
    private var minimumWidth: Int { min(64, maximumWidth) }
    private var outputWidth: Int { min(maximumWidth, max(minimumWidth, settings.gifWidth)) }
    private var outputHeight: Int {
        guard sourceSize.width.isFinite, sourceSize.height.isFinite, sourceSize.width > 0, sourceSize.height > 0 else { return max(1, outputWidth * 9 / 16) }
        let height = (Double(outputWidth) * sourceSize.height / sourceSize.width).rounded()
        guard height.isFinite else { return max(1, outputWidth * 9 / 16) }
        return Int(min(32768, max(1, height)))
    }
    private var outputFPS: Int { min(30, max(1, settings.gifFPS)) }
    private var widthBinding: Binding<Double> {
        Binding(get: { Double(outputWidth) }, set: { settings.gifWidth = Int($0.rounded()) })
    }
    private var sizeDescription: String {
        let bytes = GifExporter.estimateBytes(duration: safeDuration, fps: outputFPS, width: outputWidth, height: outputHeight)
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
