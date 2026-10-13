// Exercises disk-backed 10,000-pixel PNG stitching, duplicate/confirmation handling and transaction teardown.
import CoreGraphics
import Foundation
import XCTest
@testable import NikoShot

@MainActor
final class ScrollCaptureTests: XCTestCase {
    func testTrimmedAlphaPNGHasExactPixelOrderAcrossTheSeam() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ScrollImageFixture()
        let session = ScrollCaptureSession(options: ScrollCaptureOptions(ignoredTop: 13, ignoredBottom: 7), workingDirectory: directory)
        let first = try await fixture.frame(width: 96, height: 380, start: 0, top: 13, bottom: 7, chrome: 20, alpha: true)
        let second = try await fixture.frame(width: 96, height: 380, start: 223, top: 13, bottom: 7, chrome: 220, alpha: true)
        let result1 = try await session.append(first)
        let result2 = try await session.append(second)
        XCTAssertEqual(result1, .appended(height: 360, frames: 1))
        XCTAssertEqual(result2, .appended(height: 583, frames: 2))
        let destination = directory.appendingPathComponent("alpha.png")
        _ = try await session.finish(to: destination)
        let result = try await fixture.inspect(destination, expectedWidth: 96, expectedHeight: 583, alpha: true)
        XCTAssertEqual(result.width, 96); XCTAssertEqual(result.height, 583)
        XCTAssertLessThanOrEqual(result.maximumChannelDifference, 1, "Pixels must keep their source order and alpha")
        XCTAssertEqual(result.alphaMismatches, 0); XCTAssertTrue(result.validCRCs)
        let resources = await session.resourceCounts
        XCTAssertEqual(resources.openFiles, 0); XCTAssertEqual(resources.chunkFiles, 0)
        XCTAssertEqual(resources.ownedDirectories, 0); XCTAssertEqual(resources.residentBufferBytes, 0)
    }

    func testDuplicateStopsWithoutAddingRowsAndLowConfidenceDoesNotAdvancePrevious() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ScrollImageFixture(), session = ScrollCaptureSession(workingDirectory: directory)
        let first = try await fixture.frame(width: 96, height: 360, start: 0)
        _ = try await session.append(first)
        let repeated = try await session.append(first)
        XCTAssertEqual(repeated, .duplicate)
        let unrelated = try await fixture.frame(width: 96, height: 360, start: 0, seed: 500)
        guard case .needsConfirmation(let match) = try await session.append(unrelated) else { return XCTFail("An unrelated frame must pause") }
        XCTAssertLessThan(match.correlation, 0.90)
        let waiting = await session.progress
        XCTAssertEqual(waiting.height, 360); XCTAssertEqual(waiting.frames, 1); XCTAssertEqual(waiting.state, .awaitingConfirmation)
        let correctNext = try await fixture.frame(width: 96, height: 360, start: 223)
        let accepted = try await session.append(correctNext)
        XCTAssertEqual(accepted, .appended(height: 583, frames: 2), "A rejected candidate must not become the next reference")
        await session.cancel()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testNaturalSmallStepsPreserveEverySourceRowInTheFinalPNG() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ScrollImageFixture(), session = ScrollCaptureSession(workingDirectory: directory)
        for (index, start) in [0, 20, 80, 380].enumerated() {
            let image = try await fixture.frame(width: 96, height: 1_000, start: start)
            let result = try await session.append(image)
            XCTAssertEqual(result, .appended(height: 1_000 + start, frames: index + 1))
        }
        let output = directory.appendingPathComponent("small-steps.png")
        _ = try await session.finish(to: output)
        let result = try await fixture.inspect(output, expectedWidth: 96, expectedHeight: 1_380)
        XCTAssertLessThanOrEqual(result.maximumChannelDifference, 1)
        XCTAssertTrue(result.validCRCs)
    }

    func testBacktrackingKeepsTheAcceptedBoundaryUntilForwardProgressResumes() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ScrollImageFixture(), session = ScrollCaptureSession(workingDirectory: directory)
        let first = try await fixture.frame(width: 96, height: 1_000, start: 0)
        let accepted = try await fixture.frame(width: 96, height: 1_000, start: 300)
        _ = try await session.append(first); _ = try await session.append(accepted)
        for start in [240, 0] {
            let earlier = try await fixture.frame(width: 96, height: 1_000, start: start)
            let result = try await session.append(earlier)
            XCTAssertEqual(result, .backtracking)
            let progress = await session.progress
            XCTAssertEqual(progress.height, 1_300); XCTAssertEqual(progress.frames, 2)
            XCTAssertEqual(progress.state, .capturing)
        }
        let returned = try await session.append(accepted)
        XCTAssertEqual(returned, .duplicate)
        let next = try await fixture.frame(width: 96, height: 1_000, start: 360)
        let continued = try await session.append(next)
        XCTAssertEqual(continued, .appended(height: 1_360, frames: 3))
        let output = directory.appendingPathComponent("backtracking.png")
        _ = try await session.finish(to: output)
        let result = try await fixture.inspect(output, expectedWidth: 96, expectedHeight: 1_360)
        XCTAssertLessThanOrEqual(result.maximumChannelDifference, 1)
    }

    func testIncompatibleWidthCanBeRejectedThenContinueWithTheOriginalViewport() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ScrollImageFixture(), session = ScrollCaptureSession(workingDirectory: directory)
        let first = try await fixture.frame(width: 96, height: 1_000, start: 0)
        _ = try await session.append(first)
        let incompatible = try await fixture.frame(width: 97, height: 1_000, start: 60)
        do { _ = try await session.append(incompatible); XCTFail("A width change needs viewport recovery") }
        catch ScrollCaptureError.changedWidth {} catch { throw error }
        let retained = await session.progress, resources = await session.resourceCounts
        XCTAssertEqual(retained.height, 1_000); XCTAssertEqual(retained.frames, 1)
        XCTAssertEqual(retained.state, .capturing)
        XCTAssertEqual(resources.chunkFiles, 1); XCTAssertEqual(resources.openFiles, 1)
        let restored = try await fixture.frame(width: 96, height: 1_000, start: 60)
        let continued = try await session.append(restored)
        XCTAssertEqual(continued, .appended(height: 1_060, frames: 2))
        let output = directory.appendingPathComponent("recovered-width.png")
        _ = try await session.finish(to: output)
        let result = try await fixture.inspect(output, expectedWidth: 96, expectedHeight: 1_060)
        XCTAssertLessThanOrEqual(result.maximumChannelDifference, 1)
    }

    func testInvalidCandidateBandsAndForcedOverlapStillAllowAcceptedContentToFinish() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ScrollImageFixture()
        let session = ScrollCaptureSession(options: ScrollCaptureOptions(ignoredTop: 13, ignoredBottom: 7), workingDirectory: directory)
        let first = try await fixture.frame(width: 96, height: 380, start: 0, top: 13, bottom: 7)
        _ = try await session.append(first)
        let tooShort = try await fixture.frame(width: 96, height: 20, start: 0)
        do { _ = try await session.append(tooShort); XCTFail("Bands cannot cover a candidate") }
        catch ScrollCaptureError.invalidBands {} catch { throw error }
        let next = try await fixture.frame(width: 96, height: 380, start: 60, top: 13, bottom: 7)
        for overlap in [-1, 360] {
            do { _ = try await session.append(next, forcedOverlap: overlap); XCTFail("Reject invalid overlap without deleting accepted rows") }
            catch ScrollCaptureError.invalidOverlap {} catch { throw error }
        }
        let retained = await session.progress
        XCTAssertEqual(retained.height, 360); XCTAssertEqual(retained.frames, 1)
        XCTAssertEqual(retained.state, .capturing)
        let output = directory.appendingPathComponent("retained.png")
        _ = try await session.finish(to: output)
        let result = try await fixture.inspect(output, expectedWidth: 96, expectedHeight: 360)
        XCTAssertLessThanOrEqual(result.maximumChannelDifference, 1)
        let resources = await session.resourceCounts
        XCTAssertEqual(resources.openFiles + resources.chunkFiles + resources.ownedDirectories + resources.residentBufferBytes, 0)
    }

    func testIrrecoverableAppendFailureClosesTheWorkerAndRemovesOwnedChunks() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ScrollImageFixture(), session = ScrollCaptureSession(workingDirectory: directory)
        let first = try await fixture.frame(width: 96, height: 1_000, start: 0)
        _ = try await session.append(first)
        // Remove only this test's owned spool. Appending beyond its first 5000-row chunk must
        // create another file and fail against the now-missing directory, without permissions/TCC.
        let spool = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("niko-scroll-") })
        try FileManager.default.removeItem(at: spool)
        let next = try await fixture.frame(width: 96, height: 5_001, start: 0)
        do { _ = try await session.append(next, forcedOverlap: 0); XCTFail("The spool no longer exists") }
        catch { XCTAssertFalse(error is CancellationError) }
        let progress = await session.progress, resources = await session.resourceCounts
        XCTAssertEqual(progress.state, .failed)
        XCTAssertEqual(resources.openFiles + resources.chunkFiles + resources.ownedDirectories + resources.residentBufferBytes, 0)
        do { _ = try await session.append(first); XCTFail("A dead disk transaction must require a new session") }
        catch ScrollCaptureError.closed {} catch { throw error }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testExplicitOverlapCanAcceptThePendingCandidateIncludingZero() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ScrollImageFixture(), session = ScrollCaptureSession(workingDirectory: directory)
        let first = try await fixture.frame(width: 96, height: 360, start: 0)
        let unknown = try await fixture.frame(width: 96, height: 360, start: 360)
        _ = try await session.append(first)
        guard case .needsConfirmation = try await session.append(unknown) else { return XCTFail("A seam outside the search range must pause") }
        let confirmed = try await session.append(unknown, forcedOverlap: 0)
        XCTAssertEqual(confirmed, .appended(height: 720, frames: 2))
        let destination = directory.appendingPathComponent("manual.png")
        _ = try await session.finish(to: destination)
        let result = try await fixture.inspect(destination, expectedWidth: 96, expectedHeight: 720)
        XCTAssertLessThanOrEqual(result.maximumChannelDifference, 1)
    }

    func testTenThousandRowsUseTwoDiskChunksAndBoundedBuffers() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ScrollImageFixture(), session = ScrollCaptureSession(workingDirectory: directory)
        for index in 0..<10 {
            let frame = try await fixture.frame(width: 128, height: index == 9 ? 1_000 : 1_140, start: index * 1_000)
            guard case .appended = try await session.append(frame) else { return XCTFail("The translated sequence must stitch automatically") }
        }
        let progress = await session.progress, resources = await session.resourceCounts
        XCTAssertEqual(progress.height, 10_000); XCTAssertEqual(progress.frames, 10)
        XCTAssertEqual(resources.chunkFiles, 2); XCTAssertEqual(resources.openFiles, 1)
        XCTAssertLessThan(resources.residentBufferBytes, 1_000_000)
        XCTAssertLessThan(resources.peakBufferBytes, 4_000_000, "Only bounded frame rasters and narrow features can be retained")
        let destination = directory.appendingPathComponent("long.png")
        _ = try await session.finish(to: destination)
        let result = try await fixture.inspect(destination, expectedWidth: 128, expectedHeight: 10_000)
        XCTAssertEqual(result.height, 10_000); XCTAssertLessThanOrEqual(result.maximumChannelDifference, 1)
        XCTAssertTrue(result.validCRCs); XCTAssertGreaterThan(result.idatChunks, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["long.png"])
        let finished = await session.resourceCounts
        XCTAssertEqual(finished.openFiles + finished.chunkFiles + finished.ownedDirectories + finished.residentBufferBytes, 0)
    }

    func testCancellationDuringCompressionProtectsExistingFileAndCleansStages() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.png")
        let original = Data("original user file".utf8); try original.write(to: destination)
        let fixture = ScrollImageFixture(), session = ScrollCaptureSession(workingDirectory: directory)
        for index in 0..<10 {
            let frame = try await fixture.frame(width: 512, height: index == 9 ? 1_000 : 1_140, start: index * 1_000)
            _ = try await session.append(frame)
        }
        let export = Task { try await session.finish(to: destination) }
        try await Task.sleep(for: .milliseconds(10))
        await session.cancel()
        do { _ = try await export.value; XCTFail("Cancellation must interrupt the actor's active row compression") }
        catch is CancellationError {} catch { throw error }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.png"])
        let resources = await session.resourceCounts
        XCTAssertEqual(resources.openFiles + resources.chunkFiles + resources.ownedDirectories + resources.residentBufferBytes, 0)
    }

    func testWriteFailureCleansChunksAndPreservesOtherUserFiles() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let blockedParent = directory.appendingPathComponent("file-as-parent")
        let original = Data("preserve".utf8); try original.write(to: blockedParent)
        let session = ScrollCaptureSession(workingDirectory: directory)
        let frame = try await ScrollImageFixture().frame(width: 96, height: 360, start: 0)
        _ = try await session.append(frame)
        do { _ = try await session.finish(to: blockedParent.appendingPathComponent("output.png")); XCTFail("A file cannot become a destination directory") }
        catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: blockedParent), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["file-as-parent"])
        let resources = await session.resourceCounts
        XCTAssertEqual(resources.openFiles + resources.chunkFiles + resources.ownedDirectories + resources.residentBufferBytes, 0)
    }

    func testSuccessfulCommitAtomicallyReplacesExistingDestination() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.png")
        try Data("original".utf8).write(to: destination)
        let fixture = ScrollImageFixture(), session = ScrollCaptureSession(workingDirectory: directory)
        let frame = try await fixture.frame(width: 96, height: 360, start: 0)
        _ = try await session.append(frame)
        _ = try await session.finish(to: destination)
        let result = try await fixture.inspect(destination, expectedWidth: 96, expectedHeight: 360)
        XCTAssertLessThanOrEqual(result.maximumChannelDifference, 1); XCTAssertTrue(result.validCRCs)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.png"])
    }

    func testAlreadyCancelledCallerCleansPriorChunksBeforeEncoding() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.png")
        let original = Data("original".utf8); try original.write(to: destination)
        let session = ScrollCaptureSession(workingDirectory: directory)
        let frame = try await ScrollImageFixture().frame(width: 96, height: 360, start: 0)
        _ = try await session.append(frame)
        let export = Task { try await session.finish(to: destination) }
        export.cancel()
        do { _ = try await export.value; XCTFail("A cancelled caller must not commit its transaction") }
        catch is CancellationError {} catch { throw error }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.png"])
        let resources = await session.resourceCounts
        XCTAssertEqual(resources.openFiles + resources.chunkFiles + resources.ownedDirectories + resources.residentBufferBytes, 0)
    }

    func testIdleAndRepeatedCancelHaveNoResourcesAndInvalidDimensionsDoNotCreateStages() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let session = ScrollCaptureSession(workingDirectory: directory)
        let idle = await session.resourceCounts
        XCTAssertEqual(idle.openFiles + idle.chunkFiles + idle.ownedDirectories + idle.residentBufferBytes, 0)
        await session.cancel(); await session.cancel()
        let resources = await session.resourceCounts
        XCTAssertEqual(resources.openFiles + resources.chunkFiles + resources.ownedDirectories + resources.residentBufferBytes, 0)
        let rejected = await ScrollImageFixture().rejectsOversizedWriter(in: directory)
        XCTAssertTrue(rejected); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niko-scroll-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
