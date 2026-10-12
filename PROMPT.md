# niko-shot — 从零到一完整实现规格书（给 AI 编码代理的 Prompt）

> 你是一名资深 macOS 平台工程师。你的任务是在空目录中从零实现 **niko-shot**：一个原生 Swift 编写的、全面超越 iShot Pro 的 macOS 截图 / 录屏 / OCR / 翻译 / 滚动长截图工具。本文件是唯一需求来源（single source of truth）。
>
> **重要**：文中 §4 的 B0–B9 是**构建顺序**（反映依赖关系），**不是优先级**。所有功能全部为必交付（P0），任何一个 B 阶段的功能都不允许裁剪、降级或移出交付范围。请按顺序实现，每个阶段结束时必须能通过 `xcodebuild` 干净构建并通过该阶段验收标准，然后再进入下一个。

---

## 0. 角色与工作方式

- 你独立工作，不要向用户提问；本文件未覆盖的细节按"更简单、更原生、更省资源"的原则自行决策，并在 commit message 中记录决策理由。
- **按构建阶段交付**：每个阶段 = 一批实现 + 构建 + 自测 + git commit。禁止跳阶段，禁止在关键路径留 `TODO()` 占位代码。
- 每个文件顶部用简短注释说明职责；公开 API 写 DocC 注释；统一 Swift 6 严格并发（`-swift-version 6`），确有困难处用 `@preconcurrency` 局部降级并注释原因。
- 禁止 force unwrap；禁止 `DispatchQueue.global()` 混用 async/await（统一 Swift Concurrency）；禁止主线程做像素级图像处理。

## 1. 产品定位与差异化

**一句话**：一个菜单栏常驻、键盘优先、性能极致的原生截图工具，覆盖 截图 → 标注 → OCR → 翻译（百度/Google/有道/DeepL/自定义 REST API Key 直连）→ 贴图/保存 → 录屏 → GIF → 滚动长截图 全链路。

对标 iShot Pro（逆向分析结论见附录 A），必须在四个维度全面胜出：

| 维度 | iShot Pro 现状（逆向实测） | niko-shot 目标 |
|---|---|---|
| 安装包体积 | ~300MB（捆绑双架构 ffmpeg + 全套 codec） | **< 15MB**，零第三方二进制 |
| 空闲资源 | 常驻 100MB+，含登录 Helper 进程 | **单进程，空闲 RSS < 40MB，CPU 0%**（无轮询，纯事件驱动） |
| 翻译 | WebView 内嵌翻译网页（体验差、无法配 key） | **原生 UI + 四大翻译服务 API Key 直连 + 自定义 REST 适配**，全部必做 |
| 功能生态 | 无 Shortcuts / 无 CLI / 滚动截图粗糙 | App Intents + URL Scheme + CLI 三入口；自动滚动长截图为完整功能 |

## 2. 硬性约束

1. **最低支持 macOS 14.0 (Sonoma)**。允许用 `#available(macOS 15, *)` 做体验增强，但 14.0 必须功能完整。
2. 100% 原生：Swift 6 + AppKit/SwiftUI + 系统框架。**禁止**：Electron/WebView 做任何 UI、捆绑 ffmpeg 或任何第三方二进制。构建期工具仅允许 XcodeGen；运行时零第三方依赖（SQLite 直接用系统 libsqlite3，加密哈希用 CryptoKit/CommonCrypto）。
3. 分发方式：Developer ID 直接分发（非沙盒）。
4. Bundle ID：`com.n1ko.niko-shot`；App 名 `niko-shot`；菜单栏图标 SF Symbols `camera.viewfinder`。
5. 工程用 **XcodeGen** 管理（`project.yml`），从干净克隆两步构建：`xcodegen generate && xcodebuild -scheme niko-shot -configuration Debug build`。

## 3. 工程结构

