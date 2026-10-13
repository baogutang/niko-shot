// Presents official translation-service onboarding without account access or credential-bearing links.
import Foundation

/// Official application steps and navigation for the application's five translation integrations.
public struct ProviderSetupGuide: Sendable {
    /// An official page with a stable identity describing its navigation purpose.
    public struct Link: Identifiable, Sendable {
        /// A navigation role, such as product, console or docs, unique within this guide.
        public let id: String
        /// A localized label distinguishing product information, account management and documentation.
        public let title: String
        /// An absolute HTTPS URL containing no application credentials.
        public let url: URL

        /// Creates a navigation destination.
        public init(id: String, title: String, url: URL) {
            self.id = id
            self.title = title
            self.url = url
        }
    }

    /// One application or configuration step, optionally linked to the relevant official page.
    public struct Step: Identifiable, Sendable {
        /// A stable step identity in presentation order.
        public let id: Int
        /// The action the user performs.
        public let title: String
        /// Instructions that avoid assuming changing console button names.
        public let detail: String
        /// The official destination for this step, when one is needed.
        public let link: Link?

        /// Creates a setup step.
        public init(id: Int, title: String, detail: String, link: Link? = nil) {
            self.id = id
            self.title = title
            self.detail = detail
            self.link = link
        }
    }

    /// The provider to which this guide applies.
    public let provider: TranslationProviderID
    /// A localized guide title.
    public let title: String
    /// The service scope and the credentials the application accepts.
    public let summary: String
    /// Labels corresponding to the provider's credential inputs; custom services may omit authentication.
    public let credentialLabels: [String]
    /// Ordered setup steps, with conditional branches clearly named for custom services.
    public let steps: [Step]
    /// Official product, console and documentation destinations.
    public let links: [Link]
    /// Prerequisites and service-specific distinctions relevant to setup.
    public let notes: [String]
    /// The date on which the public official material was checked, rather than an account-connectivity claim.
    public let verifiedDate: String = "2026-10-13"

    /// Returns the complete official setup guide for a selected translation integration.
    public static func guide(for provider: TranslationProviderID) -> Self {
        switch provider {
        case .baidu: baidu
        case .google: google
        case .youdao: youdao
        case .deepl: deepl
        case .custom: custom
        }
    }

    private static var baidu: Self {
        let product = official("product", "产品介绍 · 百度通用文本翻译 API",
                               "https://fanyi-api.baidu.com/product/11")
        let console = official("console", "开发者控制台 · 百度翻译开放平台",
                               "https://fanyi-api.baidu.com/manage/developer")
        let docs = official("docs", "参考文档 · 百度通用文本翻译 API",
                            "https://fanyi-api.baidu.com/doc/21")
        let activate = official("activation", "服务开通 · 通用文本翻译 API",
                                "https://fanyi-api.baidu.com/access/0/1")
        return Self(
            provider: .baidu, title: "开通百度通用翻译",
            summary: "在百度翻译开放平台开通通用文本翻译 API，取得同一开发者账户的 APP ID 与密钥。",
            credentialLabels: ["APP ID", "密钥"],
            steps: [
                Step(id: 1, title: "申请服务",
                     detail: "登录百度翻译开放平台注册开发者，完善平台要求的资料。选择通用文本翻译 API 及服务版本，完成该版本需要的认证与开通。", link: activate),
                Step(id: 2, title: "填入凭据",
                     detail: "从同一开发者账户取得 APP ID 与密钥，确认通用文本翻译服务已生效；在本应用百度服务设置中分别填入这两项。", link: console),
                Step(id: 3, title: "测试连接",
                     detail: "保存后点击测试连接，实际请求 Hello, world! → 简体中文。成功时显示译文，失败时在当前服务显示原始错误码或 HTTP 状态。", link: docs)
            ],
            links: [product, console, docs, activate],
            notes: [
                "本应用接入通用文本翻译 API；申请时请确认服务类型与上述产品一致。",
                "认证条件、计费和额度以所选服务版本及账户内的最新信息为准。",
                "如果设置了 IP 限制，需要允许这台 Mac 发送请求时使用的公网出口 IP。"
            ])
    }

