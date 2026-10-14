// UI 与请求路由共用同一套配置判定；不保存密钥，也不为检查配置发送网络请求。
import Foundation

enum TranslationConfiguration {
    static func service(provider: TranslationProviderID, custom: CustomRESTConfiguration? = nil,
                        session: URLSession = .shared, credentials: KeychainStore = KeychainStore()) -> (any TranslationService)? {
        switch provider {
        case .baidu: BaiduProvider(session: session, credentials: credentials)
        case .google: GoogleProvider(session: session, credentials: credentials)
        case .youdao: YoudaoProvider(session: session, credentials: credentials)
        case .deepl: DeepLProvider(session: session, credentials: credentials)
        case .custom: custom.map { CustomRESTProvider(configuration: $0, session: session, credentials: credentials) }
        }
    }

    @MainActor static func isConfigured(_ settings: AppSettings, credentials: KeychainStore = KeychainStore()) -> Bool {
        let custom = settings.customTranslationServices.first { $0.id == settings.selectedCustomTranslationID }
        return service(provider: settings.translationProvider, custom: custom, credentials: credentials)?.credentialsStatus() == .ready
    }
}
