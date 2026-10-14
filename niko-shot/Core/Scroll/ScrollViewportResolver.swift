// Resolves a selected window's scrollable content without requesting any additional permission.
import AppKit
@preconcurrency import ApplicationServices

enum ScrollViewportResolver {
    /// Uses existing Accessibility consent only; unavailable or ambiguous metadata preserves the selection.
    @MainActor static func resolve(_ context: CaptureContext) async -> CaptureContext {
        guard context.kind == "window", let id = context.windowID,
              let original = context.targetWindowFrame,
              sameFrame(context.globalRect, original), AXIsProcessTrusted(),
              let window = try? CaptureEngine.windowGeometry(id: id),
              !context.appBundleID.isEmpty,
              NSRunningApplication(processIdentifier: window.ownerPID)?.bundleIdentifier == context.appBundleID,
              let primaryTop = NSScreen.screens.first?.frame.maxY else { return context }
        let expected = CoordinateSpace.windowToAppKit(window.frame, primaryTop: primaryTop)
        // AX uses top-left global coordinates; the selected context uses AppKit global points.
        let pid = window.ownerPID
        let task = Task.detached(priority: .userInitiated) {
            scrollAreas(pid: pid, window: expected)
        }
        let frames = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled else { return context }
        let candidates = frames.map { CoordinateSpace.windowToAppKit($0, primaryTop: primaryTop) }
        return refined(context, scrollAreas: candidates)
    }

    /// Pure geometry selection keeps explicit regions intact and declines equally plausible content panes.
    static func refined(_ context: CaptureContext, scrollAreas: [CGRect]) -> CaptureContext {
        guard context.kind == "window", let window = context.targetWindowFrame,
              sameFrame(context.globalRect, window) else { return context }
        let candidates = scrollAreas.filter { frame in
            finite(frame) && frame.width >= window.width * 0.35 && frame.height * context.screen.scale >= 240 &&
                frame.width * frame.height >= window.width * window.height * 0.20 &&
                window.insetBy(dx: -1, dy: -1).contains(frame)
        }.sorted { $0.width * $0.height > $1.width * $1.height }
        guard let first = candidates.first else { return context }
        // Duplicate/nested AX nodes describe the same content, while separate equally sized panes are ambiguous.
        if candidates.dropFirst().contains(where: {
            $0.width * $0.height >= first.width * first.height * 0.90 &&
                $0.intersection(first).width * $0.intersection(first).height < first.width * first.height * 0.80
        }) { return context }
        let local = CGRect(x: first.minX - context.screen.frame.minX,
                           y: context.screen.frame.maxY - first.maxY,
                           width: first.width, height: first.height).intersection(context.screen.localBounds)
        guard local.width * context.screen.scale >= 2, local.height * context.screen.scale >= 240 else { return context }
        return CaptureContext(screen: context.screen, localRect: local, kind: context.kind,
                              appBundleID: context.appBundleID, windowID: context.windowID,
                              targetWindowFrame: context.targetWindowFrame)
    }

    private static func scrollAreas(pid: pid_t, window: CGRect) -> [CGRect] {
        guard !Task.isCancelled else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        let deadline = ContinuousClock.now + .milliseconds(400)
        guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var chosen: AXUIElement?
        for element in windows.prefix(32) {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return [] }
            if let frame = frame(element), sameFrame(frame, window) { chosen = element; break }
        }
        guard let chosen else { return [] }
        var queue: [(AXUIElement, Int)] = [(chosen, 0)]
        var cursor = 0, frames: [CGRect] = []
        while cursor < queue.count, cursor < 512 {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return [] }
            let (element, depth) = queue[cursor]; cursor += 1
            if attribute(element, kAXRoleAttribute) as? String == kAXScrollAreaRole, let frame = frame(element) {
                frames.append(frame)
                continue // Descendant viewports cannot be larger than their visible containing scroll area.
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement], !children.isEmpty {
                guard depth < 12, children.count <= 512 - queue.count else { return [] }
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return frames
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        // The CF type IDs above validate both casts before using the C AXValue API.
        let pointValue = unsafeDowncast(position, to: AXValue.self)
        let sizeValue = unsafeDowncast(size, to: AXValue.self)
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(pointValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        let result = CGRect(origin: point, size: dimensions)
        return finite(result) ? result : nil
    }
    private static func finite(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite &&
            frame.width > 0 && frame.height > 0
    }
    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        finite(a) && finite(b) && abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 &&
            abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}
