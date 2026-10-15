// 长截图专用按需单帧源；普通截图和录屏继续使用各自原有的捕获路径。
import AppKit
import ScreenCaptureKit

@MainActor
final class WindowFrameGrabber {
    typealias WindowImageRequest = (CGRect, CGWindowListOption, CGWindowID) -> CGImage?
    private let request: WindowImageRequest

    init(request: @escaping WindowImageRequest = { NikoCreateWindowImage($0, $1, $2) }) {
        self.request = request
    }

    /// rect 是 WindowServer 左上原点的全局点坐标；不得提前乘 Retina 倍率。
    func captureWindow(windowID: CGWindowID, rect: CGRect) -> CGImage? {
        guard windowID != kCGNullWindowID, Self.valid(rect) else { return nil }
        return request(rect, .optionIncludingWindow, windowID)
    }

    /// 以选区蒙层为边界排除其上方的预览、控制条以及蒙层本身。
    func captureRegionBelowOwnWindow(ownWindowID: CGWindowID, rect: CGRect) -> CGImage? {
        guard ownWindowID != kCGNullWindowID, Self.valid(rect) else { return nil }
        return request(rect, .optionOnScreenBelowWindow, ownWindowID)
    }

    /// 鼠标所在屏优先；NSScreen.main 是键盘焦点屏，不适合多屏框选。
    static func screenForMouse(at location: CGPoint, screens: [ScreenGeometry]) -> ScreenGeometry? {
        screens.first { $0.frame.contains(location) }
    }

    static func windowServerRect(_ context: CaptureContext, primaryTop: CGFloat) -> CGRect {
        // 窗口移动到屏幕边缘仍保留原视口，不能再次裁成屏幕交集而伪装成窗口缩放。
        let source = context.localRect.standardized, scale = context.screen.scale
        let left = (source.minX * scale).rounded(), top = (source.minY * scale).rounded()
        let pixels = CGRect(x: left, y: top, width: (source.maxX * scale).rounded() - left,
                            height: (source.maxY * scale).rounded() - top)
        let aligned = CGRect(x: pixels.minX / context.screen.scale, y: pixels.minY / context.screen.scale,
                             width: pixels.width / context.screen.scale, height: pixels.height / context.screen.scale)
        return CoordinateSpace.windowToAppKit(CoordinateSpace.localToGlobal(aligned, screen: context.screen), primaryTop: primaryTop)
    }

