// Owns one scroll-stitching transaction, bounded image features, disk chunks and cancellable PNG commit.
import CoreGraphics
import Foundation
import os

/// A serial CPU/disk worker. Capture timing and automatic scroll events are supplied by its coordinator.
public actor ScrollCaptureSession {
    private let options: ScrollCaptureOptions
    private let directory: URL
    private let cancellation = OSAllocatedUnfairLock(initialState: false)
    private var previous: StitchFrameAnalysis?
    private var writer: ChunkedPNGWriter?
    private var state: ScrollCaptureState = .idle
    private var frames = 0
    private var width = 0, height = 0, peakBufferBytes = 0
    private var exportDirectory: URL?

    /// Creates a lazy transaction inside a unique child of the supplied working directory.
    public init(options: ScrollCaptureOptions = ScrollCaptureOptions(), workingDirectory: URL = FileManager.default.temporaryDirectory) {
        self.options = ScrollCaptureOptions(ignoredTop: options.ignoredTop, ignoredBottom: options.ignoredBottom,
                                            minimumCorrelation: options.minimumCorrelation)
        directory = workingDirectory.appendingPathComponent("niko-scroll-\(UUID().uuidString)", isDirectory: true)
    }

    /// A scalar snapshot; no CGImage or pixel pointer is exposed to UI.
    public var progress: ScrollCaptureProgress { ScrollCaptureProgress(width: width, height: height, frames: frames, state: state) }
    /// Counts open descriptors/stages and bounded owned buffers, including their observed maximum.
    public var resourceCounts: ScrollResourceCounts {
        ScrollResourceCounts(openFiles: writer?.openFiles ?? 0, chunkFiles: writer?.chunks.count ?? 0,
            ownedDirectories: (writer == nil ? 0 : 1) + (exportDirectory == nil ? 0 : 1),
            residentBufferBytes: (previous?.residentBytes ?? 0) + (writer?.residentBufferBytes ?? 0),
            peakBufferBytes: peakBufferBytes)
    }

    /// Accepts forward content; duplicates and backtracking keep the accepted boundary unchanged.
    /// Invalid candidate geometry leaves accepted chunks intact so the caller can retry or finish.
    public func append(_ image: CGImage) throws -> ScrollAppendResult { try appendFrame(image, forcedOverlap: nil) }
    /// Appends a retained candidate only after the user explicitly confirms its overlap.
    public func append(_ image: CGImage, forcedOverlap: Int) throws -> ScrollAppendResult { try appendFrame(image, forcedOverlap: forcedOverlap) }

    /// Streams a PNG and atomically commits it; an existing user file is protected until all rows succeed.
    public func finish(to destination: URL) throws -> URL {
        try checkOpen()
        guard let writer, frames > 0 else { throw ScrollCaptureError.noFrames }
        state = .finishing
        do {
            try checkCancellation()
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let stageDirectory = parent.appendingPathComponent(".niko-scroll-export-\(UUID().uuidString)", isDirectory: true)
            exportDirectory = stageDirectory
            try FileManager.default.createDirectory(at: stageDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let stage = stageDirectory.appendingPathComponent("output.png")
            try writer.writePNG(to: stage)
            peakBufferBytes = max(peakBufferBytes, writer.peakBufferBytes + (previous?.residentBytes ?? 0))
            try checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage) }
            else { try FileManager.default.moveItem(at: stage, to: destination) }
            cleanup(); state = .completed
            return destination
        } catch {
            cleanup(); state = error is CancellationError ? .cancelled : .failed
            throw error
        }
    }

    /// Signals cancellation immediately even if the actor is compressing, then waits for owned files to close.
    public nonisolated func cancel() async {
        cancellation.withLock { $0 = true }
        await cancelIsolated()
    }

    private func cancelIsolated() {
        cleanup()
        if state != .completed { state = .cancelled }
    }
    private func checkOpen() throws {
        do { try checkCancellation() }
        catch {
            cleanup()
            if state != .completed { state = .cancelled }
            throw error
        }
        guard ![.completed, .cancelled, .failed, .finishing].contains(state) else { throw ScrollCaptureError.closed }
    }
    private func checkCancellation() throws { try Self.check(cancellation) }
    private nonisolated static func check(_ flag: OSAllocatedUnfairLock<Bool>) throws {
        try Task.checkCancellation()
        if flag.withLock({ $0 }) { throw CancellationError() }
    }

    private func appendFrame(_ image: CGImage, forcedOverlap: Int?) throws -> ScrollAppendResult {
        try checkOpen()
        var writing = false
        do {
            let next = try Stitcher.analyze(image, top: options.ignoredTop, bottom: options.ignoredBottom)
            try checkCancellation()
            var overlap = 0
            if let previous {
                guard previous.width == next.width else { throw ScrollCaptureError.changedWidth }
                if let forcedOverlap {
                    guard forcedOverlap >= 0, forcedOverlap < min(previous.height, next.height) else { throw ScrollCaptureError.invalidOverlap }
                    overlap = forcedOverlap
                } else {
                    if previous.signature.normalizedDifference(to: next.signature) < 0.002 { return .duplicate }
                    let match = try Stitcher.match(previous: previous, current: next, currentImage: image,
                                                  ignoringTop: options.ignoredTop)
                    if match.correlation < options.minimumCorrelation || match.isAmbiguous {
                        state = .awaitingConfirmation; return .needsConfirmation(match)
                    }
                    if match.isBacktracking { return .backtracking }
                    overlap = match.overlap
                }
            } else if let forcedOverlap, forcedOverlap != 0 { throw ScrollCaptureError.invalidOverlap }
            // Once writing starts, a partial row/chunk cannot safely be retried in-place.
            writing = true
            if writer == nil {
                let flag = cancellation
                writer = try ChunkedPNGWriter(directory: directory, width: next.width) { try Self.check(flag) }
                width = next.width
            }
            guard let writer else { throw ScrollCaptureError.noFrames }
            try writer.append(image: image, firstRow: options.ignoredTop + overlap, numberOfRows: next.height - overlap)
            previous = next; frames += 1; height = writer.height; state = .capturing
            peakBufferBytes = max(peakBufferBytes, writer.peakBufferBytes + next.residentBytes * 2)
            return .appended(height: height, frames: frames)
        } catch {
            if error is CancellationError || Task.isCancelled || cancellation.withLock({ $0 }) {
                cleanup(); state = .cancelled
                throw CancellationError()
            }
            if !writing, let candidateError = error as? ScrollCaptureError {
                switch candidateError {
                case .image, .invalidBands, .changedWidth, .invalidOverlap: throw error
                default: break
                }
            }
            cleanup(); state = .failed
            throw error
        }
    }
    private func cleanup() {
        writer?.cleanup(); writer = nil; previous = nil
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportDirectory = nil
    }
}