```
niko-shot/
  project.yml                  # XcodeGen 定义
  README.md                    # 构建/使用/架构说明 + 性能实测表
  niko-shot/
    App/
      AppDelegate.swift        # NSApplication 生命周期、菜单栏、DI 组装
      MainMenuExtra.swift      # NSStatusItem 菜单（最近截图缩略图 + 功能 grid）
    Core/
      Capture/
        CaptureEngine.swift    # ScreenCaptureKit 静态截图（SCScreenshotManager）
        WindowList.swift       # SCShareableContent 窗口枚举、过滤、命中检测
        CoordinateSpace.swift  # 全局坐标换算（§5.4，最重要工具类）
        FreezeFrameStore.swift # 冻结帧缓存（每屏一张 CGImage + 元数据）
      Overlay/
        SelectionSession.swift # 一次截图会话状态机（结束必须零残留）
        OverlayWindow.swift    # 无边框覆盖窗
        SelectionView.swift    # 选区交互 + 窗口高亮 + 尺寸徽标 + 放大镜
        ToolbarController.swift# 截图 HUD 工具条（浮动胶囊）
      Annotation/
        AnnotationDocument.swift # Codable 命令列表 = 唯一数据源（undo/redo 基础）
        Tools/                  # Rect/Ellipse/Arrow/Line/Pen/Text/Mosaic/Blur/Highlight/Step
        AnnotationRenderer.swift # 把 Document 渲染到 CGContext（可任意倍率重渲染导出）
      Output/
        Exporters.swift        # PNG/JPEG/HEIF/TIFF (ImageIO)；GIF 见 Recording
        ClipboardWriter.swift  # NSPasteboard（PNG+TIFF+文件承诺）
        DragExporter.swift     # NSFilePromiseProvider 拖拽出图
        SavePanelRouter.swift
      Recording/
        RecordingSession.swift # SCStream → AVAssetWriter（H.264/HEVC，暂停/恢复）
        AudioRouter.swift      # 系统音频(SCStream) + 可选麦克风混流
        GifExporter.swift      # AVAssetReader → ImageIO GIF（自带调色板，无 ffmpeg）
      OCR/
        OCREngine.swift        # Vision VNRecognizeTextRequest，逐块文本 + boundingBox
      Translate/
        TranslationService.swift # 协议 + Language 枚举 + 各家语言码映射 + 错误类型
        Providers/
          BaiduProvider.swift    # 百度翻译开放平台
          GoogleProvider.swift   # Google Cloud Translation v2 (API Key)
          YoudaoProvider.swift   # 有道智云文本翻译
          DeepLProvider.swift    # DeepL API (free/pro)
          CustomRESTProvider.swift # 用户自定义 REST 模板适配（通用 AK 兼容层）
        TranslationRouter.swift  # 当前 provider 选择/持久化（无优先级、无自动降级）
      Pin/
        PinWindowManager.swift # 贴图窗口（置顶、缩放、透明度、拖拽、双击关闭）
      Scroll/
        ScrollCaptureSession.swift # 自动滚动（默认）/手动滚动 双模式
        AutoScroller.swift        # CGEvent 派发滚动事件（需辅助功能，向导引导）
        Stitcher.swift            # 重叠区归一化互相关拼接（vDSP）
      History/
        HistoryStore.swift     # SQLite（sqlite3 C API）：记录、OCR 全文索引(FTS5)、缩略图
      Hotkey/
        HotkeyCenter.swift     # Carbon RegisterEventHotKey 封装（无需任何权限）
      Settings/
        AppSettings.swift      # UserDefaults(@AppStorage) + Keychain（所有 API 密钥）
      Intents/
        CaptureIntents.swift   # App Intents（Shortcuts）
      Utilities/ (Color, Image, Log, LaunchAtLogin[SMAppService], PermissionWizard…)
    UI/                        # 全部 SwiftUI
      SettingsView.swift       # 系统设置风格：侧栏 + 分区表单
      HistoryView.swift
      OCRView.swift            # OCR 结果 + 翻译侧栏
      PinLibraryView.swift
    Resources/
      Info.plist 模板 / Assets
  Tests/
    CoordinateSpaceTests / StitcherTests / ExportersTests / AnnotationDocumentTests
    ProviderSigningTests / LanguageCodeMappingTests / ProviderResponseParsingTests
    HistoryStoreTests / GifExporterTests …
```

**UI 分工**：覆盖窗/标注画布/贴图窗用 AppKit+CALayer（性能、120Hz）；设置/历史/OCR/翻译 UI 用 SwiftUI。

## 4. 构建顺序（全部必交付，顺序仅代表依赖）

