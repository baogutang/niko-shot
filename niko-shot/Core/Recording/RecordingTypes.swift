// Defines native recording targets, encoding options, and errors shared with the controls.
import CoreGraphics
import Foundation

/// A ScreenCaptureKit source; region rectangles use top-left, display-local points.
public enum RecordingTarget: Sendable, Equatable {
    case region(displayID: UInt32, rect: CGRect, scale: CGFloat)
    case window(id: UInt32, scale: CGFloat)
    case display(id: UInt32, scale: CGFloat)
}

/// Controls hardware video encoding and the independently selected audio/camera sources.
public struct RecordingOptions: Sendable, Equatable {
    public var fps: Int
    public var codec: String
    public var quality: Double
    public var systemAudio: Bool
    public var microphone: Bool
    public var showsCursor: Bool
    public var camera: Bool

    /// Creates options with HEVC, 30 FPS, and application-audio exclusion by default.
    public init(fps: Int = 30, codec: String = "hevc", quality: Double = 0.65,
                systemAudio: Bool = true, microphone: Bool = false,
                showsCursor: Bool = true, camera: Bool = false) {
        self.fps = [15, 24, 30, 60].contains(fps) ? fps : 30
        self.codec = ["h264", "h.264"].contains(codec.lowercased()) ? "h264" : "hevc"
        self.quality = quality.isFinite ? min(1, max(0, quality)) : 0.65
        self.systemAudio = systemAudio; self.microphone = microphone
        self.showsCursor = showsCursor; self.camera = camera
    }

    /// Derives bitrate from pixel count, frame rate, codec, and the selected quality.
    public func bitRate(width: Int, height: Int) -> Int {
        let pixels = Double(max(2, width)) * Double(max(2, height))
        let efficiency = codec == "hevc" ? 0.065 : 0.105
        let calculated = pixels * Double(fps) * efficiency * (0.45 + quality * 1.1)
        return Int(min(120_000_000, max(600_000, calculated)))
    }
}

/// Represents the lifecycle displayed by the recording setup and floating controls.
public enum RecordingState: String, Sendable {
    case idle, preparing, recording, paused, finishing, failed
}

/// An actionable native-media error, with no underlying framework object crossing actors.
public enum RecordingError: LocalizedError, Sendable {
    case permission(String), invalidTarget, encoder(String), capture(String), empty, notRecording, cancelled

    public var errorDescription: String? {
        switch self {
        case .permission(let name): "请在系统设置的隐私与安全性中允许\(name)。"
        case .invalidTarget: "录制区域或窗口已经不可用，请重新选择。"
        case .encoder(let message): "视频编码失败：\(message)"
        case .capture(let message): "录屏中断：\(message)"
        case .empty: "没有收到可录制的画面，未生成空视频。"
        case .notRecording: "当前没有正在进行的录制。"
        case .cancelled: "录制已取消。"
        }
    }
}

enum RecordingEvent: Sendable {
    case duration(Double)
    case failure(String)
}

struct RecordingResult: Sendable {
    let url: URL
    let duration: Double
}
