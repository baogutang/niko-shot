// Checks shortcut vectors, duplicate rejection and preference restoration without global registration.
import Carbon
import XCTest
@testable import NikoShot

@MainActor
final class HotkeyTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "com.n1ko.niko-shot.tests.\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testLegacyKeyVectorsAreDistinctAndFreshInstallsOnlyClaimRegion() {
        XCTAssertEqual(CaptureAction.allCases.count, 9)
        XCTAssertEqual(Set(CaptureAction.allCases.map(\.legacyShortcut)).count, 9)
        let expected: [CaptureAction: UInt32] = [
            .region: UInt32(kVK_ANSI_A), .window: UInt32(kVK_ANSI_W), .fullscreen: UInt32(kVK_ANSI_F),
            .repeatRegion: UInt32(kVK_ANSI_R), .record: UInt32(kVK_ANSI_V), .ocr: UInt32(kVK_ANSI_O),
            .scroll: UInt32(kVK_ANSI_L), .pins: UInt32(kVK_ANSI_P), .togglePins: UInt32(kVK_ANSI_T)
        ]
        for action in CaptureAction.allCases {
            XCTAssertEqual(action.legacyShortcut.keyCode, expected[action])
            XCTAssertEqual(action.legacyShortcut.modifiers, action == .togglePins ? UInt32(optionKey | cmdKey) : UInt32(shiftKey | cmdKey))
            XCTAssertTrue(action.legacyShortcut.isValid)
            XCTAssertEqual(action.defaultShortcut, action == .region ? action.legacyShortcut : nil)
        }
        XCTAssertEqual(CaptureAction.region.legacyShortcut.displayString, "⇧⌘A")
        XCTAssertEqual(CaptureAction.togglePins.legacyShortcut.displayString, "⌥⌘T")
    }

    func testFreshInstallRegistersOnlyRegionWhileExistingInstallsKeepEveryLegacyShortcut() throws {
        let freshStore = try defaults()
        let fresh = HotkeyCenter(actions: [:], defaults: freshStore, registersImmediately: false)
        XCTAssertEqual(fresh.shortcuts, [.region: CaptureAction.region.legacyShortcut])
        // Finishing the welcome flow must not turn a new install into an upgraded one on the next launch.
        freshStore.set(true, forKey: "permissionWizardCompleted")
        let freshRelaunched = HotkeyCenter(actions: [:], defaults: freshStore, registersImmediately: false)
        XCTAssertEqual(freshRelaunched.shortcuts, [.region: CaptureAction.region.legacyShortcut])

        let store = try defaults()
        store.set(true, forKey: "permissionWizardCompleted")
        let upgraded = HotkeyCenter(actions: [:], defaults: store, registersImmediately: false)
        for action in CaptureAction.allCases { XCTAssertEqual(upgraded.shortcut(for: action), action.legacyShortcut) }
        upgraded.clearShortcut(for: .record)
        let relaunched = HotkeyCenter(actions: [:], defaults: store, registersImmediately: false)
        XCTAssertNil(relaunched.shortcut(for: .record), "A removed shortcut must stay removed, not fall back to a default")
        XCTAssertEqual(relaunched.shortcut(for: .ocr), CaptureAction.ocr.legacyShortcut)
    }

    func testClearedShortcutIsUnregisteredPersistedAndFreesTheCombination() throws {
        let store = try defaults()
        let center = HotkeyCenter(actions: [:], defaults: store, registersImmediately: false)
        center.clearShortcut(for: .region)
        XCTAssertNil(center.shortcut(for: .region))
        XCTAssertFalse(center.registeredActions.contains(.region))
        XCTAssertTrue(center.setShortcut(CaptureAction.region.legacyShortcut, for: .window), "The freed combination can be reused")
        let restored = HotkeyCenter(actions: [:], defaults: store, registersImmediately: false)
        XCTAssertNil(restored.shortcut(for: .region))
        XCTAssertEqual(restored.shortcut(for: .window), CaptureAction.region.legacyShortcut)
        restored.resetDefaults()
        XCTAssertEqual(restored.shortcut(for: .region), CaptureAction.region.legacyShortcut)
        XCTAssertNil(restored.shortcut(for: .window))
    }

    func testPre06PreferencesWithoutNullsStillDecode() throws {
        let store = try defaults()
        let legacy = ["region": HotkeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(shiftKey | cmdKey))]
        store.set(try JSONEncoder().encode(legacy), forKey: "globalHotkeys")
        let center = HotkeyCenter(actions: [:], defaults: store, registersImmediately: false)
        XCTAssertEqual(center.shortcut(for: .region), legacy["region"])
        XCTAssertNil(center.shortcut(for: .window), "Actions missing from saved data use the fresh-install default")
    }

    func testDuplicatesRetainExistingAssignmentAndOfferUniqueAlternatives() throws {
        let center = HotkeyCenter(actions: [:], defaults: try defaults(), registersImmediately: false)
        XCTAssertTrue(center.setShortcut(CaptureAction.window.legacyShortcut, for: .window))
        XCTAssertFalse(center.setShortcut(CaptureAction.window.legacyShortcut, for: .region))
        XCTAssertEqual(center.shortcut(for: .region), CaptureAction.region.legacyShortcut)
        XCTAssertNotNil(center.registrationErrors[.region])
        XCTAssertFalse(center.suggestions(for: .region).isEmpty)
        for suggestion in center.suggestions(for: .region) {
            XCTAssertTrue(suggestion.isValid)
            XCTAssertFalse(center.shortcuts.values.contains(suggestion))
        }
        let invalid = HotkeyShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey))
        XCTAssertFalse(center.setShortcut(invalid, for: .region))
        XCTAssertEqual(center.shortcut(for: .region), CaptureAction.region.legacyShortcut)
    }

    func testCustomAssignmentPersistsAndResetRestoresDefaults() throws {
        let store = try defaults()
        let custom = HotkeyShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey | cmdKey))
        let original = HotkeyCenter(actions: [:], defaults: store, registersImmediately: false)
        XCTAssertTrue(original.setShortcut(custom, for: .region))
        let restored = HotkeyCenter(actions: [:], defaults: store, registersImmediately: false)
        XCTAssertEqual(restored.shortcut(for: .region), custom)
        restored.resetDefaults()
        XCTAssertEqual(restored.shortcut(for: .region), CaptureAction.region.defaultShortcut)
        restored.stop()
        restored.stop()
        XCTAssertFalse(restored.isRunning)
        XCTAssertTrue(restored.registeredActions.isEmpty)
    }

    func testSettingsPersistCodablePresetsAndRequestedValues() throws {
        let store = try defaults()
        let original = AppSettings(defaults: store)
        XCTAssertTrue(original.autoOCR)
        XCTAssertTrue(original.automaticTranslation)
        original.captureDelay = 3
        original.jpegQuality = 0.72
        original.presetSizes = [CaptureSizePreset(name: "测试", width: 600, height: 400)]
        original.recordingFPS = 60
        original.microphone = true
        let restored = AppSettings(defaults: store)
        XCTAssertEqual(restored.captureDelay, 3)
        XCTAssertEqual(restored.jpegQuality, 0.72, accuracy: 0.001)
        XCTAssertEqual(restored.presetSizes, original.presetSizes)
        XCTAssertEqual(restored.recordingFPS, 60)
        XCTAssertTrue(restored.microphone)
    }
}
