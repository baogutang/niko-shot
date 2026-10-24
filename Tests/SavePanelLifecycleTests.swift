// Exercises cancellation of a real native save modal without writing a user file.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class SavePanelLifecycleTests: XCTestCase {
    func testCancelDismissesThePendingNativeSavePanel() {
        _ = NSApplication.shared
        let panel = NSSavePanel()
        let router = SavePanelRouter(panel: panel)
        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated { router.cancel() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate(); router.cancel() }
        let destination = withExtendedLifetime(router) { router.destination() }
        XCTAssertNil(destination)
        XCTAssertFalse(panel.isVisible)
    }

    func testChangingTheFormatKeepsTheTypedNameAndSwapsOnlyTheExtension() {
        _ = NSApplication.shared
        let panel = NSSavePanel()
        let router = SavePanelRouter(panel: panel)
        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated {
                panel.nameFieldStringValue = "发票截图.tiff"
                if let menu = Self.popUp(in: panel.accessoryView), let jpeg = ExportFormat.allCases.firstIndex(of: .jpeg),
                   let png = ExportFormat.allCases.firstIndex(of: .png) {
                    menu.selectItem(at: menu.indexOfSelectedItem == jpeg ? png : jpeg)
                    menu.sendAction(menu.action, to: menu.target)
                }
                router.cancel()
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate(); router.cancel() }
        XCTAssertNil(withExtendedLifetime(router) { router.destination() })
        XCTAssertTrue(["发票截图.jpg", "发票截图.png"].contains(panel.nameFieldStringValue),
                      "The typed name stays and the extension follows the new format, got \(panel.nameFieldStringValue)")
    }

    private static func popUp(in view: NSView?) -> NSPopUpButton? {
        guard let view else { return nil }
        if let button = view as? NSPopUpButton { return button }
        for child in view.subviews { if let button = popUp(in: child) { return button } }
        return nil
    }

    func testOnlyAKnownImageExtensionIsReplaced() {
        XCTAssertEqual(SavePanelRouter.name("发票截图.PNG", withExtensionOf: .jpeg), "发票截图.jpg")
        XCTAssertEqual(SavePanelRouter.name("v1.2 notes", withExtensionOf: .png), "v1.2 notes.png")
        XCTAssertEqual(SavePanelRouter.name("scan.heic", withExtensionOf: .tiff), "scan.tiff")
        XCTAssertEqual(SavePanelRouter.name("", withExtensionOf: .heif), "niko-shot.heic")
    }
}
