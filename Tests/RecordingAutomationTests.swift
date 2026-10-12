// Verifies real native setup cancellation and native video→Vision/file commits without screen/microphone TCC.
import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import XCTest
import os
@testable import NikoShot

@MainActor
final class RecordingAutomationTests: XCTestCase {
    func testNativeSetupCloseCancelsExactlyOnceAndCanRepeat() async throws {
        let coordinator = makeCoordinator()
        for captureType in [AutomationCaptureType.region, .window, .fullscreen] {
            let request = Task { try await coordinator.startAutomation(delay: 2, output: nil, format: "gif", autoOCR: true, captureType: captureType) }
            let window = try await setupWindow(coordinator)
            XCTAssertTrue(window.title.contains("GIF"))
            window.performClose(nil)
            do { _ = try await request.value; XCTFail("Closing setup must resolve its caller") }
            catch is CancellationError {} catch { throw error }
            XCTAssertFalse(coordinator.isBusy)
            XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
            await coordinator.cancel()
            XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
        }
    }

    func testCallerCancellationClosesNativeSetupAndPreservesItsExistingOutput() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("user.mp4"), original = Data("user recording".utf8)
        try original.write(to: output)
        let coordinator = makeCoordinator()
        let request = Task { try await coordinator.startAutomation(delay: 0, output: output, format: "mp4", autoOCR: false) }
        _ = try await setupWindow(coordinator)
        request.cancel()
        do { _ = try await request.value; XCTFail("The cancelled caller cannot keep waiting for target selection") }
        catch is CancellationError {} catch { throw error }
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testBusyRequestDoesNotCancelThePreviouslyOpenedSetup() async throws {
        let coordinator = makeCoordinator()
        let request = Task { try await coordinator.startAutomation(delay: 0, output: nil, format: "mp4", autoOCR: false) }
        let window = try await setupWindow(coordinator)
        do { _ = try await coordinator.startAutomation(delay: 0, output: nil, format: "gif", autoOCR: false); XCTFail("A second caller must be rejected") }
        catch AppError.busy {} catch { throw error }
        XCTAssertTrue(window.isVisible); XCTAssertTrue(coordinator.isBusy)
        XCTAssertEqual(coordinator.resourceCounts["startup"], 1)
        request.cancel()
        do { _ = try await request.value; XCTFail("The first request must cancel") }
        catch is CancellationError {} catch { throw error }
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testAlreadyCancelledRequestCreatesNoResources() async throws {
        let coordinator = makeCoordinator()
        let request = Task { try await coordinator.startAutomation(delay: 0, output: nil, format: "mp4", autoOCR: false) }
        request.cancel()
        do { _ = try await request.value; XCTFail("A cancelled caller must not open setup") }
        catch is CancellationError {} catch { throw error }
        XCTAssertFalse(coordinator.isBusy); XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testForeignSelectionIsNotDestroyedByRejectedRequestOrRecordingCancel() async throws {
        let selection = SelectionSession()
        selection.start(frames: [], completion: { _, _ in })
        let coordinator = RecordingCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList())
        do { _ = try await coordinator.startAutomation(delay: 0, output: nil, format: "mp4", autoOCR: false); XCTFail("The existing selection owns this interaction") }
        catch AppError.busy {} catch { throw error }
        await coordinator.cancel()
        XCTAssertEqual(selection.state, .selecting); XCTAssertEqual(selection.monitorCount, 1)
        selection.finish()
        XCTAssertEqual(selection.monitorCount, 0); XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testTerminationResolvesPendingStartupAndLeavesZeroResources() async throws {
        let coordinator = makeCoordinator()
        let request = Task { try await coordinator.startAutomation(delay: 10, output: nil, format: "gif", autoOCR: true) }
        _ = try await setupWindow(coordinator)
        await coordinator.finishForTermination()
        do { _ = try await request.value; XCTFail("Termination must finish the startup continuation") }
        catch is CancellationError {} catch { throw error }
        await coordinator.finishForTermination()
        XCTAssertFalse(coordinator.isBusy); XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testInvalidAutomationParametersFailBeforeUIOrFilesAreCreated() async throws {
        let coordinator = makeCoordinator()
        for (delay, format) in [(-1, "mp4"), (11, "mp4"), (0, "webm")] {
            do { _ = try await coordinator.startAutomation(delay: delay, output: nil, format: format, autoOCR: false); XCTFail("Invalid parameters must be rejected") }
            catch { XCTAssertFalse(error is CancellationError) }
        }
        XCTAssertFalse(coordinator.isBusy); XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testNativeMP4FirstDecodedFrameIsRecognizedAndAtomicCopyRemainsPlayable() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("native.mp4"), output = directory.appendingPathComponent("existing.mp4")
        try Data("original user output".utf8).write(to: output)
        try await RecordingAutomationFixture().writeVideo(to: video)
        let text = try await RecordingAutomationMedia().firstFrameText(video: video, languages: ["en-US"], accurate: true)
        XCTAssertTrue(text.contains("NIKO")); XCTAssertTrue(text.contains("2026"))
        XCTAssertFalse(text.contains("SECOND"), "OCR must use the first decodable frame, not the final frame")
        try await RecordingAutomationFiles.copy(video, to: output)
        let copiedText = try await RecordingAutomationMedia().firstFrameText(video: output, languages: ["en-US"], accurate: true)
        XCTAssertEqual(copiedText, text)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set(["native.mp4", "existing.mp4"]))
    }

    func testActiveBlockCopyCancellationKeepsUserFileAndRemovesStageDirectory() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("large.mp4"), output = directory.appendingPathComponent("existing.mp4")
        let original = Data("original".utf8); try original.write(to: output)
        try await RecordingAutomationFixture().writeLargeFile(to: source)
        let holder = OSAllocatedUnfairLock<Task<Void, any Error>?>(initialState: nil)
        let copying = Task {
            try await RecordingAutomationFiles.copy(source, to: output) { bytes in
                if bytes > 0 { holder.withLock { $0?.cancel() } }
            }
        }
        holder.withLock { $0 = copying }
        do { try await copying.value; XCTFail("Active copy cancellation must stop before replacing the target") }
        catch is CancellationError {} catch { throw error }
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set(["large.mp4", "existing.mp4"]))
    }

