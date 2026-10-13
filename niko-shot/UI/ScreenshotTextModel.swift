// Keeps an inline screenshot's editable OCR and explicitly requested translation cancellable.
import AppKit
import Observation

/// Live resources retained until the underlying recognition operation actually returns.
struct ScreenshotTextResourceCounts: Equatable, Sendable {
    let recognitionTasks: Int
    let waitingForSnapshot: Bool
    let isTranslating: Bool
    let translationRequests: Int
}

/// Local state for a screenshot text card; preferences never trigger an automatic request.
@MainActor @Observable
final class ScreenshotTextModel {
    typealias RecognitionOperation = @Sendable (CGImage, [String], Bool) async throws -> [OCRBlock]
    typealias TranslationOperation = @MainActor (TranslationViewModel, String, AppSettings) -> Void

    enum Section: String, CaseIterable, Identifiable {
        case original = "原文", translation = "译文"
        var id: String { rawValue }
    }

    let ocr = OCRViewModel()
    let translation = TranslationViewModel()
    let settings: AppSettings
    private(set) var originalText = ""
    private(set) var hasRecognizedResult = false
    var section: Section = .original
    private(set) var feedback: String?
    private(set) var isActive = true
    private(set) var isAwaitingSnapshot = false

    @ObservationIgnored var onRecognizedText: ((String) -> Void)?
    @ObservationIgnored private let recognizeOperation: RecognitionOperation
    @ObservationIgnored private let translateOperation: TranslationOperation
    @ObservationIgnored private var image: CGImage?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var translateWhenReady = false
    @ObservationIgnored private var translationTransferred = false
    @ObservationIgnored private var recognitionWorkers: [UUID: Task<[OCRBlock], any Error>] = [:]
    @ObservationIgnored private var recognitionCompletions: [UUID: Task<Void, Never>] = [:]

    /// Injects recognition for deterministic cancellation tests; production uses the existing Vision actor.
    init(settings: AppSettings, recognition: RecognitionOperation? = nil,
         translationOperation: TranslationOperation? = nil) {
        self.settings = settings
        let engine = OCREngine()
        recognizeOperation = recognition ?? { image, languages, accurate in
            try await engine.recognize(image, languages: languages, accurate: accurate)
        }
        translateOperation = translationOperation ?? { model, text, settings in
            model.translate(text: text, settings: settings)
        }
    }

    deinit {
        for worker in recognitionWorkers.values { worker.cancel() }
    }

    var resourceCounts: ScreenshotTextResourceCounts {
        ScreenshotTextResourceCounts(recognitionTasks: recognitionWorkers.count,
            waitingForSnapshot: isAwaitingSnapshot, isTranslating: !translationTransferred && translation.isTranslating,
            translationRequests: translationTransferred ? 0 : translation.pendingRequestCount)
    }

    var isWorking: Bool {
        !recognitionWorkers.isEmpty || ocr.isRecognizing ||
            (!translationTransferred && (translation.isTranslating || translation.pendingRequestCount > 0))
    }

    var canRetryRecognition: Bool { isActive && !ocr.isRecognizing && ocr.errorMessage != nil }

    var providerSelection: String {
        if settings.translationProvider == .custom, let id = settings.selectedCustomTranslationID,
           settings.customTranslationServices.contains(where: { $0.id == id }) {
            return "instance.\(id.uuidString)"
        }
        return settings.translationProvider.rawValue
    }

    /// Displays pending work before the selection has finished exporting its pixels.
    func prepareSnapshot(translateAfterRecognition: Bool) {
        guard isActive else { return }
        invalidateRecognition()
        image = nil
        originalText = ""
        hasRecognizedResult = false
        ocr.blocks = []
        ocr.errorMessage = nil
        ocr.isRecognizing = true
        isAwaitingSnapshot = true
        translateWhenReady = translateAfterRecognition
        feedback = nil
        translation.invalidate()
        section = translateAfterRecognition ? .translation : .original
    }

