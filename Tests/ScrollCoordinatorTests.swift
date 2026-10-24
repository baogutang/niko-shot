// Drives the real long-capture state machine with an injected frame source (no screen-recording consent).
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class ScrollCoordinatorTests: XCTestCase {
    /// A live "window" whose visible offset the test scrolls.
    private final class FakeTarget {
        let document: CGImage
        var offset = 0
        var captures = 0
        /// Renders the next frames mid-momentum (rows resampled at a fractional offset).
        var soft = false
        var scrolls = 0
        var scrollChecks = 0
        let height: Int
        init(document: CGImage, height: Int) { self.document = document; self.height = height }
        func frame() throws -> CGImage {
            captures += 1
            return soft ? try ScrollImageFixture.resampledViewport(document, offset: offset, height: height)
                : try ScrollImageFixture.viewport(document, offset: offset, height: height)
        }
    }

    private func context(width: Int, height: Int) -> CaptureContext {
        let screen = ScreenGeometry(id: 77, frame: CGRect(x: 0, y: 0, width: 1_200, height: 900), scale: 2)
        return CaptureContext(screen: screen, localRect: CGRect(x: 100, y: 100, width: CGFloat(width) / 2, height: CGFloat(height) / 2),
                              kind: "region", appBundleID: "com.example.fixture")
    }

    private var permissionRequests = 0

    /// `scroll` enables automatic mode and moves the fake target for each synthetic step.
    private func makeCoordinator(target: FakeTarget, selection: SelectionSession,
                                 onCapture: @escaping (CGImage, CaptureContext) -> Void,
                                 settleDelays: [Duration] = [],
                                 scroll: ((CGFloat) -> Void)? = nil) -> ScrollCoordinator {
        var workflow = ScrollCaptureWorkflow(freezeScreens: { [] }, windows: { [] },
            prepareSource: { context, _ in
                RegionSnapshot(capture: { _ in try target.frame() }, validate: { context },
                               validateScroll: { _ in target.scrollChecks += 1 })
            })
        workflow.activate = { _ in }
        workflow.settleDelays = settleDelays
        workflow.activationDelay = .zero
        workflow.isAutoScrollAuthorized = { scroll != nil }
        workflow.scroll = { points, _ in target.scrolls += 1; scroll?(points) }
        workflow.requestAutoScrollPermission = { [weak self] in self?.permissionRequests += 1 }
        return ScrollCoordinator(engine: CaptureEngine(), selection: selection, windows: WindowList(),
                                 onCapture: onCapture, workflow: workflow)
    }

    func testScrollActivityAppendsAndFinishOpensEditorWithTheStitchedImage() async throws {
        let document = try ScrollImageFixture.document(width: 800, height: 2_400)
        let target = FakeTarget(document: document, height: 500)
        let selection = SelectionSession()
        var output: CGImage?
        let coordinator = makeCoordinator(target: target, selection: selection) { image, _ in output = image }
        defer { selection.finish() }
        coordinator.continueFromSelection(context: context(width: 800, height: 500))
        XCTAssertTrue(coordinator.isBusy)
        try await waitUntil { coordinator.state.frames == 1 }
        XCTAssertEqual(coordinator.state.height, 500)
        XCTAssertEqual(coordinator.resourceCounts["controls"], 1)
        XCTAssertEqual(coordinator.resourceCounts["overlay"], 1)
        XCTAssertGreaterThan(coordinator.resourceCounts["monitors"] ?? 0, 0)

        for offset in [160, 330, 520, 700] {
            target.offset = offset
            coordinator.receive(ScrollActivity(preciseDownwardPoints: 80))
            try await waitUntil { coordinator.state.height == offset + 500 }
        }
        // A pause between scroll gestures must not end the session (the old 60 ms debounce did).
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(coordinator.isBusy)
        XCTAssertEqual(coordinator.state.phase, .capturing)

        coordinator.finish()
        try await waitUntil { !coordinator.isBusy && selection.state == .annotating }
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
        selection.confirm()
        try await waitUntil { output != nil }
        XCTAssertEqual(output?.height, 1_200)
        XCTAssertEqual(output?.width, 800)
    }

    func testCancelDuringCaptureReleasesEveryResource() async throws {
        let document = try ScrollImageFixture.document(width: 600, height: 1_600)
        let target = FakeTarget(document: document, height: 400)
        let selection = SelectionSession()
        let coordinator = makeCoordinator(target: target, selection: selection) { _, _ in XCTFail("Cancelled capture produced output") }
        coordinator.continueFromSelection(context: context(width: 600, height: 400))
        try await waitUntil { coordinator.state.frames == 1 }
        target.offset = 120
        coordinator.receive(ScrollActivity(preciseDownwardPoints: 60))
        await coordinator.cancel()
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
        XCTAssertEqual(selection.state, .idle)
    }

    func testAutomaticModeWithoutPermissionKeepsManualCapture() async throws {
        let document = try ScrollImageFixture.document(width: 600, height: 1_600)
        let target = FakeTarget(document: document, height: 400)
        let selection = SelectionSession()
        let coordinator = makeCoordinator(target: target, selection: selection) { _, _ in }
        coordinator.continueFromSelection(context: context(width: 600, height: 400))
        try await waitUntil { coordinator.state.frames == 1 }
        // The HUD button routes here; without consent the session stays manual and explains why.
        coordinator.toggleAutomatic()
        XCTAssertFalse(coordinator.state.isAutomatic)
        XCTAssertEqual(coordinator.state.tone, .warning)
        XCTAssertEqual(permissionRequests, 1)
        await coordinator.cancel()
    }

    func testUpwardBrowsingDoesNotDuplicateContent() async throws {
        let document = try ScrollImageFixture.document(width: 700, height: 2_000)
        let target = FakeTarget(document: document, height: 500)
        let selection = SelectionSession()
        let coordinator = makeCoordinator(target: target, selection: selection) { _, _ in }
        coordinator.continueFromSelection(context: context(width: 700, height: 500))
        try await waitUntil { coordinator.state.frames == 1 }
        target.offset = 300
        coordinator.receive(ScrollActivity(preciseDownwardPoints: 150))
        try await waitUntil { coordinator.state.height == 800 }
        target.offset = 120
        coordinator.receive(ScrollActivity(preciseDownwardPoints: -90))
        try await waitUntil { coordinator.state.title == "正在向上浏览" }
        XCTAssertEqual(coordinator.state.height, 800)
        await coordinator.cancel()
    }

    /// With the settle threshold pinned to zero every unmatched frame counts, so two jumps warn;
    /// with a huge threshold momentum frames never count and the status stays quiet.
    /// 断言只看状态结果，不依赖捕获到达时刻，避免 CI 时序竞争。
    func testSettledMismatchesWarnWhileMomentumMismatchesStayQuiet() async throws {
        let document = try ScrollImageFixture.document(width: 800, height: 6_000)
        let selection = SelectionSession()
        defer { selection.finish() }

        func jump(_ coordinator: ScrollCoordinator, _ target: FakeTarget, _ offset: Int) {
            target.offset = offset
            coordinator.receive(ScrollActivity(preciseDownwardPoints: CGFloat(offset)))
        }

        // Branch 1: threshold zero — two unmatched jumps warn.
        let warnTarget = FakeTarget(document: document, height: 500)
        var output: CGImage?
        let warner = makeCoordinator(target: warnTarget, selection: selection, onCapture: { image, _ in output = image },
                                     settleDelays: [.milliseconds(20), .milliseconds(40)])
        warner.mismatchSettle = .zero
        warner.continueFromSelection(context: context(width: 800, height: 500))
        try await waitUntil { warner.state.frames == 1 }
        jump(warner, warnTarget, 1_400)
        try await waitUntil { warner.state.title == "画面没对上" }
        XCTAssertNil(output)

        // Branch 2: threshold far above the test duration — the same jumps stay quiet.
        let quietTarget = FakeTarget(document: document, height: 500)
        let quieter = makeCoordinator(target: quietTarget, selection: selection, onCapture: { _, _ in },
                                      settleDelays: [.milliseconds(20), .milliseconds(40)])
        quieter.mismatchSettle = .seconds(10)
        quieter.continueFromSelection(context: context(width: 800, height: 500))
        try await waitUntil { quieter.state.frames == 1 }
        jump(quieter, quietTarget, 1_400)
        jump(quieter, quietTarget, 2_600)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNotEqual(quieter.state.title, "画面没对上", "momentum-window mismatches must stay quiet")
        XCTAssertEqual(quieter.state.phase, .capturing)
    }

    /// The stitcher measures shift from the last accepted frame, so the hint must too: the delta of a
    /// frame the app had not repainted yet (unchanged) carries over to the next, soft momentum frame,
    /// whose rescue needs a hint within a few rows of the true shift.
    func testScrollHintRunsFromTheLastAcceptedFrame() async throws {
        let document = try ScrollImageFixture.document(width: 800, height: 3_000)
        let target = FakeTarget(document: document, height: 600)
        let selection = SelectionSession()
        let coordinator = makeCoordinator(target: target, selection: selection) { _, _ in }
        coordinator.continueFromSelection(context: context(width: 800, height: 600))
        try await waitUntil { coordinator.state.frames == 1 }
        coordinator.receive(ScrollActivity(preciseDownwardPoints: 50))
        try await waitUntil { target.captures == 2 && coordinator.resourceCounts["capture"] == 0 }
        XCTAssertEqual(coordinator.state.height, 600, "the app had not moved yet")
        // 40 pt more arrive with a frame rendered mid-momentum at 90 pt (180 px at 2x).
        target.offset = 180; target.soft = true
        coordinator.receive(ScrollActivity(preciseDownwardPoints: 40))
        try await waitUntil { coordinator.state.height == 780 }
        await coordinator.cancel()
    }

    /// Automatic mode that never re-finds its overlap stops with a warning instead of looping forever,
    /// and every synthetic event (including the corrective back-scroll) validated the target first.
    func testPersistentMismatchEndsAutomaticModeAndEveryStepIsValidated() async throws {
        let document = try ScrollImageFixture.document(width: 600, height: 3_000)
        let target = FakeTarget(document: document, height: 400)
        let selection = SelectionSession()
        // Each synthetic step lands far from the accepted frame, so no frame ever overlaps it.
        let coordinator = makeCoordinator(target: target, selection: selection, onCapture: { _, _ in }) { _ in
            target.offset = target.offset == 1_500 ? 2_200 : 1_500
        }
        coordinator.continueFromSelection(context: context(width: 600, height: 400))
        try await waitUntil { coordinator.state.frames == 1 }
        coordinator.toggleAutomatic()
        XCTAssertTrue(coordinator.state.isAutomatic)
        try await waitUntil { !coordinator.state.isAutomatic && coordinator.resourceCounts["auto"] == 0 }
        XCTAssertEqual(coordinator.state.phase, .capturing, "a mismatch is not the end of the page")
        XCTAssertEqual(coordinator.state.tone, .warning)
        XCTAssertEqual(coordinator.state.frames, 1)
        XCTAssertGreaterThanOrEqual(target.scrolls, 4, "three stalls with back-scrolls in between")
        XCTAssertEqual(target.scrollChecks, target.scrolls)
        await coordinator.cancel()
    }

    /// Pause then Auto in quick succession: the finished old loop must not clear the new loop's handle.
    func testQuickPauseAndResumeKeepsTheNewAutomaticLoop() async throws {
        let document = try ScrollImageFixture.document(width: 600, height: 6_000)
        let target = FakeTarget(document: document, height: 400)
        let selection = SelectionSession()
        let coordinator = makeCoordinator(target: target, selection: selection, onCapture: { _, _ in }) { points in
            target.offset = min(target.offset + Int(points * 2), document.height - 400)
        }
        coordinator.continueFromSelection(context: context(width: 600, height: 400))
        try await waitUntil { coordinator.state.frames == 1 }
        coordinator.toggleAutomatic()
        coordinator.toggleAutomatic()
        XCTAssertFalse(coordinator.state.isAutomatic)
        coordinator.toggleAutomatic()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(coordinator.state.isAutomatic)
        XCTAssertEqual(coordinator.resourceCounts["auto"], 1, "the running loop must stay tracked for cancel/finish")
        try await waitUntil { coordinator.state.frames >= 2 }
        await coordinator.cancel()
        XCTAssertEqual(coordinator.resourceCounts.values.reduce(0, +), 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Long capture did not reach the expected state in time")
    }
}
