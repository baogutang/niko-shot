// Captures native ScreenCaptureKit snapshots, excluding this process before overlays exist.
import AppKit
// SCContentFilter/SCStreamConfiguration predate Sendable annotations; they stay within this engine's main-actor call.
@preconcurrency import ScreenCaptureKit
import os

@MainActor
final class CaptureEngine {
    private let log = OSLog(subsystem: "com.n1ko.niko-shot", category: "Capture")

    /// Requests screen recording only when capture is first invoked.
    func requirePermission() throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw AppError.permission("屏幕录制") }
    }

    /// Captures every physical screen once, retaining per-screen scale and position.
    func freezeScreens() async throws -> [FrozenFrame] {
        try requirePermission()
        os_signpost(.begin, log: log, name: "Freeze")
        defer { os_signpost(.end, log: log, name: "Freeze") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var result: [FrozenFrame] = []
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let geometry = ScreenGeometry(id: id, frame: screen.frame, scale: screen.backingScaleFactor, safeTop: screen.safeAreaInsets.top)
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = Int((screen.frame.width * geometry.scale).rounded())
            configuration.height = Int((screen.frame.height * geometry.scale).rounded())
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            result.append(FrozenFrame(screen: geometry, image: image))
        }
        guard !result.isEmpty else { throw AppError.imageCreation }
        return result
    }
}
