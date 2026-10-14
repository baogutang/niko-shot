// 新引擎的串行事务：小图通过裁片绘制，超长图复用已有分块 PNG writer。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

actor RowHashScrollSession: ScrollStitchSession {
    private var stitcher: RowHashStitcher
    private var bottom = ScrollBottomDetector()
    private var state: ScrollCaptureState = .idle
    private var preview: ScrollPreviewAccumulator?
    private let directory: URL
    private let cancellation = OSAllocatedUnfairLock(initialState: false)
    private var writer: ChunkedPNGWriter?
    private var exportDirectory: URL?
    private var peakBytes = 0
    private var reportedWidth = 0, reportedHeight = 0, reportedFrames = 0
    private(set) var isAtBottom = false
    var isBacktracking: Bool { stitcher.isBacktracking }
    var needsBoundaryCheck: Bool {
        let count = bottom.consecutiveUnchangedEvents
        return !isAtBottom && count >= 8 && (count - 8).isMultiple(of: 20)
    }
    var viewportHeight: Int { stitcher.viewportHeight }
    var contentBands: (top: Int, bottom: Int) { (stitcher.ignoredTop, stitcher.ignoredBottom) }
    var livePreview: ScrollPreviewSnapshot? { preview?.snapshot }
    var progress: ScrollCaptureProgress {
        ScrollCaptureProgress(width: reportedWidth, height: reportedHeight, frames: reportedFrames, state: state)
    }
    var resourceCounts: ScrollResourceCounts {
        ScrollResourceCounts(openFiles: writer?.openFiles ?? 0, chunkFiles: writer?.chunks.count ?? 0,
            ownedDirectories: (writer == nil ? 0 : 1) + (exportDirectory == nil ? 0 : 1),
            residentBufferBytes: stitcher.residentBufferBytes + (writer?.residentBufferBytes ?? 0) + (preview?.residentBufferBytes ?? 0),
            peakBufferBytes: peakBytes)
    }

    init(options: ScrollCaptureOptions = ScrollCaptureOptions(), workingDirectory: URL = FileManager.default.temporaryDirectory,
         previewEnabled: Bool = true) {
        stitcher = RowHashStitcher(options: options, allowsRenderingVariance: true)
        directory = workingDirectory.appendingPathComponent("niko-row-scroll-\(UUID().uuidString)", isDirectory: true)
        if previewEnabled { preview = ScrollPreviewAccumulator() }
    }

    func append(_ image: CGImage) throws -> ScrollAppendResult { try accept(image, scrollEvent: false) }
    func appendScrollEvent(_ image: CGImage) throws -> ScrollAppendResult { try accept(image, scrollEvent: true) }
    func append(_ image: CGImage, forcedOverlap: Int) throws -> ScrollAppendResult { throw ScrollCaptureError.invalidOverlap }
    func canAppendReliably(_ image: CGImage) throws -> Bool { false }

    private func accept(_ image: CGImage, scrollEvent: Bool) throws -> ScrollAppendResult {
        try checkOpen()
        do {
            let frame = try RowHashFrame(image)
            let result = try stitcher.append(frame)
            isAtBottom = bottom.observe(frame, result: result, isScrollEvent: scrollEvent,
                backtracking: stitcher.isBacktracking, ignoredBottom: stitcher.ignoredBottom)
            if case .appended = result {
                reportedWidth = stitcher.width; reportedHeight = stitcher.height; reportedFrames = stitcher.frames
                try updatePreview()
                // 避免高分辨率画布突破内存预算；32767 行以上必走分块。
                if writer != nil || stitcher.height > 32_767 || Int64(stitcher.width) * Int64(stitcher.height) * 4 > 96 * 1_024 * 1_024 {
                    try spoolSegments()
                }
                state = .capturing
                peakBytes = max(peakBytes, resourceCounts.residentBufferBytes + (writer?.peakBufferBytes ?? 0))
            }
            return result
        } catch {
            if error is CancellationError || cancellation.withLock({ $0 }) { cleanup(); state = .cancelled; throw CancellationError() }
            if error is ScrollTargetError { throw error }
            cleanup(); state = .failed; throw error
        }
    }

    private func updatePreview() throws {
        guard preview != nil else { return }
        do {
            if stitcher.revisedFirstFrame { preview = ScrollPreviewAccumulator() }
            let segments = stitcher.revisedFirstFrame ? stitcher.segments : Array(stitcher.segments.suffix(1))
            for segment in segments {
                try preview?.append(segment.image, firstRow: 0, rows: segment.height,
                    sourceHeight: segment.offset + segment.height, frames: stitcher.frames)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { preview = nil }
    }

    private func spoolSegments() throws {
        if writer == nil {
            let flag = cancellation
            writer = try ChunkedPNGWriter(directory: directory, width: stitcher.width) { try Self.check(flag) }
        }
        guard let writer else { throw ScrollCaptureError.noFrames }
        for segment in stitcher.segments {
            try checkCancellation()
            guard writer.height == segment.offset else { throw ScrollCaptureError.image }
            try writer.append(image: segment.image, firstRow: 0, numberOfRows: segment.height)
        }
        stitcher.releaseSegments()
    }

    func finish(to destination: URL) throws -> URL {
        try checkOpen()
        guard stitcher.frames > 0 else { throw ScrollCaptureError.noFrames }
        state = .finishing
        do {
            try stitcher.includeFooter()
            reportedHeight = stitcher.height
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let folder = parent.appendingPathComponent(".niko-row-export-\(UUID().uuidString)", isDirectory: true)
            exportDirectory = folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let stage = folder.appendingPathComponent("output.png")
            if writer != nil || stitcher.height > 32_767 {
                try spoolSegments(); try writer?.writePNG(to: stage)
            } else {
                let image = try stitcher.composedImage()
                try checkCancellation()
                guard let encoder = CGImageDestinationCreateWithURL(stage as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ScrollCaptureError.image }
                CGImageDestinationAddImage(encoder, image, nil)
                guard CGImageDestinationFinalize(encoder) else { throw ScrollCaptureError.disk("无法编码长截图。") }
            }
            try checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage) }
            else { try FileManager.default.moveItem(at: stage, to: destination) }
            cleanup(); state = .completed
            return destination
        } catch {
            cleanup(); state = error is CancellationError ? .cancelled : .failed; throw error
        }
    }

    nonisolated func cancel() async {
        cancellation.withLock { $0 = true }
        await cancelIsolated()
    }
    private func cancelIsolated() { cleanup(); if state != .completed { state = .cancelled } }
    private func checkOpen() throws {
        try checkCancellation()
        guard ![.completed, .cancelled, .failed, .finishing].contains(state) else { throw ScrollCaptureError.closed }
    }
    private func checkCancellation() throws { try Self.check(cancellation) }
    private nonisolated static func check(_ flag: OSAllocatedUnfairLock<Bool>) throws {
        try Task.checkCancellation(); if flag.withLock({ $0 }) { throw CancellationError() }
    }
    private func cleanup() {
        writer?.cleanup(); writer = nil; preview = nil
        stitcher = RowHashStitcher()
        bottom = ScrollBottomDetector(); isAtBottom = false
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }; exportDirectory = nil
    }
}
