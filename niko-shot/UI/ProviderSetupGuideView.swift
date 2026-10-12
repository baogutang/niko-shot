// Presents verified provider onboarding separately from credentials and connection testing.
import SwiftUI

/// A native, readable walkthrough with official links and a visible verification date.
@MainActor
public struct ProviderSetupGuideView: View {
    private let guide: ProviderSetupGuide
    @Environment(\.dismiss) private var dismiss

    /// Presents the provider's source-verified application, credential and testing steps.
    public init(guide: ProviderSetupGuide) { self.guide = guide }

    /// Loads the provider's current official application and API connection guide.
    public init(provider: TranslationProviderID) { self.guide = ProviderSetupGuide.guide(for: provider) }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                NikoSymbolBadge(symbol: "book.closed", size: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text(guide.title).font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("申请与接入指南 · \(guide.verifiedDate) 核验").font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityLabel("申请与接入指南，官方资料核验日期 \(guide.verifiedDate)")
                }
                Spacer(minLength: 12)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("关闭翻译服务接入指南")
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(guide.summary).font(.body).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(guide.steps) { step in
                            HStack(alignment: .top, spacing: 14) {
                                Text("\(step.id)")
                                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                                    .frame(width: 30, height: 30)
                                    .foregroundStyle(.tint)
                                    .background(Color.accentColor.opacity(0.10), in: Circle())
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(step.title).font(.headline).accessibilityAddTraits(.isHeader)
                                    Text(step.detail).font(.callout).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    if let link = step.link {
                                        Link(destination: link.url) {
                                            Label(link.title, systemImage: "arrow.up.right.square")
                                                .font(.callout.weight(.medium))
                                                .frame(minHeight: 44, alignment: .leading)
                                        }
                                        .accessibilityLabel("打开官方页面：\(link.title)")
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    if !guide.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("接入前确认", systemImage: "info.circle")
                                .font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            ForEach(Array(guide.notes.enumerated()), id: \.offset) { _, note in
                                Text(note).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(NikoTheme.surface, in: RoundedRectangle(cornerRadius: NikoTheme.cornerRadius))
                    }
                    if !guide.links.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("官方资源").font(.subheadline.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                                      alignment: .leading, spacing: 10) {
                                ForEach(guide.links) { link in
                                    Link(destination: link.url) {
                                        Label(link.title, systemImage: "arrow.up.right.square")
                                            .font(.callout).frame(minHeight: 44, alignment: .leading)
                                    }.accessibilityLabel("打开官方资源：\(link.title)")
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 620, height: 620)
        .background(NikoTheme.canvas)
    }
}
