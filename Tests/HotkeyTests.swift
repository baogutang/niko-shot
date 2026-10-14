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

    func testSpecifiedDefaultKeyVectorsAreDistinct() {
        XCTAssertEqual(CaptureAction.allCases.count, 9)
        XCTAssertEqual(Set(CaptureAction.allCases.map(\.defaultShortcut)).count, 9)
        let expected: [CaptureAction: UInt32] = [
            .region: UInt32(kVK_ANSI_A), .window: UInt32(kVK_ANSI_W), .fullscreen: UInt32(kVK_ANSI_F),
            .repeatRegion: UInt32(kVK_ANSI_R), .record: UInt32(kVK_ANSI_V), .ocr: UInt32(kVK_ANSI_O),
            .scroll: UInt32(kVK_ANSI_L), .pins: UInt32(kVK_ANSI_P), .togglePins: UInt32(kVK_ANSI_T)
        ]
        for action in CaptureAction.allCases {
            XCTAssertEqual(action.defaultShortcut.keyCode, expected[action])
            XCTAssertEqual(action.defaultShortcut.modifiers, action == .togglePins ? UInt32(optionKey | cmdKey) : UInt32(shiftKey | cmdKey))
            XCTAssertTrue(action.defaultShortcut.isValid)
        }
        XCTAssertEqual(CaptureAction.region.defaultShortcut.displayString, "⇧⌘A")
        XCTAssertEqual(CaptureAction.togglePins.defaultShortcut.displayString, "⌥⌘T")
    }

    func testDuplicatesRetainExistingAssignmentAndOfferUniqueAlternatives() throws {
        let center = HotkeyCenter(actions: [:], defaults: try defaults(), registersImmediately: false)
        XCTAssertFalse(center.setShortcut(CaptureAction.window.defaultShortcut, for: .region))
        XCTAssertEqual(center.shortcut(for: .region), CaptureAction.region.defaultShortcut)
        XCTAssertNotNil(center.registrationErrors[.region])
        XCTAssertFalse(center.suggestions(for: .region).isEmpty)
        for suggestion in center.suggestions(for: .region) {
            XCTAssertTrue(suggestion.isValid)
            XCTAssertFalse(center.shortcuts.values.contains(suggestion))
        }
        let invalid = HotkeyShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey))
        XCTAssertFalse(center.setShortcut(invalid, for: .region))
        XCTAssertEqual(center.shortcut(for: .region), CaptureAction.region.defaultShortcut)
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
        XCTAssertFalse(original.useLegacyScrollEngine)
        original.useLegacyScrollEngine = true
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
        XCTAssertTrue(restored.useLegacyScrollEngine)
    }
}
