// Defines immutable scroll-stitching options, confidence decisions, progress and resource diagnostics.
import Foundation

/// Fixed bands are measured in source-image pixels and removed from every captured frame.
public struct ScrollCaptureOptions: Sendable {
    public var ignoredTop: Int
    public var ignoredBottom: Int
    public var minimumCorrelation: Float
    /// Creates a pixel-based trim and an explicit confidence threshold for automatic stitching.
    public init(ignoredTop: Int = 0, ignoredBottom: Int = 0, minimumCorrelation: Float = 0.90) {
        self.ignoredTop = max(0, ignoredTop); self.ignoredBottom = max(0, ignoredBottom)
        self.minimumCorrelation = minimumCorrelation.isFinite ? min(1, max(0, minimumCorrelation)) : 0.90
    }
}

/// An overlap estimate with its normalized correlation and repeated-pattern ambiguity.
public struct StitchMatch: Sendable, Equatable {
    public let overlap: Int
    public let correlation: Float
    public let isAmbiguous: Bool
    /// Creates a match; ambiguous high peaks require the same explicit confirmation as low scores.
    public init(overlap: Int, correlation: Float, isAmbiguous: Bool = false) {
        self.overlap = overlap; self.correlation = correlation; self.isAmbiguous = isAmbiguous
    }
}

/// The caller retains a low-confidence candidate and can append it after confirming an overlap.
public enum ScrollAppendResult: Sendable, Equatable {
    case appended(height: Int, frames: Int)
    case duplicate
    case needsConfirmation(StitchMatch)
}

/// Lifecycle of one background stitching session.
public enum ScrollCaptureState: String, Sendable {
    case idle, capturing, awaitingConfirmation, finishing, completed, cancelled, failed
}

/// Immutable progress suitable for a native control panel.
public struct ScrollCaptureProgress: Sendable {
    public let width: Int
    public let height: Int
    public let frames: Int
    public let state: ScrollCaptureState
}

/// Counts owned resources; buffer bytes are implementation accounting, distinct from process RSS.
public struct ScrollResourceCounts: Sendable {
    public let openFiles: Int
    public let chunkFiles: Int
    public let ownedDirectories: Int
    public let residentBufferBytes: Int
    public let peakBufferBytes: Int
}

/// A deterministic, actionable error with no platform resources crossing an actor.
public enum ScrollCaptureError: LocalizedError, Sendable {
    case image, invalidBands, changedWidth, invalidOverlap, dimensionOverflow, noFrames, closed, disk(String)
    public var errorDescription: String? {
        switch self {
        case .image: "滚动截图图像无法读取。"
        case .invalidBands: "忽略的顶部与底部不能覆盖整个截图区域。"
        case .changedWidth: "截图区域宽度已经改变，请重新开始滚动截图。"
        case .invalidOverlap: "重叠高度必须小于相邻两帧的有效高度。"
        case .dimensionOverflow: "长图尺寸超过 PNG 支持范围。"
        case .noFrames: "还没有捕获可输出的画面。"
        case .closed: "这个滚动截图会话已经结束。"
        case .disk(let message): "长图写入失败：\(message)"
        }
    }
}
