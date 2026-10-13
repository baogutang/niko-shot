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
        try Task.checkCancellation()
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var pending: [Task<FrozenFrame, Error>] = []
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
            // Native configuration remains MainActor-owned while each independent screen request awaits the GPU.
            pending.append(Task { @MainActor in
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                try Task.checkCancellation()
                return FrozenFrame(screen: geometry, image: image)
            })
        }
        let requests = pending
        return try await withTaskCancellationHandler {
            do {
                var result: [FrozenFrame] = []
                for task in requests { result.append(try await task.value) }
                try Task.checkCancellation()
                guard !result.isEmpty else { throw AppError.imageCreation }
                return result
            } catch {
                for task in requests { task.cancel() }
                // Native requests may finish after cancellation. Drain every screen before releasing the session.
                for task in requests { _ = try? await task.value }
                throw error
            }
        } onCancel: { for task in requests { task.cancel() } }
    }

    /// Captures a preselected window for automation without an overlay or a second capture.
    func captureWindow(id: UInt32) async throws -> CGImage {
        try Task.checkCancellation()
        try requirePermission()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }) else { throw AppError.file("窗口已关闭或不可捕获。") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int((window.frame.width * CGFloat(filter.pointPixelScale)).rounded())
        config.height = Int((window.frame.height * CGFloat(filter.pointPixelScale)).rounded())
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        return image
    }

    /// Prepares one cropped display filter for the active scrolling session instead of enumerating every frame.
    func regionCapture(screen: ScreenGeometry, rect: CGRect) async throws -> RegionSnapshot {
        try Task.checkCancellation()
        try requirePermission()
        let clipped = rect.standardized.intersection(screen.localBounds)
        let pixels = CoordinateSpace.imagePixelRect(fromSelection: clipped, screen: screen)
        guard !clipped.isNull, pixels.width >= 2, pixels.height >= 2 else { throw AppError.imageCreation }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
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

    /// Prepares a fixed window identity or a geometry-checked display viewport for scrolling.
    func scrollCapture(context: CaptureContext) async throws -> RegionSnapshot {
        try Task.checkCancellation()
        try requirePermission()
        let originalWindow = context.windowID.flatMap { Self.windowGeometry(id: $0) }
        if context.windowID != nil, originalWindow == nil { throw ScrollTargetError.windowUnavailable }
        let baseline = ScrollTargetGeometry(context: context, window: originalWindow)
        let validation: @MainActor () throws -> CaptureContext? = {
            let window = context.windowID.flatMap { Self.windowGeometry(id: $0) }
            return try baseline.validate(window: window, screens: Self.screenGeometries())
        }
        let scrollValidation: @MainActor (CGPoint) throws -> Void = { point in
            guard let id = context.windowID else { throw ScrollTargetError.unsafeScroll }
            try Self.checkScrollDestination(windowID: id, point: point)
        }
        _ = try validation()
        guard context.kind == "window", let id = context.windowID, let originalWindow else {
            let prepared = try await regionCapture(screen: context.screen, rect: context.localRect)
            return RegionSnapshot(capture: { try await prepared.capture() },
                                  validate: validation, validateScroll: scrollValidation)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let window = content.windows.first(where: {
            $0.windowID == id && $0.owningApplication?.processID == originalWindow.ownerPID
        }) else { throw ScrollTargetError.windowUnavailable }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB
        // Preserve a screenshot's exact viewport relative to its window, even after the window moves.
        let originalFrame = context.targetWindowFrame ?? originalWindow.frame
        let relative = CGRect(x: context.globalRect.minX - originalFrame.minX,
                              y: originalFrame.maxY - context.globalRect.maxY,
                              width: context.globalRect.width, height: context.globalRect.height)
        let crop = CGRect(x: (relative.minX * scale).rounded(), y: (relative.minY * scale).rounded(),
                          width: (relative.width * scale).rounded(), height: (relative.height * scale).rounded())
        return RegionSnapshot(capture: {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) { () throws -> CGImage in
                try Task.checkCancellation()
                guard CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(crop),
                      let result = image.cropping(to: crop) else { throw ScrollTargetError.windowResized }
                return result
            }
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        }, validate: validation, validateScroll: scrollValidation)
    }

    private static func screenGeometries() -> [ScreenGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return ScreenGeometry(id: id, frame: screen.frame, scale: screen.backingScaleFactor, safeTop: screen.safeAreaInsets.top)
        }
    }

    private static func windowGeometry(id: UInt32) -> ScrollWindowGeometry? {
        // Query only the chosen compositor ID; no SCShareableContent enumeration occurs per frame.
        guard let dictionaries = CGWindowListCreateDescriptionFromArray([NSNumber(value: id)] as CFArray) as? [[String: Any]],
              let info = dictionaries.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              let owner = info[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
        return ScrollWindowGeometry(id: id, ownerPID: owner.int32Value,
            frame: CoordinateSpace.windowToAppKit(rect, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0),
            isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true)
    }

    private static func checkScrollDestination(windowID: UInt32, point: CGPoint) throws {
        let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], windowID) as? [[String: Any]] ?? []
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        for info in above {
            guard (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            if CoordinateSpace.windowToAppKit(rect, primaryTop: primaryTop).contains(point) {
                throw ScrollTargetError.unsafeScroll
            }
        }
    }
}

