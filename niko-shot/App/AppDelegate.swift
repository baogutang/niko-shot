// Owns the menu bar lifetime and composes application services.
import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menu: MainMenuExtra?
    private var settingsWindow: NSWindow?
    private var hotkeys: HotkeyCenter?
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
        showSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.stop()
    }
}
