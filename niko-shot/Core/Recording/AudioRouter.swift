// Converts copied microphone/system PCM to 48 kHz stereo and mixes it into one AAC input.
@preconcurrency import AVFoundation // Audio taps expose legacy non-Sendable buffers; only owned Float arrays leave a tap.
import AudioToolbox
import CoreMedia
import Foundation
import os

enum RecordingAudioSource: String, Sendable { case system, microphone }

/// An owned copy of PCM, safe to deliver from an audio-render callback to the writer queue.
struct RecordingPCMFrame: Sendable {
    var sourceTime: Double
    var sampleRate: Double
    var channels: Int
    var samples: [Float]
    var frameCount: Int { samples.count / max(1, channels) }

    /// AVAudioFormat needs an explicit channel layout above two channels, so multi-input devices keep their first pair.
    var leadingStereo: RecordingPCMFrame {
        guard channels > 2 else { return self }
        var pair = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            pair[frame * 2] = samples[frame * channels]; pair[frame * 2 + 1] = samples[frame * channels + 1]
        }
        return RecordingPCMFrame(sourceTime: sourceTime, sampleRate: sampleRate, channels: 2, samples: pair)
    }
}

struct MixedRecordingAudio: Sendable {
    var startFrame: Int
    var samples: [Float]
    var frameCount: Int { samples.count / 2 }
}

/// A bounded, timestamp-aligned stereo mixer; absent samples become silence and sums are limited.
struct RecordingAudioMixer {
    private let capacity = 48_000
    private var system: [Float] = .init(repeating: 0, count: 96_000)
    private var microphone: [Float] = .init(repeating: 0, count: 96_000)
    private var systemStamps: [Int] = .init(repeating: -1, count: 48_000)
    private var microphoneStamps: [Int] = .init(repeating: -1, count: 48_000)
    private(set) var nextFrame = 0
    private(set) var latestFrame = 0
    private(set) var latestSystemFrame = 0
    private(set) var latestMicrophoneFrame = 0

    /// Inserts one interleaved, 48 kHz stereo source without retaining any framework buffer.
    mutating func append(samples: [Float], at startFrame: Int, source: RecordingAudioSource) {
        guard samples.count >= 2 else { return }
        for offset in 0..<(samples.count / 2) {
            let frame = startFrame + offset
            guard frame >= nextFrame else { continue }
            let slot = frame % capacity
            let left = samples[offset * 2].isFinite ? samples[offset * 2] : 0
            let right = samples[offset * 2 + 1].isFinite ? samples[offset * 2 + 1] : 0
            switch source {
            case .system:
                system[slot * 2] = left; system[slot * 2 + 1] = right; systemStamps[slot] = frame
            case .microphone:
                microphone[slot * 2] = left; microphone[slot * 2 + 1] = right; microphoneStamps[slot] = frame
            }
        }
        latestFrame = max(latestFrame, startFrame + samples.count / 2)
        if source == .system { latestSystemFrame = max(latestSystemFrame, startFrame + samples.count / 2) }
        else { latestMicrophoneFrame = max(latestMicrophoneFrame, startFrame + samples.count / 2) }
    }

    /// Emits a small continuous block only when its caller has encoder capacity.
    mutating func consume(until endFrame: Int, maximumFrames: Int = 1_024) -> MixedRecordingAudio? {
        let count = min(maximumFrames, endFrame - nextFrame)
        guard count > 0 else { return nil }
        var samples = [Float](repeating: 0, count: count * 2)
        for offset in 0..<count {
            let frame = nextFrame + offset, slot = frame % capacity
            let hasSystem = systemStamps[slot] == frame, hasMicrophone = microphoneStamps[slot] == frame
            for channel in 0..<2 {
                let value = (hasSystem ? system[slot * 2 + channel] : 0)
                    + (hasMicrophone ? microphone[slot * 2 + channel] : 0)
                samples[offset * 2 + channel] = min(1, max(-1, value))
            }
        }
        let block = MixedRecordingAudio(startFrame: nextFrame, samples: samples)
        nextFrame += count
        return block
    }
}

/// Owns audio conversion/mixing on the recording writer queue, including the macOS 14 microphone path.
final class AudioRouter {
    static let sampleRate = 48_000.0
    private let includesBothSources: Bool
    private final class ConversionState {
        let converter: AVAudioConverter
        let source: RecordingAudioSource
        let firstFrame: Int
        var inputFrames = 0
        var nextFrame: Int
        init(converter: AVAudioConverter, source: RecordingAudioSource, nextFrame: Int) {
            self.converter = converter; self.source = source; self.nextFrame = nextFrame; firstFrame = nextFrame
        }
    }
    private var converters: [String: ConversionState] = [:]
    private var engine: AVAudioEngine?
    private let stereoFormat: AVAudioFormat
    private(set) var mixer = RecordingAudioMixer()
    var isMicrophoneRunning: Bool { engine?.isRunning == true }

