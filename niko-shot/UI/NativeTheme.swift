// Shares adaptive native surfaces, typography and interaction treatments across the application.
import AppKit
import SwiftUI

/// Semantic system colors; the system controls light, dark and increased-contrast appearances.
@MainActor
enum NikoTheme {
    static var canvas: Color { Color(nsColor: .windowBackgroundColor) }
    static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    static var separator: Color { Color(nsColor: .separatorColor) }
    static let cornerRadius: CGFloat = 12
}

/// A quiet symbol tile used to identify a task or a preference category.
@MainActor
struct NikoSymbolBadge: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.28))
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
        HStack(alignment: .center, spacing: 14) {
            NikoSymbolBadge(symbol: symbol, size: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A single elevated content surface without nested boxes or ornamental shadows.
@MainActor
struct NikoPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NikoTheme.surface, in: RoundedRectangle(cornerRadius: NikoTheme.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: NikoTheme.cornerRadius)
                    .strokeBorder(NikoTheme.separator.opacity(0.35), lineWidth: 0.5)
            }
    }
}

/// A compact shortcut hint; it is decoration beside an already labelled action.
@MainActor
struct NikoShortcutHint: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit().foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
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
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(isFocused ? 0.8 : prominent ? 0.18 : 0), lineWidth: isFocused ? 2 : 0.5)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: hovering)
            .onHover { hovering = $0 }
    }

    private func background(pressed: Bool) -> Color {
        if prominent { return Color.accentColor.opacity(pressed ? 0.21 : hovering ? 0.17 : 0.1) }
        return Color.primary.opacity(pressed ? 0.09 : hovering ? 0.055 : 0.025)
    }
}
