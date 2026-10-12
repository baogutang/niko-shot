// Separates active scrolling motion detection from pixel matching and never polls while idle.
import Foundation

/// Accepts a viewport only after several stable observations, with explicit manual-mode semantics.
struct StableFrameGate: Sendable {
    private var stableObservations = 0

    /// Moving frames reset the gate; a stationary manual viewport waits for the user to scroll.
    mutating func observe(previousDifference: Float, acceptedDifference: Float,
                          elapsed: Duration, mode: ScrollCaptureMode) -> Bool {
        guard previousDifference.isFinite, acceptedDifference.isFinite else {
            stableObservations = 0; return false
        }
        stableObservations = previousDifference <= 0.002 ? stableObservations + 1 : 0
        guard stableObservations >= 3, elapsed >= .milliseconds(450) else { return false }
        return mode == .automatic || acceptedDifference > 0.004
    }
}