| # | 内容 | 验收核心 |
|---|---|---|
| B0 | 工程骨架：XcodeGen、菜单栏、设置窗口壳、HotkeyCenter | 冷启动 <0.5s 出菜单栏；热键注册与冲突提示 |
| B1 | 区域截图端到端：冻结帧覆盖窗、拖框、Enter 复制、Esc 取消、Retina/多屏正确 | 副屏+Retina 像素级正确；导出 2x |
| B2 | 窗口智能识别高亮（hover + Space 循环层叠）、延时截图、上次区域、取色器、放大镜、预设尺寸 | 窗口高亮无闪烁；Space 穿透重叠窗口 |
| B3 | 标注编辑器全工具 + undo/redo + HUD 工具条 | 命令式 Document，任意倍率重渲染导出一致 |
| B4 | 输出系统：格式选择、剪贴板多类型、拖拽出图、贴图+贴图库、历史(SQLite+FTS5) | 历史可搜索（联动 OCR 文本回填） |
| B5 | OCR：逐块结果、块级编辑/勾选/复制、中文标点转换、历史重 OCR | 中英日混排准确；自动 OCR 供历史检索 |
| B6 | 翻译子系统：百度/Google/有道/DeepL/自定义 REST **五家全做** + 设置密钥管理 + OCR→翻译 UI | 五家各自真连通；签名与语言码映射有单测向量 |
| B7 | 录屏：区域/窗口/全屏、系统音频+可选麦克风、暂停恢复、MP4；GIF 导出 | 1080p30 录制 CPU <8%；GIF 循环正常 |
| B8 | 滚动长截图：自动滚动（默认）+ 手动模式、拼接、去重到底检测 | 常见页面接缝 ≤1px；拒绝辅助功能时手动模式可用 |
| B9 | App Intents + URL Scheme + CLI、开机启动(SMAppService)、首跑权限向导、性能冲刺、无障碍、README | §9 性能预算逐项实测达标 |

## 5. 核心架构（必须遵守）

### 5.1 冻结帧模式（Freeze-Frame Overlay）—— 交互基石

这是 iShot 逆向确认的核心模式，必须采用：

1. 热键触发 → `CaptureEngine` 用 **`SCScreenshotManager.captureImage(contentFilter:configuration:)`** 为**每个屏幕各拍一张冻结帧**，连同屏幕 frame/backingScaleFactor 存入 `FreezeFrameStore`。
2. 为每屏创建无边框 `NSWindow`（`level = .screenSaver`，`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`，`backgroundColor = .clear`，`isOpaque = false`），内容视图铺满冻结帧，**选区/高亮/标注全部画在这张图上**。
3. 确认后**直接从冻结帧裁剪**出结果——绝不二次截屏（避免闪烁、避免拍进自己的 overlay、避免 TCC 二次弹窗）。
4. 会话 = 状态机：`idle → frozen → selecting → selected → annotating → exporting`；`SelectionSession` 持全部状态，结束（完成/取消）后彻底销毁全部窗口与监听（移除 event monitor、关窗、清引用——iShot 逆向发现它有监听器泄漏的坑，我们必须零残留，并用单测断言销毁）。

### 5.2 事件模型

- 全局热键：Carbon `RegisterEventHotKey`（**不需要任何系统权限**）。设置界面自绘录制控件。
- 覆盖窗内：重写 mouseDown/dragged/moved/up、keyDown、flagsChanged、scrollWheel + `NSEvent.addLocalMonitorForEvents` 兜底。**禁止 CGEventTap 做全局监听**（避免"输入监控"权限；唯一例外：B8 自动滚动**派发**滚动事件用 `CGEventCreateScrollWheelEvent` + `CGEventPost`，那需要辅助功能授权，见 §7）。
- 跨模块通信用 `AsyncStream` / `NotificationCenter`；AppKit 对象 `@MainActor`；图像像素处理在 `Task.detached` 传 `CGImage` 值。

### 5.3 捕获引擎

- 静态截图：`SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display:excludingApplications:exceptingWindows:), configuration:)`；窗口截图 `SCContentFilter(desktopIndependentWindow:)`；`SCStreamConfiguration` 设 `pixelScaleFactor` 匹配目标屏、`showsCursor = false`。
- 窗口列表：`SCShareableContent.excludingDesktopWindows(false) onScreenWindowsOnly: true)`；过滤自身进程（`owningApplication?.bundleIdentifier`）；缓存 3 秒惰性刷新。
- 录屏：`SCStream` + `addStreamOutput` → CMSampleBuffer → `AVAssetWriter`；`capturesAudio = true` + `excludesCurrentProcessAudio = true`；暂停/恢复 = 丢帧 + `CMTime` 基准平移。

### 5.4 CoordinateSpace 工具类（最高优先级正确性）

三套坐标并存是截图工具 bug 之源，集中到一个测试覆盖的工具类：

- AppKit `NSScreen.frame`：原点**左下**，单位 point；
- `SCWindow.frame` / CGWindow bounds：原点**左上**，point（含多屏全局偏移）；
- 冻结帧像素：原点左上，pixel = point × backingScaleFactor。

API：`globalPointToScreenLocal` / `screenLocalToImagePixel` / `imagePixelRect(fromSelection:)` / `flippedY`。多屏混合 DPI 逐屏换算，禁止全局假设。XCTest 覆盖：单屏 2x、双屏异 scale、副屏在主屏左侧/上方、刘海屏。

### 5.5 标注数据模型

