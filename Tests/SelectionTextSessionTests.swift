// Exercises real screenshot HUD actions while recognition and translation are isolated from external services.
import AppKit
import XCTest
@testable import NikoShot

@MainActor
final class SelectionTextSessionTests: XCTestCase {
    func testRecognitionStaysInScreenshotHUDAndCompletionStillCopiesPixels() async throws {
        let (settings, suite) = try isolatedSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let probe = ScreenshotRecognitionProbe()
        let controller = ScreenshotTextController(settings: settings, recognition: { image, _, _ in
            await probe.recognize(image)
        }, translationOperation: { _, _, _ in XCTFail("OCR alone must not send text for translation") })
        let session = SelectionSession(makeTextController: { controller })
        defer { session.finish() }
        var captured: CGImage?
        try start(session) { captured = $0 }
        let panel = try panel()
        let compactHeight = panel.frame.height
        let count = session.windowCount
        try button("识别文字", in: panel.contentView).performClick(nil)
        try await waitUntil { controller.model.hasRecognizedResult }
        XCTAssertEqual(session.state, .selected)
        XCTAssertEqual(session.windowCount, count, "Inline recognition must not create a separate window")
        XCTAssertNil(captured, "Reading text must not complete or export the screenshot")
        XCTAssertGreaterThan(panel.frame.height, compactHeight)
        XCTAssertTrue(panel.canBecomeKey, "Text selection and editing need a key-capable result panel")
        XCTAssertEqual(controller.model.originalText, "snapshot 300 × 240")
        try button("完成并复制", in: panel.contentView).performClick(nil)
        try await waitUntil { captured != nil }
        XCTAssertEqual(captured?.width, 300)
        XCTAssertEqual(captured?.height, 240)
        await session.drainPendingOperations()
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.windowCount, 0)
        XCTAssertEqual(session.resourceCounts.values.reduce(0, +), 0)
    }

    func testToolbarTranslationUsesEditedOriginalWithoutRecognizingAgain() async throws {
        let (settings, suite) = try isolatedSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let probe = ScreenshotRecognitionProbe()
        var translated: [String] = []
        let controller = ScreenshotTextController(settings: settings, recognition: { image, _, _ in
            await probe.recognize(image)
        }, translationOperation: { _, text, _ in translated.append(text) })
        let session = SelectionSession(makeTextController: { controller })
        defer { session.finish() }
        try start(session) { _ in XCTFail("Translation must keep the screenshot open") }
        session.requestScreenshotText()
        try await waitUntil { controller.model.hasRecognizedResult }
        controller.model.editOriginal("edited original")
        try button("翻译", in: try panel().contentView).performClick(nil)
        XCTAssertEqual(translated, ["edited original"])
        XCTAssertEqual(session.state, .selected)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
        await session.finishAndDrain()
        XCTAssertEqual(session.resourceCounts.values.reduce(0, +), 0)
    }

    func testMovingSelectionInvalidatesCardAndRetainsCapture() async throws {
        let (settings, suite) = try isolatedSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let controller = ScreenshotTextController(settings: settings, recognition: { image, _, _ in
            [OCRBlock(text: "old selection", boundingBox: .zero, confidence: 1)]
        })
        let session = SelectionSession(makeTextController: { controller })
        defer { session.finish() }
        try start(session) { _ in }
        let panel = try panel(), compactHeight = panel.frame.height
        session.requestScreenshotText()
        try await waitUntil { controller.model.hasRecognizedResult }
        let view = try XCTUnwrap(session.windows.first?.contentView as? SelectionView)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        view.keyDown(with: event)
        await session.drainPendingOperations()
        XCTAssertFalse(controller.model.isActive)
        XCTAssertEqual(session.state, .selected)
        XCTAssertEqual(session.windowCount, 2)
        XCTAssertEqual(panel.frame.height, compactHeight)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertEqual(session.resourceCounts["screenshotText"], 0)
    }

    func testCancellationDrainsPendingSnapshotAndNeverRecognizesOrTranslates() async throws {
        let (settings, suite) = try isolatedSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let gate = ScreenshotSnapshotGate(), probe = ScreenshotRecognitionProbe()
        let controller = ScreenshotTextController(settings: settings, recognition: { image, _, _ in
            await probe.recognize(image)
        }, translationOperation: { _, _, _ in XCTFail("Closed screenshots must not translate") })
        let session = SelectionSession(afterImageOperation: { await gate.pause() }, makeTextController: { controller })
        try start(session) { _ in XCTFail("Cancelled OCR must not export a screenshot") }
        session.requestScreenshotText(translate: true)
        await gate.waitUntilEntered()
        session.finish()
        XCTAssertEqual(session.windowCount, 0)
        XCTAssertGreaterThan(session.resourceCounts["selectionTasks"] ?? 0, 0)
        await gate.resume()
        await session.drainPendingOperations()
        XCTAssertEqual(session.resourceCounts.values.reduce(0, +), 0)
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
    }

    func testExpandingWorkspaceTransfersExistingModelsAndClosesScreenshot() async throws {
        let (settings, suite) = try isolatedSettings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let controller = ScreenshotTextController(settings: settings, recognition: { _, _, _ in
            [OCRBlock(text: "recognized source", boundingBox: .zero, confidence: 1)]
        })
        let session = SelectionSession(makeTextController: { controller })
        var expanded: (OCRViewModel, TranslationViewModel)?
        session.onTextWorkspace = { expanded = ($0, $1) }
        try start(session) { _ in XCTFail("Expanding text must not export the screenshot") }
        session.requestScreenshotText()
        try await waitUntil { controller.model.hasRecognizedResult }
        controller.model.editOriginal("corrected source")
        controller.model.selectTarget(.japanese)
        controller.expandWorkspace()
        let result = try XCTUnwrap(expanded)
        XCTAssertEqual(result.0.selectedText, "corrected source")
        XCTAssertTrue(result.1 === controller.translationModel)
        XCTAssertEqual(result.1.target, .japanese)
        await session.drainPendingOperations()
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.windowCount, 0)
        XCTAssertEqual(session.resourceCounts.values.reduce(0, +), 0)
    }

    private func start(_ session: SelectionSession, completion: @escaping (CGImage) -> Void) throws {
        let context = try ImageUtilities.context(width: 900, height: 700)
        let image = try XCTUnwrap(context.makeImage())
        let screen = ScreenGeometry(id: 99, frame: CGRect(x: 0, y: 0, width: 900, height: 700), scale: 1)
        session.start(frames: [FrozenFrame(screen: screen, image: image)],
            initial: CaptureContext(screen: screen, localRect: CGRect(x: 100, y: 60, width: 300, height: 240)),
            autoConfirm: false) { image, _ in completion(image) }
    }

    private func isolatedSettings() throws -> (AppSettings, String) {
        let suite = "niko-shot.inline-session-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppSettings(defaults: defaults), suite)
    }

    private func panel() throws -> NSWindow {
        try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.accessibilityLabel() == "截图标注工具条" })
    }

    private func button(_ title: String, in view: NSView?) throws -> NSButton {
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        return try XCTUnwrap(view.flatMap { buttons($0).first { $0.accessibilityLabel() == title } }, title)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Screenshot text operation did not finish")
    }
}

private actor ScreenshotRecognitionProbe {
    private(set) var calls = 0
    func recognize(_ image: CGImage) -> [OCRBlock] {
        calls += 1
        return [OCRBlock(text: "snapshot \(image.width) × \(image.height)", boundingBox: .zero, confidence: 1)]
    }
}

private actor ScreenshotSnapshotGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
