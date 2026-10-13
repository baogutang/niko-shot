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
    private let isRestart: Bool
    @State private var mode: ScrollCaptureMode = .manual
    @State private var edge: IgnoredEdge = .top
    @State private var ignoredTop = 0
    @State private var ignoredBottom = 0

    /// Creates a preview without changing Accessibility consent or starting capture.
    init(image: CGImage, scale: CGFloat, automaticAllowed: Bool,
         onStart: @escaping (ScrollCaptureMode, Int, Int) -> Void,
         onOpenAccessibility: @escaping () -> Void, onCancel: @escaping () -> Void,
         initialMode: ScrollCaptureMode = .manual, ignoredTop: Int = 0, ignoredBottom: Int = 0,
         isRestart: Bool = false) {
        self.image = image
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        self.automaticAllowed = automaticAllowed
        self.onStart = onStart
        self.onOpenAccessibility = onOpenAccessibility
        self.onCancel = onCancel
        self.isRestart = isRestart
        _mode = State(initialValue: initialMode)
        let maximum = max(0, image.height - 240)
        let top = min(maximum, max(0, ignoredTop))
        _ignoredTop = State(initialValue: top)
        _ignoredBottom = State(initialValue: min(maximum - top, max(0, ignoredBottom)))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isRestart {
                        Label("应用这些选项会从首屏重新开始，之前的拼接分块不会沿用。", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 12)).foregroundStyle(NikoTheme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Text("滚动方式").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                            Picker("滚动方式", selection: $mode) {
                                ForEach(ScrollCaptureMode.allCases) { item in Text(item.title).tag(item) }
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 210).accessibilityLabel("长截图滚动方式")
                            Spacer()
                        }
                        Text(mode == .automatic
                             ? "自动向下滚动并拼接。窗口可移动，调整尺寸后需重新选择。"
                             : "自行向下滚动，稳定后自动捕获；完成点“结束”。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if mode == .automatic && !automaticAllowed {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Label("未授权，开始后将转为手动滚动。", systemImage: "info.circle")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button("打开权限设置", action: onOpenAccessibility)
                                    .controlSize(.small).accessibilityLabel("打开系统设置的辅助功能权限页面")
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("忽略固定栏").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                            Spacer()
                            Button("重置") { ignoredTop = 0; ignoredBottom = 0 }
                                .controlSize(.small).disabled(ignoredTop == 0 && ignoredBottom == 0)
                                .accessibilityLabel("清除顶部和底部忽略区")
                        }
                        HStack(spacing: 12) {
                            Text("编辑").foregroundStyle(.secondary)
                            Picker("编辑忽略区", selection: $edge) {
                                ForEach(IgnoredEdge.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 250).accessibilityLabel("选择要编辑的固定栏")
                            Spacer()
                        }
                        Text("拖动分界线或输入像素，固定栏将从每帧裁去。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        preview.frame(height: 258)
                        HStack(spacing: 20) {
                            exclusionField("忽略顶部", value: topBinding, maximum: maximumIgnored - ignoredBottom)
                            exclusionField("忽略底部", value: bottomBinding, maximum: maximumIgnored - ignoredTop)
                        }
                        HStack {
                            Text("\(image.width) × \(image.height) px").foregroundStyle(.secondary)
                            Spacer()
                            Label("有效高度 \(usableHeight) px", systemImage: usableHeight >= 240 ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(usableHeight >= 240 ? NikoTheme.accent : Color.red)
                        }.font(.system(size: 12)).monospacedDigit()
                        if image.height < 240 {
                            Text("滚动区域高度至少需要 240 px，请取消后重新框选。")
                                .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.padding(20)
            }
            .background(NikoTheme.surface)
            Divider()
            HStack(spacing: 12) {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction).accessibilityLabel("取消长截图设置")
                Spacer()
                Button(isRestart ? "从首屏重新开始" : "开始长截图") { onStart(mode, ignoredTop, ignoredBottom) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .foregroundStyle(NikoTheme.onAccent)
                    .disabled(usableHeight < 240).accessibilityLabel("使用所选滚动方式和忽略区域开始长截图")
            }.padding(.horizontal, 20).padding(.vertical, 12)
                .background(NikoTheme.raisedSurface.opacity(0.35))
        }
        .font(.system(size: 13)).controlSize(.regular)
        .background(NikoTheme.canvas)
        .tint(NikoTheme.accent)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 640)
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
            Text(title)
            TextField(title, value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit()
                .frame(width: 60).accessibilityLabel("\(title)，原图像素")
            Text("px").font(.system(size: 12)).foregroundStyle(.secondary)
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
            .overlay(RoundedRectangle(cornerRadius: NikoTheme.cornerRadius).strokeBorder(NikoTheme.separator.opacity(0.45), lineWidth: 0.5))
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
        Rectangle().fill(NikoTheme.accent.opacity(0.28)).frame(height: height)
            .overlay {
                if height >= 22 {
                    Text("忽略 \(count) px").font(.caption.weight(.medium)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.regularMaterial, in: Capsule())
                }
            }
    }

    private func boundary(width: CGFloat, active: Bool) -> some View {
        Rectangle().fill(active ? NikoTheme.accent : Color.primary.opacity(0.5)).frame(width: width, height: 2)
            .overlay {
                Capsule().fill(active ? NikoTheme.accent : Color.secondary).frame(width: 28, height: 5)
            }
    }
}

private enum IgnoredEdge: String, CaseIterable, Identifiable {
    case top, bottom
    var id: String { rawValue }
    var title: String { self == .top ? "顶部固定栏" : "底部固定栏" }
}
