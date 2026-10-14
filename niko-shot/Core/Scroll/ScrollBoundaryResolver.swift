// 空白尾部不能证明到底；仅自动模式可利用已授权的真实滚动条边界作独立证明。
import AppKit
@preconcurrency import ApplicationServices

enum ScrollBoundaryResolver {
    @MainActor static func isAtBottom(_ context: CaptureContext) async -> Bool {
        guard AXIsProcessTrusted(), let id = context.windowID,
              let window = try? CaptureEngine.windowGeometry(id: id), let primaryTop = NSScreen.screens.first?.frame.maxY else { return false }
        let point = CGPoint(x: context.globalRect.midX, y: primaryTop - context.globalRect.midY)
        let expected = CoordinateSpace.windowToAppKit(window.frame, primaryTop: primaryTop), pid = window.ownerPID
        let task = Task.detached(priority: .userInitiated) { query(pid: pid, point: point, expectedWindow: expected) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    static func isAtBottom(value: Double, minimum: Double, maximum: Double) -> Bool {
        value.isFinite && minimum.isFinite && maximum.isFinite && maximum > minimum && value >= maximum - 1e-9 && value <= maximum + 1e-9
    }

    private static func query(pid: pid_t, point: CGPoint, expectedWindow: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var hit: AXUIElement?
        let deadline = ContinuousClock.now + .milliseconds(250)
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return false }
        var element = hit
        for _ in 0..<12 {
            guard !Task.isCancelled, ContinuousClock.now < deadline, let current = element else { return false }
            if attribute(current, "AXRole") as? String == "AXScrollArea" {
                guard let owner = object(attribute(current, "AXWindow")), let frame = frame(owner),
                      abs(frame.minX - expectedWindow.minX) <= 1, abs(frame.minY - expectedWindow.minY) <= 1,
                      abs(frame.width - expectedWindow.width) <= 1, abs(frame.height - expectedWindow.height) <= 1,
                      let bar = object(attribute(current, "AXVerticalScrollBar")),
                      let value = number(attribute(bar, "AXValue")),
                      let minimum = number(attribute(bar, "AXMinValue")), let maximum = number(attribute(bar, "AXMaxValue")),
                      ContinuousClock.now < deadline, !Task.isCancelled else { return false }
                return isAtBottom(value: value, minimum: minimum, maximum: maximum)
            }
            element = object(attribute(current, "AXParent"))
        }
        return false
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        guard !Task.isCancelled else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    private static func object(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private static func number(_ value: CFTypeRef?) -> Double? {
        guard let value, CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, "AXPosition"), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element, "AXSize"), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(p, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(s, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