```swift
protocol AnnotationCommand: Codable, Equatable { var id: UUID; var color: AnnotationColor }
// Rect / Ellipse / Arrow / Line / Pen(points: [CGPoint]) / Text(字体快照随 Document 序列化)
// Mosaic(region) / Blur(region) / Highlight(region) / Step(number, at:)
```

`AnnotationDocument { var commands: [AnnotationCommand] }` 唯一数据源；undo/redo = 数组快照栈；**导出时同一渲染器按目标倍率离屏重画**，预览与导出像素一致。马赛克 = `CITilePixellate`，模糊 = `CIGaussianBlur`，按 stroke path 裁剪。

## 6. 功能规格（全部必交付）

### 6.1 截图交互（B1–B2）

- 拖框：8 向手柄 + 边缘命中 + Shift 锁比例 + Option 中心缩放；尺寸徽标 `W × H`（point/像素可切）。
- 窗口识别：hover 高亮 1px 描边 + 外发光；`Space` 在光标处层叠窗口间循环（超越点：iShot 无循环穿透）。
- 放大镜 loupe：像素级放大 + 颜色 + `#RRGGBB`，`⌥C` 复制色值。
- 预设尺寸列表（可自定义），框选后直接输入数字改 W/H。
- 延时截图 1–10s 环形倒计时；重复上次区域。
- 快捷键（全可改，默认）：截区域 `⇧⌘A`、截窗口 `⇧⌘W`、全屏 `⇧⌘F`、重复上次 `⇧⌘R`、录屏 `⇧⌘V`、OCR `⇧⌘O`、滚动长截图 `⇧⌘L`、贴图历史 `⇧⌘P`。
- 会话内键位：`Enter` 复制、`⌘S` 保存、`Esc` 取消、`⌘Z/⌘⇧Z` 撤销重做、`Tab` 切换框选/标注、方向键微调 1px（Shift=10px）、`1–9` 切工具。

### 6.2 输出（B4）

- 格式：PNG（默认带 alpha）、JPEG（质量滑杆）、HEIF、TIFF。（WebP 编码系统 API 不支持，写入已知限制。）
- 剪贴板多类型：PNG + TIFF + 文件承诺（拖进 Finder/聊天软件直接出图）。
- 文件名模板：`niko-shot {date} {time}.png`，`{n}` 递增可配。
- 贴图：置顶小窗、双指缩放、滚轮透明度、双击关闭、`⌥⌘T` 全部显隐；贴图库网格。
- 历史：SQLite 表 `captures(id, created_at, path, thumbnail, width, height, app_bundleid, capture_kind, ocr_text)`；OCR 后回填 `ocr_text` 建 FTS5（中文分词用内置 simple/unicode61，测试覆盖中文搜索）；列表虚拟化 + 拖出 + 删除 + 重 OCR。

### 6.3 翻译子系统（B6，招牌功能，五家全做、无优先级）

**总则**：
- 不使用任何 LLM/模型，不做 WebView。全部为**经典翻译服务 REST API + API Key 直连**。
- 五个 provider 全部实现，**彼此平级**：用户在设置里各自填密钥、各自测试，然后选择一个作为"当前翻译服务"。**没有优先级链、没有自动降级**——失败就显示该家的原始错误码与信息，由用户切换。
- 所有密钥进 Keychain（`kSecClassGenericPassword`, service=`com.n1ko.niko-shot`），设置页 `••••` 显示 + 复制按钮，不回显明文。
- 统一协议：

```swift
protocol TranslationService {
  var id: TranslationProviderID { get }        // .baidu / .google / .youdao / .deepl / .custom
  var displayName: String { get }
  func credentialsStatus() -> CredentialsStatus // .unconfigured / .ready
  func translate(_ request: TranslationRequest) async throws -> TranslationResult
}
struct TranslationRequest { let text: String; let source: Language?; let target: Language }
struct TranslationResult { let text: String; let detectedSource: Language?; let rawProviderInfo: String? }
enum TranslationError: Error { case http(Int, String); case provider(code: String, message: String); case decode; case unconfigured; case cancelled }
```

- **语言码映射**是正确性重点：内部用规范 `Language` 枚举（简中/繁中/英/日/韩/法/德/西/葡/俄/意/泰/阿拉伯/越 等 ≥14 种），每个 provider 一张映射表，**必须单测**：

| Language | Baidu | Google | Youdao | DeepL |
|---|---|---|---|---|
| 简体中文 | zh | zh-CN | zh-CHS | ZH |
| 繁体中文 | cht | zh-TW | zh-CHT | —（映射到 ZH-HANT） |
| 英语 | en | en | en | EN |
| 日语 | jp | ja | ja | JA |
| 韩语 | kor | ko | ko | KO |
| 法/德/西/葡/俄/意… | fra/de/spa/pt/ru/it… | fr/de/es/pt/ru/it… | fr/de/es/pt/ru/it… | FR/DE/ES/PT/RU/IT… |
| 自动检测 | auto | 省略 source | auto | 省略 source_lang |

