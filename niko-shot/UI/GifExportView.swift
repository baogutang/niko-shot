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
            NikoPageHeader(title: "导出 GIF", subtitle: "调整尺寸和帧率，导出循环播放的动画。", symbol: "photo.stack")
                .padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    NikoPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("输出选项").font(.headline).accessibilityAddTraits(.isHeader)
                            LabeledContent("宽度") {
                                HStack(spacing: 10) {
                                    if maximumWidth > minimumWidth {
                                        Slider(value: widthBinding, in: Double(minimumWidth)...Double(maximumWidth), step: 1)
                                            .accessibilityLabel("GIF 输出宽度")
                                    }
                                    Text("\(outputWidth) px").font(.callout).monospacedDigit()
                                        .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                                }.frame(maxWidth: 290)
                            }.frame(minHeight: 28)
                            LabeledContent("帧率") {
                                Picker("帧率", selection: $settings.gifFPS) {
                                    ForEach([5, 10, 15, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
                                }.pickerStyle(.segmented).labelsHidden().frame(width: 290)
                                    .accessibilityLabel("GIF 帧率")
                            }.frame(minHeight: 28)
                            Text("默认宽度不超过 800 px。较小尺寸和较低帧率可减少体积。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.disabled(isExporting)
                    NikoPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("预计体积").font(.headline)
                                Spacer()
                                Text(sizeDescription).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                            }.accessibilityElement(children: .combine)
                            Divider()
                            HStack(alignment: .top, spacing: 16) {
                                metric("输出尺寸", value: "\(outputWidth) × \(outputHeight) px")
                                Divider().frame(height: 36)
                                metric("时长", value: "\(safeDuration.formatted(.number.precision(.fractionLength(1)))) 秒")
                                Divider().frame(height: 36)
                                metric("预计帧数", value: "\(Int(ceil(safeDuration * Double(outputFPS))))")
                            }
                            Text("实际大小取决于画面内容。GIF 将持续循环播放。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
            Divider()
            VStack(spacing: 14) {
                if isExporting {
                    VStack(alignment: .leading, spacing: 8) {
                        if let progress {
                            HStack {
                                Text("正在导出 GIF").font(.callout)
                                Spacer()
                                Text(min(1, max(0, progress)), format: .percent.precision(.fractionLength(0)))
                                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                            }
                            ProgressView(value: min(1, max(0, progress))).accessibilityLabel("GIF 导出进度")
                        } else {
                            ProgressView("正在处理视频帧…").accessibilityLabel("正在导出 GIF")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button(isExporting ? "取消导出" : "取消", action: onCancel)
                        .keyboardShortcut(.cancelAction).accessibilityLabel(isExporting ? "取消 GIF 导出" : "取消 GIF 设置")
                    Spacer()
                    Button("导出 GIF…") { onExport(GifOptions(width: outputWidth, fps: outputFPS)) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                        .disabled(isExporting || safeDuration == 0).accessibilityLabel("选择保存位置并导出 GIF")
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .background(NikoTheme.canvas)
        .frame(minWidth: 480, idealWidth: 500, minHeight: 470)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
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
