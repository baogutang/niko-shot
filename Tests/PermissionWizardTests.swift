// Exercises native wizard navigation and isolated completion persistence without requesting TCC or login-item changes.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class PermissionWizardTests: XCTestCase {
    func testClosingEveryStepLeavesOnboardingIncompleteAndReleasesController() throws {
        let suite = "niko-shot.wizard-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var completions = 0
        for nextCount in 0...2 {
            let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
            var controller: PermissionWizardController? = PermissionWizardController(onDemo: {}, onComplete: { completions += 1 }, defaults: defaults)
            weak let weakController = controller
            controller?.show()
            controller?.show()
            XCTAssertEqual(controller?.windowCount, 1)
            try autoreleasepool {
                let window = try wizardWindow(excluding: existing)
                XCTAssertTrue(window.canBecomeKey)
                for _ in 0..<nextCount { try button("wizard.next", in: window).performClick(nil) }
                XCTAssertEqual(try button("wizard.next", in: window).keyEquivalent, "\r")
                XCTAssertEqual(try button("wizard.later", in: window).keyEquivalent, "\u{1b}")
                window.close()
            }
            controller?.close()
            XCTAssertEqual(controller?.windowCount, 0)
            XCTAssertFalse(defaults.bool(forKey: PermissionWizardController.completionKey))
            controller = nil
            XCTAssertNil(weakController)
        }
        XCTAssertEqual(completions, 0)
    }

    func testDemoIsExplicitAndOnlyFinishPersistsCompletionOnce() throws {
        let suite = "niko-shot.wizard-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalStandardCompletion = PermissionWizardController.isCompleted
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        var demos = 0, completions = 0
        let controller = PermissionWizardController(onDemo: { demos += 1 }, onComplete: { completions += 1 }, defaults: defaults)
        defer { controller.close() }
        controller.show()
        try autoreleasepool {
            let window = try wizardWindow(excluding: existing)
            try button("wizard.next", in: window).performClick(nil)
            try button("wizard.next", in: window).performClick(nil)
            XCTAssertEqual(demos, 0)
            try button("wizard.demo", in: window).performClick(nil)
            XCTAssertEqual(demos, 1)
            XCTAssertFalse(defaults.bool(forKey: PermissionWizardController.completionKey))
            controller.close()
            controller.show()
            let resumedWindow = try wizardWindow(excluding: existing)
            XCTAssertEqual(try button("wizard.next", in: resumedWindow).title, "完成", "Returning from the demo must resume the third step")
            try button("wizard.next", in: resumedWindow).performClick(nil)
        }
        XCTAssertTrue(defaults.bool(forKey: PermissionWizardController.completionKey))
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(controller.windowCount, 0)
        controller.close()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(PermissionWizardController.isCompleted, originalStandardCompletion, "An injected suite must not change user onboarding preferences")
    }

    private func wizardWindow(excluding existing: Set<ObjectIdentifier>) throws -> NSWindow {
        try XCTUnwrap(NSApplication.shared.windows.first {
            !existing.contains(ObjectIdentifier($0)) && $0.isVisible && $0.accessibilityLabel() == "niko-shot 首次使用向导"
        })
    }

    private func button(_ identifier: String, in window: NSWindow) throws -> NSButton {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == identifier { return button }
            for child in view.subviews { if let result = find(child) { return result } }
            return nil
        }
        let content = try XCTUnwrap(window.contentView)
        return try XCTUnwrap(find(content))
    }
}
