import XCTest
@testable import NikoShot

@MainActor
final class TranslationConfigurationTests: XCTestCase {
    func testEachProviderRequiresAllOfItsOwnCredentialsAndNeverUsesAnotherProvidersKey() throws {
        let suite = "niko-shot.configuration-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for provider in TranslationProviderID.allCases where provider != .custom {
            settings.translationProvider = provider
            let accounts = provider.credentialAccounts
            XCTAssertFalse(TranslationConfiguration.isConfigured(settings, credentials: KeychainStore(testValues: [:])))
            let all = Dictionary(uniqueKeysWithValues: accounts.map { ($0, "fixture") })
            XCTAssertTrue(TranslationConfiguration.isConfigured(settings, credentials: KeychainStore(testValues: all)))
            var missing = all
            missing.removeValue(forKey: try XCTUnwrap(accounts.last))
            XCTAssertFalse(TranslationConfiguration.isConfigured(settings, credentials: KeychainStore(testValues: missing)))
            settings.translationProvider = provider == .google ? .baidu : .google
            XCTAssertFalse(TranslationConfiguration.isConfigured(settings, credentials: KeychainStore(testValues: all)))
        }
    }

    func testCustomRequiresTheSelectedInstanceWhileAKeyFreeTemplateRemainsSupported() throws {
        let suite = "niko-shot.custom-configuration-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.translationProvider = .custom
        let protected = try XCTUnwrap(CustomRESTConfiguration.presets.first)
        let local = CustomRESTConfiguration(name: "Local fixture", urlTemplate: "https://example.com/translate",
            bodyTemplate: #"{"q":"$TEXT"}"#, responsePath: "text")
        settings.customTranslationServices = [protected, local]
        let credentials = KeychainStore(testValues: [protected.keyAccount: "fixture"])
        XCTAssertFalse(TranslationConfiguration.isConfigured(settings, credentials: credentials))
        settings.selectedCustomTranslationID = protected.id
        XCTAssertFalse(TranslationConfiguration.isConfigured(settings, credentials: KeychainStore(testValues: [:])))
        XCTAssertTrue(TranslationConfiguration.isConfigured(settings, credentials: credentials))
        settings.selectedCustomTranslationID = local.id
        XCTAssertTrue(TranslationConfiguration.isConfigured(settings, credentials: KeychainStore(testValues: [:])))
        settings.selectedCustomTranslationID = UUID()
        XCTAssertFalse(TranslationConfiguration.isConfigured(settings, credentials: credentials))
    }
}
