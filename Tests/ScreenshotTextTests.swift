// Exercises automatic and manual inline translation without external services.
import AppKit
import CoreText
import XCTest
@testable import NikoShot

@MainActor
final class ScreenshotTextTests: XCTestCase {
    func testEnabledAutomaticTranslationDisplaysTheTargetWithoutAnExtraClick() async throws {
        let store = try settings()
        store.settings.automaticTranslation = true
        let log = TranslationLog()
        let gate = RecognitionGate()
        let controller = makeController(settings: store.settings, gate: gate, log: log)
        var recognized: [String] = []
        controller.onRecognizedText = { recognized.append($0) }
        controller.recognize(try image(width: 8), translateAfterRecognition: false)
        try await waitForCalls(gate, 1)
        await gate.complete(1, text: "原文第一行\nOriginal second line")
        try await waitUntil { !controller.model.ocr.isRecognizing }
        XCTAssertEqual(recognized, ["原文第一行\nOriginal second line"])
        XCTAssertEqual(log.texts, recognized)
        XCTAssertEqual(log.targets, [.simplifiedChinese])
        XCTAssertEqual(controller.model.section, .translation)
        XCTAssertEqual(controller.model.ocr.selectedText, recognized.first)
        XCTAssertTrue(controller.model.isActive)
        await controller.finishAndDrain()
        store.remove()
    }

    func testAutomaticEditsAreCoalescedAndKeepTheOriginalEditorSelected() async throws {
        let store = try settings()
        store.settings.automaticTranslation = true
        let log = TranslationLog(), gate = RecognitionGate()
        let controller = makeController(settings: store.settings, gate: gate, log: log)
        controller.recognize(try image(width: 8), translateAfterRecognition: false)
        try await waitForCalls(gate, 1)
        await gate.complete(1, text: "Hello")
        try await waitUntil { log.texts.count == 1 }
        controller.model.section = .original
        controller.model.editOriginal("Hello first edit")
        controller.model.editOriginal("Hello final edit")
        XCTAssertEqual(log.texts, ["Hello"], "Typing must not send a request for each keystroke")
        XCTAssertTrue(controller.model.isAwaitingTranslation)
        try await waitUntil { log.texts.count == 2 }
        XCTAssertEqual(log.texts, ["Hello", "Hello final edit"])
        XCTAssertEqual(controller.model.section, .original, "Updating the result must not interrupt typing")
        XCTAssertEqual(controller.model.ocr.selectedText, "Hello final edit")
        await controller.finishAndDrain()
        XCTAssertEqual(controller.resourceCounts.scheduledTranslations, 0)
        store.remove()
    }

    func testAutomaticLanguageAndProviderChangesRequestOnlyTheFinalSelection() async throws {
        let store = try settings()
        store.settings.automaticTranslation = true
        let log = TranslationLog(), gate = RecognitionGate()
        let controller = makeController(settings: store.settings, gate: gate, log: log)
        controller.recognize(try image(width: 8), translateAfterRecognition: false)
        try await waitForCalls(gate, 1)
        await gate.complete(1, text: "Hello")
        try await waitUntil { log.texts.count == 1 }
        controller.model.selectTarget(.japanese)
        controller.model.selectTarget(.traditionalChinese)
        controller.model.selectProvider(TranslationProviderID.google.rawValue)
        controller.model.providerConfigurationChanged() // The native preference observer repeats this notification.
        controller.model.providerConfigurationChanged()
        try await waitUntil { log.texts.count == 2 }
        XCTAssertEqual(log.targets, [.simplifiedChinese, .traditionalChinese])
        XCTAssertEqual(log.providers, [.baidu, .google])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(log.texts.count, 2, "Observer updates must not restart the selected request")
        await controller.finishAndDrain()
        store.remove()
    }

    func testDisablingAutomaticTranslationDuringOCRKeepsTheResultLocal() async throws {
        let store = try settings()
        store.settings.automaticTranslation = true
        let log = TranslationLog(), gate = RecognitionGate()
        let controller = makeController(settings: store.settings, gate: gate, log: log)
        controller.recognize(try image(width: 8), translateAfterRecognition: false)
        try await waitForCalls(gate, 1)
        store.settings.automaticTranslation = false
        controller.model.automaticTranslationChanged()
        await gate.complete(1, text: "Hello")
        try await waitUntil { !controller.model.ocr.isRecognizing }
        XCTAssertEqual(log.texts, [])
        controller.requestTranslation()
        XCTAssertEqual(log.texts, ["Hello"], "A manual request remains available after disabling automation")
        await controller.finishAndDrain()
        store.remove()
    }

