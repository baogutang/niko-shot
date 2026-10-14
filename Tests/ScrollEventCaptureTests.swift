// 新引擎的真实协调器流程，使用可控单帧源；不请求权限或派发全局滚轮。
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class ScrollEventCaptureTests: XCTestCase {
    func testIdleSessionCapturesOnceAndOnlyScrollEventsStartThe60msFinishTimer() async throws {
        let fixture = try await EventFlowFixture.make()
        let source = EventFlowSource(images: fixture.images), selection = SelectionSession()
        let coordinator = makeCoordinator(source: source, selection: selection, context: fixture.context)
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.controlProgress.frames == 1 && coordinator.resourceCounts["operation"] == 0 }
        XCTAssertEqual(source.captures, 1)
        XCTAssertEqual(coordinator.resourceCounts["captureStream"], 0)
        XCTAssertEqual(coordinator.resourceCounts["localScrollMonitor"], 1)
        XCTAssertEqual(coordinator.resourceCounts["globalScrollMonitor"], 1)
        XCTAssertEqual(coordinator.resourceCounts["loop"], 0)
        XCTAssertEqual(coordinator.resourceCounts["finishTimer"], 0)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(source.captures, 1, "No polling or StableFrameGate sampling is allowed in the new path")
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
        XCTAssertEqual(source.stops, 1)
    }

    func testManualScrollFinishesAutomaticallyAndCollectsTheFinalViewport() async throws {
        let fixture = try await EventFlowFixture.make()
        let source = EventFlowSource(images: fixture.images), selection = SelectionSession()
        var output: CGImage?
        let coordinator = makeCoordinator(source: source, selection: selection, context: fixture.context) { output = $0 }
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.resourceCounts["operation"] == 0 && coordinator.controlProgress.frames == 1 }
        source.index = 1; coordinator.handleScrollEvent()
        XCTAssertEqual(coordinator.resourceCounts["finishTimer"], 1)
        try await waitUntil { coordinator.controlProgress.frames == 2 }
        XCTAssertFalse(coordinator.controlProgress.isMatching)
        // 事件没有再来，但最后的渲染提交发生在 debounce 到期前，完成时必须收取它。
        source.index = 2
        try await waitUntil { selection.state == .annotating && coordinator.resourceCounts["operation"] == 0 }
        XCTAssertEqual(coordinator.controlProgress.height, 330)
        XCTAssertEqual(coordinator.resourceCounts["localScrollMonitor"], 0)
        XCTAssertEqual(coordinator.resourceCounts["globalScrollMonitor"], 0)
        XCTAssertEqual(coordinator.resourceCounts["finishTimer"], 0)
        XCTAssertEqual(coordinator.resourceCounts["eventFrames"], 0)
        XCTAssertEqual(source.captures, 3)
        selection.confirm()
        try await waitUntil { output != nil }
        XCTAssertEqual(output?.height, 330)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testUnrelatedEventFrameIsSkippedWithoutASeamDialogAndRecoverableNextEventAppends() async throws {
        let fixture = try await EventFlowFixture.make()
        let source = EventFlowSource(images: fixture.images), selection = SelectionSession()
        let coordinator = makeCoordinator(source: source, selection: selection, context: fixture.context)
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.resourceCounts["operation"] == 0 && coordinator.controlProgress.frames == 1 }
        source.index = 3; coordinator.handleScrollEvent()
        try await waitUntil { coordinator.resourceCounts["eventFrames"] == 0 }
        XCTAssertEqual(coordinator.controlProgress.height, 320)
        XCTAssertFalse(coordinator.controlProgress.isPaused)
        XCTAssertFalse(coordinator.controlProgress.isMatching)
        XCTAssertFalse(coordinator.controlProgress.showsAdvanced)
        source.index = 1; coordinator.handleScrollEvent()
        try await waitUntil { coordinator.controlProgress.frames == 2 }
        XCTAssertEqual(coordinator.controlProgress.height, 325)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testCancellingDuringAnInFlightSingleFrameDrainsItAndRemovesAllMonitors() async throws {
        let fixture = try await EventFlowFixture.make()
        let source = EventFlowSource(images: fixture.images), selection = SelectionSession()
        let coordinator = makeCoordinator(source: source, selection: selection, context: fixture.context)
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.resourceCounts["operation"] == 0 && coordinator.controlProgress.frames == 1 }
        source.delay = .milliseconds(45); source.index = 1
        coordinator.handleScrollEvent()
        try await waitUntil { source.captures == 2 }
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
        XCTAssertEqual(source.stops, 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(coordinator.isBusy); XCTAssertEqual(selection.state, .idle)
    }

    func testPauseAndResumeRemoveThenReinstallMonitorsWithoutReusingAStoppedSource() async throws {
        let fixture = try await EventFlowFixture.make()
        let source = EventFlowSource(images: fixture.images), selection = SelectionSession()
        let coordinator = makeCoordinator(source: source, selection: selection, context: fixture.context)
        coordinator.continueFromSelection(context: fixture.context)
        try await waitUntil { coordinator.resourceCounts["operation"] == 0 && coordinator.controlProgress.frames == 1 }
        coordinator.pause()
        try await waitUntil { coordinator.resourceCounts["operation"] == 0 }
        XCTAssertEqual(coordinator.resourceCounts["localScrollMonitor"], 0)
        XCTAssertEqual(coordinator.resourceCounts["globalScrollMonitor"], 0)
        XCTAssertEqual(coordinator.resourceCounts["capture"], 0)
        source.index = 1; coordinator.retry()
        try await waitUntil { coordinator.controlProgress.frames == 2 && coordinator.resourceCounts["operation"] == 0 }
        XCTAssertEqual(coordinator.resourceCounts["localScrollMonitor"], 1)
        XCTAssertEqual(coordinator.resourceCounts["globalScrollMonitor"], 1)
        XCTAssertEqual(source.prepares, 2)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
        XCTAssertEqual(source.stops, 2)
    }

    func testDebounceIs60msAndResetsOnEachEventRatherThanOnCaptureCompletion() async throws {
        let monitor = ScrollEventMonitor()
        var events = 0, finished: ContinuousClock.Instant?
        monitor.start(viewport: CGRect(x: 0, y: 0, width: 100, height: 100), onScroll: { events += 1 }, onFinished: { finished = .now })
        XCTAssertEqual(ScrollEventMonitor.finishDebounce, 0.06)
        monitor.receiveScrollEvent()
        try await Task.sleep(for: .milliseconds(30))
        monitor.receiveScrollEvent()
        let finalEvent = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(finished)
        try await waitUntil { finished != nil }
        XCTAssertGreaterThanOrEqual(finalEvent.duration(to: finished!), .milliseconds(55))
        XCTAssertLessThan(finalEvent.duration(to: finished!), .milliseconds(250))
        XCTAssertEqual(events, 2)
        XCTAssertEqual(monitor.timerCount, 0)
        monitor.stop()
        XCTAssertEqual(monitor.localMonitorCount + monitor.globalMonitorCount + monitor.timerCount, 0)
    }

    func testAutomaticStepSequenceAndThreadStopPreventLateDispatch() async throws {
        var step = ProgressiveScrollStep()
        XCTAssertEqual((0..<12).map { _ in step.next() }, [1, 1, 1, 1, 1, 1, 1, 1, 1, 5, 5, 5])
        var dispatched: [CGFloat] = []
        let loop = AutoScrollLoop { dispatched.append($0) }
        try await waitUntil { dispatched.count >= 12 }
        await loop.stop()
        XCTAssertFalse(loop.isRunning)
        let count = dispatched.count
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(dispatched.count, count)
        XCTAssertEqual(Array(dispatched.prefix(12)), [1, 1, 1, 1, 1, 1, 1, 1, 1, 5, 5, 5])
    }

    func testInertialEventsCaptureEachRequestDuringGPULatencyAndFinishAfterTheLastEvent() async throws {
        let fixture = ScrollImageFixture()
        var images: [CGImage] = []
        for offset in stride(from: 0, through: 800, by: 10) { images.append(try await fixture.frame(width: 96, height: 320, start: offset)) }
        let source = EventFlowSource(images: images), selection = SelectionSession()
        let context = try await EventFlowFixture.make().context
        var output: CGImage?
        let coordinator = makeCoordinator(source: source, selection: selection, context: context) { output = $0 }
        coordinator.continueFromSelection(context: context)
        try await waitUntil { coordinator.resourceCounts["operation"] == 0 && coordinator.controlProgress.frames == 1 }
        source.delay = .milliseconds(40)
        for i in 1..<images.count {
            source.index = i; coordinator.handleScrollEvent()
            try await Task.sleep(for: .milliseconds(16))
        }
        try await waitUntil { selection.state == .annotating && coordinator.resourceCounts["operation"] == 0 }
        XCTAssertEqual(coordinator.controlProgress.height, 1_120)
        XCTAssertEqual(source.captures, images.count + 1, "One capture per event, plus one final capture; no retry or stability polling")
        XCTAssertEqual(coordinator.resourceCounts["eventFrames"], 0)
        selection.confirm(); try await waitUntil { output != nil }
        let expected = try await fixture.frame(width: 96, height: 1_120, start: 0)
        XCTAssertEqual(try RowHashFrame(XCTUnwrap(output)).bytes, try RowHashFrame(expected).bytes)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testAutomaticResumeKeepsTheAcceleratedStepCount() async throws {
        var speeds: [CGFloat] = []
        let loop = AutoScrollLoop(initialStepCount: 24) { speeds.append($0) }
        try await waitUntil { speeds.count >= 3 }
        await loop.stop()
        XCTAssertEqual(speeds, Array(repeating: 5, count: speeds.count))
        XCTAssertGreaterThan(loop.stepCount, 24)
    }

    func testOnlyAnExplicitFiniteScrollBarMaximumProvesAnEmptyPageHasEnded() {
        XCTAssertTrue(ScrollBoundaryResolver.isAtBottom(value: 1, minimum: 0, maximum: 1))
        XCTAssertFalse(ScrollBoundaryResolver.isAtBottom(value: 0.7, minimum: 0, maximum: 1))
        XCTAssertFalse(ScrollBoundaryResolver.isAtBottom(value: 0, minimum: 0, maximum: 0))
        XCTAssertFalse(ScrollBoundaryResolver.isAtBottom(value: .infinity, minimum: 0, maximum: 1))
        XCTAssertFalse(ScrollBoundaryResolver.isAtBottom(value: 1.1, minimum: 0, maximum: 1))
    }

    func testMovingToAnotherDisplayPreservesAcceptedContentAndRequiresReselection() async throws {
        let fixture = try await EventFlowFixture.make(), selection = SelectionSession()
        var context = fixture.context
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [] }, windows: { [] }, prepare: { _ in
            RegionSnapshot(capture: { fixture.images[0] }, validate: { context })
        }, activate: { _ in })
        let coordinator = ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { _, _ in }, workflow: workflow)
        coordinator.continueFromSelection(context: context)
        try await waitUntil { coordinator.controlProgress.frames == 1 && coordinator.resourceCounts["operation"] == 0 }
        let next = ScreenGeometry(id: 100, frame: context.screen.frame, scale: context.screen.scale)
        context = CaptureContext(screen: next, localRect: context.localRect, kind: context.kind, windowID: context.windowID)
        coordinator.handleScrollEvent()
        try await waitUntil { coordinator.controlProgress.requiresReselection && coordinator.resourceCounts["eventFrames"] == 0 }
        XCTAssertEqual(coordinator.controlProgress.height, 320)
        XCTAssertEqual(coordinator.resourceCounts["localScrollMonitor"], 0)
        XCTAssertEqual(coordinator.resourceCounts["globalScrollMonitor"], 0)
        XCTAssertEqual(coordinator.resourceCounts["finishTimer"], 0)
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    func testScrollingAnotherWindowOverTheSelectedRegionDoesNotCaptureOrStartTheFinishTimer() throws {
        let monitor = ScrollEventMonitor()
        var captures = 0
        monitor.start(viewport: CGRect(x: 100, y: 100, width: 200, height: 200), windowID: 42,
            onScroll: { captures += 1 }, onFinished: {})
        defer { monitor.stop() }
        let point = CGPoint(x: 150, y: 150)
        monitor.receiveScrollEvent(at: point, targetWindow: 999)
        XCTAssertEqual(captures, 0); XCTAssertEqual(monitor.timerCount, 0)
        monitor.receiveScrollEvent(at: point, targetWindow: 42)
        XCTAssertEqual(captures, 1)
        monitor.receiveScrollEvent(at: point, targetWindow: 999, synthetic: true)
        XCTAssertEqual(captures, 2, "Validated automatic events must use their explicit selected-window location")
    }

    private func makeCoordinator(source: EventFlowSource, selection: SelectionSession, context: CaptureContext,
                                 onCapture: @escaping (CGImage) -> Void = { _ in }) -> ScrollCoordinator {
        let workflow = ScrollCaptureWorkflow(freezeScreens: { [] }, windows: { [] }, prepare: { _ in
            source.prepares += 1
            return RegionSnapshot(capture: {
                source.captures += 1
                let image = source.images[source.index]
                if let delay = source.delay { try await Task.sleep(for: delay) }
                return image
            }, validate: { context }, stop: { source.stops += 1 })
        }, activate: { _ in })
        return ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
            onCapture: { image, _ in onCapture(image) }, workflow: workflow)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition(), start.duration(to: .now) < .seconds(4) { try await Task.sleep(for: .milliseconds(3)) }
        XCTAssertTrue(condition(), "Event capture did not reach its expected state")
    }
}

@MainActor
private final class EventFlowSource {
    let images: [CGImage]
    var index = 0, captures = 0, stops = 0, prepares = 0
    var delay: Duration?
    init(images: [CGImage]) { self.images = images }
}

private struct EventFlowFixture: Sendable {
    let images: [CGImage]
    let context: CaptureContext
    static func make() async throws -> EventFlowFixture {
        let fixture = ScrollImageFixture()
        var images: [CGImage] = []
        for offset in [0, 5, 10] { images.append(try await fixture.frame(width: 96, height: 320, start: offset)) }
        images.append(try await fixture.frame(width: 96, height: 320, start: 800, seed: 123))
        let screen = ScreenGeometry(id: 99, frame: CGRect(x: 0, y: 0, width: 640, height: 600), scale: 1)
        return EventFlowFixture(images: images,
            context: CaptureContext(screen: screen, localRect: CGRect(x: 20, y: 80, width: 96, height: 320), kind: "window", windowID: 42))
    }
}