    /// CG 默认分辨率可能与屏幕不同；只在尺寸不符时规范化，正常帧不反复重采样。
    static func normalized(_ image: CGImage, rect: CGRect, scale: CGFloat) throws -> CGImage {
        guard Self.valid(rect), scale.isFinite, scale > 0 else { throw ScrollCaptureError.image }
        let w = rect.width * scale, h = rect.height * scale
        guard w >= 1, h >= 1, w < CGFloat(Int32.max), h < CGFloat(Int32.max) else { throw ScrollCaptureError.dimensionOverflow }
        let width = Int(w.rounded()), height = Int(h.rounded())
        if image.width == width, image.height == height { return image }
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw ScrollCaptureError.image
        }
        canvas.interpolationQuality = .none
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = canvas.makeImage() else { throw ScrollCaptureError.image }
        return output
    }

    func prepare(context: CaptureContext, ownWindowID: CGWindowID?) async throws -> RegionSnapshot {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() else { throw AppError.permission("屏幕录制") }
        let original = try context.windowID.flatMap { try CaptureEngine.windowGeometry(id: $0) }
        if context.windowID != nil, original == nil { throw ScrollTargetError.windowUnavailable }
        if let original, !context.appBundleID.isEmpty,
           NSRunningApplication(processIdentifier: original.ownerPID)?.bundleIdentifier != context.appBundleID {
            throw ScrollTargetError.windowIdentityChanged
        }
        let baseline = ScrollTargetGeometry(context: context, window: original)
        let validate: @MainActor () throws -> CaptureContext? = {
            try baseline.validate(window: context.windowID.flatMap { try CaptureEngine.windowGeometry(id: $0) },
                screens: Self.screens())
        }
        let validateScroll: @MainActor (CGPoint) throws -> Void = { point in
            guard let id = context.windowID else { throw ScrollTargetError.unsafeScroll }
            try CaptureEngine.checkScrollDestination(windowID: id, point: point)
        }
        _ = try validate()

        var fallback: Task<RegionSnapshot, Error>?
        return RegionSnapshot(capture: { [self] in
            guard let current = try validate() else { throw ScrollCaptureError.image }
            let rect = Self.windowServerRect(current, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
            let image: CGImage?
            if current.kind == "window", let id = current.windowID { image = captureWindow(windowID: id, rect: rect) }
            else if let ownWindowID { image = captureRegionBelowOwnWindow(ownWindowID: ownWindowID, rect: rect) }
            else { throw ScrollCaptureError.image }
            if let image { return try Self.normalized(image, rect: rect, scale: current.screen.scale) }
            if #available(macOS 15, *) {
                // 后续系统不再提供 CG 图像时才初始化受支持的单帧源，正常帧没有 SCKit 枚举/流开销。
                if fallback == nil {
                    fallback = Task { @MainActor in
                        try await self.prepareModern(context: current, original: original, ownWindowID: ownWindowID,
                                                     validate: validate, validateScroll: validateScroll)
                    }
                }
                guard let fallback else { throw ScrollCaptureError.image }
                return try await fallback.value.capture()
            }
            throw AppError.imageCreation
        }, validate: validate, validateScroll: validateScroll, stop: {
            fallback?.cancel()
            if let prepared = try? await fallback?.value { await prepared.stop() }
            fallback = nil
        })
    }

    @available(macOS 15, *)
    private func prepareModern(context: CaptureContext, original: ScrollWindowGeometry?, ownWindowID: CGWindowID?,
        validate: @escaping @MainActor () throws -> CaptureContext?,
        validateScroll: @escaping @MainActor (CGPoint) throws -> Void) async throws -> RegionSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        let crop: CGRect?
        if context.kind == "window", let original,
           let window = content.windows.first(where: { $0.windowID == original.id && $0.owningApplication?.processID == original.ownerPID }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            // 使用目标屏幕的 backing 尺寸，避免移屏后套用 primary 的 DPI。
            config.width = Int((original.frame.width * context.screen.scale).rounded())
            config.height = Int((original.frame.height * context.screen.scale).rounded())
            let frame = context.targetWindowFrame ?? original.frame
            crop = CGRect(x: ((context.globalRect.minX - frame.minX) * context.screen.scale).rounded(),
                          y: ((frame.maxY - context.globalRect.maxY) * context.screen.scale).rounded(),
                          width: (context.globalRect.width * context.screen.scale).rounded(),
                          height: (context.globalRect.height * context.screen.scale).rounded())
        } else {
            guard let display = content.displays.first(where: { $0.displayID == context.screen.id }), let ownWindowID,
                  let below = CGWindowListCopyWindowInfo(.optionOnScreenBelowWindow, ownWindowID) as? [[String: Any]] else {
                throw ScrollCaptureError.image
            }
            let ids = Set(below.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
            let windows = content.windows.filter { ids.contains($0.windowID) && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, including: windows)
            let rect = CoordinateSpace.imagePixelRect(fromSelection: context.localRect, screen: context.screen)
            config.width = Int(rect.width); config.height = Int(rect.height)
            config.sourceRect = CGRect(x: rect.minX / context.screen.scale, y: rect.minY / context.screen.scale,
                                       width: rect.width / context.screen.scale, height: rect.height / context.screen.scale)
            crop = nil
        }
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        config.includeChildWindows = false
        config.captureResolution = .best; config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = false
        return RegionSnapshot(capture: {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if let crop {
                guard let cropped = image.cropping(to: crop), cropped.width == Int(crop.width), cropped.height == Int(crop.height) else {
                    throw ScrollTargetError.windowResized
                }
                return cropped
            }
            return image
        }, validate: validate, validateScroll: validateScroll)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0 && rect.origin.x.isFinite
            && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }
    private static func screens() -> [ScreenGeometry] {
        NSScreen.screens.compactMap {
            guard let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return ScreenGeometry(id: id, frame: $0.frame, scale: $0.backingScaleFactor, safeTop: $0.safeAreaInsets.top)
        }
    }
}
