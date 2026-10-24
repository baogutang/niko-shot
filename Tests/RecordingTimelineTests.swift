// Verifies clock alignment across pause/resume and late framework delivery without live capture permissions.
import XCTest
@testable import NikoShot

final class RecordingTimelineTests: XCTestCase {
    func testBothTracksRemoveTheSamePauseIntervals() {
        var clock = RecordingTimeline()
        clock.begin(at: 100)
        XCTAssertEqual(clock.presentationTime(for: 101), 1)
        clock.pause(at: 102)
        XCTAssertNil(clock.presentationTime(for: 103))
        XCTAssertEqual(clock.elapsed(at: 105), 2)
        clock.resume(at: 107)
        XCTAssertEqual(clock.presentationTime(for: 108), 3)
        clock.pause(at: 109); clock.resume(at: 111)
        XCTAssertEqual(clock.presentationTime(for: 112), 5)
        XCTAssertEqual(clock.elapsed(at: 112), 5)
        XCTAssertEqual(clock.pausedDuration, 7)
    }

    func testLatePausedSamplesStayDiscardedAfterResume() {
        var clock = RecordingTimeline(); clock.begin(at: 20)
        clock.pause(at: 22); clock.resume(at: 25)
        XCTAssertNil(clock.presentationTime(for: 23.9))
        XCTAssertEqual(clock.presentationTime(for: 25), 2)
        XCTAssertEqual(clock.presentationTime(for: 21), 1)
        XCTAssertNil(clock.presentationTime(for: 19))
    }

    func testPauseBeforeFirstCompleteFrameDoesNotCreateNegativeDuration() {
        var clock = RecordingTimeline(); clock.pause(at: 10); clock.resume(at: 11)
        clock.begin(at: 12)
        XCTAssertEqual(clock.elapsed(at: 13), 1)
        XCTAssertEqual(clock.presentationTime(for: 12), 0)
    }

    func testBitRateTracksResolutionFrameRateCodecAndQuality() {
        let low = RecordingOptions(fps: 15, quality: 0.2)
        let high = RecordingOptions(fps: 60, codec: "h264", quality: 1)
        XCTAssertGreaterThan(high.bitRate(width: 1_920, height: 1_080), low.bitRate(width: 1_920, height: 1_080))
        XCTAssertGreaterThan(high.bitRate(width: 3_840, height: 2_160), high.bitRate(width: 1_920, height: 1_080))
        XCTAssertEqual(RecordingOptions(fps: 17, quality: .nan).fps, 30)
        XCTAssertEqual(RecordingOptions(quality: .nan).quality, 0.65)
    }

    func testH264OutputFitsTheHardwareEncoderLimitWithEvenAspectPreservingSize() {
        let h264 = RecordingOptions(codec: "h264"), hevc = RecordingOptions(codec: "hevc")
        XCTAssertTrue(h264.encodedSize(width: 5_120, height: 2_880) == (4_096, 2_304))
        let retina = h264.encodedSize(width: 4_112, height: 2_658)
        XCTAssertEqual(retina.height, 2_304); XCTAssertLessThanOrEqual(retina.width, 4_096); XCTAssertEqual(retina.width % 2, 0)
        XCTAssertEqual(Double(retina.width) / Double(retina.height), 4_112.0 / 2_658, accuracy: 0.002)
        XCTAssertTrue(h264.encodedSize(width: 1_200, height: 5_000) == (552, 2_304))
        XCTAssertTrue(h264.encodedSize(width: 4_096, height: 2_304) == (4_096, 2_304))
        XCTAssertTrue(h264.encodedSize(width: 1_919, height: 1_081) == (1_918, 1_080))
        XCTAssertTrue(h264.encodedSize(width: 2.4, height: 2) == (2, 2))
        XCTAssertTrue(hevc.encodedSize(width: 5_120, height: 2_880) == (5_120, 2_880), "HEVC keeps full resolution")
    }
}
