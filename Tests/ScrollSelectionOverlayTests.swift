// Verifies live translucent selection geometry, mouse pass-through, capture exclusion, and deterministic teardown.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class ScrollSelectionOverlayTests: XCTestCase {
    func testMixedDisplaysKeepGlobalSelectionAndExcludeEveryNativeWindow() throws {
        let left = ScreenGeometry(id: 72, frame: CGRect(x: -640, y: -120, width: 640, height: 480), scale: 1)
        let primary = CGRect(x: 0, y: 0, width: 800, height: 600)
        let upper = CGRect(x: 100, y: 600, width: 480, height: 320)
        let context = CaptureContext(screen: left, localRect: CGRect(x: 30, y: 40, width: 260, height: 210),
                                     kind: "window", appBundleID: "com.example.fixture", windowID: 42)
        let controller = ScrollSelectionOverlayController(screenFrames: { [primary, left.frame, upper] })
        defer { controller.close() }
        let key = NSApplication.shared.keyWindow
        controller.show(context: context)
        XCTAssertEqual(controller.windowCount, 3)
        XCTAssertEqual(Set(controller.windowNumbers).count, 3)
        XCTAssertTrue(controller.windowNumbers.allSatisfy { $0 > 0 })
        XCTAssertEqual(controller.observerCount, 2)
        let leftFrame = try XCTUnwrap(controller.frames.first { $0.screenFrame == left.frame })
        XCTAssertEqual(leftFrame.globalSelection, CGRect(x: -610, y: 110, width: 260, height: 210))
        XCTAssertEqual(leftFrame.localSelection, CGRect(x: 30, y: 230, width: 260, height: 210))
        XCTAssertTrue(controller.frames.filter { $0.screenFrame != left.frame }.allSatisfy { $0.localSelection.isEmpty })
        for panel in try panels(for: controller) {
            XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
            XCTAssertTrue(panel.ignoresMouseEvents, "The browser must keep receiving wheel and mouse input through the viewport")
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertLessThan(panel.level.rawValue, NSWindow.Level.floating.rawValue)
            XCTAssertFalse(panel.isOpaque); XCTAssertFalse(panel.hasShadow)
        }
        XCTAssertTrue(NSApplication.shared.keyWindow === key)
        XCTAssertEqual(context.windowID, 42); XCTAssertEqual(context.appBundleID, "com.example.fixture")
    }

    func testViewportUpdateReusesWindowAndClearsOldCutout() throws {
        let screen = ScreenGeometry(id: 73, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 2)
        let controller = ScrollSelectionOverlayController(screenFrames: { [screen.frame] })
        defer { controller.close() }
        controller.show(context: CaptureContext(screen: screen, localRect: CGRect(x: 50, y: 50, width: 100, height: 100)))
        let number = controller.windowNumbers
        let panel = try XCTUnwrap(try panels(for: controller).first)
        let view = try XCTUnwrap(panel.contentView as? ScrollSelectionOverlayView)
        XCTAssertEqual(try color(at: CGPoint(x: 100, y: 200), in: view).alphaComponent, 0, accuracy: 0.01)
        controller.update(context: CaptureContext(screen: screen, localRect: CGRect(x: 240, y: 150, width: 80, height: 80)))
        XCTAssertEqual(controller.windowNumbers, number)
        XCTAssertEqual(controller.windowCount, 1)
        XCTAssertEqual(controller.frames.first?.localSelection, CGRect(x: 240, y: 70, width: 80, height: 80))
        XCTAssertGreaterThan(try color(at: CGPoint(x: 100, y: 200), in: view).alphaComponent, 0.09,
                             "The old viewport must be dimmed after a real update")
        XCTAssertEqual(try color(at: CGPoint(x: 280, y: 110), in: view).alphaComponent, 0, accuracy: 0.01)
    }

    func testRealMaskHasTransparentInteriorLightExteriorAndVisibleOutsideBorder() throws {
        let screen = CGRect(x: -400, y: 90, width: 400, height: 300)
        let view = ScrollSelectionOverlayView(frame: CGRect(origin: .zero, size: screen.size))
        view.setSelection(CGRect(x: -300, y: 170, width: 140, height: 120), on: screen)
        XCTAssertFalse(view.isOpaque)
        XCTAssertEqual(view.selectionRect, CGRect(x: 100, y: 80, width: 140, height: 120))
        XCTAssertEqual(try color(at: CGPoint(x: 170, y: 140), in: view).alphaComponent, 0, accuracy: 0.01)
        let outside = try color(at: CGPoint(x: 20, y: 20), in: view)
        XCTAssertGreaterThan(outside.alphaComponent, 0.09)
        XCTAssertLessThan(outside.alphaComponent, 0.3, "The live desktop must remain visible through the surrounding mask")
        let edge = try color(at: CGPoint(x: 99, y: 140), in: view)
        XCTAssertGreaterThan(edge.alphaComponent, 0.8)
        XCTAssertGreaterThan(edge.redComponent, edge.blueComponent)
        XCTAssertEqual(try color(at: CGPoint(x: 103, y: 140), in: view).alphaComponent, 0, accuracy: 0.01,
                       "The outside border must not tint captured interior pixels")
    }

    func testCloseAndDropReleaseAllWindowsWithoutLateUpdateRevivingThem() throws {
        let screen = ScreenGeometry(id: 74, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1)
        let context = CaptureContext(screen: screen, localRect: CGRect(x: 40, y: 40, width: 280, height: 220))
        var controller: ScrollSelectionOverlayController? = ScrollSelectionOverlayController(screenFrames: { [screen.frame] })
        weak let weakController = controller
        controller?.show(context: context)
        let old = try panels(for: try XCTUnwrap(controller))
        controller?.close(); controller?.close(); controller?.update(context: context)
        XCTAssertEqual(controller?.windowCount, 0); XCTAssertEqual(controller?.observerCount, 0)
        XCTAssertTrue(controller?.windowNumbers.isEmpty == true)
        XCTAssertTrue(old.allSatisfy { !$0.isVisible && $0.contentView == nil })
        controller?.show(context: context)
        let reopened = try panels(for: try XCTUnwrap(controller))
        controller = nil
        XCTAssertNil(weakController)
        XCTAssertTrue(reopened.allSatisfy { !$0.isVisible && $0.contentView == nil })
    }

    func testChangedDisplaysAndInvalidViewportCleanUpWithoutDuplicatePanels() throws {
        let screen = ScreenGeometry(id: 75, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1)
        let screens = ScrollOverlayScreenFixture(frames: [screen.frame, CGRect(x: -400, y: 0, width: 400, height: 300), screen.frame, .null])
        let controller = ScrollSelectionOverlayController(screenFrames: { screens.frames })
        defer { controller.close() }
        let context = CaptureContext(screen: screen, localRect: CGRect(x: 40, y: 40, width: 280, height: 220))
        controller.show(context: context)
        XCTAssertEqual(controller.windowCount, 2)
        let removed = try XCTUnwrap(try panels(for: controller).first { $0.frame.minX < 0 })
        screens.frames = [screen.frame]
        controller.update(context: context)
        XCTAssertEqual(controller.windowCount, 1)
        XCTAssertFalse(removed.isVisible); XCTAssertNil(removed.contentView)
        // A display change re-lays the overlay out instead of closing it; the live window stays the same.
        let number = controller.windowNumbers
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(controller.windowCount, 1); XCTAssertEqual(controller.observerCount, 2)
        XCTAssertEqual(controller.windowNumbers, number)
        controller.show(context: CaptureContext(screen: screen, localRect: .zero))
        XCTAssertEqual(controller.windowCount, 0); XCTAssertEqual(controller.observerCount, 0)
        controller.update(context: context)
        XCTAssertEqual(controller.windowCount, 0)
    }

    /// Region capture uses an overlay window number as its "below this window" reference, so display
    /// reconfiguration must move the existing panels, keep their numbers and keep updates working.
    func testDisplayReconfigurationRepositionsPanelsAndKeepsWindowNumbers() throws {
        let screen = ScreenGeometry(id: 76, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1)
        let side = CGRect(x: 400, y: 0, width: 300, height: 300)
        let screens = ScrollOverlayScreenFixture(frames: [screen.frame, side])
        let controller = ScrollSelectionOverlayController(screenFrames: { screens.frames })
        defer { controller.close() }
        controller.show(context: CaptureContext(screen: screen, localRect: CGRect(x: 40, y: 40, width: 200, height: 150)))
        let target = try XCTUnwrap(controller.frames.first { $0.screenFrame == screen.frame }).windowNumber
        let numbers = Set(controller.windowNumbers)
        // The side display moves; the target display is untouched.
        let moved = CGRect(x: -300, y: 0, width: 300, height: 300)
        screens.frames = [screen.frame, moved]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(Set(controller.windowNumbers), numbers, "panels are moved, not recreated")
        XCTAssertEqual(controller.frames.first { $0.screenFrame == screen.frame }?.windowNumber, target)
        XCTAssertEqual(controller.frames.map(\.screenFrame), [screen.frame, moved])
        let movedPanel = try XCTUnwrap(try panels(for: controller).first { $0.frame == moved })
        XCTAssertTrue(movedPanel.isVisible)
        XCTAssertEqual(movedPanel.contentView?.frame.size, moved.size)
        // Updates keep working after the change.
        controller.update(context: CaptureContext(screen: screen, localRect: CGRect(x: 100, y: 60, width: 120, height: 90)))
        XCTAssertEqual(controller.frames.first { $0.screenFrame == screen.frame }?.localSelection,
                       CGRect(x: 100, y: 150, width: 120, height: 90))
        XCTAssertTrue(controller.windowNumbers.contains(target))
    }

    private func panels(for controller: ScrollSelectionOverlayController) throws -> [NSWindow] {
        let panels = controller.windowNumbers.compactMap { number in NSApplication.shared.windows.first { $0.windowNumber == number } }
        XCTAssertEqual(panels.count, controller.windowCount)
        return panels
    }
    private func color(at point: CGPoint, in view: ScrollSelectionOverlayView) throws -> NSColor {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let x = Int((point.x - view.bounds.minX) / view.bounds.width * CGFloat(bitmap.pixelsWide))
        let y = Int((view.bounds.maxY - point.y) / view.bounds.height * CGFloat(bitmap.pixelsHigh))
        return try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }
}

@MainActor
private final class ScrollOverlayScreenFixture {
    var frames: [CGRect]
    init(frames: [CGRect]) { self.frames = frames }
}
