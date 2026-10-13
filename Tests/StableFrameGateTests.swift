// Verifies moving-frame rejection and that a stationary manual page never implies the bottom.
import XCTest
@testable import NikoShot

final class StableFrameGateTests: XCTestCase {
    func testMovingFramesResetTheThreeObservationGate() {
        var gate = StableFrameGate()
        XCTAssertFalse(gate.observe(previousDifference: 0.1, acceptedDifference: 0.2, elapsed: .seconds(1), mode: .automatic))
        XCTAssertFalse(gate.observe(previousDifference: 0.001, acceptedDifference: 0.2, elapsed: .seconds(1), mode: .automatic))
        XCTAssertFalse(gate.observe(previousDifference: 0.001, acceptedDifference: 0.2, elapsed: .seconds(1), mode: .automatic))
        XCTAssertFalse(gate.observe(previousDifference: 0.1, acceptedDifference: 0.2, elapsed: .seconds(1), mode: .automatic))
        XCTAssertFalse(gate.observe(previousDifference: 0.001, acceptedDifference: 0.2, elapsed: .seconds(1), mode: .automatic))
        XCTAssertFalse(gate.observe(previousDifference: 0.001, acceptedDifference: 0.2, elapsed: .seconds(1), mode: .automatic))
        XCTAssertTrue(gate.observe(previousDifference: 0.001, acceptedDifference: 0.2, elapsed: .seconds(1), mode: .automatic))
    }

    func testManualModeWaitsForChangedContentEvenAfterLongIdle() {
        var gate = StableFrameGate()
        for _ in 0..<10 {
            XCTAssertFalse(gate.observe(previousDifference: 0, acceptedDifference: 0, elapsed: .seconds(60), mode: .manual))
        }
        XCTAssertTrue(gate.observe(previousDifference: 0.001, acceptedDifference: 0.1, elapsed: .seconds(61), mode: .manual))
    }

    func testAutomaticModeWaitsForInitialScrollToSettleBeforeDetectingBottom() {
        var gate = StableFrameGate()
        for _ in 0..<4 {
            XCTAssertFalse(gate.observe(previousDifference: 0, acceptedDifference: 0, elapsed: .milliseconds(300), mode: .automatic))
        }
        XCTAssertTrue(gate.observe(previousDifference: 0, acceptedDifference: 0, elapsed: .milliseconds(500), mode: .automatic))
    }

    @MainActor
    func testSparseTextScrollIsDetectedAfterItSettles() async throws {
        let fixture = ScrollImageFixture()
        let accepted = try await fixture.sparseText(start: 0)
        let moved = try await fixture.sparseText(start: 20)
        let changed = try await fixture.signatureDifference(accepted, moved)
        let stationary = try await fixture.signatureDifference(moved, moved)
        var gate = StableFrameGate()
        XCTAssertFalse(gate.observe(previousDifference: changed, acceptedDifference: changed, elapsed: .seconds(1), mode: .manual))
        XCTAssertFalse(gate.observe(previousDifference: stationary, acceptedDifference: changed, elapsed: .seconds(1), mode: .manual))
        XCTAssertFalse(gate.observe(previousDifference: stationary, acceptedDifference: changed, elapsed: .seconds(1), mode: .manual))
        XCTAssertTrue(gate.observe(previousDifference: stationary, acceptedDifference: changed, elapsed: .seconds(1), mode: .manual))
    }

    @MainActor
    func testContinuousSparseTextMotionKeepsResettingUntilARealPause() async throws {
        let fixture = ScrollImageFixture()
        let accepted = try await fixture.sparseText(start: 0)
        var previous = accepted, gate = StableFrameGate()
        for movement in [5, 10, 15, 20] {
            let image = try await fixture.sparseText(start: movement)
            let motion = try await fixture.signatureDifference(previous, image)
            let changed = try await fixture.signatureDifference(accepted, image)
            XCTAssertFalse(gate.observe(previousDifference: motion, acceptedDifference: changed, elapsed: .seconds(1), mode: .manual),
                "A changing text line must not appear stationary merely because most pixels are white")
            previous = image
        }
        let changed = try await fixture.signatureDifference(accepted, previous)
        XCTAssertFalse(gate.observe(previousDifference: 0, acceptedDifference: changed, elapsed: .seconds(1), mode: .manual))
        XCTAssertFalse(gate.observe(previousDifference: 0, acceptedDifference: changed, elapsed: .seconds(1), mode: .manual))
        XCTAssertTrue(gate.observe(previousDifference: 0, acceptedDifference: changed, elapsed: .seconds(1), mode: .manual))
    }
}
