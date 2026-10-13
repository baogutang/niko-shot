# 验收记录

唯一功能来源：[PROMPT.md](../PROMPT.md)。全部 B0–B9 保持必交付。

构建与自动测试使用 `scripts/verify.sh Bn`；完整原始日志保存在 `build/evidence`。
自动测试、实机交互、账号连通和性能采样分开记录。构建成功不等于产品验收通过。

## 2026-10-13 · 0.1.2 安装修复

用户安装 0.1.1 后反馈：鼠标框选后看不到底部按钮，打开菜单时应用退出。本轮先复核实际安装副本与系统崩溃报告，再针对根因修复。

- 工具栏被覆盖：`NSPanel.isFloatingPanel` 的赋值会把已经设置的截图层级重置为普通浮窗层级 3，而选区遮罩为 1000。将浮窗标志移到自定义层级设置之前。新增真实 `NSEvent` 鼠标拖选回归首先在旧实现失败，修复后检查全部 23 个工具与操作、44pt 点击区域、显示透明度、工具栏高于遮罩，以及 OCR 输出和原选区长截图交接。
- 菜单绘制崩溃：安装版的三份 `EXC_BREAKPOINT` 报告指向 `com.apple.SwiftUI.DisplayLink` 上的 Swift 执行器断言。对实际安装的 0.1.1 二进制定位到 `NativeTheme.swift:30` 的动态颜色回调；此前它继承了 MainActor，而 AppKit/SwiftUI 会在后台绘制线程解析颜色。回调改为 Sendable，构造方法明确 nonisolated，继续保留系统浅深色与对比度适配。新增后台真实线程测试覆盖整套主题的 42 次解析，没有把解析强制转回主线程来掩盖问题。
- 界面整理：菜单主操作、功能网格和最近截图区收紧；设置默认 820×600、最低 780×540、侧栏 180pt，保留用户窗口尺寸；登录启动关闭显示正常的“已关闭”，权限分别展示用途、状态、设置入口与手动刷新。没有后台请求新权限或轮询。五家翻译的官方申请指南、未保存草稿和密钥操作保留。

严格 Swift 6 complete、编译警告作为错误的最终 **clean build/test：179 项通过、0 失败、0 跳过、0 编译警告**。证据为 `build/evidence/repair-0.1.2-final-tests.xcresult`、`repair-0.1.2-test-summary.json`。首次捕获工具栏层级错误的失败结果保留为 `repair-0.1.2-tests.xcresult`，未判为通过。

独立 clean universal Release 包含 arm64/x86_64、App Intents 元数据、无测试框架，签名完整性通过；本机构建应用为 7,811,573 字节，主二进制 SHA256 为 `d9842e0d0f1198f19a50990a44e9537a8b854b145f5f2db01d33157eb64255a7`。GitHub 会独立重建，公开安装包的版本、提交和哈希以候选 manifest 为准。

本机 `/Applications/niko-shot.app` 更新为该最终构建，偏好、历史与已有权限保持；原安装副本在私有 build 目录备份。通过 Computer Use 实际打开设置、翻译服务、百度三步申请指南及标准工具菜单，进程保持运行，未产生新的崩溃报告。当前系统屏幕录制为未授权，实际截图入口显示明确拒绝提示；新增授权需用户当次确认。真实屏幕鼠标拖选、底部按钮的屏幕可见性及页面长截图仍待这项确认，自动回归与离屏预览不替代实机通过。

当前源码的菜单与翻译设置合成预览同步官网；公开图不含用户桌面、历史、凭据或本机 iShot 参考素材。所有 B0–B9 继续保持 P0，旧性能失败、账号及外设验收缺口不因这次修复撤销，整体 DoD 未通过。

## 2026-10-13 · 0.1.1 历史交付

参考 Ping Island 的排版、暖琥珀重点色与紧凑界面语言，更新应用浅深色、NIKO 原创 N 字取景框标志、官网交互画布与 README。各翻译服务的三步申请、官方链接和凭据路径保留；指南生成器同步新外壳，源数据及 2026-10-13 核对日期不变。

