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

    /// Captures a preselected window for automation without an overlay or a second capture.
    func captureWindow(id: UInt32) async throws -> CGImage {
        try requirePermission()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }) else { throw AppError.file("窗口已关闭或不可捕获。") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int((window.frame.width * CGFloat(filter.pointPixelScale)).rounded())
        config.height = Int((window.frame.height * CGFloat(filter.pointPixelScale)).rounded())
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Prepares one cropped display filter for the active scrolling session instead of enumerating every frame.
    func regionCapture(screen: ScreenGeometry, rect: CGRect) async throws -> RegionSnapshot {
        try requirePermission()
        let clipped = rect.standardized.intersection(screen.localBounds)
        let pixels = CoordinateSpace.imagePixelRect(fromSelection: clipped, screen: screen)
        guard !clipped.isNull, pixels.width >= 2, pixels.height >= 2 else { throw AppError.imageCreation }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.id }) else {
            throw AppError.file("目标显示器已断开。")
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixels.width); configuration.height = Int(pixels.height)
        configuration.sourceRect = CGRect(x: pixels.minX / screen.scale, y: pixels.minY / screen.scale,
                                          width: pixels.width / screen.scale, height: pixels.height / screen.scale)
        configuration.showsCursor = false; configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB
        return RegionSnapshot(filter: filter, configuration: configuration)
    }
}

/// A session-owned ScreenCaptureKit request; native configuration never crosses actors.
@MainActor
final class RegionSnapshot {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        self.filter = filter; self.configuration = configuration
    }

    /// Captures a fresh viewport without retaining previous samples or installing any listener.
    func capture() async throws -> CGImage {
        try Task.checkCancellation()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        return image
    }
}
