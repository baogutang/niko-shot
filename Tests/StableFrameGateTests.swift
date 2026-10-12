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
}
