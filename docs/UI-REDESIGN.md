# 原生界面改版与翻译接入引导

2026-10-13，根据用户要求，实际查看本机 iShot Pro 2.5.8 的截图和 OCR 偏好设置，再修订 niko-shot 的原生界面。参考其紧凑的分类导航、控件密度和系统交互；没有使用 iShot 的图像或资源。实现继续使用 SwiftUI、AppKit、SF Symbols、系统颜色和材质，不增加运行时依赖，PROMPT.md 的全部 P0 功能保留。

| 页面 | 本次呈现与交互 |
|---|---|
| 菜单栏 | 紧凑的区域截图入口、六项功能、重复区域、最近三张缩略图、历史、设置和退出 |
| 设置 | 九分类系统侧栏、彩色符号、小标题与原生表单；清除独立分隔线造成的空白行；保留热键录制、冲突、预设、权限和登录启动状态 |
| 翻译配置 | 五类分段配置入口；当前服务与正在编辑的服务独立；输入框不重复显示标签；保留凭据保存、复制、移除、连接测试和敏感草稿清理 |
| OCR | 可收起的文字区块侧栏；连续原文／译文文稿区；每段选择、编辑、复制与置信度；语言、自动翻译、取消、错误和指南入口 |
| 历史 | 原生列表选择、工具栏操作和轻量元数据；搜索分页、中文 OCR 检索与文件承诺拖出保留 |
| 贴图库 | 选中、悬停和键盘反馈；异步读取实际尺寸与日期，读取图片头而非完整解码；持久化和拖出保留 |
| 标注 HUD | 常规宽度下两排工具；12 种工具、全部输出、七色和 1–16 pt 线宽；控件保持 44 pt 命中区，外观使用系统弹出框 |
| 录屏、GIF、长截图 | 对齐的原生表单与固定底部操作；减少占屏的状态条；音源、摄像头、质量、固定栏排除、接缝确认和恢复操作保留 |
| 窗口 | 更紧凑的默认尺寸；设置和 OCR 记住窗口位置；从 Finder 再次打开菜单栏应用时显示设置 |

官方接入资料核验日期 **2026-10-13**。应用内指南按「申请服务 → 填入凭据 → 测试连接」提供官方入口、控制台与参考文档，日期可见。完整步骤和来源见 [TRANSLATION.md](TRANSLATION.md)。百度 APP ID／密钥、Google Basic v2 项目与计费、有道文本翻译应用、DeepL 当前 Developer／Growth／Enterprise API 路径，以及彩云和 LibreTranslate 模板均保留。

## 实际窗口检查

此前安装目录已更新，仍运行的旧进程却早于上一轮改版提交。本次通过正常退出、原子替换和 Finder 打开，确认新版进程运行于 `/Users/n1ko/Applications/niko-shot.app`；同时保留旧应用备份和用户原有数据。

本机已实际打开新版设置、切换翻译配置、打开和用 Esc 关闭 DeepL 指南、打开和取消录屏设置。切换到 DeepL 配置时，当前翻译服务仍为百度。真实窗口检查发现表单空行和输入框标签重复，已修正后重新进入构建门禁。截图和录屏不会因为设置页的开关状态而判为通过。

新构建的屏幕录制调用返回权限错误，系统列表却显示 niko-shot 已开启。刷新该授权时，macOS 要求用户本机输入登录密码；没有读取、输入或保存密码。需要完成身份验证后再核对最终构建的实际截图、标注弹出框焦点和录屏交互。已有屏幕录制授权不扩展为辅助功能、麦克风或摄像头授权。

## 验证与预览

首轮完整严格干净构建测试 **169 项通过、0 失败、0 跳过**，Swift 6 完整并发和编译警告作为错误；独立 universal Release 也通过。首轮证据为 `build/evidence/precision-ui-tests.xcresult`、`precision-ui-tests-summary.json` 和 `precision-ui-release.log`。表单细节修正后的最终门禁再次通过 **169 项、0 失败、0 跳过、0 编译警告**，结果为 `precision-ui-verified-tests.xcresult` 与 `precision-ui-verified-tests-summary.json`。最终 universal Release 包含 arm64／x86_64、App Intents 元数据，应用文件总计 7,890,754 字节；严格签名完整性校验通过，仍为未公证的 ad hoc 开发签名。证据为 `precision-ui-verified-release.log` 与 `precision-ui-verified-release-verification.json`。

官网与 README 使用当前产品源码的浅／深色**离屏渲染预览**，只含公开合成文字、图像及隔离设置／数据库。窗口未激活，部分控件显示非活动外观；这类预览用于排版检查，不替代真实应用、键盘焦点、VoiceOver 或拖拽验收。本机 iShot 参考截图与真实验收资料仅保存在忽略的 `build/evidence` 中。

上一轮 `ec9fee08a7784f2b6add5cf9de78f3729ce2e8be` 的 157 项回归和离屏检查属于历史证据，不能替代本轮。后续 OCR 精度修复使全量测试达到 169 项；公开候选以 [GitHub 发布](https://github.com/baogutang/niko-shot/releases/tag/nightly)中的不可变源码提交和 `release-info.json` 为准。

Developer ID、公证、真实翻译账号、双 DPI／120 Hz、外设和 VoiceOver 仍需完成相应验收；B9 冷启动和使用后 RSS 预算仍未达标。所有项目继续保留 P0 范围，整体 DoD 尚未通过，具体证据见 [ACCEPTANCE.md](ACCEPTANCE.md)。