（各家剩余语种照官方文档补全映射表；DeepL 繁中用 `ZH-HANT`；不支持的组合在 UI 置灰并提示原因。）

**五家 Provider 实现规格**（签名算法逐字实现，配套 `ProviderSigningTests` 用官方文档示例向量）：

1. **BaiduProvider — 百度翻译开放平台**
   - Endpoint：`POST https://fanyi-api.baidu.com/api/trans/vip/translate`，`application/x-www-form-urlencoded`。
   - 参数：`q`（原文 UTF-8 URL 编码，可含 `\n`，多行返回多条结果）、`from`、`to`、`appid`、`salt`（随机数）、`sign`。
   - **签名**：`sign = MD5(appid + q + salt + 密钥)` 的小写十六进制；`q` 参与 MD5 时用**原始未编码 UTF-8 字节**。
   - 响应：`{"from":…,"to":…,"trans_result":[{"src":…,"dst":…},…]}` → 用 `\n` join `dst`；错误码 `error_code/error_msg` 原样透传（如 54003 签名错、58002/58003 并发与流量限制——429/限流时 UI 直接显示百度错误码）。
2. **GoogleProvider — Google Cloud Translation API v2 (API Key)**
   - Endpoint：`POST https://translation.googleapis.com/language/translate/v2?key={API_KEY}`，JSON body `{"q": text, "target": "zh-CN", "source": "en"(可选，省略即自动检测), "format": "text"}`。
   - 响应：`data.translations[0].translatedText`；`detectedSourceLanguage` 为检测源。
   - 错误：HTTP 403（key 无效/未启用 API）、429（配额）→ 展示 Google 返回的 `error.message`。
3. **YoudaoProvider — 有道智云文本翻译**
   - Endpoint：`POST https://openapi.youdao.com/api`，form-urlencoded。
   - 参数：`q`、`from`、`to`（如 `auto`→`zh-CHS`）、`appKey`、`salt`、`signType=v3`、`curtime`（Unix 秒）、`sign`。
   - **签名**：`input = q.count ≤ 20 ? q : (q 前 10 字符 + String(q 字符总数) + q 后 10 字符)`；`sign = SHA256(appKey + input + salt + curtime + appSecret)` 小写十六进制。
   - 响应：`{"errorCode":"0","translation":["…"]}`；errorCode ≠ "0" 时透传码表（如 108 应用 ID 无效、110 无权限、205/206 签名/服务异常、111 并发限制）。
4. **DeepLProvider**
   - Key 以 `:fx` 结尾 → `https://api-free.deepl.com/v2/translate`，否则 `https://api.deepl.com/v2/translate`。
   - Header：`Authorization: DeepL-Auth-Key {KEY}`；JSON body `{"text":[text],"target_lang":"ZH"}`（`source_lang` 可选）。
   - 响应：`translations[0].text` / `detect_source`。
5. **CustomRESTProvider — 通用 AK 兼容适配层**（让任何"填 AK 的翻译服务"都能接入）
   - 用户配置：名称、Method+URL 模板、Header 模板（值可含 `$KEY`）、Body 模板（JSON 或 form，占位符 `$TEXT` `$SOURCE` `$TARGET`）、响应提取路径（点分 JSON 路径，如 `data.trans_result.0.dst` 或 `translations.0.text`）。
   - $KEY 存 Keychain；请求前做占位符替换 + URL 编码；响应按路径提取字符串；HTTP 非 2xx 显示状态码 + body 前 200 字符。
   - 提供两份内置预填模板（如彩云/腾讯机器翻译的参数格式示例）供一键创建。

**网络与稳健性**：统一 `URLSession` 注入（可 mock 测试）；每家超时 15s；`async let` 并发不受限；不做任何自动重试/自动切换（无优先级原则），仅展示错误。同一文本 5 分钟内存缓存（per provider+语言对）。

**UI**：OCR 窗口右栏 原文/译文并排；顶部"当前服务"下拉（五家 + 自定义实例）+ 语言对选择（默认 自动检测→简体中文，可锁）；"翻译"按钮 + OCR 完成自动翻译开关（默认开）；译文一键复制；错误行内显示 `[百度 error_code 54003] 签名错误` 样式。设置页每家一张卡片：密钥输入、状态灯、**"测试连接"**按钮（翻一句 "Hello, world!" → zh，行内显示成功/失败详情）。

### 6.4 OCR（B5）

