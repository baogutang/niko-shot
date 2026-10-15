// Captures native ScreenCaptureKit snapshots, excluding this process before overlays exist.
import AppKit
// SCContentFilter/SCStreamConfiguration predate Sendable annotations; they stay within this engine's main-actor call.
@preconcurrency import ScreenCaptureKit
import os

@MainActor
final class CaptureEngine {
    private let log = OSLog(subsystem: "com.n1ko.niko-shot", category: "Capture")

    /// Checks screen recording consent; a missing grant opens the drag-to-authorize guide instead of a system alert.
    func requirePermission() throws {
        guard CGPreflightScreenCaptureAccess() else { throw AppError.permission("屏幕录制") }
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

    /// Reads compositor metadata without confusing unavailable query data with a closed window.
    static func windowGeometry(id: UInt32) throws -> ScrollWindowGeometry? {
        switch ScrollWindowServer.lookup(id: id) {
        case .visible(let geometry), .notVisible(let geometry): return geometry
        case .missing: return nil
        case .unknown: throw ScrollTargetError.windowStateUnknown
        }
    }

    static func checkScrollDestination(windowID: UInt32, point: CGPoint) throws {
        // Ask AppKit which window would receive input. Compositor rectangles also include
        // transparent Dock surfaces and our click-through overlay, which do not intercept it.
        guard NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == Int(windowID) else {
            throw ScrollTargetError.unsafeScroll
        }
    }
}

/// A session-owned single-frame source with target validation; native configuration never crosses actors.
@MainActor
final class RegionSnapshot {
    private let request: @MainActor () async throws -> CGImage
    private let validation: @MainActor () throws -> CaptureContext?
    private let scrollValidation: @MainActor (CGPoint) throws -> Void
    private let stopRequest: @MainActor () async -> Void
    private var stopped = false

    /// Injects a real image source and geometry check without requiring capture consent in flow tests.
    init(capture: @escaping @MainActor () async throws -> CGImage,
         validate: @escaping @MainActor () throws -> CaptureContext? = { nil },
         validateScroll: @escaping @MainActor (CGPoint) throws -> Void = { _ in },
         stop: @escaping @MainActor () async -> Void = {}) {
        request = capture; validation = validate; scrollValidation = validateScroll
        stopRequest = stop
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
        guard !stopped else { throw CancellationError() }
        _ = try validation()
        let image = try await request()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        _ = try validation()
        return image
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        await stopRequest()
    }
}

/// Immutable window identity and point geometry from the window server, never pixel data.
struct ScrollWindowGeometry: Sendable {
    let id: UInt32
    let ownerPID: Int32
    let frame: CGRect
    let isOnScreen: Bool
}

/// Successful list membership proves visibility; unknown metadata never authorizes capture.
enum ScrollWindowObservation: Sendable {
    case visible(ScrollWindowGeometry), notVisible(ScrollWindowGeometry), missing, unknown
}

/// Uses lightweight compositor lists instead of enumerating ScreenCaptureKit content every frame.
@MainActor
enum ScrollWindowServer {
    /// Queries hidden windows only when the selected ID is absent from the positive on-screen list.
    static func lookup(id: UInt32) -> ScrollWindowObservation {
        let visible = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        return resolve(id: id, onScreen: visible, includingHidden: {
            CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        }, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    /// Resolves optional visibility keys against positive membership while preserving ID, PID and bounds.
    static func resolve(id: UInt32, onScreen: [[String: Any]]?,
                        includingHidden: () -> [[String: Any]]?, primaryTop: CGFloat) -> ScrollWindowObservation {
        guard id != kCGNullWindowID else { return .missing }
        guard primaryTop.isFinite, let onScreen,
              onScreen.allSatisfy({ windowID(in: $0) != nil }) else { return .unknown }
        if let info = onScreen.first(where: { windowID(in: $0) == id }) {
            if let flag = info[kCGWindowIsOnscreen as String],
               (flag as? NSNumber)?.boolValue != true { return .unknown }
            guard let value = geometry(info, isOnScreen: true, primaryTop: primaryTop) else { return .unknown }
            return .visible(value)
        }
        guard let all = includingHidden(), all.allSatisfy({ windowID(in: $0) != nil }) else { return .unknown }
        guard let info = all.first(where: { windowID(in: $0) == id }) else { return .missing }
        // A window becoming visible between queries is retried, never mislabeled as closed.
        if let flag = info[kCGWindowIsOnscreen as String],
           (flag as? NSNumber)?.boolValue != false { return .unknown }
        guard let value = geometry(info, isOnScreen: false, primaryTop: primaryTop) else { return .unknown }
        return .notVisible(value)
    }

    private static func windowID(in info: [String: Any]) -> UInt32? {
        guard let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value, value > 0, value <= Double(UInt32.max) else { return nil }
        return UInt32(value)
    }

    private static func geometry(_ info: [String: Any], isOnScreen: Bool, primaryTop: CGFloat) -> ScrollWindowGeometry? {
        guard let id = windowID(in: info), let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        let pid = owner.doubleValue
        guard pid.isFinite, pid.rounded() == pid, pid > 0, pid <= Double(Int32.max) else { return nil }
        let frame = CoordinateSpace.windowToAppKit(rect, primaryTop: primaryTop)
        guard frame.origin.x.isFinite, frame.origin.y.isFinite else { return nil }
        return ScrollWindowGeometry(id: id, ownerPID: Int32(pid), frame: frame, isOnScreen: isOnScreen)
    }
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
        guard let current, current.isOnScreen else {
            throw ScrollTargetError.windowUnavailable
        }
        guard current.id == window.id, current.ownerPID == window.ownerPID else {
            throw ScrollTargetError.windowIdentityChanged
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
    case windowUnavailable, windowIdentityChanged, windowStateUnknown, windowResized, regionMoved, displayChanged, unsafeScroll
    var errorDescription: String? {
        switch self {
        case .windowUnavailable: "目标窗口已关闭或最小化。捕获已暂停，请重新选择窗口。"
        case .windowIdentityChanged: "目标窗口的身份已改变。捕获已暂停，请重新选择窗口。"
        case .windowStateUnknown: "暂时无法确认目标窗口状态。捕获已安全暂停，请稍后重试。"
        case .windowResized: "窗口尺寸已改变。捕获已暂停，请重新选择并从首屏开始。"
        case .regionMoved: "选区所在窗口已移动。捕获已暂停，请重新选择区域。"
        case .displayChanged: "显示器或缩放已改变。捕获已暂停，请重新选择窗口或区域。"
        case .unsafeScroll: "滚动位置被其他窗口遮挡，未派发滚动。请露出目标窗口后重试，或改为手动滚动。"
        }
    }
    var requiresReselection: Bool {
        switch self {
        case .unsafeScroll, .windowStateUnknown: false
        default: true
        }
    }
}