截图底部的「长截图」为可见文字按钮。会话传递原屏幕坐标、缩放与窗口身份；关闭覆盖层并排空旧图像任务后，读取当前屏幕预览，不把已标注的冻结图片当成滚动内容。历史或导入图片说明并引导重新框选。重新选区提示使用原生窗口回调，避免同步 modal 循环阻挡异步取消；工具栏分组明确宽度，窄屏仍保留至少 44pt 点击区域。

最终严格 Swift 6 complete、编译警告作为错误的 clean build/test：**176 项通过、0 失败、0 跳过、0 编译警告**，其中 7 项覆盖文字入口、窗口身份、旧任务排空、取消与重新选区提示释放。结果为 `build/evidence/niko-0.1.1-final-tests.xcresult` 和 `niko-0.1.1-test-summary.json`。修复前的首次自动测试因发现 modal 取消阻塞而中止，记录另存，未判为通过。

独立 clean universal Release 为 **7,811,125 字节**，包含 arm64/x86_64、App Intents 元数据，无注入测试框架，签名完整性通过；主二进制 SHA256 为 `799ba0f877cae3d878247011527e902a436b3d3992bc9b1b158b889e3dad4a93`。公开安装包由 GitHub 对同一提交重新构建，具体二进制身份以后续候选 manifest 为准。官网静态检查通过：2 个页面、150 个本地引用、5 类同源翻译指南。新版界面图是公开合成数据的离屏渲染，不代表真实捕获或账号验收。

**本机清理已执行**：已退出并移除安装目录中的应用、应用数据及偏好；仅对 `com.n1ko.niko-shot` 重置全部 TCC 权限并清理钥匙串服务项，未重置其他软件。旧应用及历史数据在废纸篓可恢复；源码保留，没有重新安装或启动生产应用。按用户要求，后续真实截图、长截图、录屏及交互由用户自行验收。

完整 B0–B9 仍为 P0。历史冷启动和使用后内存预算失败不被本轮 UI 更新覆盖；真实账号、macOS 14、混合 DPI 双屏、120Hz 与外设验收未补测。候选仍为 ad hoc 签名、未 Developer ID 公证；整体 DoD 尚未通过。

2026-10-13 原生界面改版的构建、预览和接入指南记录见 [UI-REDESIGN.md](UI-REDESIGN.md)。下列 B0–B9 表格及实机证据属于改版前 B9 源码 `f6cb924`，新版没有自动继承这些实机验收结果。界面改版、翻译密钥脱敏与 OCR 漏行恢复后的最新本机回归为 **169 项、零失败、零跳过**；Swift 6 完整并发检查及编译警告作为错误的门禁通过。锁定阶段的离屏检查属于历史证据；本轮已实际检查新版窗口、历史和 OCR 操作，系统旁白开关已确认关闭，完整 VoiceOver 走查仍未完成。

源码 `ae4c656` 的发布前安全修复覆盖五类翻译服务的 HTTP 正文、服务消息/代码、失败 URL 和嵌套原生错误；新增 9 项真实 URLSession / URLProtocol 回归，成功译文和取消行为保留。严格干净构建与 166 项完整测试通过，记录在 `build/evidence/GitHub-delivery-tests.xcresult`；另有干净双架构 Release 和本机 ZIP / DMG 签名、结构、校验和验证。官网检查见 [website/QA.md](website/QA.md)，GitHub 实际发布仍需以远程任务及匿名下载为证，不能把本机打包替代远程成功。

