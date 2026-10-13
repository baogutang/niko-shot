// Keeps translation requests cancellable and prevents stale responses from replacing newer UI state.
import Foundation
import Observation

/// Main-actor state for one OCR translation workspace.
@MainActor @Observable
final class TranslationViewModel {
    var source: Language?
    var target: Language = .simplifiedChinese
    private(set) var translatedText = ""
    private(set) var detectedSource: Language?
    private(set) var rawProviderInfo: String?
    private(set) var isTranslating = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var requestedText = ""
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRequests: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = UUID()

    deinit { for task in pendingRequests.values { task.cancel() } }

    /// Cancelled requests remain owned until the transport has actually returned.
    var pendingRequestCount: Int { pendingRequests.count }

    /// Translates explicitly through the chosen peer provider without fallback or retries.
    func translate(text: String, settings: AppSettings) {
        cancel()
        translatedText = ""
        detectedSource = nil
        rawProviderInfo = nil
        errorMessage = nil
        statusMessage = nil
        requestedText = text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请先勾选需要翻译的文字。"
            return
        }
        let provider = settings.translationProvider
        let custom = settings.customTranslationServices.first { $0.id == settings.selectedCustomTranslationID }
        if let reason = unsupportedReason(settings: settings) {
            errorMessage = reason
            return
        }
        let request = TranslationRequest(text: text, source: source, target: target)
        let current = UUID()
        generation = current
        isTranslating = true
        let task = Task { [weak self] in
            defer { self?.pendingRequests.removeValue(forKey: current) }
            do {
                let result = try await TranslationRouter.shared.translate(request, provider: provider, custom: provider == .custom ? custom : nil)
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                self.translatedText = result.text
                self.detectedSource = result.detectedSource
                self.rawProviderInfo = result.rawProviderInfo
                self.isTranslating = false
                self.requestTask = nil
            } catch {
                guard let self, self.generation == current else { return }
                self.isTranslating = false
                self.requestTask = nil
                if error is CancellationError { return }
                if case TranslationError.cancelled = error { return }
                self.errorMessage = Self.describe(error, provider: provider)
            }
        }
        pendingRequests[current] = task
        requestTask = task
    }

    /// Cancels an in-flight request and invalidates its response generation.
    func cancel() {
        generation = UUID()
        requestTask?.cancel()
        requestTask = nil
        isTranslating = false
    }

    /// Waits only for the requests owned at this point, without affecting a newly attached workspace.
    func drainPendingRequests() async {
        let pending = Array(pendingRequests.values)
        for task in pending { await task.value }
    }

    func cancelAndDrain() async {
        cancel()
        await drainPendingRequests()
    }

    /// Clears obsolete results when text, languages or the chosen provider change.
    func invalidate(message: String? = nil) {
        cancel()
        translatedText = ""
        detectedSource = nil
        rawProviderInfo = nil
        errorMessage = nil
        statusMessage = message
    }

    /// Makes editing invalidate results while keeping typing completely local.
    func originalTextChanged(_ text: String) {
        guard text != requestedText, isTranslating || !translatedText.isEmpty || errorMessage != nil else { return }
        invalidate(message: "原文已更新，点击“翻译”获取新结果。")
    }

    /// Explains unsupported language pairs before a request can leave the application.
    func unsupportedReason(settings: AppSettings) -> String? {
        let provider = settings.translationProvider
        if provider == .custom {
            guard let configuration = settings.customTranslationServices.first(where: { $0.id == settings.selectedCustomTranslationID }) else {
                return "请在设置中创建并选择一个自定义翻译服务。"
            }
            return configuration.unsupportedReason(source: source, target: target)
        }
        if let source, !source.supports(provider: provider, asSource: true) {
            return "\(provider.displayName) 不支持将\(source.displayName)作为原文语言。"
        }
        if !target.supports(provider: provider) {
            return "\(provider.displayName) 不支持翻译为\(target.displayName)。"
        }
        return nil
    }

    /// Preserves provider error codes and HTTP detail for inline native UI feedback.
    static func describe(_ error: any Error, provider: TranslationProviderID) -> String {
        switch error {
        case TranslationError.provider(let code, let message): "[\(provider.displayName) error_code \(code)] \(message)"
        case TranslationError.http(let status, let body): "[\(provider.displayName) HTTP \(status)] \(body)"
        case TranslationError.unconfigured: "[\(provider.displayName)] 请先在设置中保存服务凭据。"
        case TranslationError.decode: "[\(provider.displayName)] 无法解析服务返回的数据。"
        default: "[\(provider.displayName)] \(error.localizedDescription)"
        }
    }
}
