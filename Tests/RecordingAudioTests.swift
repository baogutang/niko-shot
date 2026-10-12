// Validates actual dual-source PCM addition, clipping, timestamp placement and native sample-rate conversion.
import AVFoundation
import CoreMedia
import XCTest
@testable import NikoShot

final class RecordingAudioTests: XCTestCase {
    func testSystemAndMicrophoneAreMixedIntoOneAlignedStereoBlock() throws {
        var mixer = RecordingAudioMixer()
        mixer.append(samples: [0.3, -0.3, 0.8, -0.8], at: 1, source: .system)
        mixer.append(samples: [0.2, -0.2, 0.7, -0.7], at: 1, source: .microphone)
        let block = try XCTUnwrap(mixer.consume(until: 3))
        XCTAssertEqual(block.startFrame, 0)
        XCTAssertEqual(block.samples, [0, 0, 0.5, -0.5, 1, -1])
        mixer.append(samples: [0.9, 0.9], at: 1, source: .microphone)
        XCTAssertNil(mixer.consume(until: 3), "Late audio must not rewrite an already emitted block")
    }

    func testNativeConverterProduces48kStereoAndReadyPCMForAAC() throws {
        let router = try AudioRouter(systemAudio: false, microphone: true)
        let frame = RecordingPCMFrame(sourceTime: 0, sampleRate: 44_100, channels: 1,
                                      samples: [Float](repeating: 0.25, count: 4_410))
        try router.append(frame, at: 0, source: .microphone)
        try router.flushConverters()
        XCTAssertGreaterThan(router.mixer.latestFrame, 4_700)
        let block = try XCTUnwrap(router.consume(until: router.readyThroughFrame))
        let sample = try router.sampleBuffer(for: block)
        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description))
        XCTAssertEqual(format.pointee.mSampleRate, 48_000)
        XCTAssertEqual(format.pointee.mChannelsPerFrame, 2)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, 0)
        XCTAssertEqual(block.samples[200], block.samples[201], accuracy: 0.000_1)
        XCTAssertEqual(block.samples[200], 0.25, accuracy: 0.01)
    }

    func testResamplingKeepsContiguousOutputAcrossInputCallbacksAndDrainsTail() throws {
        let router = try AudioRouter(systemAudio: false, microphone: true)
        for callback in 0..<10 {
            let frame = RecordingPCMFrame(sourceTime: Double(callback) / 10, sampleRate: 44_100, channels: 1,
                                          samples: [Float](repeating: 0.25, count: 4_410))
            try router.append(frame, at: Double(callback) / 10, source: .microphone)
            // Simulate a writer continuously consuming output while the next tap is being delivered.
            while let block = router.consume(until: router.readyThroughFrame) {
                assertStableInterior(block)
            }
        }
        try router.flushConverters()
        while let block = router.consume(until: router.readyThroughFrame) {
            assertStableInterior(block)
        }
        XCTAssertEqual(router.mixer.nextFrame, 48_000, accuracy: 2)
    }

    private func assertStableInterior(_ block: MixedRecordingAudio) {
        // A finite DC fixture legitimately rings at its first/last FIR edge; callback boundaries must not.
        for index in 0..<block.frameCount where (128..<47_872).contains(block.startFrame + index) {
            XCTAssertEqual(block.samples[index * 2], 0.25, accuracy: 0.01, "Converter buffering must not insert gaps")
            XCTAssertEqual(block.samples[index * 2 + 1], 0.25, accuracy: 0.01)
        }
    }

    func testTailAudioDrainsInBoundedContinuousBlocks() throws {
        let router = try AudioRouter(systemAudio: true, microphone: true)
        let samples = [Float](repeating: 0.1, count: 9_600)
        try router.append(RecordingPCMFrame(sourceTime: 0, sampleRate: 48_000, channels: 2, samples: samples), at: 0, source: .system)
        try router.append(RecordingPCMFrame(sourceTime: 0, sampleRate: 48_000, channels: 2, samples: samples), at: 0, source: .microphone)
        XCTAssertLessThan(router.readyThroughFrame, 4_800)
        var emitted = 0
        while let block = router.consume(until: 4_800) {
            XCTAssertEqual(block.startFrame, emitted)
            XCTAssertLessThanOrEqual(block.frameCount, 1_024)
            XCTAssertEqual(block.samples[0], 0.2, accuracy: 0.000_1)
            emitted += block.frameCount
        }
        XCTAssertEqual(emitted, 4_800)
        XCTAssertEqual(router.mixer.nextFrame, 4_800)
    }
}
