// Executes only the user-selected provider and caches successful results for five minutes per credential and pair.
import Foundation
import CryptoKit

/// The single translation coordinator; concurrent requests remain independent and no fallback exists.
public actor TranslationRouter {
    /// The lazily initialized app-wide router.
    public static let shared = TranslationRouter()
    private let session: URLSession
    private let credentials: KeychainStore
    private struct CacheKey: Hashable {
        let request: TranslationRequest
        let provider: TranslationProviderID
        let configuration: Data?
        let credentialFingerprint: String
    }
    private struct Entry { let expires: Date; let result: TranslationResult }
    private var cache: [CacheKey: Entry] = [:]
    /// Creates a router with an injectable URLSession and Keychain facade.
    public init(session: URLSession = .shared, credentials: KeychainStore = KeychainStore()) {
        self.session = session; self.credentials = credentials
    }
    /// Reports whether the exact selected service or custom instance has all credentials.
    public func credentialsStatus(provider: TranslationProviderID, custom: CustomRESTConfiguration? = nil) -> CredentialsStatus {
        guard let service = service(provider: provider, custom: custom) else { return .unconfigured }
        return service.credentialsStatus()
    }
    /// Discards cached plaintext when settings change or the user clears translation state.
    public func invalidateCache() { cache.removeAll() }
    /// Translates through one service; connection tests use useCache=false to exercise the network.
    public func translate(_ request: TranslationRequest, provider: TranslationProviderID,
                          custom: CustomRESTConfiguration? = nil, useCache: Bool = true) async throws -> TranslationResult {
        guard let service = service(provider: provider, custom: custom), service.credentialsStatus() == .ready else { throw TranslationError.unconfigured }
        if Task.isCancelled { throw TranslationError.cancelled }
        let accountNames = provider == .custom ? custom.map { [$0.keyAccount] } ?? [] : provider.credentialAccounts
        let fingerprintInput = accountNames.map { name in name + "\u{0}" + (credentials.get(name) ?? "") }.joined(separator: "\u{0}")
        let fingerprint = SHA256.hash(data: Data(fingerprintInput.utf8)).map { String(format: "%02x", $0) }.joined()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let key = CacheKey(request: request, provider: provider,
                           configuration: provider == .custom ? try custom.map(encoder.encode) : nil,
                           credentialFingerprint: fingerprint)
        let now = Date()
        if useCache, let entry = cache[key], entry.expires > now { return entry.result }
        let result = try await service.translate(request)
        if Task.isCancelled { throw TranslationError.cancelled }
        if useCache {
            cache = cache.filter { $0.value.expires > now }
            if cache.count >= 128, let oldest = cache.min(by: { $0.value.expires < $1.value.expires })?.key { cache.removeValue(forKey: oldest) }
            cache[key] = Entry(expires: Date().addingTimeInterval(300), result: result)
        }
        return result
    }
    private func service(provider: TranslationProviderID, custom: CustomRESTConfiguration?) -> (any TranslationService)? {
        switch provider {
        case .baidu: return BaiduProvider(session: session, credentials: credentials)
        case .google: return GoogleProvider(session: session, credentials: credentials)
        case .youdao: return YoudaoProvider(session: session, credentials: credentials)
        case .deepl: return DeepLProvider(session: session, credentials: credentials)
        case .custom:
            guard let custom else { return nil }
            return CustomRESTProvider(configuration: custom, session: session, credentials: credentials)
        }
    }
}
