# 翻译服务配置

在「设置 → OCR 与翻译」分别填写凭据，点击保存，再点击该服务的「测试连接」。测试会实际请求 `Hello, world!` → 简体中文，绕过结果缓存；成功时显示译文，失败时显示服务原始错误码或 HTTP 状态。五家服务彼此平级，当前服务失败不会自动换另一家。

| 服务 | 需要填写 | 接口与注意事项 |
|---|---|---|
| 百度 | APP ID、密钥 | [百度通用文本翻译 API](https://fanyi-api.baidu.com/doc/21)；启用通用翻译服务，使用原始 UTF-8 文本计算 MD5 签名 |
| Google | API Key | [Cloud Translation Basic v2](https://docs.cloud.google.com/translate/docs/reference/rest/v2/translate)；项目启用 API 与计费，密钥允许 Translation API；使用经典 `nmt` 模型 |
| 有道 | 应用 ID（appKey）、应用密钥 | [智云文本翻译](https://ai.youdao.com/DOCSIRMA/html/trans/api/wbfy/index.html)；应用绑定文本翻译服务，使用 v3 SHA256 签名 |
| DeepL | Auth Key | [DeepL API](https://www.deepl.com/en/developers)；完整密钥以 `:fx` 结尾自动使用 Free 端点，其余使用 Pro 端点；繁体中文目标码为 `ZH-HANT`；请求显式选择 `latency_optimized` |
| 自定义 REST | 请求/响应模板；需要认证时填写该实例的 API Key / Token | 支持 HTTP/HTTPS REST 翻译服务；内置彩云小译与 LibreTranslate 模板，可编辑服务地址、认证和语言约定 |

## 官方申请指南

资料核对日期：**2026-10-13**。以下链接均为官方 HTTPS 页面，不包含用户凭据。产品介绍、控制台和参考文档分开标明；账户申请、认证、计费和额度可能随地区及套餐变化，以官方页面及账户内信息为准。应用中的指南来自独立数据模型 `ProviderSetupGuide`，查看或打开指南不会向翻译接口发送原文。

### 百度通用文本翻译 API

1. 登录[百度翻译开发者控制台](https://fanyi-api.baidu.com/manage/developer)，注册开发者并完善平台要求的资料。
2. 阅读[通用文本翻译产品介绍](https://fanyi-api.baidu.com/product/11)，进入[通用文本翻译开通流程](https://fanyi-api.baidu.com/access/0/1)。选择适合的服务版本，完成该版本需要的认证和开通。
3. 在开发者账户取得 **APP ID** 和对应的 **密钥**，确认通用文本翻译服务已生效。
4. 将两项凭据分别填写到本应用百度服务设置，保存后测试连接。若账户设置了 IP 限制，允许本机请求使用的公网出口 IP。

接口参数与签名以[公开的通用文本翻译参考文档](https://fanyi-api.baidu.com/doc/21)为准。这里接入的是通用文本翻译产品，申请时应确认服务类型一致。

### Google Cloud Translation Basic v2

1. 按[官方开通指南](https://docs.cloud.google.com/translate/docs/setup)，登录 Google Cloud，创建或选择有管理权限的项目，并为项目关联可用的结算账户。官方要求使用 Cloud Translation 时启用计费。
2. 在同一项目[启用 Cloud Translation API](https://console.cloud.google.com/apis/enableflow?apiid=translate.googleapis.com)（服务 ID：`translate.googleapis.com`），确认它出现在「API 和服务 → 已启用的 API 和服务」中。此入口会直接打开翻译 API 的启用流程。
3. 到[项目凭据控制台](https://console.cloud.google.com/apis/credentials)，确认顶部项目与上一步一致，选择「创建凭据 → API 密钥」，创建 **标准 API Key**。按照[API Key 管理文档](https://docs.cloud.google.com/docs/authentication/api-keys)把 API 限制设为 Cloud Translation API；无需勾选「Authenticate API calls through a service account」或绑定服务账号。
4. 将 API Key 填入本应用 Google 服务设置，保存后测试连接。应用限制需允许本机的原生 REST 请求；网站 Referer、Android 和 iOS 应用限制不适用于当前请求。使用 IP 限制时填写公网出口 IP，切换网络后重新核对。

产品说明见[Cloud Translation](https://cloud.google.com/translate)，接口见[Basic v2 translate 参考文档](https://docs.cloud.google.com/translate/docs/reference/rest/v2/translate)。[官方认证说明](https://docs.cloud.google.com/translate/docs/authentication)明确：Basic v2 支持 API Key，Advanced v3 不支持。此处无需上传服务账号 JSON。

**凭据页里找不到 Cloud Translation API：** 先回到上面的启用入口，核对当前项目并启用服务，再刷新凭据页。启用服务与创建密钥两页顶部的**项目 ID 必须相同**；凭据页负责管理密钥，服务开通在 API 库中完成。如果账号无法启用 API，[官方说明](https://docs.cloud.google.com/translate/docs/setup)要求具有 `serviceusage.services.enable` 权限，可由项目所有者或 Service Usage Admin 管理员开通。

### 有道智云文本翻译

1. 登录[有道智云控制台](https://ai.youdao.com/console/)，注册账户并完善开发者信息。
2. 按[官方接入指南](https://ai.youdao.com/doc.s)创建应用，选择 **文本翻译服务** 和 **API 接入方式**，确认应用已绑定该服务。
3. 在应用详情取得 **应用 ID（appKey）** 与对应的 **应用密钥**。
4. 将两项凭据分别填写到本应用有道服务设置，保存后测试连接。

产品介绍见[智云文本翻译](https://ai.youdao.com/new/product-fanyi-text.s)，协议与错误码见[文本翻译 API 参考文档](https://ai.youdao.com/DOCSIRMA/html/trans/api/wbfy/index.html)。智云 API 应用凭据与有道词典会员、账户登录密码不同；服务绑定和可用额度以该应用的控制台信息为准。

### DeepL API：当前申请与已有 Free / Pro 账户

1. 先阅读[官方 API 套餐说明](https://support.deepl.com/hc/en-us/articles/360021200939-DeepL-API-plans)。截至资料核对日期，**API Free 和 API Pro 已不再接受新购买**；新申请使用官方当前提供的 **Developer API、Growth API 或 Enterprise API** 路径。
2. 从上述说明的官方申请入口或[DeepL API 产品页](https://www.deepl.com/en/developers)完成 API 账户注册及开通。DeepL 网页/桌面翻译订阅与 API 套餐属于不同产品，请确认取得 API 访问权限。
3. 到[API 账户密钥管理](https://www.deepl.com/en/your-account/keys)创建或复制用于翻译请求的 **API Auth Key**，将完整内容填入本应用并保存、测试。取得密钥的条件见[官方密钥说明](https://support.deepl.com/hc/en-us/articles/360020695820-API-key-for-DeepL-API)。

已有 API Free / Pro 账户可使用仍然有效的密钥。[当前认证文档](https://developers.deepl.com/docs/getting-started/auth)依然规定 Free 端点为 `api-free.deepl.com`，Pro 端点为 `api.deepl.com`，并以 `:fx` 识别 Free 密钥。本应用与现行[官方 Python SDK](https://github.com/DeepL/deepl-python/blob/main/deepl/util.py)一致，完整密钥后缀为 `:fx` 时选择 Free 端点，其余选择 Pro 端点；不要自行修改后缀。

官方套餐说明表示同一 API 文档适用于所有 API 套餐，但公开文档尚未明确逐一说明新 Developer / Growth 套餐实际发放的密钥后缀。本次未开通真实新账户，也未发送翻译请求，因此这里只确认官方端点规则与客户端一致，不能作为新套餐真实账户连通性验收。

### 自定义 REST：彩云与 LibreTranslate

创建自定义服务后，选择相应预设或按目标服务文档填写模板。以下接入路径按所选服务任选一种：

- **彩云小译 API**：阅读[当前 API 申请及参考文档](https://docs.caiyunapp.com/lingocloud-api/index.html)，在[彩云开发者平台](https://platform.caiyunapp.com/)注册并申请小译 **API Token**，填入彩云预设的独立密钥输入框。[官方账户说明](https://docs.caiyunapp.com/lingocloud-app/lingocloud-web/trans-api.html)明确区分彩云小译 App / 网页会员与 API Token。预设会将 Token 放入目标接口要求的认证 Header。
- **LibreTranslate 官方托管**：产品入口为[libretranslate.com](https://libretranslate.com/)，使用其托管 API 时通过[官方密钥门户](https://portal.libretranslate.com/)购买该服务的 API Key，再填入 LibreTranslate 预设；方案与价格以门户当前信息为准。官方托管密钥与自托管管理员发放的密钥不能互换。
- **LibreTranslate 自托管**：按[官方部署指南](https://docs.libretranslate.com/guides/installation/)部署或连接自己的实例，修改预设服务地址。若管理员启用了 API Key 验证，按照[自托管密钥管理文档](https://docs.libretranslate.com/guides/manage_api_keys/)取得该实例密钥。默认未启用验证的实例可免密访问；根据[API 使用说明](https://docs.libretranslate.com/guides/api_usage/)删除 Body 中的 `api_key` 字段，并移除 URL、Headers、Body 中全部 `$KEY` 占位符，密钥即可留空，无需为本应用强行开启密钥验证。

只有请求模板含 `$KEY` 时，本应用才要求该实例有密钥。无需认证的自托管服务可以使用不带 `$KEY` 的模板。保存后测试所选实例，检查语言码、请求格式与响应路径。本文不固定赠送量、价格或控制台按钮名称。

## 凭据、模板与协议

有道签名采用[官方 Python3 示例](https://download.ydstatic.com/ead/TranslateDemo-py1.zip)中 `AuthV3Util.py` 的 Unicode 码点计数与切片：原文超过 20 个码点时，取前 10 个码点、十进制码点总数和后 10 个码点拼接；其余使用完整原文，再按 UTF-8 计算 SHA256。组合字符分别计数，原文不做 NFC/NFD 转换。官方网页的 JavaScript 示例采用 UTF-16 代码单元，因此超 BMP 字符（如部分 Emoji）与 Python3 示例的签名可能不同；本应用选择保留有效 UTF-8 的 Python3 规则。这些输入仍须使用真实有道账号验证，离线向量通过不表示 Emoji 已经在真实服务上翻译成功。

所有凭据写入系统钥匙串，服务名为 `com.n1ko.niko-shot`。设置不会回显已存密钥；输入框的 `••••` 仅表示已有凭据。空输入不会覆盖已有值，删除使用单独按钮。复制密钥是显式操作，请按需要使用。模板及语言偏好保存在 UserDefaults，密钥不进入模板持久化或历史数据库。

创建自定义服务时，设置名称、HTTP Method、URL、Headers、JSON/Form Body 和响应路径。Headers 用 JSON 对象表达，例如 `{"Authorization":"Bearer $KEY"}`；JSON Body 的占位符须置于 JSON 字符串内，例如 `{"q":"$TEXT","source":"$SOURCE","target":"$TARGET"}`。Form 示例为 `q=$TEXT&source=$SOURCE&target=$TARGET&key=$KEY`。响应路径支持数组下标，如 `translations.0.text`。占位符只扫描模板一次，原文中的引号、换行或 `$KEY` 字样都作为普通文本处理。

URL 占位符会编码；Headers 禁止换行；GET/HEAD 应把参数放在 URL 并留空 Body。自定义模板的 `$KEY` 从该实例独立的钥匙串条目读取。彩云与 LibreTranslate 模板有各自的语言码约定；更换服务后应确认目标接口支持所选语种。某家经典接口不支持的组合会被禁用，并给出原因。

OCR 窗口选择当前服务、源语言与目标语言，默认自动检测 → 简体中文。可以关闭默认开启的自动翻译。编辑区块不会逐键发请求，修改后点击「翻译」重新请求；译文支持选择与一键复制。请求超时为 15 秒，无自动重试。成功结果按服务、实例、凭据、原文及语言对缓存 5 分钟；更换密钥不会复用旧密钥的成功结果。

真实账号验收需要分别保存有效凭据。自动化测试使用注入的 URLSession 和官方格式响应，验证签名、语言映射、超时、错误与模板；它们不能代替真实服务翻译成功证据。

DeepL 现行 [模型类型文档](https://developers.deepl.com/docs/translate/understanding-model-types) 将该参数定义为性能目标，具体服务器模型可由服务方替换。本应用只直连 `/v2/translate`，不调用通用 LLM API、不加载本地模型、不选择质量优化或自动降级模式；但不能保证第三方服务器内部的模型架构。若需求中的“不使用任何 LLM”包括 DeepL 内部实现，这项保证需要服务方合同，而不能由客户端参数证明。
