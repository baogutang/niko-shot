// Checks setup cancellation without requesting ScreenCaptureKit or Accessibility consent.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class ScrollCoordinatorLifecycleTests: XCTestCase {
    func testUnalignedFramesKeepObservingAndRecoverWithoutPausingOrOpeningAdvancedSettings() async throws {
        let fixture = try await ScrollFlowFixture.make()
        let unrelated = try await ScrollImageFixture().frame(width: 220, height: 320, start: 0, seed: 999)
        let source = ScrollFlowSource(images: [fixture.images[0], unrelated, fixture.images[1]])
        let selection = SelectionSession()
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [fixture.frame] }, windows: { [fixture.candidate] },
            prepare: { context in RegionSnapshot(capture: { source.current }, validate: { context }, continuous: true) },
            activate: { _ in })
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in }, workflow: workflow)
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.controlProgress.frames == 1 && !coordinator.controlProgress.isWorking }
        source.index = 1
        try await waitUntil { coordinator.controlProgress.isMatching }
        XCTAssertFalse(coordinator.controlProgress.isPaused)
        XCTAssertFalse(coordinator.controlProgress.showsAdvanced)
        XCTAssertEqual(coordinator.controlProgress.height, 320)
        XCTAssertEqual(coordinator.resourceCounts["livePreviewImage"], 1)
        source.index = 2
        try await waitUntil { coordinator.controlProgress.frames == 2 }
        XCTAssertEqual(coordinator.controlProgress.height, 352)
        XCTAssertFalse(coordinator.controlProgress.isMatching)
        XCTAssertFalse(coordinator.controlProgress.isPaused)
        XCTAssertFalse(coordinator.controlProgress.showsAdvanced)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testReturningToAcceptedViewportClearsRecoveryWithoutAppendingUnrelatedPixels() async throws {
        let fixture = try await ScrollFlowFixture.make()
        let unrelated = try await ScrollImageFixture().frame(width: 220, height: 320, start: 0, seed: 999)
        let source = ScrollFlowSource(images: [fixture.images[0], unrelated, fixture.images[1]])
        let selection = SelectionSession()
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [fixture.frame] }, windows: { [fixture.candidate] },
            prepare: { context in RegionSnapshot(capture: { source.current }, validate: { context }) }, activate: { _ in })
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in }, workflow: workflow)
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.controlProgress.frames == 1 && !coordinator.controlProgress.isWorking }
        source.index = 1
        try await waitUntil { coordinator.controlProgress.isMatching }
        source.index = 0
        try await waitUntil { !coordinator.controlProgress.isMatching }
        XCTAssertEqual(coordinator.controlProgress.height, 320)
        source.index = 2
        try await waitUntil { coordinator.controlProgress.frames == 2 }
        XCTAssertEqual(coordinator.controlProgress.height, 352)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testPausingReleasesTheStreamAndAdvancedOptionsCanReopenWithoutLosingAcceptedRows() async throws {
        let fixture = try await ScrollFlowFixture.make(), source = ScrollFlowSource(images: fixture.images)
        let selection = SelectionSession()
        var prepared = 0, stops = 0
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [fixture.frame] }, windows: { [fixture.candidate] },
            prepare: { context in
                prepared += 1
                return RegionSnapshot(capture: { source.current }, validate: { context },
                                      stop: { stops += 1 }, continuous: true)
            }, activate: { _ in })
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in }, workflow: workflow)
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.controlProgress.frames == 1 && !coordinator.controlProgress.isWorking }
        coordinator.pause()
        try await waitUntil { coordinator.resourceCounts["operation"] == 0 && coordinator.resourceCounts["capture"] == 0 }
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(coordinator.controlProgress.isPaused)
        XCTAssertEqual(coordinator.resourceCounts["livePreviewImage"], 1)
        coordinator.openAdvanced()
        try await waitUntil { coordinator.resourceCounts["setup"] == 1 && coordinator.resourceCounts["operation"] == 0 }
        XCTAssertEqual(prepared, 2); XCTAssertEqual(stops, 2)
        XCTAssertEqual(coordinator.resourceCounts["captureStream"], 0)
        let setup = try XCTUnwrap(NSApp.windows.first { $0.title == "长截图高级选项" && $0.isVisible })
        setup.close()
        coordinator.retry()
        try await waitUntil { coordinator.resourceCounts["captureStream"] == 1 && coordinator.resourceCounts["operation"] == 0 }
        XCTAssertEqual(prepared, 3)
        source.index = 1
        try await waitUntil { coordinator.controlProgress.frames == 2 }
        XCTAssertEqual(coordinator.controlProgress.height, 352)
        await coordinator.cancel()
        XCTAssertEqual(stops, 3)
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testContinuousFramesAdvanceBeforeScrollingStopsAndCloseTheirStream() async throws {
        let fixture = try await ScrollFlowFixture.make()
        let source = ScrollFlowSource(images: fixture.images)
        var motion = false, stops = 0
        let selection = SelectionSession()
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [fixture.frame] }, windows: { [fixture.candidate] },
            prepare: { context in
                RegionSnapshot(capture: {
                    if motion { source.index = source.index == 1 ? 3 : 1 }
                    return source.current
                }, validate: { context }, stop: { stops += 1 }, continuous: true)
            }, activate: { _ in })
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in }, workflow: workflow)
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.controlProgress.frames == 1 && !coordinator.controlProgress.isWorking }
        XCTAssertGreaterThan(coordinator.resourceCounts["selectionOverlay"] ?? 0, 0)
        XCTAssertEqual(coordinator.resourceCounts["captureStream"], 1)
        motion = true
        try await waitUntil { coordinator.controlProgress.frames >= 3 }
        XCTAssertEqual(coordinator.controlProgress.height, 370)
        XCTAssertFalse(coordinator.controlProgress.isMatching)
        await coordinator.cancel()
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testSetupCancellationReleasesEveryOwnedResourceAndCanRepeat() async throws {
        let selection = SelectionSession()
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(), onCapture: { _, _ in })
        let image = try await Task.detached { () -> CGImage in
            guard let context = CGContext(data: nil, width: 96, height: 320, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AppError.imageCreation }
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 320))
            guard let image = context.makeImage() else { throw AppError.imageCreation }
            return image
        }.value
        let screen = ScreenGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 96, height: 320), scale: 1)
        for _ in 0..<2 {
            coordinator.showSetup(image: image, context: CaptureContext(screen: screen, localRect: screen.localBounds, kind: "scroll"))
            XCTAssertTrue(coordinator.isBusy)
            XCTAssertEqual(coordinator.resourceCounts["setup"], 1)
            await coordinator.cancel()
            XCTAssertFalse(coordinator.isBusy)
            XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
            XCTAssertEqual(selection.windowCount, 0)
            XCTAssertEqual(selection.monitorCount, 0)
        }
    }

    func testMouseWindowSelectionStartsManualCaptureWithoutSetupAndFinishesRealPNG() async throws {
        let fixture = try await ScrollFlowFixture.make()
        let source = ScrollFlowSource(images: fixture.images)
        let selection = SelectionSession()
        var output: CGImage?
        var prepared: [CaptureContext] = []
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [fixture.frame] }, windows: { [fixture.candidate] },
            prepare: { context in
                XCTAssertEqual(selection.windowCount, 0, "Frozen overlays must close before live capture")
                prepared.append(context)
                return RegionSnapshot(capture: { source.current }, validate: { context })
            }, activate: { _ in XCTFail("Fixture replaced activation below") })
        var injected = workflow; injected.activate = { _ in }
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { image, _ in output = image }, workflow: injected)
        coordinator.select()
        try await waitUntil { selection.state == .selecting && coordinator.resourceCounts["operation"] == 0 }
        let selector = try XCTUnwrap(selection.windows.first?.contentView as? SelectionView)
        XCTAssertTrue(selector.windowMode)
        try mouse(.leftMouseDown, point: CGPoint(x: 130, y: 220), to: selector)
        XCTAssertEqual(coordinator.controlProgress.frames, 0)
        try mouse(.leftMouseUp, point: CGPoint(x: 130, y: 220), to: selector)
        XCTAssertEqual(selection.state, .idle, "Mouse completion must hand off directly without Enter")
        try await waitUntil { coordinator.controlProgress.frames == 1 && !coordinator.controlProgress.isWorking }
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared.first?.windowID, 42)
        XCTAssertEqual(prepared.first?.kind, "window")
        XCTAssertEqual(prepared.first?.targetWindowFrame, fixture.candidate.frame)
        XCTAssertEqual(coordinator.resourceCounts["setup"], 0)
        XCTAssertEqual(coordinator.resourceCounts["controls"], 1)
        XCTAssertEqual(coordinator.controlProgress.mode, .manual)
        XCTAssertEqual(coordinator.controlProgress.height, 320)

        source.index = 1
        try await waitUntil { coordinator.controlProgress.frames == 2 }
        XCTAssertEqual(coordinator.controlProgress.height, 352, "A small manual scroll must append its actual rows")
        source.index = 2
        try await waitUntil { coordinator.controlProgress.isBacktracking }
        XCTAssertEqual(coordinator.controlProgress.frames, 2, "Browsing upward must not append previously captured pixels")
        XCTAssertEqual(coordinator.controlProgress.height, 352)
        source.index = 1
        try await waitUntil { !coordinator.controlProgress.isBacktracking }
        source.index = 3
        try await waitUntil { coordinator.controlProgress.frames == 3 }
        XCTAssertEqual(coordinator.controlProgress.height, 370)
        coordinator.finish()
        try await waitUntil { selection.state == .annotating && coordinator.resourceCounts["operation"] == 0 }
        selection.confirm()
        try await waitUntil { output != nil }
        XCTAssertEqual(output?.width, 220)
        XCTAssertEqual(output?.height, 370)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
        XCTAssertEqual(selection.resourceCounts.values.reduce(0, +), 0)
        XCTAssertEqual(selection.windowCount, 0)
    }

    func testRegionChoiceWaitsForMouseUpAndRepeatedCancellationReleasesEverything() async throws {
        let fixture = try await ScrollFlowFixture.make()
        let selection = SelectionSession()
        var prepared: [CaptureContext] = []
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [fixture.frame] }, windows: { [fixture.candidate] },
            prepare: { context in
                prepared.append(context)
                return RegionSnapshot(capture: { fixture.images[0] }, validate: { context })
            }, activate: { _ in })
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in XCTFail("Cancelled capture produced output") }, workflow: workflow)
        for iteration in 1...2 {
            coordinator.select()
            try await waitUntil { selection.state == .selecting && coordinator.resourceCounts["operation"] == 0 }
            let selector = try XCTUnwrap(selection.windows.first?.contentView as? SelectionView)
            let modes = try XCTUnwrap(selector.subviews.flatMap(\.subviews).compactMap { $0 as? NSSegmentedControl }.first)
            XCTAssertEqual(modes.segmentCount, 2, "Region selection remains a visible native option")
            try key("\t", code: 48, to: selector)
            XCTAssertFalse(selector.windowMode)
            try mouse(.leftMouseDown, point: CGPoint(x: 20, y: 120), to: selector)
            try mouse(.leftMouseDragged, point: CGPoint(x: 240, y: 440), to: selector)
            XCTAssertEqual(prepared.count, iteration - 1, "Intermediate drags must never start live capture")
            try mouse(.leftMouseUp, point: CGPoint(x: 240, y: 440), to: selector)
            try await waitUntil { coordinator.controlProgress.frames == 1 && !coordinator.controlProgress.isWorking }
            XCTAssertEqual(prepared.count, iteration)
            XCTAssertEqual(prepared.last?.kind, "region")
            XCTAssertEqual(prepared.last?.localRect, CGRect(x: 20, y: 120, width: 220, height: 320))
            await coordinator.cancel(); await coordinator.cancel()
            XCTAssertFalse(coordinator.isBusy)
            XCTAssertEqual(coordinator.controlProgress.frames, 0, "A cancelled session must not satisfy the next session's first-frame condition")
            XCTAssertEqual(coordinator.controlProgress.height, 0)
            XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
            XCTAssertEqual(selection.resourceCounts.values.reduce(0, +), 0)
            XCTAssertEqual(selection.windowCount, 0)
            XCTAssertEqual(selection.monitorCount, 0)
        }
    }

    func testFinishingImmediatelyAfterScrollingCollectsTheLastViewportAndClosesLivePreview() async throws {
        let fixture = try await ScrollFlowFixture.make(), source = ScrollFlowSource(images: fixture.images)
        let selection = SelectionSession()
        var output: CGImage?
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [fixture.frame] }, windows: { [fixture.candidate] },
            prepare: { context in RegionSnapshot(capture: { source.current }, validate: { context }) }, activate: { _ in })
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { image, _ in output = image }, workflow: workflow)
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.controlProgress.frames == 1 && !coordinator.controlProgress.isWorking }
        XCTAssertEqual(coordinator.resourceCounts["livePreviewWindow"], 1)
        XCTAssertEqual(coordinator.resourceCounts["livePreviewImage"], 1)
        source.index = 1
        coordinator.finish() // Do not give the sampling loop a turn to observe this final scroll.
        try await waitUntil { selection.state == .annotating && coordinator.resourceCounts["operation"] == 0 }
        XCTAssertEqual(coordinator.controlProgress.height, 352, "Finish must not truncate the last unsettled viewport")
        XCTAssertEqual(coordinator.resourceCounts["livePreviewWindow"], 0)
        XCTAssertEqual(coordinator.resourceCounts["livePreviewImage"], 0)
        selection.confirm()
        try await waitUntil { output != nil }
        XCTAssertEqual(output?.height, 352)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testAnUncertainFinalSeamKeepsTheAcceptedLivePreviewAndWaitsForConfirmation() async throws {
        let fixture = try await ScrollFlowFixture.make()
        let unrelated = try await ScrollImageFixture().frame(width: 220, height: 320, start: 0, seed: 999)
        let source = ScrollFlowSource(images: [fixture.images[0], unrelated]), selection = SelectionSession()
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [fixture.frame] }, windows: { [fixture.candidate] },
            prepare: { context in RegionSnapshot(capture: { source.current }, validate: { context }) }, activate: { _ in })
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in XCTFail("An unconfirmed last viewport must not be exported") }, workflow: workflow)
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.controlProgress.frames == 1 && !coordinator.controlProgress.isWorking }
        source.index = 1; coordinator.finish()
        try await waitUntil { coordinator.controlProgress.isMatching && coordinator.resourceCounts["operation"] == 0 }
        XCTAssertEqual(selection.state, .idle)
        XCTAssertEqual(coordinator.controlProgress.height, 320)
        XCTAssertTrue(coordinator.controlProgress.status.contains("最后一屏"))
        XCTAssertFalse(coordinator.controlProgress.isWorking)
        XCTAssertEqual(coordinator.resourceCounts["livePreviewImage"], 1)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testHidingPreviewKeepsCaptureRunningAndReopeningShowsLatestAcceptedRows() async throws {
        let fixture = try await ScrollFlowFixture.make(), source = ScrollFlowSource(images: fixture.images)
        let selection = SelectionSession()
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [fixture.frame] }, windows: { [fixture.candidate] },
            prepare: { context in RegionSnapshot(capture: { source.current }, validate: { context }) }, activate: { _ in })
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in }, workflow: workflow)
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.previewProgress?.frames == 1 && !coordinator.controlProgress.isWorking }
        coordinator.togglePreview()
        XCTAssertEqual(coordinator.resourceCounts["livePreviewWindow"], 0)
        XCTAssertEqual(coordinator.resourceCounts["livePreviewImage"], 1)
        source.index = 1
        try await waitUntil { coordinator.controlProgress.frames == 2 }
        XCTAssertFalse(coordinator.controlProgress.isPaused)
        coordinator.togglePreview()
        try await waitUntil { coordinator.previewProgress?.frames == 2 }
        XCTAssertEqual(coordinator.previewProgress?.sourceSize.height, 352)
        XCTAssertEqual(coordinator.resourceCounts["livePreviewWindow"], 1)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testWindowTranslationFollowsIdentityWhileMovedRegionAndResizeAreRejected() throws {
        let screen = ScreenGeometry(id: 99, frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2)
        let original = ScrollWindowGeometry(id: 42, ownerPID: 123, frame: CGRect(x: 20, y: 120, width: 220, height: 320), isOnScreen: true)
        var context = CaptureContext(screen: screen, localRect: CGRect(x: 20, y: 160, width: 220, height: 320),
            kind: "window", appBundleID: "com.example.fixture", windowID: 42, targetWindowFrame: original.frame)
        let moved = ScrollWindowGeometry(id: 42, ownerPID: 123, frame: original.frame.offsetBy(dx: 80, dy: 20), isOnScreen: true)
        let translated = try ScrollTargetGeometry(context: context, window: original).validate(window: moved, screens: [screen])
        XCTAssertEqual(translated.windowID, 42)
        XCTAssertEqual(translated.globalRect, context.globalRect.offsetBy(dx: 80, dy: 20))
        XCTAssertEqual(translated.localRect.size, context.localRect.size)
        context.kind = "region"
        XCTAssertThrowsError(try ScrollTargetGeometry(context: context, window: original).validate(window: moved, screens: [screen])) {
            guard case ScrollTargetError.regionMoved = $0 else { return XCTFail("Expected moved-region rejection, got \($0)") }
        }
        let resized = ScrollWindowGeometry(id: 42, ownerPID: 123, frame: CGRect(x: 20, y: 120, width: 221, height: 320), isOnScreen: true)
        XCTAssertThrowsError(try ScrollTargetGeometry(context: context, window: original).validate(window: resized, screens: [screen]))
        let reusedID = ScrollWindowGeometry(id: 42, ownerPID: 456, frame: original.frame, isOnScreen: true)
        XCTAssertThrowsError(try ScrollTargetGeometry(context: context, window: original).validate(window: reusedID, screens: [screen]))
        XCTAssertThrowsError(try ScrollTargetGeometry(context: context, window: original).validate(window: nil, screens: [screen]))
        XCTAssertThrowsError(try ScrollTargetGeometry(context: context, window: original).validate(window: original, screens: []))
    }

    func testChangedRegionPausesBeforeReadingWrongPixelsAndKeepsAcceptedFrame() async throws {
        let fixture = try await ScrollFlowFixture.make()
        let selection = SelectionSession()
        let source = ScrollFlowSource(images: fixture.images)
        var reads = 0
        let target = fixture.context
        let window = ScrollWindowGeometry(id: 42, ownerPID: 123, frame: fixture.candidate.frame, isOnScreen: true)
        let baseline = ScrollTargetGeometry(context: target, window: window)
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [fixture.frame] }, windows: { [fixture.candidate] },
            prepare: { _ in
                RegionSnapshot(capture: { reads += 1; return source.current }, validate: {
                    let frame = source.index == 0 ? window.frame : window.frame.offsetBy(dx: 5, dy: 0)
                    return try baseline.validate(window: ScrollWindowGeometry(id: 42, ownerPID: 123, frame: frame, isOnScreen: true),
                                                 screens: [target.screen])
                })
            }, activate: { _ in })
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in }, workflow: workflow)
        coordinator.continueFromSelection(context: target)
        try await waitUntil { coordinator.controlProgress.frames == 1 && !coordinator.controlProgress.isWorking }
        let before = reads
        source.index = 1
        try await waitUntil { coordinator.controlProgress.requiresReselection }
        XCTAssertTrue(coordinator.controlProgress.isPaused)
        XCTAssertFalse(coordinator.controlProgress.requiresRestart, "The disk actor remains usable for accepted content")
        XCTAssertEqual(reads, before, "Geometry must be checked before the native image request")
        XCTAssertEqual(coordinator.controlProgress.frames, 1)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testTerminalDiskFailureRestartsWithNewWorkerInsteadOfRetryingClosedActor() async throws {
        let fixture = try await ScrollFlowFixture.make()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scroll-failed-flow-\(UUID().uuidString)")
        let invalidDirectory = try await Task.detached { () throws -> URL in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("regular-file")
            try Data([1]).write(to: file)
            return file
        }.value
        let failed = ScrollCaptureSession(workingDirectory: invalidDirectory)
        let selection = SelectionSession()
        var workers = 0
        var workflow = ScrollCaptureWorkflow(freezeScreens: { [fixture.frame] }, windows: { [fixture.candidate] },
            prepare: { context in RegionSnapshot(capture: { fixture.images[0] }, validate: { context }) }, activate: { _ in })
        workflow.makeWorker = { options in
            workers += 1
            return workers == 1 ? failed : ScrollCaptureSession(options: options, workingDirectory: folder)
        }
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in }, workflow: workflow)
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.controlProgress.requiresRestart && coordinator.resourceCounts["operation"] == 0 }
        let failedProgress = await failed.progress
        XCTAssertEqual(failedProgress.state, .failed)
        XCTAssertEqual(coordinator.resourceCounts["loop"], 0)
        XCTAssertEqual(workers, 1)
        coordinator.retry()
        try await waitUntil { coordinator.controlProgress.frames == 1 && !coordinator.controlProgress.isWorking }
        XCTAssertEqual(workers, 2, "Retry on terminal failure must construct a fresh disk transaction")
        XCTAssertFalse(coordinator.controlProgress.requiresRestart)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
        await Task.detached { try? FileManager.default.removeItem(at: folder) }.value
    }

    func testAutomationCallerCancellationDrainsSelectorAndCompletesOnlyOnce() async throws {
        let fixture = try await ScrollFlowFixture.make()
        let selection = SelectionSession()
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [fixture.frame] }, windows: { [fixture.candidate] },
            prepare: { _ in XCTFail("Cancelled selector started capture"); throw CancellationError() }, activate: { _ in })
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in XCTFail("Cancelled automation produced output") }, workflow: workflow)
        for _ in 0..<2 {
            let caller = Task { try await coordinator.captureForAutomation() }
            try await waitUntil { selection.state == .selecting && coordinator.resourceCounts["operation"] == 0 }
            caller.cancel()
            do { _ = try await caller.value; XCTFail("Cancellation returned an image") }
            catch is CancellationError {}
            catch { XCTFail("Unexpected cancellation error: \(error)") }
            await coordinator.cancel()
            XCTAssertFalse(coordinator.isBusy)
            XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
            XCTAssertEqual(selection.windowCount, 0)
        }
    }

    private func mouse(_ type: NSEvent.EventType, point: CGPoint, to view: SelectionView) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: XCTFail("Unsupported fixture event")
        }
    }

    private func key(_ text: String, code: UInt16, to view: NSView) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code))
        view.keyDown(with: event)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { throw AppError.file("Native scroll-flow fixture did not reach its expected state") }
    }

}


