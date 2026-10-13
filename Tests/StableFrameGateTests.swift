// Checks real quiet time after the last motion, while keeping idle and bottom detection distinct.
import XCTest
@testable import NikoShot

final class StableFrameGateTests: XCTestCase {
    func testStableContentIsAcceptedAfter120MillisecondsInsteadOf450() {
        var gate = StableFrameGate()
        XCTAssertFalse(gate.observe(previousDifference: 0, acceptedDifference: 0.1, elapsed: .zero, mode: .manual))
        XCTAssertFalse(gate.observe(previousDifference: 0, acceptedDifference: 0.1, elapsed: .milliseconds(60), mode: .manual))
        XCTAssertTrue(gate.observe(previousDifference: 0, acceptedDifference: 0.1, elapsed: .milliseconds(120), mode: .manual))
    }

    func testLateMotionStartsANewQuietPeriodInsteadOfUsingTheLoopStartTime() {
        var gate = StableFrameGate()
        XCTAssertFalse(gate.observe(previousDifference: 0.1, acceptedDifference: 0.2, elapsed: .seconds(5), mode: .manual))
        for offset in [10, 20, 30, 60, 100] {
            XCTAssertFalse(gate.observe(previousDifference: 0, acceptedDifference: 0.2,
                elapsed: .seconds(5) + .milliseconds(offset), mode: .manual))
        }
        XCTAssertTrue(gate.observe(previousDifference: 0, acceptedDifference: 0.2,
            elapsed: .seconds(5) + .milliseconds(120), mode: .manual))
    }

    func testManualIdleNeverMeansTheBottom() {
        var gate = StableFrameGate()
        for second in 1...10 {
            XCTAssertFalse(gate.observe(previousDifference: 0, acceptedDifference: 0,
                elapsed: .seconds(second), mode: .manual))
        }
        XCTAssertFalse(gate.observe(previousDifference: 0.1, acceptedDifference: 0.1, elapsed: .seconds(11), mode: .manual))
        for offset in [40, 80] {
            XCTAssertFalse(gate.observe(previousDifference: 0, acceptedDifference: 0.1,
                elapsed: .seconds(11) + .milliseconds(offset), mode: .manual))
        }
        XCTAssertTrue(gate.observe(previousDifference: 0, acceptedDifference: 0.1,
            elapsed: .seconds(11) + .milliseconds(120), mode: .manual))
    }

    func testAutomaticBottomWaitsForTheDispatchedScrollToHaveTimeToAppear() {
        var gate = StableFrameGate()
        for offset in [0, 60, 120, 300, 440] {
            XCTAssertFalse(gate.observe(previousDifference: 0, acceptedDifference: 0,
                elapsed: .milliseconds(offset), mode: .automatic, minimumObservationTime: .milliseconds(450)))
        }
        XCTAssertTrue(gate.observe(previousDifference: 0, acceptedDifference: 0,
            elapsed: .milliseconds(450), mode: .automatic, minimumObservationTime: .milliseconds(450)))
    }

    @MainActor
    func testSparseTextScrollIsAcceptedOnlyAfterItSettles() async throws {
        let fixture = ScrollImageFixture()
        let accepted = try await fixture.sparseText(start: 0), moved = try await fixture.sparseText(start: 20)
        let changed = try await fixture.signatureDifference(accepted, moved)
        var gate = StableFrameGate()
        XCTAssertFalse(gate.observe(previousDifference: changed, acceptedDifference: changed, elapsed: .zero, mode: .manual))
        for offset in [40, 80] {
            XCTAssertFalse(gate.observe(previousDifference: 0, acceptedDifference: changed, elapsed: .milliseconds(offset), mode: .manual))
        }
        XCTAssertTrue(gate.observe(previousDifference: 0, acceptedDifference: changed, elapsed: .milliseconds(120), mode: .manual))
    }

    @MainActor
    func testContinuousSparseMotionNeverLooksStationary() async throws {
        let fixture = ScrollImageFixture(), accepted = try await fixture.sparseText(start: 0)
        var previous = accepted, gate = StableFrameGate()
        for (tick, movement) in [5, 10, 15, 20].enumerated() {
            let image = try await fixture.sparseText(start: movement)
            let motion = try await fixture.signatureDifference(previous, image)
            let changed = try await fixture.signatureDifference(accepted, image)
            XCTAssertFalse(gate.observe(previousDifference: motion, acceptedDifference: changed,
                elapsed: .milliseconds(tick * 60), mode: .manual))
            previous = image
        }
        let changed = try await fixture.signatureDifference(accepted, previous)
        for offset in [220, 260] {
            XCTAssertFalse(gate.observe(previousDifference: 0, acceptedDifference: changed,
                elapsed: .milliseconds(offset), mode: .manual))
        }
        XCTAssertTrue(gate.observe(previousDifference: 0, acceptedDifference: changed, elapsed: .milliseconds(300), mode: .manual))
    }
}
