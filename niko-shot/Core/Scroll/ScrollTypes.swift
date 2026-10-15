// Shared scroll-capture errors and modes.
import Foundation

/// Automatic mode dispatches wheel steps; manual mode follows the user's own scrolling.
public enum ScrollCaptureMode: String, CaseIterable, Sendable, Identifiable {
    case automatic, manual
    public var id: String { rawValue }
    public var title: String { self == .automatic ? "自动滚动" : "手动滚动" }
}

/// A deterministic, actionable error with no platform resources crossing an actor.
public enum ScrollCaptureError: LocalizedError, Sendable {
    case image, dimensionOverflow, noFrames, closed
    public var errorDescription: String? {
        switch self {
        case .image: "长截图画面无法读取，请重新选择区域。"
        case .dimensionOverflow: "长图尺寸超出可处理范围。"
        case .noFrames: "还没有捕获可输出的画面。"
        case .closed: "这次长截图已经结束。"
        }
    }
}