    func testClosingTheCardCancelsQueuedAutomaticEditsAndDrainsTheirTasks() async throws {
        let store = try settings()
        store.settings.automaticTranslation = true
        let log = TranslationLog(), gate = RecognitionGate()
        let controller = makeController(settings: store.settings, gate: gate, log: log)
        controller.recognize(try image(width: 8), translateAfterRecognition: false)
        try await waitForCalls(gate, 1)
        await gate.complete(1, text: "Hello")
        try await waitUntil { log.texts.count == 1 }
        controller.model.editOriginal("This edit must remain local after closing")
        XCTAssertGreaterThan(controller.resourceCounts.scheduledTranslations, 0)
        await controller.finishAndDrain()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(log.texts, ["Hello"])
        XCTAssertEqual(controller.resourceCounts.scheduledTranslations, 0)
        XCTAssertFalse(controller.isWorking)
        store.remove()
    }

    func testSnapshotAndRecognitionTranslationUpgradeUseExactlyOneOCRAndOneExplicitTranslation() async throws {
        let store = try settings()
        let log = TranslationLog()
        let gate = RecognitionGate()
        let controller = makeController(settings: store.settings, gate: gate, log: log)
        controller.prepareSnapshot(translateAfterRecognition: false)
        controller.requestTranslation()
        XCTAssertTrue(controller.resourceCounts.waitingForSnapshot)
        let beforeSnapshotCalls = await gate.count
        XCTAssertEqual(beforeSnapshotCalls, 0)
        XCTAssertEqual(log.texts, [])
        controller.recognize(try image(width: 8), translateAfterRecognition: false)
        controller.requestTranslation()
        controller.requestTranslation()
        try await waitForCalls(gate, 1)
        await gate.complete(1, text: "Explicit request")
        try await waitUntil { !controller.model.ocr.isRecognizing }
        let upgradedCalls = await gate.count
        XCTAssertEqual(upgradedCalls, 1)
        XCTAssertEqual(log.texts, ["Explicit request"])
        XCTAssertEqual(log.providers, [.baidu])
        await controller.finishAndDrain()
        store.remove()
    }

    func testOlderUncooperativeRecognitionCannotReplaceNewTextOrStartOldTranslation() async throws {
        let store = try settings()
        let log = TranslationLog()
        let gate = RecognitionGate()
        let controller = makeController(settings: store.settings, gate: gate, log: log)
        var recognized: [String] = []
        controller.onRecognizedText = { recognized.append($0) }
        controller.recognize(try image(width: 8), translateAfterRecognition: true)
        try await waitForCalls(gate, 1)
        controller.recognize(try image(width: 9), translateAfterRecognition: false)
        try await waitForCalls(gate, 2)
        await gate.complete(2, text: "新截图")
        try await waitUntil { controller.model.originalText == "新截图" }
        XCTAssertEqual(controller.resourceCounts.recognitionTasks, 1)
        await gate.complete(1, text: "旧截图")
        try await waitUntil { controller.resourceCounts.recognitionTasks == 0 }
        XCTAssertEqual(controller.model.originalText, "新截图")
        XCTAssertEqual(recognized, ["新截图"])
        XCTAssertEqual(log.texts, [])
        let cancelled = await gate.cancelledCompletions
        XCTAssertTrue(cancelled.contains(1))
        await controller.finishAndDrain()
        store.remove()
    }

    func testClosingCardRetainsAndDrainsNativeWorkButLateSnapshotCannotReactivateIt() async throws {
        let store = try settings()
        let log = TranslationLog()
        let gate = RecognitionGate()
        let controller = makeController(settings: store.settings, gate: gate, log: log)
        controller.recognize(try image(width: 8), translateAfterRecognition: true)
        try await waitForCalls(gate, 1)
        controller.cancel()
        controller.requestTranslation()
        controller.prepareSnapshot(translateAfterRecognition: true)
        controller.recognize(try image(width: 9), translateAfterRecognition: true)
        XCTAssertFalse(controller.model.isActive)
        XCTAssertTrue(controller.isWorking, "Cancellation must retain an unfinished native request")
        var drained = false
        let drain = Task { await controller.finishAndDrain(); drained = true }
        await Task.yield()
        XCTAssertFalse(drained)
        await gate.complete(1, text: "late result")
        await drain.value
        XCTAssertTrue(drained)
        XCTAssertFalse(controller.isWorking)
        XCTAssertEqual(controller.resourceCounts.recognitionTasks, 0)
        let closedCalls = await gate.count
        XCTAssertEqual(closedCalls, 1)
        XCTAssertEqual(log.texts, [])
        XCTAssertEqual(controller.model.originalText, "")
        store.remove()
    }