- `VNRecognizeTextRequest`：`recognitionLevel = .accurate`（可切 fast），`recognitionLanguages = ["zh-Hans","en-US","ja-JP"]` 可配，`usesLanguageCorrection = true`。
- 逐行块结果：每块可勾选/编辑/复制；支持合并段落、去多余换行、中文标点转英文。
- 历史条目可重 OCR；设置"自动 OCR 供历史搜索"开关（默认开，异步低优先级队列）。

### 6.5 录屏与 GIF（B7）

- 区域/窗口/全屏；悬浮控制条（时长、暂停、停止、取消、可选摄像头画中画窗）；3 秒倒计时。
- `SCStreamConfiguration`：帧率预设 15/24/30/60（`minimumFrameInterval`）、`queueDepth = 3`、`capturesAudio = true`（系统音频）、麦克风可选、`excludesCurrentProcessAudio = true`、`showsCursor` 可设置。
- 编码 HEVC 默认 / H.264 兼容；码率 = 质量预设 × 分辨率计算。
- **GIF 零 ffmpeg**：`AVAssetReader` 逐帧 → 用户 FPS 抽帧 → ImageIO `CGImageDestination`（GIF，帧延迟来自 PTS，`loopCount = 0`，全局 256 色调色板）；默认宽度 ≤800px 控制体积，UI 显示预估体积。
- 完成通知中心提醒 + 保存面板。

### 6.6 滚动长截图（B8，必交付，自动滚动为默认模式）

- 流程：框选滚动区域 → 模式确认（默认**自动滚动**，可选手动）→ 首屏捕获 → 滚动 → 逐帧捕获 → 到底检测 → 拼接 → 预览/标注/输出（复用标注编辑器）。
- **AutoScroller**：`CGEventCreateScrollWheelEvent` + `CGEventPost` 派发步进滚动（需**辅助功能**授权，首跑向导/触发时引导，含"打开系统设置 > 隐私 > 辅助功能"深链；用户拒绝则自动落到手动模式并在 UI 说明）。滚动节奏自适应：捕获线程就绪才发下一滚动事件（信号量驱动），并监听 `CGEventTapCreateForPid`?——不需要：用捕获帧差分判断页面是否停止滚动后再取帧，避免运动模糊/半滚动帧。
- **Stitcher**：相邻帧估计重叠 80–200px；重叠区归一化互相关（`vDSP` 粗搜 + 金字塔细化）求偏移；首尾帧间内容差值 < 阈值 → "已到底"自动停止；固定头部/底部（浏览器工具栏）允许用户框选忽略区自动裁掉；结果接缝 ≤1px。
- 失败降级：相关系数低于阈值暂停并询问；手动模式 = 用户自己滚，App 检测稳定即拍。
- 拼接在后台线程，长图分块写入避免内存峰值（按 5000px 高度分块落盘，最终按行流式写出 PNG）。

### 6.7 自动化入口（B9）

- **App Intents**：`CaptureRegionIntent` / `CaptureWindowIntent` / `StartRecordingIntent` / `ScrollCaptureIntent` / `LastOCRTextIntent`，参数支持延时/输出路径/是否自动 OCR。
- **URL Scheme**：`niko-shot://capture?type=region&delay=2`、`niko-shot://record?format=gif`、`niko-shot://scroll`。
- **CLI**：主二进制识别 `CommandLine.arguments` headless 路径（通过 URL Scheme/DistributedNotificationCenter 唤起常驻进程执行）：`niko capture --region --output ~/Desktop/s.png`、`niko ocr --clipboard`（截图→OCR→文本进剪贴板）、`niko translate --to zh`（取剪贴板文本→当前 provider 翻译→写回剪贴板）。提供 `niko` 安装脚本（`/usr/local/bin` 可选）。

## 7. 权限模型（比 iShot 少要一项常驻权限）

| 权限 | 需要？ | 用途 / 规避手段 |
|---|---|---|
| 屏幕录制 (TCC) | ✅ 必需 | ScreenCaptureKit 首次调用自动弹；`CGPreflightScreenCaptureAccess` 检测 + `CGRequestScreenCaptureAccess` 触发 + 设置深链 |
| 辅助功能 | 仅自动滚动模式需要 | `AXIsProcessTrusted` 检测；拒绝则自动落手动滚动模式（功能不缺失） |
| 麦克风 | 仅录屏开麦克风时 | 按需 |
| 输入监控 | ❌ 永不 | 不做 CGEventTap 全局监听（iShot 因此要这项，我们不要） |
| 通知 | 可选 | 录屏/长截图完成提醒 |

首跑向导 3 步：欢迎 → 屏幕录制授权（深链 `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`）→ 试截一张示例图 + 说明滚动长截图的辅助功能授权入口。