| 阶段 | 实现 | 自动构建与测试 | 实机验收 |
|---|---|---|---|
| B0 | 已实现 | clean build + 5 tests 全绿 | Release 菜单就绪 349–381ms；原生设置热键录制、重复组合行内报错及恢复已走查；物理全局触发需另测 |
| B1 | 已实现 | clean build + 9 tests 全绿 | 双屏异 DPI、Retina、全屏空间需实机走查 |
| B2 | 已实现 | clean build + 12 tests 全绿 | 重叠窗口循环、放大镜、延时需 UI 走查 |
| B3 | 已实现 | clean build + 15 tests 全绿，全部 12 工具及原图像素方向；最终另含 8 项键盘回归 | 最终候选实际键盘循环 12 工具、原生文字/便签输入、撤销/重做、保存 2800×1896 PNG；其余 HUD 交互仍需逐项验收 |
| B4 | 已实现 | clean build + 17 tests 全绿，四格式实际编解码及中文 FTS5 | 最终贴图置顶、滚轮透明度、双击关闭、两张图库持久化已走查；Finder/聊天拖拽及物理双指缩放仍待验证 |
| B5 | 已实现 | clean build + 19 tests 全绿，真实 Vision 识别及文字整理；B9 加入 3 项混排回归 | 实际 SC 窗口 2800×1896：日文完整行从 0/13 改为 13/13，原中英前缀保留；区块操作与重 OCR 需走查 |
| B6 | 已实现 | clean build + 46 tests 全绿，五家签名/映射/请求/响应及缓存、并发、取消 | 有效账号未配置，五家真实成功连通未验证；DeepL 服务端模型架构不由客户端保证 |
| B7 | 已实现 | clean build + 64 tests 全绿；真实 HEVC/AAC 编解码、双音源混流、连续转换尾部、GIF 全局 256 色/循环/帧延迟、取消与 UI 释放 | 真实 SCStream 区域 1920×1080 MP4、HUD 暂停/继续/停止和自动化指定路径已完成；静态样本短 top CPU 4.2%，持续动态负载、物理麦克风/摄像头仍待验证 |
| B8 | 已实现 | clean build + 85 tests 全绿；80–200px NCC 偏移误差 0px，透明 PNG 全像素/CRC 校验、5000 行分块、取消/原子替换；1920×10000 编码阶段峰值 RSS 约 42MB | 真页面接缝、辅助功能拒绝后的手动交互仍需授权环境走查 |
| B9 | 已实现，总验收未通过 | 2026-10-12 23:58 最终候选 clean build + 149 tests、0 failures、0 编译警告；实际干净 Git 克隆复验通过 | 两小时 fresh idle 无增长；最终正常退出资源归零；登录启动注册/注销、五项 App Intents 发现及最近 OCR 冷/热调用已完成；冷启动及使用后 RSS 未达预算，其余外部验收未全部完成 |