    func testFailedOCRRetriesRetainedPixelsAndDoesNotAutomaticallyRetryTranslation() async throws {
        let store = try settings()
        let log = TranslationLog()
        let gate = RecognitionGate()
        let controller = makeController(settings: store.settings, gate: gate, log: log)
        controller.recognize(try image(width: 8), translateAfterRecognition: false)
        try await waitForCalls(gate, 1)
        await gate.fail(1, message: "native recognition fixture failure")
        try await waitUntil { controller.model.ocr.errorMessage != nil }
        XCTAssertEqual(controller.model.ocr.errorMessage, "native recognition fixture failure")
        XCTAssertTrue(controller.model.retryRecognition())
        try await waitForCalls(gate, 2)
        await gate.complete(2, text: "Recovered OCR")
        try await waitUntil { controller.model.originalText == "Recovered OCR" }
        XCTAssertNil(controller.model.ocr.errorMessage)
        let retriedWidths = await gate.widths
        XCTAssertEqual(retriedWidths, [8, 8], "Retry must reuse the actual retained image")
        XCTAssertEqual(log.texts, [])
        controller.requestTranslation()
        XCTAssertEqual(log.texts, ["Recovered OCR"])
        await controller.finishAndDrain()
        store.remove()
    }

    func testUnconfiguredServiceKeepsOriginalEditableAndNeverStartsAutomaticOrExplicitRequests() async throws {
        let store = try settings()
        store.settings.automaticTranslation = true
        store.settings.translationProvider = .custom
        let controller = ScreenshotTextController(settings: store.settings,
            recognition: { _, _, _ in [Self.block("original")] },
            translationOperation: { _, _, _ in XCTFail("An unconfigured service must not receive text") },
            configurationCheck: { TranslationConfiguration.isConfigured($0, credentials: KeychainStore(testValues: [:])) })
        controller.prepareSnapshot(translateAfterRecognition: true)
        XCTAssertEqual(controller.model.section, .original)
        controller.recognize(try image(width: 8), translateAfterRecognition: false)
        try await waitUntil { !controller.model.ocr.isRecognizing }
        controller.requestTranslation()
        XCTAssertNil(controller.translationModel.errorMessage)
        XCTAssertEqual(controller.model.section, .original)
        XCTAssertTrue(store.settings.automaticTranslation, "The preference remains enabled for a later configured service")
        XCTAssertEqual(controller.translationModel.pendingRequestCount, 0)
        controller.model.editOriginal("edited 原文")
        XCTAssertNil(controller.translationModel.errorMessage)
        XCTAssertEqual(controller.model.ocr.selectedText, "edited 原文")
        controller.requestTranslation()
        XCTAssertEqual(controller.translationModel.requestedText, "")
        controller.model.selectTarget(.english)
        XCTAssertNil(controller.translationModel.errorMessage)
        XCTAssertEqual(controller.translationModel.target, .english)
        controller.requestTranslation()
        XCTAssertNil(controller.translationModel.errorMessage)
        controller.model.selectProvider(TranslationProviderID.google.rawValue)
        XCTAssertNil(controller.translationModel.errorMessage)
        XCTAssertEqual(store.settings.translationProvider, .google)
        XCTAssertEqual(controller.translationModel.pendingRequestCount, 0)
        XCTAssertEqual(controller.resourceCounts.scheduledTranslations, 0)
        XCTAssertFalse(controller.model.isTranslationConfigured)
        controller.model.editOriginal("")
        XCTAssertTrue(controller.model.hasRecognizedResult, "Deleting all text must leave the original editor usable")
        controller.model.editOriginal("new entry")
        XCTAssertEqual(controller.model.ocr.selectedText, "new entry")
        await controller.finishAndDrain()
        store.remove()
    }

