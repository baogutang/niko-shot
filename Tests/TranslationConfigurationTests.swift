import AppKit
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

    func testInlinePickersOfferOnlyReadyServicesAndConcreteCustomInstances() throws {
        let suite = "niko-shot.service-choice-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let protected = try XCTUnwrap(CustomRESTConfiguration.presets.first)
        var unkeyed = protected; unkeyed.id = UUID(); unkeyed.name = "Unkeyed fixture"
        let local = CustomRESTConfiguration(name: "Local fixture", urlTemplate: "https://example.com/translate",
            bodyTemplate: #"{"q":"$TEXT"}"#, responsePath: "text")
        settings.customTranslationServices = [protected, unkeyed, local]
        let credentials = KeychainStore(testValues: ["google.key": "fixture", "baidu.appid": "fixture", protected.keyAccount: "fixture"])
        let ready = TranslationServiceChoice.configured(settings, credentials: credentials)
        XCTAssertEqual(ready.providers, [.google], "Baidu lacks its secret and the generic custom entry is never listed")
        XCTAssertEqual(ready.custom.map(\.id), [protected.id, local.id])
        XCTAssertTrue(TranslationServiceChoice.configured(settings, credentials: KeychainStore(testValues: [:])).providers.isEmpty)
        TranslationServiceChoice.select(TranslationServiceChoice.tag(UUID()), in: settings)
        XCTAssertEqual(settings.translationProvider, .baidu, "A deleted instance cannot be selected")
        TranslationServiceChoice.select(TranslationServiceChoice.tag(local.id), in: settings)
        XCTAssertEqual(TranslationServiceChoice.tag(settings), TranslationServiceChoice.tag(local.id))
        XCTAssertTrue(TranslationConfiguration.isConfigured(settings, credentials: credentials))
    }

    func testCopiedSecretsStayOnThisMacAreConcealedAndExpireOnlyWhileUnchanged() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let owner = SecretPasteboard.copy("sk-fixture", to: pasteboard, clearAfter: .milliseconds(50))
        XCTAssertEqual(owner, pasteboard.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "sk-fixture")
        XCTAssertTrue(pasteboard.types?.contains(SecretPasteboard.concealedType) == true)
        XCTAssertTrue(pasteboard.types?.contains(SecretPasteboard.transientType) == true)
        for _ in 0..<200 where pasteboard.string(forType: .string) != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(pasteboard.string(forType: .string), "The secret expires from the pasteboard")

        SecretPasteboard.copy("sk-second", to: pasteboard, clearAfter: .milliseconds(50))
        pasteboard.clearContents()
        pasteboard.setString("user text", forType: .string)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(pasteboard.string(forType: .string), "user text", "A newer copy must never be erased")
    }
}
