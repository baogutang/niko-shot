// Keeps an inline screenshot's OCR and automatic translation cancellable.
import AppKit
import Observation

/// Live resources retained until the underlying recognition operation actually returns.
struct ScreenshotTextResourceCounts: Equatable, Sendable {
    let recognitionTasks: Int
    let waitingForSnapshot: Bool
    let isTranslating: Bool
    let translationRequests: Int
    let scheduledTranslations: Int
}

/// Shares the automatic translation preference with the expanded OCR workspace.
@MainActor @Observable
final class ScreenshotTextModel {
    typealias RecognitionOperation = @Sendable (CGImage, [String], Bool) async throws -> [OCRBlock]
    typealias TranslationOperation = @MainActor (TranslationViewModel, String, AppSettings) -> Void
    typealias ConfigurationCheck = @MainActor (AppSettings) -> Bool

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
    private(set) var isAwaitingTranslation = false
    private(set) var isTranslationConfigured: Bool

    @ObservationIgnored var onRecognizedText: ((String) -> Void)?
    @ObservationIgnored private let recognizeOperation: RecognitionOperation
    @ObservationIgnored private let translateOperation: TranslationOperation
    @ObservationIgnored private let configurationCheck: ConfigurationCheck
    @ObservationIgnored private var image: CGImage?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var translateWhenReady = false
    @ObservationIgnored private var translationTransferred = false
    @ObservationIgnored private var recognitionWorkers: [UUID: Task<[OCRBlock], any Error>] = [:]
    @ObservationIgnored private var recognitionCompletions: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var automaticTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var automaticToken: UUID?
    @ObservationIgnored private var providerConfiguration: ProviderConfiguration

    private struct ProviderConfiguration: Equatable {
        let provider: TranslationProviderID
        let custom: CustomRESTConfiguration?
        @MainActor init(_ settings: AppSettings) {
            provider = settings.translationProvider
            custom = provider == .custom ? settings.customTranslationServices.first {
                $0.id == settings.selectedCustomTranslationID
            } : nil
        }
    }

    /// Injects recognition for deterministic cancellation tests; production uses the existing Vision actor.
    init(settings: AppSettings, recognition: RecognitionOperation? = nil,
         translationOperation: TranslationOperation? = nil, configurationCheck: ConfigurationCheck? = nil) {
        self.settings = settings
        let check = configurationCheck ?? { TranslationConfiguration.isConfigured($0) }
        self.configurationCheck = check
        isTranslationConfigured = check(settings)
        providerConfiguration = ProviderConfiguration(settings)
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
        for task in automaticTasks.values { task.cancel() }
    }

    var resourceCounts: ScreenshotTextResourceCounts {
        ScreenshotTextResourceCounts(recognitionTasks: recognitionWorkers.count,
            waitingForSnapshot: isAwaitingSnapshot, isTranslating: !translationTransferred && translation.isTranslating,
            translationRequests: translationTransferred ? 0 : translation.pendingRequestCount,
            scheduledTranslations: automaticTasks.count)
    }

    var isWorking: Bool {
        !recognitionWorkers.isEmpty || !automaticTasks.isEmpty || ocr.isRecognizing ||
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
        refreshConfiguration()
        cancelScheduledTranslation()
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
        section = isTranslationConfigured && (translateAfterRecognition || settings.automaticTranslation) ? .translation : .original
    }

    /// Starts one OCR operation, retaining older cancelled workers solely for eventual draining.
    func recognize(_ image: CGImage, translateAfterRecognition: Bool) {
        guard isActive else { return }
        refreshConfiguration()
        cancelScheduledTranslation()
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
        section = isTranslationConfigured && (translateWhenReady || settings.automaticTranslation) ? .translation : .original

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
                let shouldTranslate = self.translateWhenReady || self.settings.automaticTranslation
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
        cancelScheduledTranslation()
        refreshConfiguration()
        guard isTranslationConfigured else {
            section = .original
            translateWhenReady = false
            return
        }
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
        cancelScheduledTranslation()
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
        translation.invalidate(message: settings.automaticTranslation ? nil : "原文已更新，点击翻译。")
        feedback = nil
        scheduleTranslation(after: .milliseconds(400))
    }

