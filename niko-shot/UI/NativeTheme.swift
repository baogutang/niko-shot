// Shares adaptive native surfaces, typography and interaction treatments across the application.
import AppKit
import SwiftUI

/// Warm, adaptive surfaces; text and separators retain native system contrast behavior.
@MainActor
enum NikoTheme {
  static var canvas: Color {
    adaptive(light: (0.965, 0.960, 0.949), dark: (0.095, 0.099, 0.108))
  }
  static var surface: Color {
    adaptive(light: (1.000, 0.997, 0.987), dark: (0.135, 0.140, 0.150))
  }
  static var raisedSurface: Color {
    adaptive(light: (0.945, 0.937, 0.923), dark: (0.175, 0.180, 0.190))
  }
  static var accent: Color {
    adaptive(light: (0.620, 0.380, 0.105), dark: (0.955, 0.705, 0.365))
  }
  static var onAccent: Color {
    adaptive(light: (1.000, 1.000, 1.000), dark: (0.115, 0.100, 0.075))
  }
  static var selection: Color { accent.opacity(0.12) }
  static var separator: Color { Color(nsColor: .separatorColor) }
  static let cornerRadius: CGFloat = 10

  private static func adaptive(
    light: (Double, Double, Double), dark: (Double, Double, Double)
  ) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
    })
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
    return Color.primary.opacity(pressed ? 0.09 : hovering ? 0.055 : 0.025)
  }
}
