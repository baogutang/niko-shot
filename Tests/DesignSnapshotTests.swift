// Renders windows and capture chrome to PNG for design review and the website; skipped unless a directory is given.
import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import NikoShot

@MainActor
final class DesignSnapshotTests: XCTestCase {
    private nonisolated static var path: String? {
        ProcessInfo.processInfo.environment["NIKO_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    }
    private var directory: URL? { Self.path.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    override nonisolated func setUpWithError() throws {
        guard let path = Self.path else {
            throw XCTSkip("Set TEST_RUNNER_NIKO_SNAPSHOT_DIR to render design snapshots.")
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
    }

    func testRenderSettingsPanesInBothAppearances() throws {
        let store = try XCTUnwrap(UserDefaults(suiteName: "com.n1ko.niko-shot.snapshots.\(UUID().uuidString)"))
        let hotkeys = HotkeyCenter(actions: [:], defaults: store, registersImmediately: false)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let window = SettingsWindowFactory.makeWindow(settings: AppSettings(defaults: store), hotkeys: hotkeys, onShowWizard: {})
            window.appearance = NSAppearance(named: appearance)
            window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
            window.orderFront(nil)
            let tabs = try XCTUnwrap(window.contentViewController as? SettingsTabController)
            for pane in SettingsPane.allCases {
                tabs.select(pane, animated: false)
                try render(window, name: "settings-\(pane.rawValue)-\(appearance == .aqua ? "light" : "dark")")
            }
            window.close()
        }
    }

    func testRenderWelcomeWindow() throws {
        let controller = WelcomeWindowController(onDemo: {}, onComplete: {}, defaults: try XCTUnwrap(UserDefaults(suiteName: "snap.\(UUID())")),
            shortcuts: [(CaptureAction.region.title, CaptureAction.region.legacyShortcut.displayString)])
        controller.show()
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "欢迎使用 niko-shot" })
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            try render(window, name: "welcome-\(appearance == .aqua ? "light" : "dark")")
        }
        controller.close()
    }