@MainActor
private final class ScrollFlowSource {
    let images: [CGImage]
    var index = 0
    var current: CGImage { images[index] }
    init(images: [CGImage]) { self.images = images }
}

private struct ScrollFlowFixture: Sendable {
    let frame: FrozenFrame
    let candidate: WindowCandidate
    let images: [CGImage]
    var context: CaptureContext {
        CaptureContext(screen: frame.screen, localRect: CGRect(x: 20, y: 120, width: 220, height: 320), kind: "region",
                       appBundleID: candidate.appBundleID, windowID: candidate.id, targetWindowFrame: candidate.frame)
    }
    static func make() async throws -> ScrollFlowFixture {
        try await Task.detached {
            let width = 220, height = 900
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            var random: UInt64 = 0x314159265
            for y in 0..<height {
                for x in 0..<width {
                    random = random &* 6364136223846793005 &+ 1442695040888963407
                    let value = UInt8(truncatingIfNeeded: random >> 40)
                    let i = (y * width + x) * 4
                    bytes[i] = value; bytes[i + 1] = UInt8(truncatingIfNeeded: value &+ UInt8(truncatingIfNeeded: y))
                    bytes[i + 2] = UInt8(truncatingIfNeeded: random >> 32)
                }
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let document = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw AppError.imageCreation }
            let images = try [100, 132, 116, 150].map { offset -> CGImage in
                guard let image = document.cropping(to: CGRect(x: 0, y: offset, width: width, height: 320)) else { throw AppError.imageCreation }
                return image
            }
            let canvas = try ImageUtilities.context(width: 640, height: 600)
            canvas.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: 640, height: 600))
            guard let frozen = canvas.makeImage() else { throw AppError.imageCreation }
            let screen = ScreenGeometry(id: 99, frame: CGRect(x: 0, y: 0, width: 640, height: 600), scale: 1)
            let candidate = WindowCandidate(id: 42, frame: CGRect(x: 20, y: 160, width: 220, height: 320), title: "Fixture window", appBundleID: "com.example.fixture")
            return ScrollFlowFixture(frame: FrozenFrame(screen: screen, image: frozen), candidate: candidate, images: images)
        }.value
    }
}
