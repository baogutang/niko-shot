// Shares surfaces, typography and interaction treatments across the application.
// Surfaces are the system's own colors so every window reads as part of macOS; the one brand
// color is the amber from the app icon.
import AppKit
import SwiftUI

/// Native surfaces plus the single icon-amber accent.
@MainActor
enum NikoTheme {
  static var canvas: Color { Color(nsColor: .windowBackgroundColor) }
  static var surface: Color { Color(nsColor: .controlBackgroundColor) }
  static var raisedSurface: Color { Color(nsColor: .textBackgroundColor) }
  /// Icon amber #E8A333 in dark mode; a deeper #AD7111 in light mode keeps glyphs and text legible on white.
  static var accent: Color { Color(nsColor: NikoAccent.nsColor) }
  /// Ink on amber in both appearances: amber is too light to carry white text.
  static var onAccent: Color {
    adaptive(light: (0.109804, 0.090196, 0.062745), dark: (0.109804, 0.090196, 0.062745))
  }
  static var selection: Color { accent.opacity(0.14) }
  static var separator: Color { Color(nsColor: .separatorColor) }
  /// Translated text: the system teal, so it reads as "different" without a second brand color.
  static var translation: Color { Color(nsColor: .systemTeal) }
  /// Recording state only.
  static var seal: Color { Color(nsColor: .systemRed) }
  static let cornerRadius: CGFloat = 8

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

/// AppKit-side brand accent for custom drawing; resolves with the current appearance.
nonisolated enum NikoAccent {
  static let nsColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? bright
      : NSColor(srgbRed: 0.678431, green: 0.443137, blue: 0.066667, alpha: 1)
  }
  /// The icon amber, unchanged by appearance: capture overlays and HUDs sit on arbitrary pixels
  /// or dark glass, never on a light window.
  static let bright = NSColor(srgbRed: 0.909804, green: 0.639216, blue: 0.2, alpha: 1)
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
      Text(title).accessibilityAddTraits(.isHeader)
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

/// A compact empty state that identifies the next useful action without oversized decoration.
@MainActor
struct NikoEmptyState: View {
  let title: String
  let symbol: String
  let detail: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.system(size: 28, weight: .light))
        .foregroundStyle(.tertiary).accessibilityHidden(true)
      Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
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
