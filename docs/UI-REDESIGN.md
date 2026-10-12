# 原生界面改版与翻译接入引导

本轮依据用户 2026-10-13 的界面重做要求，延续 PROMPT.md 的全部 P0 范围。使用 SwiftUI、AppKit、SF Symbols、系统颜色和原生材质，运行时依赖不变。

| 页面 | 操作与呈现 |
|---|---|
| 菜单栏 | 区域截图为主要入口；窗口／全屏及四种工具分组；重复区域、最近三张缩略图、设置与退出保留 |
| 设置 | 九分类侧栏；页头、分组面板和统一间距；热键录制、冲突、权限与登录启动反馈保留 |
| 翻译配置 | 五张并排选择卡；当前服务与配置对象独立；凭据填写、保存、复制、移除及行内连接测试；切换配置和设置分类保留未保存输入，关闭设置清除敏感草稿 |
| OCR | 左侧逐段勾选、编辑和复制；右侧原文／译文并排；语言选择、自动翻译、取消、错误及译文复制；直接打开指南或服务配置 |
| 历史与贴图库 | 清晰的页面说明、预览和操作；原有搜索分页、中文 OCR 检索、文件承诺拖拽与贴图管理保留 |
| 标注 HUD | 工具、颜色／线宽、输出操作分为三行，保持全部 12 种工具与 44pt 命中区 |
| 录屏、GIF、长截图 | 分组配置；可滚动内容；主要操作及 GIF 进度固定在底部；原有质量、声音、摄像头、固定栏排除和恢复操作保留 |
| 首次向导与图标 | 三步进度、符号徽标、快捷键面板；10 种尺寸的静态 macOS AppIcon |

官方接入资料核验日期 **2026-10-13**。应用内的「申请与接入指南」提供申请服务、填入凭据、测试连接三个阶段，附产品、控制台和参考文档链接；核验日期在指南页头可见。详细步骤和全部来源见 [TRANSLATION.md](TRANSLATION.md)。

- 百度：通用文本翻译 API，APP ID 与密钥。
- Google：Cloud Translation Basic v2，项目启用 API 和计费，使用 API Key。
- 有道：创建并绑定文本翻译 API 应用，应用 ID 与密钥。
- DeepL：按现行 Developer／Growth／Enterprise API 申请路径；已有 Free／Pro 密钥继续按官方端点规则使用，翻译器订阅与 API 产品分开说明。
- 自定义 REST：彩云 API Token、LibreTranslate 官方托管密钥及自托管申请方式。未启用认证的自托管实例删除 `$KEY` 引用后可免密测试；JSON Unicode 转义和 Form 编码中的密钥占位符仍要求凭据。

本机 `clean build test` 与后续最终回归 **157 项通过、0 failures**，编译警告为零。原始日志：`build/evidence/UI-redesign-xcodebuild.log`、`UI-redesign-final-xcodebuild.log`。新增真实 loopback HTTP 测试覆盖免密 REST 请求和缓存、编码认证占位符在无凭据时阻止请求、OPTIONS 方法；导航测试检查官方 HTTPS、凭据范围和链接角色。测试不会请求外部翻译服务或保存真实凭据。

交付源码提交为 `ec9fee08a7784f2b6add5cf9de78f3729ce2e8be`（`feat(ui): redesign native workflows and provider onboarding`）。从该提交重新建立干净 Git 检出，仅依次执行 `xcodegen generate` 和 `xcodebuild -scheme niko-shot -configuration Debug build test`，两个步骤均返回 0，157 项测试通过。首轮 Xcode 测试报告写入超时；随后使用显式 `-resultBundlePath` 补验，同样 157 项通过、0 失败、0 跳过，并通过 `xcresulttool get test-results summary` 验证报告可读。补验时 Xcode 对 Debug 可执行文件的 App Intents 元数据提取报告无框架依赖警告，Swift 编译没有警告；实际交付的 Release 构建正常生成 `Metadata.appintents`。证据为 `build/evidence/UI-redesign-clean-clone.json`、`UI-redesign-clean-clone-report.log`、`UI-redesign-clean-clone-report.xcresult` 和 `UI-redesign-clean-clone-summary.json`。后续提交仅补充文档，不改变该交付源码与安装产物。

当前产品源码生成了浅／深色的原生离屏预览，保存在 `build/evidence/UI-redesign/previews`，包括菜单、设置、五类翻译配置、OCR、历史、录屏、GIF、长截图、指南和标注 HUD。预览仅使用公开合成文字、图像与隔离的设置／数据库；窗口未激活，部分系统控件显示非活动外观，文件拖拽缩略图没有可靠显示。这些预览用于排版检查，不能替代真实窗口、键盘焦点、VoiceOver 或拖拽验收。

纯 Release 构建包含 arm64／x86_64，7,232 KiB（7.41MB）；开发 ZIP 为 3,389,663 字节（3.39MB）。ad hoc 签名完整性校验通过，未作 Developer ID 公证。主二进制 SHA256：`75e0edd777da7d5bda27101d42f186ba693fe775a023c92a5c4921b54f4095dc`；ZIP SHA256：`2bb22f59ecf7d5381deb24f541a39443e33d650d1bf22c9e8306e16c54944c5c`。

已以原子替换更新 `/Users/n1ko/Applications/niko-shot.app`，安装副本与 Release 主二进制哈希一致。改版前应用完整保存在 `build/distribution/niko-shot-before-ui-redesign.app`；用户数据和偏好继续由原路径加载。既有进程仍运行旧代码，退出并重新打开后新版才生效。可移交 ZIP：`build/distribution/niko-shot-ui-redesign.zip`；构建及安装证据为 `build/evidence/UI-redesign-artifacts.json`。

Computer Use 当前报告 Mac 锁定；真实窗口走查和旧版退出／新版启动待手动解锁，此前开启的 VoiceOver 也仍待恢复。五家真实账号连通、外设、Developer ID 分发，以及 B9 冷启动和使用后 RSS 预算继续按 [ACCEPTANCE.md](ACCEPTANCE.md) 记录，整体 DoD 尚未通过。
