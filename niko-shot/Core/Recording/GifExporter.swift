// Reads native MP4 frames sequentially and exports a looping, shared-palette GIF through ImageIO.
@preconcurrency import AVFoundation // AVAssetReader and its samples remain local to the worker actor.
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Controls frame sampling and downscaling, with a conservative default of 800 pixels and 15 FPS.
public struct GifOptions: Sendable, Equatable {
    public var width: Int
    public var fps: Int
    /// Creates GIF options; GIF's centisecond clock is most reliable at 30 FPS or less.
    public init(width: Int = 800, fps: Int = 15) {
        self.width = min(4_096, max(1, width)); self.fps = min(30, max(1, fps))
    }
}

/// An export failure containing safe text rather than actor-bound media objects.
public enum GifExportError: LocalizedError, Sendable {
    case video(String), noFrames, image, destination
    public var errorDescription: String? {
        switch self {
        case .video(let message): "GIF 视频读取失败：\(message)"
        case .noFrames: "视频没有可导出的画面。"
        case .image: "GIF 调色板或图像生成失败。"
        case .destination: "GIF 文件未能完成写入。"
        }
    }
}

/// Serial worker for native AVAssetReader decoding, ImageIO output, and atomic destination replacement.
public actor GifExporter {
    /// Creates a worker that has no persistent decoder, image context, or output file while idle.
    public init() {}

    /// Runs one export on a fresh worker, allowing UI callers to use the stateless API.
    public nonisolated static func export(video: URL, destination: URL, options: GifOptions = GifOptions(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await GifExporter().export(video: video, destination: destination, options: options, progress: progress)
    }

    /// Estimates indexed-pixel/LZW storage; the result intentionally varies from content-specific compression.
    public nonisolated static func estimateBytes(duration: Double, fps: Int, width: Int, height: Int) -> Int {
        guard duration.isFinite, duration > 0, width > 0, height > 0 else { return 0 }
        let frames = ceil(duration * Double(min(30, max(1, fps))))
        let estimate = frames * (Double(width) * Double(height) * 0.45 + 128) + 1_024
        return Int(min(Double(Int.max - 1_024), max(1_024, estimate)))
    }

    /// Plans from visible decoded PTS, then emits one frame at a time without retaining pixel arrays.
    public func export(video: URL, destination: URL, options: GifOptions = GifOptions(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let options = GifOptions(width: options.width, fps: options.fps)
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw GifExportError.noFrames }
        let duration = try await asset.load(.duration).seconds
        let transform = try await track.load(.preferredTransform)
        guard duration.isFinite, duration > 0 else { throw GifExportError.noFrames }
        let timestamps = try readTimestamps(asset: asset, track: track, duration: duration, progress: progress)
        let plan = Self.makePlan(timestamps: timestamps, duration: duration, fps: options.fps)
        guard !plan.isEmpty else { throw GifExportError.noFrames }
        try Task.checkCancellation()
        let stage = try stagedDestination(for: destination)
        // ImageIO may create a sibling temporary file before Finalize. Own the whole private staging directory.
        defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
        guard let output = CGImageDestinationCreateWithURL(stage as CFURL, UTType.gif.identifier as CFString, plan.count, nil) else {
            throw GifExportError.destination
        }
        Self.setGlobalProperties(on: output)
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw GifExportError.video("无法建立视频解码输出。") }
        reader.add(videoOutput)
        guard reader.startReading() else { throw GifExportError.video(reader.error?.localizedDescription ?? "解码器未启动。") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
        var index = 0, delayClock = DelayClock()
        while index < plan.count {
            try Task.checkCancellation()
            let added = try autoreleasepool { () -> Bool? in
                guard let sample = videoOutput.copyNextSampleBuffer() else { return nil }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard time.isFinite, time + 0.000_01 >= plan[index].timestamp else { return false }
                guard abs(time - plan[index].timestamp) < 0.002, let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw GifExportError.video("视频解码时间线与采样计划不一致。")
                }
                var image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                guard let decoded = context.createCGImage(image, from: image.extent) else { throw GifExportError.image }
                let indexed = try Self.indexedImage(decoded, maximumWidth: options.width)
                let delay = delayClock.quantize(plan[index].delay)
                CGImageDestinationAddImage(output, indexed, Self.frameProperties(delay: delay))
                return true
            }
            guard let added else { break }
            if added { index += 1; progress(0.12 + 0.86 * Double(index) / Double(plan.count)) }
        }
        if reader.status == .failed { throw GifExportError.video(reader.error?.localizedDescription ?? "解码失败。") }
        guard index == plan.count else { throw GifExportError.video("视频结束前缺少预期画面。") }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(output) else { throw GifExportError.destination }
        try GIFGlobalPalette.ensure256Colors(at: stage)
        try Task.checkCancellation()
        try Self.commit(stage: stage, destination: destination)
        progress(1)
    }

    /// Exports deterministic images using the same palette, PTS sampling, delay clock, and destination safety.
    public func exportFrames(images: [CGImage], timestamps: [Double], destination: URL,
                             options: GifOptions = GifOptions()) async throws {
        let options = GifOptions(width: options.width, fps: options.fps)
        guard !images.isEmpty, images.count == timestamps.count,
              timestamps.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0 < $1 }) else { throw GifExportError.noFrames }
        let duration = (timestamps.last ?? 0) + 1 / Double(options.fps)
        let plan = Self.makePlan(timestamps: timestamps, duration: duration, fps: options.fps)
        let stage = try stagedDestination(for: destination)
        defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
        guard let output = CGImageDestinationCreateWithURL(stage as CFURL, UTType.gif.identifier as CFString, plan.count, nil) else {
            throw GifExportError.destination
        }
        Self.setGlobalProperties(on: output)
        var delayClock = DelayClock()
        for item in plan {
            try Task.checkCancellation()
            guard let index = timestamps.firstIndex(of: item.timestamp) else { throw GifExportError.noFrames }
            try autoreleasepool {
                CGImageDestinationAddImage(output, try Self.indexedImage(images[index], maximumWidth: options.width),
                                          Self.frameProperties(delay: delayClock.quantize(item.delay)))
            }
        }
        guard CGImageDestinationFinalize(output) else { throw GifExportError.destination }
        try GIFGlobalPalette.ensure256Colors(at: stage)
        try Task.checkCancellation(); try Self.commit(stage: stage, destination: destination)
    }

    private func readTimestamps(asset: AVAsset, track: AVAssetTrack, duration: Double,
                               progress: @Sendable (Double) -> Void) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        // HEVC compressed output includes empty start/end marker samples (including PTS == duration).
        // Use the same visible-frame output as the second pass so ImageIO's frame count is exact.
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw GifExportError.video("无法读取视频时间戳。") }
        reader.add(output)
        guard reader.startReading() else { throw GifExportError.video(reader.error?.localizedDescription ?? "时间戳读取失败。") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var timestamps: [Double] = []
        while true {
            try Task.checkCancellation()
            let time = autoreleasepool { () -> Double? in
                guard let buffer = output.copyNextSampleBuffer() else { return nil }
                guard CMSampleBufferGetImageBuffer(buffer) != nil else { return .nan }
                return CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            }
            guard let time else { break }
            if time.isFinite, time >= 0, time < duration { timestamps.append(time) }
            if timestamps.count.isMultiple(of: 120) { progress(min(0.12, max(0, time / duration * 0.12))) }
        }
        guard reader.status != .failed else { throw GifExportError.video(reader.error?.localizedDescription ?? "视频时间戳读取失败。") }
        return Array(Set(timestamps)).sorted()
    }

    private struct PlannedFrame { let timestamp: Double; let delay: Double }
    private nonisolated static func makePlan(timestamps: [Double], duration: Double, fps: Int) -> [PlannedFrame] {
        let interval = 1 / Double(min(30, max(1, fps)))
        guard let first = timestamps.first else { return [] }
        var due = first, selected: [Double] = []
        for time in timestamps where time + 0.000_01 >= due {
            selected.append(time)
            repeat { due += interval } while due <= time + 0.000_01
        }
        return selected.enumerated().map { index, time in
            let end = index + 1 < selected.count ? selected[index + 1] : max(time + 0.02, duration)
            return PlannedFrame(timestamp: time, delay: max(0.02, end - time))
        }
    }

    private struct DelayClock {
        private var expected = 0.0, emitted = 0
        mutating func quantize(_ seconds: Double) -> Double {
            // Error diffusion avoids speeding up a 30 FPS GIF by rounding every delay to 0.03 s.
            expected += seconds * 100
            let delay = max(2, Int(expected.rounded()) - emitted)
            emitted += delay
            return Double(delay) / 100
        }
    }

    private nonisolated static var palette: [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(768)
        for value in 0..<256 {
            let red = ((value >> 5) & 7) * 255 / 7
            let green = ((value >> 2) & 7) * 255 / 7
            let blue = (value & 3) * 255 / 3
            result.append(UInt8(red)); result.append(UInt8(green)); result.append(UInt8(blue))
        }
        return result
    }

    private nonisolated static func setGlobalProperties(on output: CGImageDestination) {
        CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0, kCGImagePropertyGIFHasGlobalColorMap: true,
            kCGImagePropertyGIFImageColorMap: Data(palette)
        ]] as CFDictionary)
    }

    private nonisolated static func frameProperties(delay: Double) -> CFDictionary {
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
            kCGImagePropertyGIFUnclampedDelayTime: delay, kCGImagePropertyGIFHasGlobalColorMap: true,
            kCGImagePropertyGIFImageColorMap: Data(palette)]] as CFDictionary
    }

    private nonisolated static func indexedImage(_ image: CGImage, maximumWidth: Int) throws -> CGImage {
        let width = min(image.width, max(1, maximumWidth))
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard width <= 4_096, height <= 32_768,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw GifExportError.image }
        // GIF has no partial alpha. Flatten transparent source pixels onto white before quantizing.
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var indices = [UInt8](repeating: 0, count: width * height)
        for index in indices.indices {
            let red = (Int(bytes[index * 4]) * 7 + 127) / 255
            let green = (Int(bytes[index * 4 + 1]) * 7 + 127) / 255
            let blue = (Int(bytes[index * 4 + 2]) * 3 + 127) / 255
            indices[index] = UInt8(red << 5 | green << 2 | blue)
        }
        let colors = palette
        let space = colors.withUnsafeBufferPointer { pointer -> CGColorSpace? in
            guard let address = pointer.baseAddress else { return nil }
            return CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 255, colorTable: address)
        }
        guard let space, let provider = CGDataProvider(data: Data(indices) as CFData),
              let indexed = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw GifExportError.image }
        return indexed
    }

    private func stagedDestination(for destination: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let folder = destination.deletingLastPathComponent().appendingPathComponent(".niko-shot-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder.appendingPathComponent("output.gif")
    }

    private nonisolated static func commit(stage: URL, destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage)
        } else { try FileManager.default.moveItem(at: stage, to: destination) }
    }
}