    func testSavingThenRemovingCredentialsRefreshesAnOpenCardAndCancelsQueuedText() async throws {
        let store = try settings()
        defer { store.remove() }
        store.settings.automaticTranslation = true
        let readiness = ReadinessProbe()
        let log = TranslationLog()
        let controller = ScreenshotTextController(settings: store.settings,
            recognition: { _, _, _ in [Self.block("source")] },
            translationOperation: { _, text, _ in log.texts.append(text) }, configurationCheck: { _ in readiness.ready })
        controller.recognize(try image(width: 8), translateAfterRecognition: false)
        try await waitUntil { !controller.model.ocr.isRecognizing }
        XCTAssertEqual(controller.model.section, .original)
        XCTAssertEqual(log.texts, [])
        readiness.ready = true
        controller.model.providerConfigurationChanged(credentialsChanged: true)
        try await waitUntil { log.texts == ["source"] }
        controller.model.section = .translation
        controller.model.editOriginal("pending edit")
        XCTAssertTrue(controller.model.isAwaitingTranslation)
        readiness.ready = false
        controller.model.providerConfigurationChanged(credentialsChanged: true)
        XCTAssertEqual(controller.model.section, .original)
        XCTAssertFalse(controller.model.isAwaitingTranslation)
        XCTAssertNil(controller.translationModel.errorMessage)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(log.texts, ["source"])
        await controller.finishAndDrain()
        XCTAssertEqual(controller.resourceCounts.scheduledTranslations, 0)
        XCTAssertEqual(controller.resourceCounts.translationRequests, 0)
    }

    func testExpandTransfersTheSameEditedOCRAndTranslationModelBeforeDeferredCleanup() async throws {
        let store = try settings()
        let gate = RecognitionGate()
        let log = TranslationLog()
        let controller = makeController(settings: store.settings, gate: gate, log: log)
        controller.recognize(try image(width: 8), translateAfterRecognition: false)
        try await waitForCalls(gate, 1)
        await gate.complete(1, text: "recognized")
        try await waitUntil { !controller.model.ocr.isRecognizing }
        controller.model.editOriginal("edited for full workspace")
        controller.model.selectTarget(.japanese)
        let translation = controller.translationModel
        var expanded: OCRViewModel?
        controller.onExpand = { model in
            expanded = model
            // This invalid-service request cannot leave the process. Its inline error
            // must survive cleanup of the old card after ownership has transferred.
            store.settings.translationProvider = .custom
            translation.translate(text: model.selectedText, settings: store.settings)
        }
        controller.expandWorkspace()
        XCTAssertTrue(expanded === controller.model.ocr)
        XCTAssertEqual(expanded?.selectedText, "edited for full workspace")
        XCTAssertTrue(translation === controller.translationModel)
        XCTAssertEqual(translation.target, .japanese)
        XCTAssertNotNil(translation.errorMessage)
        let message = translation.errorMessage
        await controller.finishAndDrain()
        controller.cancel()
        XCTAssertEqual(translation.errorMessage, message)
        XCTAssertEqual(log.texts, [])
        store.remove()
    }