2026-10-13 首次 GitHub 干净构建（`macos-15-arm64`、macOS 15.7.9 / Xcode 26.3，[运行 38300497228](https://github.com/baogutang/niko-shot/actions/runs/38300497228)）捕获中日混排真实回归：Vision 自动语言检测选中日语模型，部分简体汉字被替换。修复遵循显式启用语言并选择对应 CJK 主模型，保留全部原 fixture / 断言，补齐反向顺序及英日组合检查。本机严格干净构建与 **167 项、零失败** 通过，记录在 `build/evidence/ocr-ci-repair-tests.xcresult`；云端修复是否通过仍以后续真实运行结果为准。

2026-10-13 第二次 GitHub 全量回归（[运行 38301916447](https://github.com/baogutang/niko-shot/actions/runs/38301916447)）进一步发现中文模型会漏掉整行，辅助日语请求能够检测该行，但其汉字不准确。保留原图、原 fixture 和全部精度断言；使用原生 Han 子区间的近似几何保守扩边，再从实际裁剪识别结果中按原图空间重叠选择汉字串，保留辅助行中的英文与假名，未使用字符宽度猜测或硬编码修文。新增漏行注入与空间去重回归，本机严格干净构建与 **169 项、零失败、零跳过** 已通过，结果为 `build/evidence/ocr-han-recovery-tests.xcresult`。独立源码复核未发现阻断；[真实引擎云端诊断 38304577861](https://github.com/baogutang/niko-shot/actions/runs/38304577861) 在 macOS 15.7.9 返回完整三行，原图坐标保留。诊断不代替最终全量云端测试与公开安装包验证。通常双语言复核为两次 Vision 请求，每个缺失 Han-only 片段额外增加一次请求；使用后模型缓存 RSS 的未达标结果不因该准确性修复而覆盖。

## 2026-10-13 原生界面精修

以本机 iShot Pro 2.5.8 的实际偏好设置为参考，调整系统侧栏、原生表单、OCR 文稿区、两排标注 HUD、历史和录制窗口；全部 B0–B9 功能保留。最终表单修正后，本机严格 Swift 6 complete、编译警告作为错误的干净构建测试 **169 项通过、0 失败、0 跳过**，报告为 `build/evidence/precision-ui-verified-tests.xcresult` 和 `precision-ui-verified-tests-summary.json`。

本轮实际启动安装目录的新进程，打开设置与录屏窗口，切换 DeepL 配置仍保持百度为当前服务，指南与录屏设置的 Esc 取消有效。实际发现并修正了系统表单空行和输入框重复标签。屏幕权限列表显示已开启，但新构建真实捕获仍返回权限错误；刷新授权触发 macOS 登录密码验证，正在交由用户本机完成，未输入或读取密码。此项没有据设置开关判为通过，也没有增加辅助功能、麦克风或摄像头授权。实际截图及后续交互证据以 [UI-REDESIGN.md](UI-REDESIGN.md) 为准。

后续实际历史单击、上下键选择、双击标注，以及 12 工具键盘循环与 Esc 退出通过；OCR 公开样本为 20 段／784 字，侧栏收起／展开、原生区块勾选、中文粘贴、撤销／重做与滚动至末段通过。重复 AX label 查询导致的栈溢出经原生编辑标签和控件真实标题修正后未再复现；这不是完整屏幕阅读器认证。补齐标准文件和窗口菜单后，Command+W 实际关闭历史窗口。末次严格干净测试 **169 项、0 失败、0 跳过、0 编译警告**，证据为 `precision-ui-native-final-tests.xcresult`；独立 universal Release、App Intents 元数据和签名完整性通过，见 `precision-ui-native-final-release-verification.json`。后续系统屏幕权限列表没有当前安装副本，最终新构建的真实捕获仍需单独验证；系统旁白当前关闭已实际确认。

## 当前环境

- macOS 15.7.7，Apple Silicon；Xcode 26.3 / Swift 6.2.4。
- 本机代码签名查询返回 0 个有效身份，开发构建使用 ad hoc 签名。
- Developer ID 分发、公证必须由有证书的环境完成，不能以 ad hoc 构建替代。
- 改版前 B9 的纯 Release 应用 6,168 KiB，包含 arm64/x86_64；ad hoc 开发 ZIP 3,116 KiB，签名完整性校验通过。主二进制 SHA256：`a265defca2d94a7f5be5bfc4cee7cb3195c0d986e805e6224c55709a71dea816`。

## 已取得的原生证据

- `build/evidence/B9-idle-lazy.json`：菜单及热键注册就绪 381.22ms；30 秒 fresh idle RSS 峰值 30,528 KiB，CPU 全部 0%；下一独立进程 `B9-idle-lifecycle.json` 就绪 353.98ms，20 秒 RSS 峰值 32,144 KiB。它们不能替代两小时或使用后的空闲验收。
- `build/evidence/B9-window.png`：实际 ScreenCaptureKit 窗口截图 2800×1896；13 行原生中英日公开测试文字。`B9-real-OCR.txt` 为修复前结果；修复后回归保留中文和英文并补全原生候选的日文假名。
- `build/evidence/B9-native.mp4`：实际 ScreenCaptureKit 区域录制，指定 MP4 输出，系统音频开、麦克风和摄像头关。HUD 在 2:08 暂停，继续后仍为 2:08，最终约 2:24 停止；精确暂停墙钟未采样，不能从静止画面推断。
- `build/evidence/B9-ui-lifecycle.teardown.json`：做过截图、OCR、录屏后正常 Command+Q；选择窗口/监听、倒计时、display links、热键、OCR/输出任务、音视频 stream/pipeline、摄像头、自动化 observer/operation/draining/process observer 和可见原生窗口全部为 0，PID 已退出。
- `build/evidence/B9-ui-lifecycle.capture.json`：单块 5120×2880 屏幕第一次区域覆盖准备 403.91ms；这是 5K、单次结果，不是物理热键或 4K 预算通过证据。显示刷新实测约 74.82fps，上限 75Hz，不能用于宣称 120Hz 通过。
- `build/evidence/B9-cli-cold-concurrent.json`：两个真实 CLI 同时冷启动，均成功且返回相同 OCR 文本，启动约 612ms，常驻只留下一个 PID。安装脚本 10 项真实本机检查覆盖带空格路径、幂等、错误参数和防误覆盖。
- `build/evidence/B9-annotated.png`：实际历史编辑、绘图、撤销/重做、原生保存面板得到 2800×1896 PNG。最终新增 8 项纯键盘回归，覆盖 12 工具、原图 1px/Shift10px 步进、原生文字/便签字体、导出像素与 modal 退出；历史宽度适配另有原图尺寸断言。
- `build/evidence/B9-final-keyboard.json` 与 `.png`：最终候选实际键盘循环矩形、椭圆、箭头、直线、画笔、文字、马赛克、模糊、高亮、序号、便签、放大标注；Space 放置、文字/便签原生输入，撤销后 2 项、重做后 3 项，Command+S 原生保存仍为 2800×1896。精确 1px/10px 和字体尺寸来自独立回归断言，未冒充屏幕坐标实测。新文件已进入历史并自动回填 OCR。
- `build/evidence/B9-final-pins.json`：最终候选浮动图片窗、滚轮可见透明度变化、双击关闭、原生图库两张记录。物理双指缩放和拖到 Finder 未验收。
- 新增 3 项贴图生命周期测试与 1 项选择会话真实渲染取消测试，等待复制、解码、索引原子写入及旧预览实际结束后资源归零，不靠提前清任务引用达成。
- `build/custom-rest-network-probe/network-tests.log`：3 项真实 loopback HTTP/URLSession 测试、5 次本机 HTTP 请求；中文/换行/引号与字面 `$KEY`、429/502 原始错误和取消后连接清理通过。凭据为内存 fixture，不代表 Keychain 或第三方账号成功。
- `build/evidence/B9-idle-before-signing-fix.json`：前一候选 21 分钟空闲峰值 RSS 31,984 KiB、CPU 全部 0%；有道 Unicode 签名问题修复后正常退出，因此明确记录为中断。其退出新增贴图/标注任务计数全部归零，保存在同名前缀的 `.teardown.json`；不是两小时通过。
- 有道采用官方 Python3 示例的码点/UTF-8 签名，新增独立 Python 标准库固定哈希向量覆盖组合字符、非 BMP、ZWJ 及 20/21 边界；官方 JavaScript 的 UTF-16 差异和真实账号验收边界见配置指南。
- `build/evidence/B9-idle-before-lazy-startup.json`：前一版本 9 分钟短基线，MenuReady 427.74ms，随后因为延迟初始化优化正常退出；不是两小时通过。
- `build/evidence/B9-clean-final.json`：提交 f6cb924 的实际本地 Git 克隆，仅使用规定两步构建成功；再在克隆中执行 149 项测试，0 failures、0 编译警告。
- `build/evidence/B9-idle-two-hours.json` 与 `B9-final-soak-summary.json`：最终候选 PID 2315，2026-10-13 00:03:16–02:03:16，连续不操作应用 7200.01 秒，121 次 external ps 采样。RSS 初始 32,352、最终 30,512、峰值 32,400 KiB，净变化 −1,840 KiB；CPU 全部 0%。首次 MenuReady 414.24ms，超过 400ms 预算。二进制哈希保持一致；fresh idle 无增长不等于使用后内存或 Instruments 验收。
- `build/evidence/B9-idle-two-hours.teardown.json`：完整空闲采样后执行最终键盘标注、自动 OCR、贴图及录屏设置取消，再正常 Command+Q。选择、显示刷新、热键、音视频、滚动、自动化及贴图复制/解码/索引持久化任务计数全部 0，可见原生窗口 0；PID 2315 和采样器已退出。
- `build/evidence/B9-user-applications-install.json`：同一最终构建复制到此前不存在的 `~/Applications/niko-shot.app`，哈希一致、ad hoc 签名校验通过。正常完整路径 GUI 启动后，登录启动状态实际从 notFound 经开关注册变为 enabled，再关闭变为 notRegistered；最终关闭，无辅助常驻进程。没有执行真实登录或重启。
- `build/evidence/B9-shortcuts-final.json`：安装并正常启动正式应用、正常重启 Shortcuts 后，系统发现五个正式动作；`com.n1ko.niko-shot.LastOCRTextIntent` 在 PID 12280 运行时返回公开 OCR 文本。正常退出后先确认无进程，随后仅由 Shortcuts 冷启动安装副本 PID 13594，再次返回相同文本。其他四个动作完整捕获未因此判为通过；未对安装/启动/重启三步单独作因果归因。
- `build/evidence/B9-shortcuts-before-launch.json`：记录正式应用此前未被发现，以及独立 Swift 6/AppKit/ad hoc 控制样本的排查结果。`LSUIElement` 为 true 与 false 的两个样本均被系统发现，单一 Echo 动作实际返回 `public native echo fixture`；不能替代正式应用证据。测试进程已正常退出。验收动作已清空，一个具名空条目保留，未执行影响所有 iCloud 设备的删除。
- 同一证据另含五动作参数隔离实验：复制正式候选的 `CaptureIntents`、`AutomationCommand`、`AutomationBridge`，仅给标题加 `niko QA` 前缀，并安装公开常量 fixture handler。系统发现五个中文动作，显示延时/可选输出/自动 OCR/可选窗口 ID 与 MP4、GIF 枚举，五动作流水线返回 `public schema fixture: lastOCR; delay=0; autoOCR=true; format=mp4`。正式应用完全未被调用；这是元数据模式和原生调用控制样本，不是正式产品端到端通过。样本进程正常退出，五个动作已移除。
- 参数隔离样本还完成真实系统冷启动：进程原先不存在，由 Shortcuts 启动后 `LastOCRTextIntent` 返回上述公开文本。只记录了本次测试进程的 `CommandLine.arguments`，其中只有可执行文件路径，未出现推测中的额外系统参数；该观察不等于所有系统启动场景的参数保证，也未运行正式应用的 CLI 分流代码。
- `build/evidence/B9-voiceover-partial.json`：系统旁白原先关闭，字幕面板原先开启、AppleScript 控制关闭；通过系统设置开启旁白并点击欢迎页的“使用旁白”，未修改字幕和脚本控制偏好。进入设置走查时 Computer Use 报告 Mac 已锁定，需要用户在本机解锁；此项没有判为通过，旁白恢复关闭也待解锁后完成。

## 当前未达标或外部验收条件

`build/evidence/B9-final-post-use.json`：完成两小时采样后，最终候选进行录屏设置取消、键盘标注、自动 OCR 和贴图，关闭全部原生窗口并等待 15 秒，RSS 仍为 334,064 KiB（326.2MiB）、CPU 0%，超过 40MB。旧 Release 使用后结果为 381,984 KiB，保留原始证据。fresh idle 达标不会覆盖使用后失败。原生 Vision 第二语言复核在独立冷探针中从约 811ms / 146.1MiB RSS 增至约 2356ms / 270.4MiB RSS；这是准确性修复的实测成本，不能用 autoreleasepool 宣称系统模型缓存已释放。

本机只有一块 75Hz、2x 显示器，无法确认双屏异 DPI、拔插屏、ProMotion 120Hz 或 macOS 14 真机。百度、有道有效测试账号未配置；Google/DeepL 当前为协议 mock，不能宣称四家真实成功。辅助功能、麦克风、摄像头需得到当次确认后才能增加本机权限；签名查询为 0 个有效身份，Developer ID 公证仍需对应证书环境。

历史记录：2026-10-12 用户允许屏幕录制用于当时的本机验收；该应用的本机权限已按 2026-10-13 最新要求重置。此前系统身份验证面板未完成，未输入或读取密码；取消该面板后，系统列表显示 niko-shot 开关开启，但没有据此推断最终二进制的 ScreenCaptureKit 调用成功。最终动态录屏和真实页面拼接还需通过最终构建的屏幕授权验证；VoiceOver 设置走查仍需完成；不将旧候选实录或隔离样本替代最终实测。

独立公开 API 计算设备探针见 `build/ocr-compute-probe/REPORT.md`。释放图片、请求和 autoreleasepool 后 15 秒，默认 / GPU / CPU / Neural Engine 的 RSS 分别为 207.03 / 278.12 / 374.44 / 238.92 MiB；均未达 40MB，CPU/GPU 还有英文及编号差异，因此保留默认设备选择，没有以准确性换取未证实的内存改善。

以上项目维持 P0 验收范围；没有因为环境缺失而删除功能或将其改成后续路线图。
