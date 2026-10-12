// Configures scroll capture and full-width fixed-band exclusions without requesting permissions.
import AppKit
import SwiftUI

/// Native preflight preview; exclusions are always measured in the original image's pixels.
@MainActor
struct ScrollSetupView: View {
    private let image: CGImage
    private let scale: CGFloat
    private let automaticAllowed: Bool
    private let onStart: (ScrollCaptureMode, Int, Int) -> Void
    private let onOpenAccessibility: () -> Void
    private let onCancel: () -> Void
    @State private var mode: ScrollCaptureMode = .automatic
    @State private var edge: IgnoredEdge = .top
    @State private var ignoredTop = 0
    @State private var ignoredBottom = 0

    /// Creates a preview without changing Accessibility consent or starting capture.
    init(image: CGImage, scale: CGFloat, automaticAllowed: Bool,
         onStart: @escaping (ScrollCaptureMode, Int, Int) -> Void,
         onOpenAccessibility: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.image = image
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        self.automaticAllowed = automaticAllowed
        self.onStart = onStart
        self.onOpenAccessibility = onOpenAccessibility
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            NikoPageHeader(title: "滚动长截图", subtitle: "选定滚动方式，排除页面的固定栏。", symbol: "arrow.down.document")
                .padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    NikoPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("滚动方式").font(.headline).accessibilityAddTraits(.isHeader)
                            Picker("滚动方式", selection: $mode) {
                                ForEach(ScrollCaptureMode.allCases) { item in Text(item.title).tag(item) }
                            }.pickerStyle(.segmented).accessibilityLabel("长截图滚动方式")
                            Text(mode == .automatic
                                 ? "工具会自动向下滚动，请保持窗口位置并等待捕获完成。"
                                 : "请自行向下滚动，画面稳定后会自动捕获；完成时请点结束。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if mode == .automatic && !automaticAllowed {
                                Divider()
                                Label("尚未授予辅助功能权限。开始后将转为手动滚动。", systemImage: "info.circle")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("打开辅助功能设置", action: onOpenAccessibility)
                                    .accessibilityLabel("打开系统设置的辅助功能权限页面")
                            }
                        }
                    }
                    NikoPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("忽略固定栏").font(.headline).accessibilityAddTraits(.isHeader)
                            HStack {
                                Picker("编辑忽略区", selection: $edge) {
                                    ForEach(IgnoredEdge.allCases) { Text($0.title).tag($0) }
                                }.pickerStyle(.segmented).frame(width: 210).accessibilityLabel("选择要编辑的固定栏")
                                Spacer()
                                Button("重置") { ignoredTop = 0; ignoredBottom = 0 }
                                    .disabled(ignoredTop == 0 && ignoredBottom == 0)
                                    .accessibilityLabel("清除顶部和底部忽略区")
                            }
                            Text("选择顶部或底部，然后在预览中拖动分界线。高亮区域会从每一帧中裁去。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            preview.frame(height: 244)
                            HStack(spacing: 16) {
                                exclusionField("忽略顶部", value: topBinding, maximum: maximumIgnored - ignoredBottom)
                                exclusionField("忽略底部", value: bottomBinding, maximum: maximumIgnored - ignoredTop)
                            }
                            HStack {
                                Text("原图 \(image.width) × \(image.height) px").foregroundStyle(.secondary)
                                Spacer()
                                Label("有效高度 \(usableHeight) px", systemImage: usableHeight >= 240 ? "checkmark.circle" : "exclamationmark.circle")
                                    .foregroundStyle(usableHeight >= 240 ? Color.secondary : Color.red)
                            }.font(.caption).monospacedDigit()
                            if image.height < 240 {
                                Text("滚动区域高度至少需要 240 px，请取消后重新框选。")
                                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            Divider()
            HStack(spacing: 12) {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction).accessibilityLabel("取消长截图设置")
                Spacer()
                Button("开始长截图") { onStart(mode, ignoredTop, ignoredBottom) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(usableHeight < 240).accessibilityLabel("使用所选滚动方式和忽略区域开始长截图")
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .background(NikoTheme.canvas)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 620, idealHeight: 740)
    }

    private var maximumIgnored: Int { max(0, image.height - 240) }
    private var usableHeight: Int { image.height - ignoredTop - ignoredBottom }
    private var topBinding: Binding<Int> {
        Binding(get: { ignoredTop }, set: { ignoredTop = min(maximumIgnored - ignoredBottom, max(0, $0)) })
    }
    private var bottomBinding: Binding<Int> {
        Binding(get: { ignoredBottom }, set: { ignoredBottom = min(maximumIgnored - ignoredTop, max(0, $0)) })
    }

    private func exclusionField(_ title: String, value: Binding<Int>, maximum: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.callout)
            TextField(title, value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit()
                .frame(width: 60).accessibilityLabel("\(title)，原图像素")
            Text("px").font(.caption).foregroundStyle(.secondary)
            Stepper(title, value: value, in: 0...max(0, maximum)).labelsHidden()
                .accessibilityLabel("调整\(title)像素数")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var preview: some View {
        GeometryReader { geometry in
            let aspect = CGFloat(image.width) / CGFloat(image.height)
            let width = min(geometry.size.width, geometry.size.height * aspect)
            let height = width / aspect
            let top = CGFloat(ignoredTop) / CGFloat(image.height) * height
            let bottom = CGFloat(ignoredBottom) / CGFloat(image.height) * height
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: scale, orientation: .up)
                    .resizable().interpolation(.high).frame(width: width, height: height)
                if ignoredTop > 0 { ignoredBand(height: top, count: ignoredTop).frame(maxHeight: .infinity, alignment: .top) }
                if ignoredBottom > 0 {
                    ignoredBand(height: bottom, count: ignoredBottom).offset(y: height - bottom)
                }
                boundary(width: width, active: edge == .top).offset(y: top)
                boundary(width: width, active: edge == .bottom).offset(y: height - bottom)
            }
            .frame(width: width, height: height).background(NikoTheme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: NikoTheme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: NikoTheme.cornerRadius).strokeBorder(NikoTheme.separator.opacity(0.45)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                guard height > 0 else { return }
                let distance = Int((min(1, max(0, event.location.y / height)) * CGFloat(image.height)).rounded())
                if edge == .top { topBinding.wrappedValue = distance }
                else { bottomBinding.wrappedValue = image.height - distance }
            })
            .onHover { NSCursor.crosshair.set(); if !$0 { NSCursor.arrow.set() } }
            .onDisappear { NSCursor.arrow.set() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("固定栏预览。顶部忽略 \(ignoredTop) 像素，底部忽略 \(ignoredBottom) 像素，有效高度 \(usableHeight) 像素。可在下方输入数值。")
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    private func ignoredBand(height: CGFloat, count: Int) -> some View {
        Rectangle().fill(Color.accentColor.opacity(0.28)).frame(height: height)
            .overlay {
                if height >= 22 {
                    Text("忽略 \(count) px").font(.caption.weight(.medium)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.regularMaterial, in: Capsule())
                }
            }
    }

    private func boundary(width: CGFloat, active: Bool) -> some View {
        Rectangle().fill(active ? Color.accentColor : Color.primary.opacity(0.5)).frame(width: width, height: 2)
            .overlay {
                Capsule().fill(active ? Color.accentColor : Color.secondary).frame(width: 28, height: 5)
            }
    }
}

private enum IgnoredEdge: String, CaseIterable, Identifiable {
    case top, bottom
    var id: String { rawValue }
    var title: String { self == .top ? "顶部固定栏" : "底部固定栏" }
}
