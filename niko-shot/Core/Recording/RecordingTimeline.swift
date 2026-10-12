// Maps the ScreenCaptureKit and host-clock timestamps onto one pause-free media timeline.
import Foundation

/// A clock mapping shared by the video track and the mixed audio track.
public struct RecordingTimeline: Sendable, Equatable {
    public private(set) var origin: Double?
    public private(set) var pausedAt: Double?
    public private(set) var pausedDuration: Double = 0
    private var completedPauses: [Range<Double>] = []

    /// Creates an unstarted recording timeline.
    public init() {}

    /// Starts at the first complete screen frame, preventing leading hours of host-clock time.
    public mutating func begin(at sourceTime: Double) {
        guard origin == nil, sourceTime.isFinite else { return }
        origin = sourceTime
        completedPauses.removeAll { $0.upperBound <= sourceTime }
        pausedDuration = completedPauses.reduce(0) { $0 + max(0, $1.upperBound - max(sourceTime, $1.lowerBound)) }
        if let start = pausedAt { pausedAt = max(start, sourceTime) }
    }

    /// Freezes the elapsed time while samples from all sources are discarded.
    public mutating func pause(at hostTime: Double) {
        guard pausedAt == nil, hostTime.isFinite else { return }
        pausedAt = hostTime
    }

    /// Removes the same host-clock pause interval from every source.
    public mutating func resume(at hostTime: Double) {
        guard let start = pausedAt, hostTime.isFinite else { return }
        let end = max(start, hostTime)
        completedPauses.append(start..<end)
        pausedDuration += end - start
        pausedAt = nil
    }

    /// Returns a presentation timestamp, or nil for paused/pre-roll samples.
    public func presentationTime(for sourceTime: Double) -> Double? {
        guard pausedAt == nil, let origin, sourceTime.isFinite else { return nil }
        // Framework delivery can be delayed past Resume; paused-source frames still must be dropped.
        guard !completedPauses.contains(where: { $0.contains(sourceTime) }) else { return nil }
        let offset = completedPauses.reduce(0) { sum, interval in
            sum + (interval.upperBound <= sourceTime ? max(0, interval.upperBound - max(origin, interval.lowerBound)) : 0)
        }
        let value = sourceTime - origin - offset
        return value >= 0 ? value : nil
    }

    /// Includes time spent displaying an unchanged screen, and excludes every pause.
    public func elapsed(at hostTime: Double) -> Double {
        guard let origin else { return 0 }
        return max(0, (pausedAt ?? hostTime) - origin - pausedDuration)
    }
}
