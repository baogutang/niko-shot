// Owns the menu bar lifetime and composes application services.
import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menu: MainMenuExtra?
    private var settingsWindow: NSWindow?
    private var hotkeys: HotkeyCenter?
    private let captureEngine = CaptureEngine()
    private let selectionSession = SelectionSession()
    private var captureTask: Task<Void, Never>?
    private let windowList = WindowList()
    private let countdown = CaptureCountdown()
    private var lastRegion: CaptureContext?
    private let launchLog = OSLog(subsystem: "com.n1ko.niko-shot", category: "Lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NSApp.setActivationPolicy(.accessory)
        hotkeys = HotkeyCenter(actions: Dictionary(uniqueKeysWithValues: CaptureAction.allCases.map { action in
            (action, { [weak self] in self?.perform(action) })
        }))
        menu = MainMenuExtra(action: { [weak self] id in
            if let action = CaptureAction(rawValue: id) { self?.perform(action) }
        }, settings: { [weak self] in self?.showSettings() })
        os_signpost(.event, log: launchLog, name: "MenuReady")
        if let metricsPath = ProcessInfo.processInfo.environment["NIKO_STARTUP_METRICS"] {
            let uptime = ProcessInfo.processInfo.systemUptime
            try? String(uptime).write(toFile: metricsPath, atomically: true, encoding: .utf8)
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "niko-shot 设置"
            window.isReleasedWhenClosed = false
            if let hotkeys { window.contentView = NSHostingView(rootView: SettingsView(hotkeys: hotkeys)) }
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func perform(_ action: CaptureAction) {
        guard captureTask == nil, selectionSession.state == .idle else { return }
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.captureTask = nil }
            do {
                try await self.countdown.wait(seconds: AppSettings.shared.captureDelay)
                let frames = try await self.captureEngine.freezeScreens()
                let candidates = try await self.windowList.windows()
                var initial: CaptureContext?
                if action == .repeatRegion { initial = self.lastRegion ?? self.loadLastRegion(frames: frames) }
                if action == .fullscreen, let frame = frames.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) ?? frames.first {
                    initial = CaptureContext(screen: frame.screen, localRect: frame.screen.localBounds, kind: "fullscreen")
                }
                self.selectionSession.start(frames: frames, candidates: candidates, kind: action.rawValue, initial: initial) { [weak self] image, context in self?.handleCapture(image, context: context) }
            } catch is CancellationError {} catch { ErrorPresenter.show(error) }
        }
    }

    func handleCapture(_ image: CGImage, context: CaptureContext) {
        lastRegion = context
        UserDefaults.standard.set(["screen": Double(context.screen.id), "x": context.localRect.minX, "y": context.localRect.minY, "width": context.localRect.width, "height": context.localRect.height], forKey: "lastRegion")
        Task {
            do {
                let png = try await Task.detached(priority: .userInitiated) { try ImageUtilities.png(image) }.value
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
            } catch { ErrorPresenter.show(error) }
        }
    }

    private func loadLastRegion(frames: [FrozenFrame]) -> CaptureContext? {
        guard let saved = UserDefaults.standard.dictionary(forKey: "lastRegion") as? [String: Double],
              let screen = saved["screen"], let x = saved["x"], let y = saved["y"], let width = saved["width"], let height = saved["height"],
              let frame = frames.first(where: { Double($0.screen.id) == screen }) else { return nil }
        return CaptureContext(screen: frame.screen, localRect: CGRect(x: x, y: y, width: width, height: height))
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.stop()
        captureTask?.cancel()
        selectionSession.finish()
    }
}