## 8. UI / UX 设计规范

**设计语言**："Pro Minimal"——深色 HUD 玻璃 + 精确键盘流 + 物理感动画。参照气质（不抄像素）：系统截图工具的克制 + Raycast 的顺滑 + Linear 的精致。

- **材质**：HUD 工具条/徽标 `NSVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)`；设置 `.sidebar`；全支持深/浅色 + AccentColor。
- **工具条**：截图确认后的浮动胶囊，自动在选区外上/下/左/右择优贴靠；SF Symbols 图标、44pt 命中区、分组细分隔线；hover `scale 1.06` + spring(stiffness: 400, damping: 30)；进入 150ms spring 浮现、退出 100ms crossfade。
- **字体**：SF Pro；数字 `monospacedDigit` 防跳动。
- **动画基线**：一切 UI 动画 100–200ms；`NSHapticFeedbackManager`（工具切换/拖拽吸附）；尊重"减少动态效果"（`NSWorkspace.accessibilityDisplayShouldReduceMotion`）。
- **光标**：框选 crosshair、手柄 resize、文本 I-beam、马赛克 crosshair+预览圆。
- **无障碍**：全部控件 `accessibilityLabel`；覆盖窗 VoiceOver 可朗读选区尺寸；纯键盘走完 截图→标注→保存。
- **设置窗**：`NavigationSplitView` 侧栏：通用 / 热键 / 截图 / 标注 / 输出 / OCR 与翻译（五家 provider 卡片 + 当前服务选择）/ 录屏 / 历史 / 关于。热键行内录制；provider 卡片"测试连接"结果行内反馈，不用 alert 打断。
- **菜单栏下拉**：最近 3 次截图缩略横滑 + 功能 grid + 设置入口。

## 9. 性能预算（B9 验收逐项实测，写进 README 表格）

| 指标 | 预算 | 测量方法 |
|---|---|---|
| 冷启动 → 菜单栏可用 | < 400ms | signpost / Instruments |
| 空闲 RSS | < 40MB | Activity Monitor |
| 空闲 CPU | 0%（无定时器轮询） | Instruments Time Sampler |
| 热键 → 冻结帧上屏 | < 120ms（4K < 200ms） | signpost |
| 框选交互 | 稳定 ProMotion 120fps | CADisplayLink 统计 |
| 常驻进程数 | 1（登录启动 SMAppService，无 Helper） | `ps` |
| 安装包 | < 15MB | du |
| 1080p30 录屏 CPU | < 8%（Apple Silicon） | `top` |
| 10000px 长图拼接内存峰值 | < 500MB | Instruments Allocations |
| 退出后残留 | 0 窗口 0 监听 0 定时器 | 手动 + 单测断言 session 销毁 |

实现要点：进入标注阶段后冻结帧按选区裁剪驻留（释放全屏大图）；窗口列表缓存 + 失效策略；缩略图 `CGImageSourceCreateThumbnailAtIndex` 下采样；历史虚拟化（LazyVStack + 分页 SQL）；长图分块处理。

## 10. 已知坑清单（每条显式处理 + 测试覆盖）

1. **坐标三套并存** → CoordinateSpace + 专项单测（§5.4）。
2. **Retina/多屏混合 DPI**：导出尺寸 = point × 目标屏 backingScale；跨屏拖选禁止（锁定起始屏）。
3. **刘海屏**：预设尺寸避开 `safeAreaInsets`；尺寸徽标不落刘海。
4. **SCScreenshotManager 拒权**：API 只返回错误不弹窗——必须 `CGPreflightScreenCaptureAccess` 主动检测引导，否则用户只看到黑图。
5. **全屏 Space**：overlay 必须 `.canJoinAllSpaces + .fullScreenAuxiliary`（iShot 同款坑）。
6. **自身窗口/声音污染**：窗口列表过滤自身 bundle id；录制 `excludesCurrentProcessAudio`。
7. **ProMotion**：overlay 避免 `drawRect:` 同步绘制掉帧，用 layer + displaylink。
8. **翻译签名**：百度 MD5 对**原始 q**（非 URL 编码）计算；有道 input 的"前10+长度+后10"截断规则；两家全部写死向量测试。
9. **翻译语种不全**：某家不支持某语言 → UI 置灰并说明，不发请求。
10. **GIF 体积**：默认 ≤800px + 抽帧 + 全局调色板 + 预估体积显示。
11. **滚动拼接**：运动中不取帧（帧差分稳定判定）；固定头/尾忽略区；分块写盘防爆内存。
12. **Keychain**：全部密钥入 Keychain 不回显；导出/备份提供"显示明文"需二次确认。
13. **Swift 6 并发**：SCStream 回调专用 queue → `AsyncStream` 桥接；CMSampleBuffer 不跨 actor 带状态。
14. **热键冲突**：注册失败标红提示并建议替代键。
15. **URLSession 可注入**：所有 provider 依赖注入 session，测试用 `URLProtocol` mock 官方响应样例。