    init(systemAudio: Bool, microphone: Bool) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: Self.sampleRate, channels: 2, interleaved: true) else {
            throw RecordingError.encoder("无法创建双声道音频格式。")
        }
        stereoFormat = format
        includesBothSources = systemAudio && microphone
    }

    /// Starts an AVAudioEngine tap only when the user explicitly enables their microphone.
    func startMicrophone(deliver: @escaping @Sendable (RecordingPCMFrame) -> Void) throws {
        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.capture("没有可用的麦克风输入设备。")
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, time in
            // The tap-owned PCM buffer never enters a Task or a dispatch closure.
            let host = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if let copy = Self.copyPCM(buffer, sourceTime: host) { deliver(copy) }
        }
        audioEngine.prepare()
        do { try audioEngine.start() }
        catch { input.removeTap(onBus: 0); throw RecordingError.capture(error.localizedDescription) }
        engine = audioEngine
    }

    /// Removes the tap before stopping the engine; no capture work remains when idle.
    func stopMicrophone() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Converts one owned PCM frame and aligns it to the pause-free output timeline.
    func append(_ frame: RecordingPCMFrame, at presentationTime: Double, source: RecordingAudioSource) throws {
        let frame = frame.leadingStereo
        guard frame.frameCount > 0, presentationTime >= 0 else { return }
        let start = Int((presentationTime * Self.sampleRate).rounded())
        if frame.sampleRate == Self.sampleRate, frame.channels == 2 {
            mixer.append(samples: frame.samples, at: start, source: source); return
        }
        let key = "\(source.rawValue):\(frame.sampleRate):\(frame.channels)"
        let state: ConversionState
        if let cached = converters[key] { state = cached }
        else {
            guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: frame.sampleRate,
                                                  channels: AVAudioChannelCount(frame.channels), interleaved: false),
                  let converter = AVAudioConverter(from: sourceFormat, to: stereoFormat) else {
                throw RecordingError.encoder("麦克风采样率转换不可用。")
            }
            converter.primeMethod = .none
            if frame.channels == 1 { converter.channelMap = [0, 0] }
            state = ConversionState(converter: converter, source: source, nextFrame: start)
            converters[key] = state
        }
        state.inputFrames += frame.frameCount
        let samples = try convert(frame, converter: state.converter)
        // NoDataNow may retain up to an internal conversion block. Anchor output to its original samples,
        // not to the timestamp of the newer input that finally releases those samples.
        mixer.append(samples: samples, at: state.nextFrame, source: source)
        state.nextFrame += samples.count / 2
    }

    /// Releases every resampler's buffered tail at Pause/Stop, then resets conversion for the next segment.
    func flushConverters() throws {
        for state in converters.values {
            let converted = try drain(converter: state.converter, capacity: 4_096) { _, status in
                status.pointee = .endOfStream; return nil
            }
            // EOS includes the FIR filter's extra trailing zeros/ringing. Keep the exact source duration.
            let end = state.firstFrame + Int((Double(state.inputFrames) * Self.sampleRate / state.converter.inputFormat.sampleRate).rounded())
            let samples = Array(converted.prefix(max(0, end - state.nextFrame) * 2))
            mixer.append(samples: samples, at: state.nextFrame, source: state.source)
            state.nextFrame += samples.count / 2
        }
        converters.removeAll()
    }

    /// Waits for both source cursors, including resampler buffering, with a bounded 170 ms silence fallback.
    var readyThroughFrame: Int {
        guard includesBothSources else { return mixer.latestFrame }
        let shared = min(mixer.latestSystemFrame, mixer.latestMicrophoneFrame) - 1_024
        return max(0, max(shared, mixer.latestFrame - 8_192))
    }

    func consume(until frame: Int) -> MixedRecordingAudio? { mixer.consume(until: frame) }

    /// Builds a queue-confined CMSampleBuffer for the single AAC writer input.
    func sampleBuffer(for block: MixedRecordingAudio) throws -> CMSampleBuffer {
        let length = block.samples.count * MemoryLayout<Float>.size
        var data: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &data)
        guard status == noErr, let data else { throw RecordingError.encoder("音频缓冲区分配失败 (\(status))。") }
        status = block.samples.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(with: address, blockBuffer: data, offsetIntoDestination: 0, dataLength: length)
        }
        guard status == noErr else { throw RecordingError.encoder("音频数据复制失败 (\(status))。") }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: data, formatDescription: stereoFormat.formatDescription, sampleCount: block.frameCount,
            presentationTimeStamp: CMTime(value: Int64(block.startFrame), timescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw RecordingError.encoder("音频时间戳封装失败 (\(status))。") }
        return sample
    }

    /// Copies ScreenCaptureKit PCM synchronously while the callback's retained block is valid.
    static func copySystemPCM(_ sample: CMSampleBuffer) -> RecordingPCMFrame? {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        // The system wrapper sizes the variable-length ABL exactly and retains its data for this scope.
        // Some macOS CoreMedia builds reject an oversized ABL even when its capacity is sufficient.
        return try? sample.withAudioBufferList(flags: .audioBufferListAssure16ByteAlignment) { list, _ in
            copyPCM(list: list, format: format,
                    frameCount: CMSampleBufferGetNumSamples(sample), sourceTime: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
    }

    private static func copyPCM(_ buffer: AVAudioPCMBuffer, sourceTime: Double) -> RecordingPCMFrame? {
        copyPCM(list: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList)),
                format: buffer.format, frameCount: Int(buffer.frameLength), sourceTime: sourceTime)
    }

    private static func copyPCM(list: UnsafeMutableAudioBufferListPointer, format: AVAudioFormat,
                                frameCount: Int, sourceTime: Double) -> RecordingPCMFrame? {
        let channels = Int(format.channelCount)
        guard frameCount > 0, channels > 0, channels <= 32, sourceTime.isFinite else { return nil }
        let sampleBytes: Int
        switch format.commonFormat {
        case .pcmFormatFloat32, .pcmFormatInt32: sampleBytes = 4
        case .pcmFormatFloat64: sampleBytes = 8
        case .pcmFormatInt16: sampleBytes = 2
        default: return nil
        }
        let expectedBuffers = format.isInterleaved ? 1 : channels
        guard list.count >= expectedBuffers else { return nil }
        for index in 0..<expectedBuffers {
            guard list[index].mData != nil,
                  Int(list[index].mDataByteSize) >= frameCount * (format.isInterleaved ? channels : 1) * sampleBytes else { return nil }
        }
        var samples = [Float](repeating: 0, count: frameCount * channels)
        for frame in 0..<frameCount {
            for channel in 0..<channels {
                let buffer = list[format.isInterleaved ? 0 : channel]
                guard let pointer = buffer.mData else { return nil }
                let offset = format.isInterleaved ? frame * channels + channel : frame
                let value: Float
                switch format.commonFormat {
                case .pcmFormatFloat32: value = pointer.assumingMemoryBound(to: Float.self)[offset]
                case .pcmFormatFloat64: value = Float(pointer.assumingMemoryBound(to: Double.self)[offset])
                case .pcmFormatInt16: value = Float(pointer.assumingMemoryBound(to: Int16.self)[offset]) / 32_768
                case .pcmFormatInt32: value = Float(pointer.assumingMemoryBound(to: Int32.self)[offset]) / 2_147_483_648
                default: return nil
                }
                samples[frame * channels + channel] = value
            }
        }
        return RecordingPCMFrame(sourceTime: sourceTime, sampleRate: format.sampleRate, channels: channels, samples: samples)
    }

    private func convert(_ frame: RecordingPCMFrame, converter: AVAudioConverter) throws -> [Float] {
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frame.frameCount)),
              let channels = input.floatChannelData else { throw RecordingError.encoder("无法创建麦克风转换缓冲区。") }
        input.frameLength = AVAudioFrameCount(frame.frameCount)
        for channel in 0..<frame.channels {
            for sample in 0..<frame.frameCount { channels[channel][sample] = frame.samples[sample * frame.channels + channel] }
        }
        let capacity = Int(ceil(Double(frame.frameCount) * Self.sampleRate / frame.sampleRate)) + 128
        let supplied = OSAllocatedUnfairLock(initialState: false)
        return try drain(converter: converter, capacity: capacity) { _, state in
            let alreadySupplied = supplied.withLock { value in
                let previous = value; value = true; return previous
            }
            if alreadySupplied { state.pointee = .noDataNow; return nil }
            state.pointee = .haveData; return input
        }
    }

    private func drain(converter: AVAudioConverter, capacity: Int,
                       input: @escaping AVAudioConverterInputBlock) throws -> [Float] {
        guard let output = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw RecordingError.encoder("无法创建转换后的音频缓冲区。")
        }
        var samples: [Float] = [], conversionError: NSError?
        while true {
            output.frameLength = 0
            let status = converter.convert(to: output, error: &conversionError, withInputFrom: input)
            guard status != .error, let pointer = output.floatChannelData?[0] else {
                throw RecordingError.encoder(conversionError?.localizedDescription ?? "音频转换失败。")
            }
            let count = Int(output.frameLength) * 2
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
            if status != .haveData || count == 0 { break }
        }
        return samples
    }
}