    func testRenderingFailureHasNoRecognitionOrNetworkWorkAndCanAwaitAnotherSnapshot() async throws {
        let store = try settings()
        let gate = RecognitionGate()
        let log = TranslationLog()
        let controller = makeController(settings: store.settings, gate: gate, log: log)
        controller.prepareSnapshot(translateAfterRecognition: true)
        controller.showError(NSError(domain: "fixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Snapshot export failed"] ))
        XCTAssertEqual(controller.model.ocr.errorMessage, "Snapshot export failed")
        XCTAssertFalse(controller.isWorking)
        XCTAssertTrue(controller.model.canRetryRecognition)
        XCTAssertFalse(controller.model.retryRecognition(), "A missing snapshot must be recreated by the selection owner")
        controller.prepareSnapshot(translateAfterRecognition: false)
        controller.requestTranslation()
        controller.cancel()
        await controller.finishAndDrain()
        let renderingCalls = await gate.count
        XCTAssertEqual(renderingCalls, 0)
        XCTAssertEqual(log.texts, [])
        store.remove()
    }

    func testNativeVisionTextAppearsInAnOffscreenEditableAppKitView() async throws {
        let store = try settings()
        store.settings.ocrLanguages = ["en-US"]
        let controller = ScreenshotTextController(settings: store.settings)
        controller.recognize(try textFixture(), translateAfterRecognition: false)
        try await waitUntil(attempts: 15_000) { !controller.model.ocr.isRecognizing }
        XCTAssertTrue(controller.model.originalText.contains("INLINE SCREENSHOT"), controller.model.originalText)
        XCTAssertEqual(controller.translationModel.pendingRequestCount, 0)
        let view = controller.view
        view.frame = CGRect(x: 0, y: 0, width: 600, height: controller.preferredHeight)
        view.layoutSubtreeIfNeeded()
        try await waitUntil { Self.editors(in: view).contains(where: { $0.string.contains("INLINE SCREENSHOT") }) }
        let editor = try XCTUnwrap(Self.editors(in: view).first(where: { $0.isEditable }))
        XCTAssertTrue(editor.isSelectable)
        XCTAssertEqual(editor.string, controller.model.originalText)
        XCTAssertEqual(editor.accessibilityLabel(), "原文，可编辑")
        XCTAssertGreaterThan(editor.bounds.width, 200)
        XCTAssertGreaterThan(editor.bounds.height, 30)
        editor.string = "Native editor 修改后的原文"
        editor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(controller.model.originalText, "Native editor 修改后的原文")
        XCTAssertEqual(controller.model.ocr.selectedText, "Native editor 修改后的原文")
        view.frame.size.width = 360
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(editor.bounds.width, 150)
        XCTAssertGreaterThan(editor.bounds.height, 20)
        await controller.finishAndDrain()
        store.remove()
    }

    private func makeController(settings: AppSettings, gate: RecognitionGate, log: TranslationLog) -> ScreenshotTextController {
        ScreenshotTextController(settings: settings,
            recognition: { image, languages, accurate in
                try await gate.recognize(image, languages: languages, accurate: accurate)
            }, translationOperation: { model, text, settings in
                log.texts.append(text)
                log.providers.append(settings.translationProvider)
                log.targets.append(model.target)
            }, configurationCheck: { _ in true })
    }

    private func settings() throws -> SettingsStore {
        let suite = "com.n1ko.niko-shot.screenshot-text-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.automaticTranslation = false
        return SettingsStore(settings: settings, defaults: defaults, suite: suite)
    }

    private func waitUntil(attempts: Int = 2_000, _ predicate: () -> Bool) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw NSError(domain: "ScreenshotTextTests.timeout", code: 1)
    }

    private func waitForCalls(_ gate: RecognitionGate, _ count: Int) async throws {
        for _ in 0..<2_000 {
            if await gate.count == count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw NSError(domain: "ScreenshotTextTests.recognition-timeout", code: count)
    }

    private func image(width: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 8, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    private func textFixture() throws -> CGImage {
        let width = 1600, height = 180
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textPosition = CGPoint(x: 32, y: 66)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 54, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "INLINE SCREENSHOT TEXT", attributes: attributes)), context)
        return try XCTUnwrap(context.makeImage())
    }

    private static func editors(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { editors(in: $0) }
    }

    private nonisolated static func block(_ text: String) -> OCRBlock {
        OCRBlock(text: text, boundingBox: CGRect(x: 0.05, y: 0.1, width: 0.9, height: 0.8), confidence: 1)
    }

    private struct SettingsStore {
        let settings: AppSettings
        let defaults: UserDefaults
        let suite: String
        func remove() { defaults.removePersistentDomain(forName: suite) }
    }

    private final class TranslationLog {
        var texts: [String] = []
        var providers: [TranslationProviderID] = []
        var targets: [Language] = []
    }

    @MainActor private final class ReadinessProbe { var ready = false }
}

/// Deliberately ignores cancellation until released, like an already executing native Vision request.
private actor RecognitionGate {
    private var pending: [Int: CheckedContinuation<[OCRBlock], any Error>] = [:]
    private(set) var count = 0
    private(set) var widths: [Int] = []
    private(set) var cancelledCompletions: Set<Int> = []

    func recognize(_ image: CGImage, languages: [String], accurate: Bool) async throws -> [OCRBlock] {
        count += 1
        let id = count
        widths.append(image.width)
        let result: [OCRBlock] = try await withCheckedThrowingContinuation { continuation in pending[id] = continuation }
        if Task.isCancelled { cancelledCompletions.insert(id) }
        return result
    }

    func complete(_ id: Int, text: String) {
        pending.removeValue(forKey: id)?.resume(returning: [OCRBlock(text: text,
            boundingBox: CGRect(x: 0.05, y: 0.1, width: 0.9, height: 0.8), confidence: 1)])
    }

    func fail(_ id: Int, message: String) {
        pending.removeValue(forKey: id)?.resume(throwing: NSError(domain: "recognition-fixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]))
    }
}