    func selectProvider(_ value: String) {
        guard isActive, value != providerSelection else { return }
        if value.hasPrefix("instance."), let id = UUID(uuidString: String(value.dropFirst("instance.".count))),
           settings.customTranslationServices.contains(where: { $0.id == id }) {
            settings.translationProvider = .custom
            settings.selectedCustomTranslationID = id
        } else if let provider = TranslationProviderID(rawValue: value) {
            settings.translationProvider = provider
            if provider == .custom { settings.selectedCustomTranslationID = nil }
        }
        providerConfigurationChanged()
    }

    func selectTarget(_ language: Language) {
        guard isActive, translation.target != language else { return }
        translation.invalidate()
        translation.target = language
        feedback = nil
        if settings.automaticTranslation && isTranslationConfigured { section = .translation }
        scheduleTranslation(after: .milliseconds(150))
    }

    /// Clears a result when preferences are edited in another application window.
    func providerConfigurationChanged(credentialsChanged: Bool = false) {
        guard isActive else { return }
        let current = ProviderConfiguration(settings)
        let wasConfigured = isTranslationConfigured
        refreshConfiguration()
        guard current != providerConfiguration || credentialsChanged || wasConfigured != isTranslationConfigured else { return }
        providerConfiguration = current
        translation.invalidate()
        feedback = nil
        scheduleTranslation(after: .milliseconds(150))
    }

    /// Turning automation off cancels queued edits; an explicit translation remains available.
    func automaticTranslationChanged() {
        guard isActive else { return }
        cancelScheduledTranslation()
        refreshConfiguration()
        if settings.automaticTranslation && isTranslationConfigured {
            section = .translation
            if !translation.isTranslating && translation.translatedText.isEmpty && translation.errorMessage == nil {
                scheduleTranslation(after: .zero)
            }
        } else if translation.translatedText.isEmpty && !translation.isTranslating {
            section = .original
        }
    }

    /// Cancels both pending edits and the selected service's current request.
    func cancelTranslation() {
        cancelScheduledTranslation()
        translation.cancel()
    }

    private func scheduleTranslation(after delay: Duration) {
        cancelScheduledTranslation()
        refreshConfiguration()
        guard isActive, settings.automaticTranslation, isTranslationConfigured, !ocr.isRecognizing, !isAwaitingSnapshot,
              !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = UUID()
        automaticToken = token
        isAwaitingTranslation = true
        automaticTasks[token] = Task { [weak self] in
            defer {
                self?.automaticTasks[token] = nil
                if self?.automaticToken == token {
                    self?.automaticToken = nil
                    self?.isAwaitingTranslation = false
                }
            }
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, self.isActive, self.automaticToken == token,
                  self.settings.automaticTranslation, !self.ocr.isRecognizing else { return }
            self.refreshConfiguration()
            guard self.isTranslationConfigured else { return }
            self.feedback = nil
            self.translateOperation(self.translation, self.originalText, self.settings)
        }
    }

    private func cancelScheduledTranslation() {
        automaticToken = nil
        isAwaitingTranslation = false
        for task in automaticTasks.values { task.cancel() }
    }

    private func refreshConfiguration() {
        isTranslationConfigured = configurationCheck(settings)
        if !isTranslationConfigured {
            cancelScheduledTranslation()
            translation.invalidate()
            section = .original
        }
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
        cancelScheduledTranslation()
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
        while !automaticTasks.isEmpty {
            for task in Array(automaticTasks.values) { await task.value }
        }
        if !translationTransferred { await translation.drainPendingRequests() }
    }

    private func invalidateRecognition() {
        generation = UUID()
        for worker in recognitionWorkers.values { worker.cancel() }
    }
}