/// A session-owned ScreenCaptureKit request; native configuration never crosses actors.
@MainActor
final class RegionSnapshot {
    private let request: @MainActor () async throws -> CGImage
    private let validation: @MainActor () throws -> CaptureContext?
    private let scrollValidation: @MainActor (CGPoint) throws -> Void
    init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        request = { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) }
        validation = { nil }; scrollValidation = { _ in }
    }

    /// Injects a real image source and geometry check without requiring capture consent in flow tests.
    init(capture: @escaping @MainActor () async throws -> CGImage,
         validate: @escaping @MainActor () throws -> CaptureContext? = { nil },
         validateScroll: @escaping @MainActor (CGPoint) throws -> Void = { _ in }) {
        request = capture; validation = validate; scrollValidation = validateScroll
    }

    /// Validates identity and geometry before dispatching any event to the native target.
    func validatedContext(forAutomaticScroll: Bool = false) throws -> CaptureContext? {
        let context = try validation()
        if forAutomaticScroll, let context {
            try scrollValidation(CGPoint(x: context.globalRect.midX, y: context.globalRect.midY))
        }
        return context
    }

    /// Captures a fresh viewport without retaining previous samples or installing any listener.
    func capture() async throws -> CGImage {
        try Task.checkCancellation()
        _ = try validation()
        let image = try await request()
        try Task.checkCancellation()
        _ = try validation()
        return image
    }
}

/// Immutable window identity and point geometry from the window server, never pixel data.
struct ScrollWindowGeometry: Sendable {
    let id: UInt32
    let ownerPID: Int32
    let frame: CGRect
    let isOnScreen: Bool
}

/// A pure target check shared by native capture and geometry-change regression tests.
struct ScrollTargetGeometry: Sendable {
    let context: CaptureContext
    let window: ScrollWindowGeometry?

    /// Window captures follow translation; display regions must stay at their original coordinates.
    func validate(window current: ScrollWindowGeometry?, screens: [ScreenGeometry]) throws -> CaptureContext {
        guard let originalScreen = screens.first(where: { $0.id == context.screen.id }),
              originalScreen.frame == context.screen.frame, originalScreen.scale == context.screen.scale else {
            throw ScrollTargetError.displayChanged
        }
        guard let window else { return context }
        guard let current, current.id == window.id, current.ownerPID == window.ownerPID, current.isOnScreen else {
            throw ScrollTargetError.windowUnavailable
        }
        let initialFrame = context.targetWindowFrame ?? window.frame
        guard abs(current.frame.width - initialFrame.width) <= 0.5,
              abs(current.frame.height - initialFrame.height) <= 0.5 else { throw ScrollTargetError.windowResized }
        if context.kind != "window" {
            guard current.frame == initialFrame else { throw ScrollTargetError.regionMoved }
            return context
        }
        let relative = context.globalRect.offsetBy(dx: -initialFrame.minX, dy: -initialFrame.minY)
        let viewport = relative.offsetBy(dx: current.frame.minX, dy: current.frame.minY)
        guard let screen = screens.max(by: { a, b in
            let x = a.frame.intersection(viewport), y = b.frame.intersection(viewport)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        }), screen.frame.intersects(viewport), screen.scale == context.screen.scale else { throw ScrollTargetError.displayChanged }
        let origin = CoordinateSpace.globalPointToScreenLocal(CGPoint(x: viewport.minX, y: viewport.maxY), screen: screen)
        return CaptureContext(screen: screen, localRect: CGRect(origin: origin, size: viewport.size), kind: context.kind,
            appBundleID: context.appBundleID, windowID: current.id, targetWindowFrame: current.frame)
    }
}

/// Safe capture pauses distinguish a temporarily covered window from a target requiring reselection.
enum ScrollTargetError: LocalizedError, Sendable {
    case windowUnavailable, windowResized, regionMoved, displayChanged, unsafeScroll
    var errorDescription: String? {
        switch self {
        case .windowUnavailable: "目标窗口已关闭或最小化。捕获已暂停，请重新选择窗口。"
        case .windowResized: "窗口尺寸已改变。捕获已暂停，请重新选择并从首屏开始。"
        case .regionMoved: "选区所在窗口已移动。捕获已暂停，请重新选择区域。"
        case .displayChanged: "显示器或缩放已改变。捕获已暂停，请重新选择窗口或区域。"
        case .unsafeScroll: "滚动位置被其他窗口遮挡，未派发滚动。请露出目标窗口后重试，或改为手动滚动。"
        }
    }
    var requiresReselection: Bool { if case .unsafeScroll = self { false } else { true } }
}
