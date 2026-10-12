// Checks onboarding navigation against the credential and API scopes accepted by the app.
import Foundation
import XCTest
@testable import NikoShot

final class ProviderSetupGuideTests: XCTestCase {
    func testEveryIntegrationHasCompleteDistinctNavigationAndResolvableSteps() throws {
        let guides = TranslationProviderID.allCases.map(ProviderSetupGuide.guide(for:))
        XCTAssertEqual(Set(guides.map(\.provider)), Set(TranslationProviderID.allCases))

        for guide in guides {
            XCTAssertFalse(guide.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(guide.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(guide.steps.map(\.id), [1, 2, 3],
                           "The settings sheet presents application, credential entry and connection testing.")
            XCTAssertFalse(guide.notes.isEmpty, guide.provider.rawValue)
            XCTAssertEqual(Set(guide.links.map(\.id)).count, guide.links.count)
            XCTAssertEqual(Set(guide.steps.map(\.id)).count, guide.steps.count)
            XCTAssertEqual(guide.steps.map(\.id), guide.steps.map(\.id).sorted())
            for role in ["product", "console", "docs"] {
                XCTAssertNotNil(guide.links.first { $0.id == role }, "\(guide.provider): \(role)")
            }
            if guide.provider != .custom {
                XCTAssertEqual(guide.credentialLabels.count, guide.provider.credentialAccounts.count,
                               "The guide must cover every credential the selected adapter requires.")
            }
            for step in guide.steps {
                XCTAssertFalse(step.title.isEmpty)
                XCTAssertFalse(step.detail.isEmpty)
                if let destination = step.link {
                    let listed = try XCTUnwrap(guide.links.first { $0.id == destination.id })
                    XCTAssertEqual(destination.url, listed.url,
                                   "A step must resolve to the destination shown in the guide's navigation.")
                    XCTAssertEqual(destination.title, listed.title)
                }
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            XCTAssertNotNil(formatter.date(from: guide.verifiedDate))
        }
    }

    func testEveryDestinationIsAnOfficialHTTPSPageWithoutCredentialsOrAPIRequests() throws {
        let allowedHosts: [TranslationProviderID: Set<String>] = [
            .baidu: ["fanyi-api.baidu.com"],
            .google: ["cloud.google.com", "docs.cloud.google.com", "console.cloud.google.com"],
            .youdao: ["ai.youdao.com"],
            .deepl: ["www.deepl.com", "developers.deepl.com", "support.deepl.com"],
            .custom: ["libretranslate.com", "portal.libretranslate.com", "docs.libretranslate.com",
                      "platform.caiyunapp.com", "docs.caiyunapp.com"]
        ]
        let secretQueryNames: Set<String> = [
            "key", "api_key", "apikey", "token", "secret", "password", "sign", "access_token", "auth_key"
        ]
        for provider in TranslationProviderID.allCases {
            let hosts = try XCTUnwrap(allowedHosts[provider])
            for link in ProviderSetupGuide.guide(for: provider).links {
                let components = try XCTUnwrap(URLComponents(url: link.url, resolvingAgainstBaseURL: false))
                XCTAssertEqual(components.scheme, "https", link.id)
                let host = try XCTUnwrap(components.host)
                XCTAssertTrue(hosts.contains(host), "\(provider): \(host)")
                XCTAssertNil(components.user)
                XCTAssertNil(components.password)
                XCTAssertNil(components.port)
                XCTAssertFalse(link.title.isEmpty)
                XCTAssertFalse(link.url.absoluteString.contains("$"))
                for item in components.queryItems ?? [] {
                    XCTAssertFalse(secretQueryNames.contains(item.name.lowercased()), link.id)
                }
                // Exact host allowlists exclude request hosts such as api.deepl.com and api.interpreter.caiyunai.com.
                // These links are account/documentation navigation, so clicking one cannot submit a translation.
            }
        }
    }

    func testClassicProviderGuidesNavigateToTheInterfacesAcceptedByTheirAdapters() throws {
        let baidu = ProviderSetupGuide.guide(for: .baidu)
        XCTAssertEqual(try destination("product", in: baidu).path, "/product/11",
                       "Baidu general translation must not send users to the large-model product.")
        XCTAssertEqual(try destination("docs", in: baidu).path, "/doc/21",
                       "Use the public general-translation reference, not an internal developer variant.")

        let google = ProviderSetupGuide.guide(for: .google)
        XCTAssertEqual(try destination("docs", in: google).path, "/translate/docs/reference/rest/v2/translate",
                       "The app accepts a Basic v2 API Key, not Advanced v3 authentication.")
        let enable = try XCTUnwrap(URLComponents(url: destination("enable-api", in: google),
                                                resolvingAgainstBaseURL: false))
        XCTAssertEqual(enable.queryItems?.first { $0.name == "apiid" }?.value, "translate.googleapis.com")
        XCTAssertEqual(try destination("console", in: google).path, "/apis/credentials")

        let youdao = ProviderSetupGuide.guide(for: .youdao)
        XCTAssertEqual(try destination("docs", in: youdao).path, "/DOCSIRMA/html/trans/api/wbfy/index.html")
        XCTAssertEqual(try destination("console", in: youdao).path, "/console")
    }

    func testDeepLApplicationAndKeyManagementStayWithinTheAPIProduct() throws {
        let guide = ProviderSetupGuide.guide(for: .deepl)
        XCTAssertEqual(try destination("product", in: guide).path, "/en/developers")
        XCTAssertEqual(try destination("console", in: guide).path, "/en/your-account/keys")
        XCTAssertEqual(try destination("api-plans", in: guide).host, "support.deepl.com")
        XCTAssertTrue(try destination("api-plans", in: guide).path.hasSuffix("DeepL-API-plans"))
        let applicationStep = try XCTUnwrap(guide.steps.first)
        XCTAssertEqual(applicationStep.link?.id, "api-plans",
                       "New applicants need current API-plan eligibility before choosing a subscription.")
        XCTAssertFalse(guide.links.contains { ["/pro", "/en/pro", "/en/pro-api"].contains($0.url.path) },
                       "A generic Translator pricing redirect is not an API application instruction.")
    }

    func testCustomServicesSeparateCaiyunHostedLibreAndSelfHostedAdministration() throws {
        let guide = ProviderSetupGuide.guide(for: .custom)
        let caiyunConsole = try destination("console", in: guide)
        XCTAssertEqual(caiyunConsole.host, "platform.caiyunapp.com")
        XCTAssertEqual(try destination("caiyun-docs", in: guide).path, "/lingocloud-api/index.html")

        let hosted = try destination("libretranslate-hosted-keys", in: guide)
        let selfHosted = try destination("libretranslate-self-host", in: guide)
        let localKeys = try destination("libretranslate-key-management", in: guide)
        XCTAssertEqual(hosted.host, "portal.libretranslate.com")
        XCTAssertEqual(selfHosted.host, "docs.libretranslate.com")
        XCTAssertEqual(selfHosted.path, "/guides/installation")
        XCTAssertEqual(localKeys.path, "/guides/manage_api_keys")
        XCTAssertNotEqual(hosted, localKeys,
                          "Official hosted credentials and self-hosted administrator keys have separate issuers.")
        XCTAssertEqual(guide.steps.first?.link?.id, "caiyun-docs")
        XCTAssertEqual(guide.steps.last?.link?.id, "docs")
    }

    private func destination(_ id: String, in guide: ProviderSetupGuide) throws -> URL {
        try XCTUnwrap(guide.links.first { $0.id == id }?.url, "\(guide.provider.rawValue): \(id)")
    }
}
