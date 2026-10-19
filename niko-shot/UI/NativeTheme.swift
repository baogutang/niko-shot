// Shares adaptive native surfaces, typography and interaction treatments across the application.
// Design language: light = 纸间 Print Shop (warm paper, cinnabar accent),
// dark = 墨 Ink (deep ink, turmeric accent); one accent per appearance.
import AppKit
import SwiftUI

/// Adaptive brand surfaces; the palette follows the niko-shot paper-and-ink identity.
@MainActor
enum NikoTheme {
  /// 纸本 #F3EDE2 / 深墨 #121417 — window canvas.
  static var canvas: Color {
    adaptive(light: (0.952941, 0.929412, 0.886275), dark: (0.070588, 0.078431, 0.090196))
  }
  /// 冲印纸 #FBF8F2 / 墨面 #1E2226 — cards and panels.
  static var surface: Color {
    adaptive(light: (0.984314, 0.972549, 0.949020), dark: (0.117647, 0.133333, 0.149020))
  }
  /// 纸白 #FFFDF7 / 墨台 #262B30 — raised controls resting on surface.
  static var raisedSurface: Color {
    adaptive(light: (1.000000, 0.992157, 0.968627), dark: (0.149020, 0.168627, 0.188235))
  }
  /// 朱砂 #C8402F / 藤黄 #F2B33D — the single accent: primary actions, selection, readings.
  static var accent: Color {
    adaptive(light: (0.784314, 0.250980, 0.184314), dark: (0.949020, 0.701961, 0.239216))
  }
  static var onAccent: Color {
    adaptive(light: (0.992157, 0.968627, 0.941176), dark: (0.133333, 0.094118, 0.015686))
  }
  static var selection: Color { accent.opacity(0.12) }
  /// 暖纸发丝线 #E2D9C6 / 墨缝线 #2A2D32 — hairline separators.
  static var separator: Color {
    adaptive(light: (0.886275, 0.850980, 0.776471), dark: (0.164706, 0.176471, 0.196078))
  }
  /// 青瓷 #2F5D62 / 花青 #5FB3A1 — reserved for translated text and connection success.
  static var translation: Color {
    adaptive(light: (0.184314, 0.364706, 0.384314), dark: (0.372549, 0.701961, 0.631373))
  }
  /// 朱砂印 #C8402F / 朱砂 #CE3527 — seals and recording state only; dark value keeps 3:1 on ink surfaces.
  static var seal: Color {
    adaptive(light: (0.784314, 0.250980, 0.184314), dark: (0.807843, 0.207843, 0.152941))
  }
  static let cornerRadius: CGFloat = 10

  private nonisolated static func adaptive(
    light: (Double, Double, Double), dark: (Double, Double, Double)
  ) -> Color {
    // AppKit and SwiftUI resolve dynamic colors on drawing threads, not only the main actor.
    Color(nsColor: NSColor(name: nil) { @Sendable appearance in
      let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
    })
  }
}

/// AppKit-side brand accent for overlay layers and custom drawing; resolves with current appearance.
nonisolated enum NikoAccent {
  static let nsColor = NSColor(name: nil) { appearance in
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return dark ? NSColor(srgbRed: 0.949020, green: 0.701961, blue: 0.239216, alpha: 1)
      : NSColor(srgbRed: 0.784314, green: 0.250980, blue: 0.184314, alpha: 1)
  }
}

/// A quiet symbol tile used to identify a task or a preference category.
@MainActor
struct NikoSymbolBadge: View {
  let symbol: String
  var tint: Color = NikoTheme.accent
  var size: CGFloat = 24

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.54, weight: .medium))
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.25))
      .accessibilityHidden(true)
  }
}

/// Consistent page identity with a readable title and a short purpose statement.
@MainActor
struct NikoPageHeader: View {
  let title: String
  let subtitle: String
  let symbol: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      NikoSymbolBadge(symbol: symbol, size: 28)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 20, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        if !subtitle.isEmpty {
          Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A single elevated content surface without nested boxes or ornamental shadows.
@MainActor
struct NikoPanel<Content: View>: View {
  private let content: Content
  @Environment(\.colorSchemeContrast) private var contrast

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    content.padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(NikoTheme.surface, in: RoundedRectangle(cornerRadius: NikoTheme.cornerRadius))
      .overlay {
        RoundedRectangle(cornerRadius: NikoTheme.cornerRadius)
          .strokeBorder(
            NikoTheme.separator.opacity(contrast == .increased ? 1 : 0.5),
            lineWidth: contrast == .increased ? 1 : 0.5)
      }
  }
}

/// A native grouped-form section, without a second decorative container.
@MainActor
struct NikoSection<Content: View>: View {
  let title: String
  let footer: String?
  private let content: Content

  init(title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    Section {
      content
    } header: {
      Text(title).font(.system(size: 12, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
    } footer: {
      if let footer {
        Text(footer).font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// Aligns preference labels and controls at a consistent text baseline.
@MainActor
struct NikoPreferenceRow<Content: View>: View {
  let title: String
  let detail: String?
  let labelWidth: CGFloat
  private let content: Content

  init(
    title: String, detail: String? = nil, labelWidth: CGFloat = 130,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.detail = detail
    self.labelWidth = labelWidth
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
      }
      .frame(width: labelWidth, alignment: .leading)
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        content
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: 13))
    .frame(minHeight: 28)
  }
}

/// A compact shortcut hint; it is decoration beside an already labelled action.
@MainActor
struct NikoShortcutHint: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 11, weight: .medium))
      .monospacedDigit().foregroundStyle(.secondary)
      .padding(.horizontal, 6).padding(.vertical, 3)
      .background(NikoTheme.surface, in: RoundedRectangle(cornerRadius: 4))
      .overlay {
        RoundedRectangle(cornerRadius: 4).strokeBorder(
          NikoTheme.separator.opacity(0.6), lineWidth: 0.5)
      }
      .accessibilityHidden(true)
  }
}

/// A compact empty state that identifies the next useful action without oversized decoration.
@MainActor
struct NikoEmptyState: View {
  let title: String
  let symbol: String
  let detail: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.system(size: 28, weight: .light))
        .foregroundStyle(NikoTheme.accent.opacity(0.7)).accessibilityHidden(true)
      Text(title).font(.system(size: 15, weight: .medium))
      Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 280)
    }
    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Subtle native hover and press feedback for the task launcher; keyboard focus stays visible.
@MainActor
struct NikoActionButtonStyle: ButtonStyle {
  var prominent = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(RoundedRectangle(cornerRadius: 6))
      .background(
        background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 6)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(
            NikoTheme.accent.opacity(isFocused ? 0.8 : prominent ? 0.28 : 0),
            lineWidth: isFocused ? 2 : 0.5)
      }
      .opacity(isEnabled ? 1 : 0.45)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: configuration.isPressed)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: hovering)
      .onHover { hovering = $0 }
  }

  private func background(pressed: Bool) -> Color {
    if prominent { return NikoTheme.accent.opacity(pressed ? 0.21 : hovering ? 0.17 : 0.1) }
    return Color.primary.opacity(pressed ? 0.09 : hovering ? 0.055 : 0)
  }
}