    /// Starts one OCR operation, retaining older cancelled workers solely for eventual draining.
    func recognize(_ image: CGImage, translateAfterRecognition: Bool) {
        guard isActive else { return }
        let pendingTranslation = isAwaitingSnapshot && translateWhenReady
        invalidateRecognition()
        self.image = image
        isAwaitingSnapshot = false
        translateWhenReady = translateAfterRecognition || pendingTranslation
        originalText = ""
        hasRecognizedResult = false
        ocr.blocks = []
        ocr.errorMessage = nil
        ocr.isRecognizing = true
        feedback = nil
        translation.invalidate()
        section = translateWhenReady ? .translation : .original

        let token = generation
        let operation = recognizeOperation
        let languages = settings.ocrLanguages
        let accurate = settings.accurateOCR
        let worker = Task.detached(priority: .userInitiated) {
            try await operation(image, languages, accurate)
        }
        recognitionWorkers[token] = worker
        recognitionCompletions[token] = Task { [weak self] in
            let result = await worker.result
            guard let self else { return }
            self.recognitionWorkers[token] = nil
            self.recognitionCompletions[token] = nil
            guard self.isActive, self.generation == token else { return }
            self.ocr.isRecognizing = false
            switch result {
            case .success(let blocks):
                self.ocr.blocks = blocks
                self.hasRecognizedResult = !blocks.isEmpty
                self.originalText = self.ocr.selectedText
                self.onRecognizedText?(self.originalText)
                let shouldTranslate = self.translateWhenReady
                self.translateWhenReady = false
                if shouldTranslate, !self.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.requestTranslation()
                }
            case .failure(let error):
                guard !(error is CancellationError), !worker.isCancelled else { return }
                self.ocr.errorMessage = error.localizedDescription
            }
        }
    }

    /// Upgrades pending OCR instead of repeating it, or explicitly translates the user's current edits.
    func requestTranslation() {
        guard isActive else { return }
        section = .translation
        feedback = nil
        if ocr.isRecognizing || isAwaitingSnapshot {
            translateWhenReady = true
            return
        }
        guard !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        translateOperation(translation, originalText, settings)
    }

    /// Presents capture-rendering failures in the card, leaving the parent responsible for another snapshot.
    func showError(_ error: any Error) {
        guard isActive else { return }
        invalidateRecognition()
        isAwaitingSnapshot = false
        ocr.isRecognizing = false
        ocr.errorMessage = error.localizedDescription
        translation.invalidate()
        feedback = nil
    }

    /// Retries the retained pixels; nil signals that the parent must retry screenshot rendering instead.
    @discardableResult func retryRecognition() -> Bool {
        guard isActive, !ocr.isRecognizing, let image else { return false }
        recognize(image, translateAfterRecognition: translateWhenReady)
        return true
    }

    /// Writes edits back to the existing workspace model and invalidates any result for the old text.
    func editOriginal(_ text: String) {
        guard isActive, originalText != text, !ocr.isRecognizing else { return }
        originalText = text
        ocr.blocks = text.isEmpty ? [] : [OCRBlock(text: text,
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1)]
        translation.invalidate(message: "原文已更新，点击翻译。")
        feedback = nil
    }

    func selectProvider(_ value: String) {
        guard isActive, value != providerSelection else { return }
        translation.invalidate()
        feedback = nil
        if value.hasPrefix("instance."), let id = UUID(uuidString: String(value.dropFirst("instance.".count))),
           settings.customTranslationServices.contains(where: { $0.id == id }) {
            settings.translationProvider = .custom
            settings.selectedCustomTranslationID = id
        } else if let provider = TranslationProviderID(rawValue: value) {
            settings.translationProvider = provider
            if provider == .custom { settings.selectedCustomTranslationID = nil }
        }
    }

    func selectTarget(_ language: Language) {
        guard isActive, translation.target != language else { return }
        translation.invalidate()
        translation.target = language
        feedback = nil
    }

    /// Clears a result when preferences are edited in another application window.
    func providerConfigurationChanged() {
        translation.invalidate()
        feedback = nil
    }

    func supportsTarget(_ language: Language) -> Bool {
        if settings.translationProvider == .custom,
           let configuration = settings.customTranslationServices.first(where: { $0.id == settings.selectedCustomTranslationID }) {
            return configuration.unsupportedReason(source: translation.source, target: language) == nil
        }
        return language.supports(provider: settings.translationProvider)
    }

    /// Copies the chosen text with explicit inline feedback rather than presenting an alert.
    func copy(_ section: Section) {
        let text = section == .original ? originalText : translation.translatedText
        guard isActive, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            feedback = section == .original ? "原文已复制" : "译文已复制"
        }
    }

    /// Makes all late recognition and translation responses ineligible without dropping worker handles.
    func cancel() {
        isActive = false
        invalidateRecognition()
        translateWhenReady = false
        isAwaitingSnapshot = false
        ocr.isRecognizing = false
        if !translationTransferred { translation.cancel() }
    }

    /// Moves translation ownership to the expanded workspace before invoking its presentation callback.
    func transferTranslationOwnership() {
        translationTransferred = true
        cancel()
    }

    /// Waits for every native OCR worker, including an earlier request which ignored cancellation.
    func finishAndDrain() async {
        cancel()
        while !recognitionCompletions.isEmpty {
            let pending = Array(recognitionCompletions.values)
            for completion in pending { await completion.value }
        }
        if !translationTransferred { await translation.drainPendingRequests() }
    }

    private func invalidateRecognition() {
        generation = UUID()
        for worker in recognitionWorkers.values { worker.cancel() }
    }
}
