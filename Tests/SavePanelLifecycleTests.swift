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
}
