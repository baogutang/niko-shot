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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("输出选项").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        formRow("宽度") {
                            HStack(spacing: 12) {
                                if maximumWidth > minimumWidth {
                                    Slider(value: widthBinding, in: Double(minimumWidth)...Double(maximumWidth), step: 1)
                                        .accessibilityLabel("GIF 输出宽度")
                                }
                                Text("\(outputWidth) px").monospacedDigit()
                                    .foregroundStyle(.secondary).frame(width: 68, alignment: .trailing)
                            }
                        }
                        formRow("帧率") {
                            Picker("帧率", selection: $settings.gifFPS) {
                                ForEach([5, 10, 15, 24, 30], id: \.self) { Text("\($0)").tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("GIF 帧率，每秒帧数")
                        }
                        Text("宽度默认不超过 800 px；降低尺寸或帧率可减小文件。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.disabled(isExporting)
                    Divider()
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("预计体积").foregroundStyle(.secondary)
                            Spacer()
                            Text(sizeDescription).font(.system(size: 20, weight: .medium)).monospacedDigit()
                        }.accessibilityElement(children: .combine)
                        HStack(alignment: .top, spacing: 20) {
                            metric("尺寸", value: "\(outputWidth) × \(outputHeight) px")
                            metric("时长", value: "\(safeDuration.formatted(.number.precision(.fractionLength(1)))) 秒")
                            metric("帧数", value: "\(Int(ceil(safeDuration * Double(outputFPS))))")
                        }
                        Label("循环播放 · 实际体积随画面内容变化", systemImage: "repeat")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(20)
            }
            Divider()
            VStack(spacing: 12) {
                if isExporting {
                    VStack(alignment: .leading, spacing: 8) {
                        if let progress {
                            HStack {
                                Text("正在导出 GIF")
                                Spacer()
                                Text(min(1, max(0, progress)), format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit().foregroundStyle(.secondary)
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
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(isExporting || safeDuration == 0).accessibilityLabel("选择保存位置并导出 GIF")
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .font(.system(size: 13)).controlSize(.regular)
        .background(NikoTheme.canvas)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 340, idealHeight: 380)
    }

    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 24)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13)).monospacedDigit()
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
