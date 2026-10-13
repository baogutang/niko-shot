// Separates active scrolling motion detection from pixel matching and never polls while idle.
import Foundation

/// Accepts a viewport only after several stable observations, with explicit manual-mode semantics.
struct StableFrameGate: Sendable {
    private var stableObservations = 0
    private var lastMovement: Duration = .zero

    /// Moving frames reset the gate; a stationary manual viewport waits for the user to scroll.
    mutating func observe(previousDifference: Float, acceptedDifference: Float,
                          elapsed: Duration, mode: ScrollCaptureMode,
                          minimumObservationTime: Duration = .zero) -> Bool {
        guard previousDifference.isFinite, acceptedDifference.isFinite else {
            stableObservations = 0; lastMovement = elapsed; return false
        }
        if previousDifference > 0.002 { stableObservations = 0; lastMovement = elapsed }
        else { stableObservations += 1 }
        guard stableObservations >= 3, elapsed - lastMovement >= .milliseconds(120),
              elapsed >= minimumObservationTime else { return false }
        return mode == .automatic || acceptedDifference > 0.004
    }
}
