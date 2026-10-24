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
  public init(provider: TranslationProviderID) {
    self.guide = ProviderSetupGuide.guide(for: provider)
  }

  public var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(guide.title).font(.system(size: 20, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Text("官方资料核对于 \(guide.verifiedDate)").font(.system(size: 12)).foregroundStyle(
          .secondary
        )
        .accessibilityLabel("申请与接入指南，官方资料核验日期 \(guide.verifiedDate)")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
      Form {
        Section {
          Text(guide.summary).font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
        }
        NikoSection(title: "接入流程") {
          ForEach(guide.steps) { step in
            HStack(alignment: .top, spacing: 12) {
              Text("\(step.id)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(NikoTheme.accent).frame(width: 24, height: 24)
                .background(NikoTheme.selection, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 8) {
                Text(step.title).font(.system(size: 13, weight: .medium))
                  .accessibilityAddTraits(.isHeader)
                Text(step.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let link = step.link {
                  Link(destination: link.url) {
                    Label(link.title, systemImage: "arrow.up.right.square")
                      .font(.system(size: 12))
                      .frame(minHeight: 24, alignment: .leading)
                  }
                  .accessibilityLabel("打开官方页面：\(link.title)")
                }
              }
            }
          }
        }
        if !guide.notes.isEmpty {
          NikoSection(title: "接入前确认") {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(Array(guide.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
        if !guide.links.isEmpty {
          NikoSection(title: "官方资源") {
            ForEach(guide.links) { link in
              Link(destination: link.url) {
                Label(link.title, systemImage: "arrow.up.right.square")
                  .font(.system(size: 12)).frame(minHeight: 24, alignment: .leading)
              }.accessibilityLabel("打开官方资源：\(link.title)")
            }
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .font(.system(size: 13))
      Divider()
      HStack {
        Spacer()
        Button("完成") { dismiss() }
          .keyboardShortcut(.defaultAction)
          .accessibilityLabel("关闭翻译服务接入指南")
      }.padding(.horizontal, 20).padding(.vertical, 12)
    }
    .onExitCommand { dismiss() }
    .frame(width: 580, height: 600)
    .background(NikoTheme.canvas)
    .tint(NikoTheme.accent)
  }
}