    func testCopyRefusesToReplaceAUserDirectoryAndBadMediaIsAnExplicitError() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("bad.mp4"), output = directory.appendingPathComponent("user-folder")
        try Data("invalid media".utf8).write(to: source)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let marker = output.appendingPathComponent("keep.txt"), original = Data("preserve".utf8); try original.write(to: marker)
        do { try await RecordingAutomationFiles.copy(source, to: output); XCTFail("A directory cannot be replaced as a recording file") }
        catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: marker), original)
        do { _ = try await RecordingAutomationMedia().firstFrameText(video: source, languages: ["en-US"], accurate: true); XCTFail("Invalid media cannot silently satisfy auto OCR") }
        catch { XCTAssertFalse(error is CancellationError) }
    }

    private func makeCoordinator() -> RecordingCoordinator {
        RecordingCoordinator(engine: CaptureEngine(), selection: SelectionSession(), windows: WindowList())
    }
    private func setupWindow(_ coordinator: RecordingCoordinator) async throws -> NSWindow {
        for _ in 0..<100 {
            if coordinator.resourceCounts["setup"] == 1,
               let window = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix("开始录屏 · ") }) { return window }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The native setup must appear without requesting capture permission")
        throw AppError.file("录屏设置窗口未打开。")
    }
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niko-recording-automation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Genuine AVAssetWriter fixtures are generated on this actor with no screen or microphone source.
actor RecordingAutomationFixture {
    func writeVideo(to url: URL) async throws {
        let width = 640, height = 200
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw RecordingError.encoder("Fixture input unavailable") }
        writer.add(input)
        guard writer.startWriting() else { throw RecordingError.encoder(writer.error?.localizedDescription ?? "Fixture writer failed") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<10 {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)); try Task.checkCancellation() }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw RecordingError.encoder("Fixture pixel buffer failed") }
            CVPixelBufferLockBaseAddress(buffer, [])
            do {
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw RecordingError.empty }
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 46, nil)
                let string = NSAttributedString(string: index < 5 ? "NIKO SHOT 2026" : "SECOND FRAME", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
                context.textMatrix = .identity; context.textPosition = CGPoint(x: 30, y: 85)
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            } catch { CVPixelBufferUnlockBaseAddress(buffer, []); writer.cancelWriting(); throw error }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                writer.cancelWriting(); throw RecordingError.encoder(writer.error?.localizedDescription ?? "Fixture append failed")
            }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw RecordingError.encoder(writer.error?.localizedDescription ?? "Fixture finalization failed") }
    }

    func writeLargeFile(to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw AppError.file("Fixture creation failed") }
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        let data = Data(repeating: 0x5a, count: 1_048_576)
        for _ in 0..<32 { try file.write(contentsOf: data) }
    }
}
