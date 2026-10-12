// Exports the application's checked official guides into the static public website.
import CryptoKit
import Foundation

@main
struct GenerateWebsiteGuide {
    static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func anchor(_ link: ProviderSetupGuide.Link) -> String {
        "<a href=\"\(escaped(link.url.absoluteString))\">\(escaped(link.title)) <svg aria-hidden=\"true\"><use href=\"assets/icons.svg#arrow-up-right\"></use></svg></a>"
    }

    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let guides = TranslationProviderID.allCases.map { ProviderSetupGuide.guide(for: $0) }
        let cards = guides.map { guide in
            let steps = guide.steps.map { step in
                "<div class=\"guide-step\"><h3>\(step.id). \(escaped(step.title))</h3><p>\(escaped(step.detail))</p>\(step.link.map(anchor) ?? "")</div>"
            }.joined(separator: "\n")
            let notes = guide.notes.map { "<p>\(escaped($0))</p>" }.joined(separator: "\n")
            let links = guide.links.map(anchor).joined(separator: "\n")
            return """
            <section class="guide-card" id="\(guide.provider.rawValue)" aria-labelledby="title-\(guide.provider.rawValue)">
              <h2 id="title-\(guide.provider.rawValue)">\(escaped(guide.title))</h2>
              <p class="guide-summary">\(escaped(guide.summary))</p>
              <p class="credential-kind">所需凭据 · \(escaped(guide.credentialLabels.joined(separator: " / ")))</p>
              <div class="guide-steps">\(steps)</div>
              <div class="guide-note" aria-label="接入注意事项">\(notes)</div>
              <h3 class="guide-subheading">官方入口</h3><div class="guide-step official-links">\(links)</div>
            </section>
            """
        }.joined(separator: "\n")
        let navigation = guides.map { "<a href=\"#\($0.provider.rawValue)\">\(escaped($0.provider.displayName))</a>" }.joined()
        let date = guides[0].verifiedDate
        let html = """
        <!doctype html>
        <!-- Generated from ProviderSetupGuide.swift. Run the committed generator after changing official guides. -->
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="light dark">
          <title>翻译接入指南 | niko-shot</title>
          <meta name="description" content="百度、Google Cloud、有道、DeepL、彩云与 LibreTranslate 的官方申请入口、凭据类型和配置步骤。与 niko-shot 应用内指南同步。">
          <link rel="canonical" href="https://baogutang.github.io/niko-shot/guide.html">
          <link rel="icon" type="image/png" href="assets/app-icon.png"><link rel="stylesheet" href="styles.css"><script src="site.js" defer></script>
        </head>
        <body>
          <a class="skip-link" href="#main">跳到主要内容</a>
          <header class="site-header"><nav class="nav-shell" aria-label="主导航">
            <a class="wordmark" href="./" aria-label="niko-shot 首页"><img src="assets/app-icon.png" width="36" height="36" alt=""><span>niko-shot</span></a>
            <div class="nav-links"><a href="./#experience">体验</a><a href="./#workflow">功能</a><a href="guide.html" aria-current="page">接入指南</a></div>
            <div class="nav-actions"><button class="icon-button theme-toggle" aria-label="切换明暗外观" title="切换明暗外观"><svg aria-hidden="true"><use href="assets/icons.svg#sun"></use></svg></button><a class="icon-button github-link" href="https://github.com/baogutang/niko-shot" aria-label="查看 GitHub 仓库"><svg aria-hidden="true"><use href="assets/icons.svg#brand-github"></use></svg></a><a class="button nav-download" href="./#download">下载 <svg aria-hidden="true"><use href="assets/icons.svg#arrow-up-right"></use></svg></a></div>
          </nav></header>
          <main id="main" class="shell">
            <div class="guide-hero"><p class="eyebrow">连接你的翻译服务</p><h1>申请清楚。<br>配置顺手。</h1><p>选择服务，按步骤开通 API、填入凭据，再在应用里测试连接。所有申请入口均指向各家官方平台。</p><p class="verified-date">官方公开文档核对日期：\(date) · 与应用内指南使用同一份源数据。</p></div>
            <div class="guide-layout"><nav class="guide-nav" aria-label="翻译服务目录">\(navigation)</nav><div>
              \(cards)
              <p class="guide-footer-note">本页只提供说明与导航，不读取或提交密钥。真实账号连通性仍需你在应用内验证；认证、服务状态、套餐和额度以官方账户当前信息为准。更多模板示例见 <a href="https://github.com/baogutang/niko-shot/blob/main/docs/TRANSLATION.md">翻译配置文档</a>。</p>
            </div></div>
          </main>
          <footer class="site-footer shell"><div><a class="wordmark" href="./"><img src="assets/app-icon.png" width="28" height="28" alt=""><span>niko-shot</span></a><p>为你的下一张截图而做。</p></div><div class="footer-links"><a href="https://github.com/baogutang/niko-shot">GitHub</a><a href="guide.html">接入指南</a><a href="https://github.com/baogutang/niko-shot/issues">反馈问题</a></div><small>© 2026 niko-shot</small></footer>
        </body></html>
        """
        try (html + "\n").write(to: root.appendingPathComponent("website/guide.html"), atomically: true, encoding: .utf8)
        let sourcePath = "niko-shot/Core/Translate/ProviderSetupGuide.swift"
        let sourceData = try Data(contentsOf: root.appendingPathComponent(sourcePath))
        let sourceHash = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = [
            "source": sourcePath, "sourceSHA256": sourceHash, "verifiedDate": date,
            "providers": guides.map { guide -> [String: Any] in
                ["id": guide.provider.rawValue, "title": guide.title,
                 "stepCount": guide.steps.count,
                 "officialURLs": guide.links.map { $0.url.absoluteString }]
            }
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try json.write(to: root.appendingPathComponent("website/guide-data.json"), options: .atomic)
    }
}