    /// Website previews: content only, at the sizes the site already lays out.
    func testRenderWebsitePreviews() throws {
        let store = try XCTUnwrap(UserDefaults(suiteName: "com.n1ko.niko-shot.snapshots.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: store)
        let model = OCRViewModel()
        model.blocks = [
            OCRBlock(text: "Less effort. More clarity.\nA small note for the way you work.", boundingBox: .zero, confidence: 0.98),
            OCRBlock(text: "把想法留在眼前，\n让工作更从容。", boundingBox: .zero, confidence: 0.97),
            OCRBlock(text: "毎日を、少しシンプルに。", boundingBox: .zero, confidence: 0.95)
        ]
        let previews: [(String, () -> NSView, CGSize)] = [
            ("ocr", { NSHostingView(rootView: OCRView(model: model, settings: settings)) }, CGSize(width: 980, height: 620)),
            ("recording", { NSHostingView(rootView: RecordingSetupView(settings: settings, onStart: { _ in }, onCancel: {})) },
             CGSize(width: 500, height: 560))
        ]
        for (name, makeView, size) in previews {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let view = makeView()
                let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                window.orderFront(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
                try render(view, name: "app-\(name)\(appearance == .aqua ? "" : "-dark")")
                window.contentView = nil
                window.close()
            }
        }
    }

    /// History, pin library and GIF export, the windows a design pass most easily forgets.
    func testRenderSecondaryWindows() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(url: folder.appendingPathComponent("history.sqlite"))
        let sources = [try image(named: "backdrop.png"), try image(named: "scroll-preview-source.png")].compactMap { $0 }
        let kinds = ["region", "window", "scroll", "region", "fullscreen", "region"]
        for (index, kind) in kinds.enumerated() {
            let source = sources.isEmpty ? try solidImage() : sources[index % sources.count]
            let thumbnail = try XCTUnwrap(CapturePreviewController.makeThumbnail(source, backingScale: 2))
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]))
            try await store.insert(HistoryRecord(id: UUID(), createdAt: Date(timeIntervalSinceNow: Double(-index * 3_600)), path: "",
                thumbnail: png, width: source.width, height: source.height, appBundleID: "com.apple.TextEdit", captureKind: kind,
                ocrText: index == 0 ? "下周三之前完成设计评审" : ""))
        }
        let pins = PinWindowManager(directory: folder.appendingPathComponent("pins", isDirectory: true))
        let windows: [(String, NSView, CGSize)] = [
            ("history", NSHostingView(rootView: HistoryView(store: store, onOCR: { _ in }, onPin: { _ in }, onEdit: { _ in })), CGSize(width: 900, height: 640)),
            ("pins", NSHostingView(rootView: PinLibraryView(manager: pins)), CGSize(width: 760, height: 500)),
            ("gif", NSHostingView(rootView: GifExportView(settings: AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: "snap.\(UUID())"))),
                duration: 12.4, sourceSize: CGSize(width: 1_440, height: 900), onExport: { _ in }, onCancel: {})), CGSize(width: 440, height: 420))
        ]
        for (name, view, size) in windows {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                // Matches AppDelegate.makeUtilityWindow.
                let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                    styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.toolbarStyle = .unified; window.titlebarAppearsTransparent = true
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(600))
                try render(window, name: "\(name)-\(appearance == .aqua ? "light" : "dark")")
                window.contentView = nil
                window.close()
            }
        }
    }

    private func solidImage() throws -> CGImage {
        let context = try ImageUtilities.context(width: 640, height: 400)
        context.setFillColor(CGColor(gray: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        return try XCTUnwrap(context.makeImage())
    }

    /// The capture overlay and toolbar as layers; the hero composite adds the glass blur afterwards.
    func testRenderCaptureOverlayLayers() throws {
        // The website's practice note, rendered at 2x into the snapshot folder; without it, the OCR window stands in.
        let backdrop: CGImage, size: CGSize, drag: (CGPoint, CGPoint)
        if let note = try image(named: "backdrop.png") {
            backdrop = note
            size = CGSize(width: note.width / 2, height: note.height / 2)
            // The headline and the highlighted to-do, in window coordinates.
            drag = (CGPoint(x: 112, y: size.height - 212), CGPoint(x: 800, y: size.height - 445))
        } else {
            let store = try XCTUnwrap(UserDefaults(suiteName: "com.n1ko.niko-shot.snapshots.\(UUID().uuidString)"))
            let model = OCRViewModel()
            model.blocks = [OCRBlock(text: "Less effort. More clarity.", boundingBox: .zero, confidence: 0.98)]
            size = CGSize(width: 980, height: 620)
            let host = NSHostingView(rootView: OCRView(model: model, settings: AppSettings(defaults: store)))
            let hostWindow = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                styleMask: [.titled], backing: .buffered, defer: false)
            hostWindow.isReleasedWhenClosed = false
            hostWindow.appearance = NSAppearance(named: .aqua)
            hostWindow.contentView = host
            hostWindow.orderFront(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            backdrop = try XCTUnwrap(rep.cgImage)
            hostWindow.contentView = nil
            hostWindow.close()
            drag = (CGPoint(x: 333, y: 528), CGPoint(x: 600, y: 396))
        }

        let session = SelectionSession()
        let screen = ScreenGeometry(id: 9, frame: CGRect(origin: CGPoint(x: -12_000, y: -12_000), size: size), scale: 2)
        session.start(frames: [FrozenFrame(screen: screen, image: backdrop)]) { _, _ in }
        defer { session.finish() }
        let overlay = try XCTUnwrap(session.windows.first)
        let view = try XCTUnwrap(overlay.contentView as? SelectionView)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: overlay.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, drag.0))
        view.mouseDragged(with: try event(.leftMouseDragged, drag.1))
        view.mouseUp(with: try event(.leftMouseUp, drag.1))
        // Rest the pointer inside the selection, where the loupe steps aside.
        view.mouseMoved(with: try event(.mouseMoved, CGPoint(x: (drag.0.x + drag.1.x) / 2, y: (drag.0.y + drag.1.y) / 2)))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        try renderLayer(view, name: "overlay")
        let toolbar = try XCTUnwrap(session.toolbarWindow)
        let toolbarView = try XCTUnwrap(toolbar.contentView)
        try renderGlass(toolbarView, name: "toolbar")
        let origin = CGPoint(x: toolbar.frame.minX - overlay.frame.minX, y: overlay.frame.maxY - toolbar.frame.maxY)
        try writeGeometry(["toolbar": CGRect(origin: origin, size: toolbar.frame.size)], name: "toolbar")
    }

    /// The long-capture HUD, live preview and viewport mask, placed by the app's own placement rules on an
    /// 880x560 desktop. The website composite adds the document backdrop and the glass blur.
    func testRenderScrollCapture() throws {
        guard let stitched = try image(named: "scroll-preview-source.png") else {
            throw XCTSkip("Render scroll-preview-source.png into the snapshot folder first.")
        }
        let canvas = CGRect(x: 0, y: 0, width: 880, height: 560)
        let viewport = CGRect(x: 135, y: canvas.height - 460, width: 450, height: 400)
        let state = ScrollControlState()
        state.phase = .capturing; state.isAutomatic = true
        state.width = 900; state.height = 1_920; state.frames = 6
        state.title = "正在自动滚动"; state.message = "到底后自动完成，可随时暂停"
        state.preview = ScrollPreviewSnapshot(image: stitched, sourceWidth: 900, sourceHeight: 1_920, frames: 6)
        let hudFrame = ScrollControlBarController.placement(size: CGSize(width: 600, height: 56), near: viewport, visible: canvas)
        let previewFrame = ScrollPreviewPanelController.placement(near: viewport, avoiding: hudFrame, visible: canvas)

        let mask = ScrollSelectionOverlayView(frame: canvas)
        mask.setSelection(viewport, on: canvas)
        try renderDrawing(mask, name: "scroll-mask")

        let bar = ScrollControlBarController(state: state, onFinish: {}, onCancel: {}, onToggleAutomatic: {}, onTogglePreview: {})
        bar.show(near: viewport)
        defer { bar.close() }
        let preview = ScrollPreviewPanelController(state: state)
        preview.show(near: viewport, avoiding: hudFrame)
        defer { preview.close() }
        let hudPanel = try XCTUnwrap(NSApp.windows.first { $0.accessibilityLabel() == "长截图控制条" })
        let previewPanel = try XCTUnwrap(NSApp.windows.first { $0.accessibilityLabel() == "长截图实时预览" })
        previewPanel.setFrame(CGRect(origin: previewPanel.frame.origin, size: previewFrame.size), display: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        try renderGlass(try XCTUnwrap(hudPanel.contentView), name: "scroll-hud")
        try renderGlass(try XCTUnwrap(previewPanel.contentView), name: "scroll-preview")
        if let dark = try image(named: "scroll-preview-source-dark.png") {
            state.preview = ScrollPreviewSnapshot(image: dark, sourceWidth: 900, sourceHeight: 1_920, frames: 6)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            try renderGlass(try XCTUnwrap(previewPanel.contentView), name: "scroll-preview-dark")
        }
        func topLeft(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height) }
        try writeGeometry(["viewport": topLeft(viewport), "hud": topLeft(hudFrame), "preview": topLeft(previewFrame)], name: "scroll")
    }

    /// Offscreen, a behind-window material flattens to opaque gray. Hide its private layers so only the
    /// tint and the controls render; the website composite blurs the real backdrop underneath.
    private func renderGlass(_ view: NSView, name: String) throws {
        func materialLayers(in view: NSView) -> [CALayer] {
            var layers = view.subviews.flatMap(materialLayers(in:))
            if view is NSVisualEffectView {
                let controls = Set(view.subviews.compactMap(\.layer).map(ObjectIdentifier.init))
                layers += (view.layer?.sublayers ?? []).filter { !controls.contains(ObjectIdentifier($0)) }
            }
            return layers
        }
        let material = materialLayers(in: view)
        material.forEach { $0.isHidden = true }
        defer { material.forEach { $0.isHidden = false } }
        try render(view, name: name)
    }

    private func image(named name: String) throws -> CGImage? {
        let url = try XCTUnwrap(directory).appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Frames in top-left points, for the website compositing script.
    private func writeGeometry(_ frames: [String: CGRect], name: String) throws {
        let json = frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: try XCTUnwrap(directory).appendingPathComponent("\(name).json"))
    }

    /// Draws a `draw(_:)`-based view at 2x, keeping its transparency.
    private func renderDrawing(_ view: NSView, name: String) throws {
        let scale: CGFloat = 2
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: view.isFlipped)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: try XCTUnwrap(directory).appendingPathComponent("\(name).png"))
    }

    private func renderLayer(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let layer = try XCTUnwrap(view.layer)
        let scale: CGFloat = 2
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped { context.translateBy(x: 0, y: view.bounds.height); context.scaleBy(x: 1, y: -1) }
        layer.render(in: context)
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: try XCTUnwrap(directory).appendingPathComponent("\(name).png"))
    }

    private func render(_ window: NSWindow, name: String) throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        try render(try XCTUnwrap(window.contentView?.superview), name: name)
    }

    private func render(_ frameView: NSView, name: String) throws {
        frameView.layoutSubtreeIfNeeded()
        let bounds = frameView.bounds
        let rep = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: bounds))
        frameView.cacheDisplay(in: bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: try XCTUnwrap(directory).appendingPathComponent("\(name).png"))
    }
}