## 11. 测试与验收

- **单元测试**（`xcodebuild test` 必绿）：
  - `CoordinateSpaceTests`：单屏 2x / 双屏异 scale / 副屏各方位 / 刘海。
  - `AnnotationDocumentTests`：序列化、undo/redo、字体快照。
  - `ExportersTests`：像素尺寸、alpha、EXIF 时间。
  - `ProviderSigningTests`：百度 MD5（官方示例 appid/q/salt/key → 期望 sign）、有道 SHA256（含 ≤20 与 >20 两种 input 截断）、DeepL key 类型→endpoint 选择。
  - `LanguageCodeMappingTests`：Language × 五家映射表完整性与不支持项标记。
  - `ProviderResponseParsingTests`：五家成功/错误响应 JSON 样例解析（含百度 54003、有道 errorCode≠0、Google 403 body）。
  - `CustomRESTProviderTests`：占位符替换、JSON 路径提取、$KEY 注入。
  - `StitcherTests`：合成平移序列（纯色+噪声纹理）亚像素级对齐；到底检测。
  - `HistoryStoreTests`：FTS5 中文搜索、分页。
  - `GifExporterTests`：帧延迟、循环标志、调色板大小。
  - `SelectionSessionTests`：会话销毁后零窗口/零监听断言。
- **手测清单**（每阶段 commit 描述打勾）：双屏异 DPI 各模式像素正确；全屏 App 截图；Esc 全路径退出无残留；深浅色切换；拔插屏会话安全退出；2 小时空闲 RSS 无增长；五家翻译真连通截图（百度/有道用自己的测试账号，Google/DeepL 用 mock+可选真连）；VoiceOver 走查设置页。
- **DoD（总）**：干净克隆 → `xcodegen generate` → `xcodebuild build` & `test` 全绿；README 含构建说明、架构图（mermaid）、性能实测表、快捷键表、五家翻译配置指南；§9 全达标；关键路径无 TODO/FIXME。

## 12. 交付节奏

按 §4 B0→B9 顺序，每阶段循环：实现 → 构建 → 自测 → `git commit`（conventional commits，如 `feat(b6): youdao v3 sha256 signing provider`）。规格未定细节选更原生/更省资源方案并在 commit body 记录。全部完成后输出总结：功能清单、性能实测表、五家翻译配置说明、已知限制（WebP 编码暂缺等）、后续路线图。

---

## 附录 A：iShot Pro 2.5.8 逆向结论摘要（设计情报）

- **交互核心 = 冻结帧模式**：先拍全屏 → 无边框窗显示冻结图 → 交互画在图上 → 从冻结帧裁剪（§5.1 继承）。
- 选区三层 `CAShapeLayer` + 尺寸指示；窗口识别 = 鼠标位置 + `CGWindowListCopyWindowInfo` 命中测试；macOS 15+ 才弱链接 ScreenCaptureKit（"性能模式"）——我们 14 起步全 `SCScreenshotManager` 单引擎。
- 录屏 = `AVCaptureSession + AVCaptureScreenInput` + `AVAssetWriter`；GIF = 捆绑 ffmpeg 二次转码（300MB 包体元凶）——我们 SCStream + 原生 GIF 替代。
- OCR = Vision `VNRecognizeTextRequest` 标准用法；翻译 = WebView 套翻译网页——我们原生五家 AK 直连。
- 热键 = Carbon（PTHotKey）+ CGEventTap（所以要输入监控权限）；登录启动靠 Helper.app——我们 Carbon + SMAppService 单进程。
- 标注工具全集（对标）：矩形/椭圆/直线/箭头/画笔/马赛克/文字/便签/高亮/放大镜/序号/滚动截图/撤销重做/贴图——本规格全含。
- 它的坑别踩：事件监听器泄漏、双引擎状态分裂、沙盒书签补丁一堆。

## 附录 B：术语表

- 冻结帧 Freeze Frame：触发瞬间拍下的全屏静态图，会话期间的唯一"世界"。
- 会话 Session：热键触发到输出/取消的完整生命周期，结束必须零残留。
- Provider：翻译服务适配器（百度/Google/有道/DeepL/自定义 REST），彼此平级，用户单选当前服务。
- AK：API Key/密钥（含百度 appid+密钥、有道 appKey+appSecret、Google API Key、DeepL Auth Key、自定义服务的 `$KEY`）。
