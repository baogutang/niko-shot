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
        let height: Int
        init(document: CGImage, height: Int) { self.document = document; self.height = height }
        func frame() throws -> CGImage {
            captures += 1
            return try ScrollImageFixture.viewport(document, offset: offset, height: height)
        }
    }

    private func context(width: Int, height: Int) -> CaptureContext {
        let screen = ScreenGeometry(id: 77, frame: CGRect(x: 0, y: 0, width: 1_200, height: 900), scale: 2)
        return CaptureContext(screen: screen, localRect: CGRect(x: 100, y: 100, width: CGFloat(width) / 2, height: CGFloat(height) / 2),
                              kind: "region", appBundleID: "com.example.fixture")
    }

    private var permissionRequests = 0

    private func makeCoordinator(target: FakeTarget, selection: SelectionSession,
                                 onCapture: @escaping (CGImage, CaptureContext) -> Void,
                                 settleDelays: [Duration] = []) -> ScrollCoordinator {
        var workflow = ScrollCaptureWorkflow(freezeScreens: { [] }, windows: { [] },
            prepareSource: { context, _ in RegionSnapshot(capture: { try target.frame() }, validate: { context }) })
        workflow.activate = { _ in }
        workflow.settleDelays = settleDelays
        workflow.activationDelay = .zero
        workflow.isAutoScrollAuthorized = { false }
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
    func testSettledMismatchesWarnWhileMomentumMismatchesStayQuiet() async throws {
        let document = try ScrollImageFixture.document(width: 800, height: 6_000)
        let selection = SelectionSession()
        defer { selection.finish() }

        func jump(_ coordinator: ScrollCoordinator, _ target: FakeTarget, _ offset: Int) {
            target.offset = offset
            coordinator.receive(ScrollActivity(preciseDownwardPoints: CGFloat(offset)))
        }
        func waitForCaptures(_ target: FakeTarget, _ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while target.captures < count, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThanOrEqual(target.captures, count)
        }

        // Branch 1: threshold zero — two unmatched jumps warn immediately.
        let warnTarget = FakeTarget(document: document, height: 500)
        var output: CGImage?
        let warner = makeCoordinator(target: warnTarget, selection: selection, onCapture: { image, _ in output = image },
                                     settleDelays: [.milliseconds(20), .milliseconds(40)])
        warner.mismatchSettle = .zero
        warner.continueFromSelection(context: context(width: 800, height: 500))
        try await waitUntil { warner.state.frames == 1 }
        jump(warner, warnTarget, 1_400)
        try await waitForCaptures(warnTarget, 4)
        jump(warner, warnTarget, 2_600)
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
        try await waitForCaptures(quietTarget, 4)
        jump(quieter, quietTarget, 2_600)
        // The settle chain (immediate, +20 ms, +60 ms) and well beyond it: quiet throughout.
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNotEqual(quieter.state.title, "画面没对上", "momentum-window mismatches must stay quiet")
        XCTAssertEqual(quieter.state.phase, .capturing)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Long capture did not reach the expected state in time")
    }
}
