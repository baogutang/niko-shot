// Keeps one ScreenCaptureKit stream and one latest frame for an active long screenshot.
import Accelerate
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import os

enum ScrollFrameSourceError: LocalizedError, Sendable {
    case unavailable, stopped, firstFrameTimeout
    var errorDescription: String? {
        switch self {
        case .unavailable: "当前屏幕画面不可用，请露出目标窗口后重试。"
        case .stopped: "屏幕捕获流已停止，请重试以接续长截图。"
        case .firstFrameTimeout: "尚未收到目标画面，请确认 Mac 已解锁、窗口可见，然后重试。"
        }
    }
}

/// The producer only replaces its latest immutable surface; consumers never queue screen images.
final class ScrollFrameBuffer: @unchecked Sendable {
    // Access is confined to the unfair lock; retained complete CoreVideo surfaces are read-only.
    private struct State: @unchecked Sendable {
        var pixelBuffer: CVPixelBuffer?
        var sequence: UInt64 = 0
        var error: (any Error)?
        var closed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let renderLock = NSLock()
    private var cachedSequence: UInt64?
    private var cachedImage: CGImage?
    private var cachedCrop: CGRect?

    var retainedFrameCount: Int { state.withLock { $0.pixelBuffer == nil ? 0 : 1 } }
    var renderedFrameCount: Int { renderLock.withLock { cachedImage == nil ? 0 : 1 } }

    /// Only complete compositor frames authorize pixels; idle retains the last complete frame.
    func receive(_ pixelBuffer: CVPixelBuffer?, status: SCFrameStatus) {
        state.withLockUnchecked { value in
            guard !value.closed else { return }
            switch status {
            case .complete:
                guard let pixelBuffer else { return }
                value.pixelBuffer = pixelBuffer; value.sequence &+= 1; value.error = nil
            case .idle: break
            case .started: break
            case .blank, .suspended:
                value.pixelBuffer = nil; value.error = ScrollFrameSourceError.unavailable
            case .stopped:
                value.pixelBuffer = nil; value.error = ScrollFrameSourceError.stopped
            @unknown default:
                value.pixelBuffer = nil; value.error = ScrollFrameSourceError.unavailable
            }
        }
    }

    func fail(_ error: any Error) {
        state.withLock { value in
            guard !value.closed else { return }
            value.pixelBuffer = nil; value.error = error
        }
    }

    /// Copies the configured sRGB BGRA surface once, without a second GPU color conversion.
    func image(crop: CGRect? = nil) throws -> CGImage? {
        let frame = try state.withLockUnchecked { value -> (CVPixelBuffer, UInt64)? in
            if value.closed { throw CancellationError() }
            if let error = value.error { throw error }
            return value.pixelBuffer.map { ($0, value.sequence) }
        }
        guard let (pixelBuffer, sequence) = frame else { return nil }
        return try renderLock.withLock {
            try Task.checkCancellation()
            try checkAvailable()
            if cachedSequence == sequence, cachedCrop == crop { return cachedImage }
            let topDown = crop ?? CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer),
                                        height: CVPixelBufferGetHeight(pixelBuffer))
            guard topDown.width >= 2, topDown.height >= 2,
                  topDown == topDown.integral,
                  CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer),
                         height: CVPixelBufferGetHeight(pixelBuffer)).contains(topDown) else {
                throw ScrollTargetError.windowResized
            }
            guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
                  CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
                throw AppError.imageCreation
            }
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw AppError.imageCreation }
            let width = Int(topDown.width), height = Int(topDown.height)
            let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let offset = Int(topDown.minY) * sourceStride + Int(topDown.minX) * 4
            var input = vImage_Buffer(data: base.advanced(by: offset), height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: sourceStride)
            var pixels = Data(count: width * height * 4)
            let channels: [UInt8] = [2, 1, 0, 3]
            let status = pixels.withUnsafeMutableBytes { bytes in
                var output = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(height),
                                          width: vImagePixelCount(width), rowBytes: width * 4)
                return channels.withUnsafeBufferPointer { map in
                    vImagePermuteChannels_ARGB8888(&input, &output, map.baseAddress!, vImage_Flags(kvImageNoFlags))
                }
            }
            guard status == kvImageNoError, let provider = CGDataProvider(data: pixels as CFData),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw AppError.imageCreation
            }
            try Task.checkCancellation()
            try checkAvailable()
            cachedSequence = sequence; cachedCrop = crop; cachedImage = image
            return image
        }
    }

    private func checkAvailable() throws {
        try state.withLock { value in
            if value.closed { throw CancellationError() }
            if let error = value.error { throw error }
        }
    }

    func close() {
        state.withLock { $0.closed = true; $0.pixelBuffer = nil; $0.error = nil }
        renderLock.withLock { cachedSequence = nil; cachedImage = nil; cachedCrop = nil }
    }
}

private final class ScrollStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let buffer: ScrollFrameBuffer
    init(buffer: ScrollFrameBuffer) { self.buffer = buffer }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        buffer.receive(CMSampleBufferGetImageBuffer(sampleBuffer), status: status)
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { buffer.fail(error) }
}

/// This sendable holder permits final cleanup without resurrecting its main-actor owner.
private final class ScrollNativeStream: @unchecked Sendable {
    let stream: SCStream
    let output: ScrollStreamOutput
    @MainActor private var stopped = false
    @MainActor init(filter: SCContentFilter, configuration: SCStreamConfiguration, buffer: ScrollFrameBuffer) throws {
        output = ScrollStreamOutput(buffer: buffer)
        stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "com.n1ko.niko-shot.scroll-frames", qos: .userInitiated))
    }
    @MainActor func stop() async {
        guard !stopped else { return }
        stopped = true
        output.buffer.close()
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(output, type: .screen)
    }
}

@MainActor
final class ScrollFrameSource {
    private let buffer = ScrollFrameBuffer()
    private let crop: CGRect?
    private var native: ScrollNativeStream?
    private var closed = false
    private init(crop: CGRect?) { self.crop = crop }
    deinit {
        buffer.close()
        if let remaining = native { Task { @MainActor in await remaining.stop() } }
    }

    static func start(filter: SCContentFilter, configuration: SCStreamConfiguration,
                      crop: CGRect? = nil) async throws -> ScrollFrameSource {
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.capturesAudio = false
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 15.0, *) { configuration.captureDynamicRange = .SDR }
        let source = ScrollFrameSource(crop: crop)
        do {
            let native = try ScrollNativeStream(filter: filter, configuration: configuration, buffer: source.buffer)
            source.native = native
            try await native.stream.startCapture()
            try Task.checkCancellation()
            return source
        } catch { await source.stop(); throw error }
    }

    func capture() async throws -> CGImage {
        let started = ContinuousClock.now
        while !closed {
            try Task.checkCancellation()
            let buffer = buffer, crop = crop
            let render = Task.detached(priority: .userInitiated) { try buffer.image(crop: crop) }
            let image = try await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if let image { return image }
            if started.duration(to: .now) >= .seconds(3) { throw ScrollFrameSourceError.firstFrameTimeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    func stop() async {
        guard !closed else { return }
        closed = true; buffer.close()
        let remaining = native; native = nil
        await remaining?.stop()
    }
}
