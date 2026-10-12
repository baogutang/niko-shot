// Exercises pin termination with real PNG copying, decoding and atomic JSON writes paused after native I/O.
import AppKit
import ImageIO
import XCTest
@testable import NikoShot

@MainActor
final class PinLifecycleTests: XCTestCase {
    func testTerminationDrainsDelayedCopyWithoutPresentingOrLeavingAnUncommittedFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = PinLifecycleGate()
        var manager: PinWindowManager? = PinWindowManager(directory: fixture.library) { operation in
            if case .copy = operation { await gate.pause() }
        }
        weak let weakManager = manager
        manager?.pin(image: fixture.image, url: fixture.source, thumbnail: Data())
        await gate.waitUntilEntered()
        let copiedFiles = try FileManager.default.contentsOfDirectory(at: fixture.library, includingPropertiesForKeys: nil)
        let copiedURL = try XCTUnwrap(copiedFiles.first { $0.pathExtension == "png" })
        XCTAssertEqual(try Data(contentsOf: copiedURL), try Data(contentsOf: fixture.source))

        manager?.prepareForTermination()
        let finishing = Task { [weak manager] in await manager?.finishForTermination() }
        await Task.yield()
        XCTAssertEqual(manager?.resourceCounts["pinTasks"], 1, "Cancelled native work remains tracked until its completion")
        XCTAssertEqual(manager?.resourceCounts["pinWindows"], 0)
        manager?.show(id: UUID())
        manager?.pin(image: fixture.image, url: fixture.source, thumbnail: Data())
        XCTAssertEqual(manager?.resourceCounts["pinTasks"], 1, "Termination blocks new operations synchronously")

        await gate.release()
        await finishing.value
        XCTAssertTrue(manager?.pins.isEmpty ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(manager?.resourceCounts.values.reduce(0, +), 0)
        manager = nil
        XCTAssertNil(weakManager)
    }

    func testDelayedDecodeCannotReopenAWindowAfterTerminationAndPreservesSavedPin() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = PinLifecycleGate()
        var manager: PinWindowManager? = PinWindowManager(directory: fixture.library) { operation in
            if case .decode = operation { await gate.pause() }
        }
        weak let weakManager = manager
        manager?.toggleVisibility()
        manager?.pin(image: fixture.image, url: fixture.source, thumbnail: Data([1, 2, 3]))
        await manager?.waitForPendingOperations()
        let entry = try XCTUnwrap(manager?.pins.first)
        manager?.closeAll()
        manager?.show(id: entry.id)
        manager?.show(id: entry.id)
        await gate.waitUntilEntered()
        XCTAssertEqual(manager?.resourceCounts["pinTasks"], 1, "Repeated show reuses one pending decode")
        manager?.prepareForTermination()
        let finishing = Task { [weak manager] in await manager?.finishForTermination() }
        await Task.yield()
        XCTAssertEqual(manager?.resourceCounts["pinTasks"], 1)
        await gate.release()
        await finishing.value

        XCTAssertEqual(manager?.resourceCounts.values.reduce(0, +), 0)
        let saved = try JSONDecoder().decode([PinEntry].self, from: Data(contentsOf: fixture.library.appendingPathComponent("index.json")))
        XCTAssertEqual(saved.map(\.id), [entry.id])
        XCTAssertEqual(saved.first?.thumbnail, entry.thumbnail)
        XCTAssertEqual(try Data(contentsOf: entry.url), try Data(contentsOf: fixture.source))
        manager = nil
        XCTAssertNil(weakManager)
    }

    func testTerminationWaitsForCommittedIndexWriteWithoutCancellingIt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = PinLifecycleGate()
        var manager: PinWindowManager? = PinWindowManager(directory: fixture.library) { operation in
            if case .persist = operation {
                await gate.pause()
                await gate.recordCancellation(Task.isCancelled)
            }
        }
        weak let weakManager = manager
        manager?.toggleVisibility()
        manager?.pin(image: fixture.image, url: fixture.source, thumbnail: Data())
        await gate.waitUntilEntered()
        let entry = try XCTUnwrap(manager?.pins.first)
        XCTAssertEqual(manager?.resourceCounts["pinWindows"], 1)
        manager?.prepareForTermination()
        let finishing = Task { [weak manager] in await manager?.finishForTermination() }
        await Task.yield()
        XCTAssertEqual(manager?.resourceCounts["pinWindows"], 0)
        XCTAssertEqual(manager?.resourceCounts["pinPersistenceTasks"], 1)
        await gate.release()
        await finishing.value

        let wasCancelled = await gate.wasCancelled
        XCTAssertFalse(wasCancelled, "Successful pin metadata must survive resident termination")
        XCTAssertEqual(manager?.resourceCounts.values.reduce(0, +), 0)
        let saved = try JSONDecoder().decode([PinEntry].self, from: Data(contentsOf: fixture.library.appendingPathComponent("index.json")))
        XCTAssertEqual(saved.map(\.id), [entry.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.url.path))
        manager = nil
        XCTAssertNil(weakManager)
    }

    private func makeFixture() throws -> (root: URL, library: URL, source: URL, image: CGImage) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("niko-shot-pin-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("capture.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (root, root.appendingPathComponent("Pins", isDirectory: true), source, image)
    }
}

private actor PinLifecycleGate {
    private var entered = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false

    func pause() async {
        entered = true
        for waiter in arrivalWaiters { waiter.resume() }
        arrivalWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
    func recordCancellation(_ value: Bool) { wasCancelled = value }
}