    private static var google: Self {
        let product = official("product", "产品介绍 · Google Cloud Translation",
                               "https://cloud.google.com/translate")
        let console = official("console", "凭据控制台 · Google Cloud",
                               "https://console.cloud.google.com/apis/credentials")
        let docs = official("docs", "参考文档 · Basic v2 translate",
                            "https://docs.cloud.google.com/translate/docs/reference/rest/v2/translate")
        let setup = official("setup", "开通指南 · 项目、计费与 API",
                             "https://docs.cloud.google.com/translate/docs/setup")
        let enable = official("enable-api", "启用服务 · Cloud Translation API",
                              "https://console.cloud.google.com/apis/enableflow?apiid=translate.googleapis.com")
        let keys = official("key-management", "凭据指南 · API Key 与访问限制",
                            "https://docs.cloud.google.com/docs/authentication/api-keys")
        let authentication = official("authentication", "认证说明 · Basic v2 与 Advanced v3",
                                      "https://docs.cloud.google.com/translate/docs/authentication")
        return Self(
            provider: .google, title: "开通 Google Cloud Translation",
            summary: "本应用使用 Cloud Translation Basic v2，通过项目的 API Key 请求文本翻译。",
            credentialLabels: ["API Key"],
            steps: [
                Step(id: 1, title: "启用翻译 API",
                     detail: "登录 Google Cloud，在顶部选择或创建项目并关联结算账户。打开下方启用入口，在该项目启用 Cloud Translation API（translate.googleapis.com），确认它出现在已启用的 API 和服务中。", link: enable),
                Step(id: 2, title: "创建并填写 API Key",
                     detail: "保持顶部项目与第 1 步一致，在凭据页选择“创建凭据 → API 密钥”。创建标准 API Key，将 API 限制设为 Cloud Translation API，应用限制需允许本机 REST 请求；将完整密钥填入本应用 Google 服务设置。", link: console),
                Step(id: 3, title: "测试连接",
                     detail: "保存后点击测试连接，实际请求 Hello, world! → 简体中文。成功时显示译文，失败时在当前服务显示原始错误码或 HTTP 状态。", link: docs)
            ],
            links: [product, console, docs, setup, enable, keys, authentication],
            notes: [
                "Basic v2 支持 API Key；Advanced v3 不支持这种认证方式。本应用此处只需要 API Key。",
                "如果创建凭据或 API 限制列表里找不到 Cloud Translation API，先返回第 1 步确认已启用，再刷新凭据页，并核对两页顶部的项目 ID 一致。凭据页用于管理密钥，启用服务需进入 API 库或上述启用入口。",
                "密钥所属项目必须同时启用 Translation API 与计费；费用和使用额度以 Google Cloud 账户为准。",
                "标准 API Key 无需绑定服务账号；创建时不勾选“Authenticate API calls through a service account”。若无法启用 API，需要项目所有者或具有 Service Usage Admin 权限的管理员开通。",
                "网站 Referer、Android 和 iOS 的应用限制不适用于本应用的 macOS REST 请求。使用 IP 限制时填写公网出口 IP，网络变化后需重新核对。"
            ])
    }

    private static var youdao: Self {
        let product = official("product", "产品介绍 · 有道智云文本翻译",
                               "https://ai.youdao.com/new/product-fanyi-text.s")
        let console = official("console", "开发者控制台 · 有道智云",
                               "https://ai.youdao.com/console/")
        let docs = official("docs", "参考文档 · 有道文本翻译 API",
                            "https://ai.youdao.com/DOCSIRMA/html/trans/api/wbfy/index.html")
        let setup = official("setup", "接入指南 · 有道智云",
                             "https://ai.youdao.com/doc.s")
        return Self(
            provider: .youdao, title: "开通有道智云文本翻译",
            summary: "在有道智云创建文本翻译的 API 应用，取得应用 ID（appKey）与应用密钥。",
            credentialLabels: ["应用 ID（appKey）", "应用密钥"],
            steps: [
                Step(id: 1, title: "申请服务",
                     detail: "注册有道智云开发者账户并完善资料。创建应用时选择文本翻译服务与 API 接入方式，确认应用已绑定该服务。", link: setup),
                Step(id: 2, title: "填入凭据",
                     detail: "从同一智云应用取得应用 ID（接口参数 appKey）及应用密钥，在本应用有道服务设置中分别填入这两项。", link: console),
                Step(id: 3, title: "测试连接",
                     detail: "保存后点击测试连接，实际请求 Hello, world! → 简体中文。成功时显示译文，失败时在当前服务显示原始错误码或 HTTP 状态。", link: docs)
            ],
            links: [product, console, docs, setup],
            notes: [
                "应用 ID 与应用密钥来自智云 API 应用；有道词典会员或账户登录密码不能用于这些输入框。",
                "应用必须绑定文本翻译服务，并使用 API 接入方式。服务状态、计费及可用额度以智云控制台为准。"
            ])
    }

