# 翻译服务配置

在「设置 → OCR 与翻译」分别填写凭据，点击保存，再点击该服务的「测试连接」。测试会实际请求 `Hello, world!` → 简体中文，绕过结果缓存；成功时显示译文，失败时显示服务原始错误码或 HTTP 状态。五家服务彼此平级，当前服务失败不会自动换另一家。

| 服务 | 需要填写 | 接口与注意事项 |
|---|---|---|
| 百度 | APP ID、密钥 | [百度通用翻译 API](https://fanyi-api.baidu.com/doc_bd/21)；启用通用翻译服务，使用原始 UTF-8 文本计算 MD5 签名 |
| Google | API Key | [Cloud Translation Basic v2](https://docs.cloud.google.com/translate/docs/reference/rest/v2/translate)；项目启用 API 与计费，密钥允许 Translation API；使用经典 `nmt` 模型 |
| 有道 | 应用 ID（appKey）、应用密钥 | [智云文本翻译](https://ai.youdao.com/DOCSIRMA/html/trans/api/wbfy/index.html)；应用绑定文本翻译服务，使用 v3 SHA256 签名 |
| DeepL | Auth Key | [DeepL API](https://www.deepl.com/en/developers)；以 `:fx` 结尾自动使用 Free 接口，其余使用 Pro 接口；繁体中文目标码为 `ZH-HANT`；请求显式选择 `latency_optimized` |
| 自定义 REST | 模板及独立 API Key | 支持任意 HTTP/HTTPS REST 翻译服务；内置彩云小译与 LibreTranslate 模板，可编辑服务地址与语言约定 |

有道签名采用[官方 Python3 示例](https://download.ydstatic.com/ead/TranslateDemo-py1.zip)中 `AuthV3Util.py` 的 Unicode 码点计数与切片：原文超过 20 个码点时，取前 10 个码点、十进制码点总数和后 10 个码点拼接；其余使用完整原文，再按 UTF-8 计算 SHA256。组合字符分别计数，原文不做 NFC/NFD 转换。官方网页的 JavaScript 示例采用 UTF-16 代码单元，因此超 BMP 字符（如部分 Emoji）与 Python3 示例的签名可能不同；本应用选择保留有效 UTF-8 的 Python3 规则。这些输入仍须使用真实有道账号验证，离线向量通过不表示 Emoji 已经在真实服务上翻译成功。

所有凭据写入系统钥匙串，服务名为 `com.n1ko.niko-shot`。设置不会回显已存密钥；输入框的 `••••` 仅表示已有凭据。空输入不会覆盖已有值，删除使用单独按钮。复制密钥是显式操作，请按需要使用。模板及语言偏好保存在 UserDefaults，密钥不进入模板持久化或历史数据库。

创建自定义服务时，设置名称、HTTP Method、URL、Headers、JSON/Form Body 和响应路径。Headers 用 JSON 对象表达，例如 `{"Authorization":"Bearer $KEY"}`；JSON Body 的占位符须置于 JSON 字符串内，例如 `{"q":"$TEXT","source":"$SOURCE","target":"$TARGET"}`。Form 示例为 `q=$TEXT&source=$SOURCE&target=$TARGET&key=$KEY`。响应路径支持数组下标，如 `translations.0.text`。占位符只扫描模板一次，原文中的引号、换行或 `$KEY` 字样都作为普通文本处理。

URL 占位符会编码；Headers 禁止换行；GET/HEAD 应把参数放在 URL 并留空 Body。自定义模板的 `$KEY` 从该实例独立的钥匙串条目读取。彩云与 LibreTranslate 模板有各自的语言码约定；更换服务后应确认目标接口支持所选语种。某家经典接口不支持的组合会被禁用，并给出原因。

OCR 窗口选择当前服务、源语言与目标语言，默认自动检测 → 简体中文。可以关闭默认开启的自动翻译。编辑区块不会逐键发请求，修改后点击「翻译」重新请求；译文支持选择与一键复制。请求超时为 15 秒，无自动重试。成功结果按服务、实例、凭据、原文及语言对缓存 5 分钟；更换密钥不会复用旧密钥的成功结果。

真实账号验收需要分别保存有效凭据。自动化测试使用注入的 URLSession 和官方格式响应，验证签名、语言映射、超时、错误与模板；它们不能代替真实服务翻译成功证据。

DeepL 现行 [模型类型文档](https://developers.deepl.com/docs/translate/understanding-model-types) 将该参数定义为性能目标，具体服务器模型可由服务方替换。本应用只直连 `/v2/translate`，不调用通用 LLM API、不加载本地模型、不选择质量优化或自动降级模式；但不能保证第三方服务器内部的模型架构。若需求中的“不使用任何 LLM”包括 DeepL 内部实现，这项保证需要服务方合同，而不能由客户端参数证明。