    private static var deepl: Self {
        let product = official("product", "产品介绍 · DeepL API",
                               "https://www.deepl.com/en/developers")
        let console = official("console", "密钥管理 · DeepL API 账户",
                               "https://www.deepl.com/en/your-account/keys")
        let docs = official("docs", "参考文档 · API 端点与认证",
                            "https://developers.deepl.com/docs/getting-started/auth")
        let plans = official("api-plans", "申请与套餐说明 · DeepL API",
                             "https://support.deepl.com/hc/en-us/articles/360021200939-DeepL-API-plans")
        let keys = official("key-management", "凭据指南 · DeepL API Key",
                            "https://support.deepl.com/hc/en-us/articles/360020695820-API-key-for-DeepL-API")
        return Self(
            provider: .deepl, title: "开通 DeepL API",
            summary: "选择面向开发者的 DeepL API 套餐并取得 API Auth Key；已有 API Free / Pro 账户可继续使用其有效密钥。",
            credentialLabels: ["Auth Key"],
            steps: [
                Step(id: 1, title: "申请服务",
                     detail: "阅读当前 API 套餐说明，选择 Developer API、Growth API 或 Enterprise API，按官方申请流程完成 API 账户开通。已有 API Free / Pro 账户可使用有效密钥。", link: plans),
                Step(id: 2, title: "填入凭据",
                     detail: "在具备 API 权限的账户中创建或复制用于翻译的 API Auth Key，在本应用 DeepL 服务设置中粘贴完整密钥，保留原有后缀。", link: console),
                Step(id: 3, title: "测试连接",
                     detail: "保存后点击测试连接，实际请求 Hello, world! → 简体中文。成功时显示译文，失败时在当前服务显示原始错误码或 HTTP 状态。", link: docs)
            ],
            links: [product, console, docs, plans, keys],
            notes: [
                "截至核对日期，官方说明 API Free 与 API Pro 不再接受新购买；新申请请查看当前 Developer / Growth / Enterprise API 套餐。",
                "DeepL 网页或桌面翻译订阅与 DeepL API 套餐是不同产品。需要取得具备 API 权限的密钥。",
                "应用按官方认证规则自动选择端点：以 :fx 结尾的完整密钥使用 api-free.deepl.com，其余使用 api.deepl.com；请勿自行添加或删除后缀。",
                "当前文档和官方 SDK 保留上述端点规则；新套餐实际发放的密钥后缀与真实账户连通性尚未在本应用中验证。"
            ])
    }

    private static var custom: Self {
        let product = official("product", "产品介绍 · LibreTranslate",
                               "https://libretranslate.com/")
        let console = official("console", "开发者控制台 · 彩云小译 API",
                               "https://platform.caiyunapp.com/")
        let docs = official("docs", "参考文档 · LibreTranslate API",
                            "https://docs.libretranslate.com/guides/api_usage/")
        let caiyun = official("caiyun-docs", "申请与参考文档 · 彩云小译 API",
                              "https://docs.caiyunapp.com/lingocloud-api/index.html")
        let membership = official("caiyun-membership", "账户说明 · 彩云会员与 API Token",
                                  "https://docs.caiyunapp.com/lingocloud-app/lingocloud-web/trans-api.html")
        let hosted = official("libretranslate-hosted-keys", "密钥申请 · LibreTranslate 官方托管",
                              "https://portal.libretranslate.com/")
        let installation = official("libretranslate-self-host", "部署指南 · LibreTranslate 自托管",
                                    "https://docs.libretranslate.com/guides/installation/")
        let keys = official("libretranslate-key-management", "密钥管理 · LibreTranslate 自托管",
                            "https://docs.libretranslate.com/guides/manage_api_keys/")
        return Self(
            provider: .custom, title: "配置自定义 REST 翻译",
            summary: "按所选服务申请自己的 API Key / Token，或连接允许免密访问的自托管实例。彩云、官方托管和自托管是不同接入路径，任选适用的一种。",
            credentialLabels: ["API Key / Token（需要认证时）"],
            steps: [
                Step(id: 1, title: "申请服务",
                     detail: "按所选服务任选一条路径：彩云在开发者平台注册并申请小译 API Token；LibreTranslate 官方托管在密钥门户购买 API Key；自托管连接自己的实例，有认证时向管理员领取密钥，无认证时可免密。各路径官方入口列在下方。", link: caiyun),
                Step(id: 2, title: "填入凭据",
                     detail: "新建自定义服务并选择预设，填写名称、URL、Headers、Body 与响应路径，需要认证时填入该实例的 API Key / Token。LibreTranslate 免密实例需删除 api_key 字段及模板中全部 $KEY 占位符，密钥可留空。", link: console),
                Step(id: 3, title: "测试连接",
                     detail: "保存后点击测试连接，实际请求 Hello, world! → 简体中文。成功时显示译文，失败时显示原始错误码或 HTTP 状态；检查服务地址、认证、语言和响应路径。", link: docs)
            ],
            links: [product, console, docs, caiyun, membership, hosted, installation, keys],
            notes: [
                "彩云小译 App / 网页会员账户与小译 API Token 分属不同产品；请使用开发者平台发放的 API Token。",
                "LibreTranslate 官方托管密钥来自其官方门户；自托管实例的密钥由实例管理员管理，两者不能互换。",
                "LibreTranslate 自托管默认可不启用 API Key 验证。预设包含 api_key 和 $KEY；免密实例需删除这些认证内容，无需为本应用强行启用密钥验证。",
                "只有 URL、Headers 或 Body 模板包含 $KEY 时，本应用才要求该实例的密钥。密钥单独保存在系统钥匙串，不要直接写入模板。",
                "计费、可用语种和额度由所选服务或自托管实例决定。官方导航使用 HTTPS；本地自托管服务地址按你的部署填写。"
            ])
    }

    private static func official(_ id: String, _ title: String, _ address: String) -> Link {
        guard let url = URL(string: address), url.scheme == "https", url.host != nil else {
            preconditionFailure("Invalid static official setup-guide URL.")
        }
        return Link(id: id, title: title, url: url)
    }
}
