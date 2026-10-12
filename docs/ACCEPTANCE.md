# 验收记录

唯一功能来源：[PROMPT.md](../PROMPT.md)。全部 B0–B9 保持必交付。

构建与自动测试使用 `scripts/verify.sh Bn`；完整原始日志保存在 `build/evidence`。
自动测试、实机交互、账号连通和性能采样分开记录。构建成功不等于产品验收通过。

| 阶段 | 实现 | 自动构建与测试 | 实机验收 |
|---|---|---|---|
| B0 | 已实现 | clean build + 5 tests 全绿 | Release 菜单就绪 349–381ms；原生设置热键录制、重复组合行内报错及恢复已走查；物理全局触发需另测 |
| B1 | 已实现 | clean build + 9 tests 全绿 | 双屏异 DPI、Retina、全屏空间需实机走查 |
| B2 | 已实现 | clean build + 12 tests 全绿 | 重叠窗口循环、放大镜、延时需 UI 走查 |
| B3 | 已实现 | clean build + 15 tests 全绿，全部 12 工具及原图像素方向 | 全工具键盘与 HUD 需交互走查 |
| B4 | 已实现 | clean build + 17 tests 全绿，四格式实际编解码及中文 FTS5 | Finder/聊天拖拽、贴图手势需 UI 走查 |
| B5 | 已实现 | clean build + 19 tests 全绿，真实 Vision 识别及文字整理；B9 加入 3 项混排回归 | 实际 SC 窗口 2800×1896：日文完整行从 0/13 改为 13/13，原中英前缀保留；区块操作与重 OCR 需走查 |
| B6 | 已实现 | clean build + 46 tests 全绿，五家签名/映射/请求/响应及缓存、并发、取消 | 有效账号未配置，五家真实成功连通未验证；DeepL 服务端模型架构不由客户端保证 |
| B7 | 已实现 | clean build + 64 tests 全绿；真实 HEVC/AAC 编解码、双音源混流、连续转换尾部、GIF 全局 256 色/循环/帧延迟、取消与 UI 释放 | 真实 SCStream 区域 1920×1080 MP4、HUD 暂停/继续/停止和自动化指定路径已完成；静态样本短 top CPU 4.2%，持续动态负载、物理麦克风/摄像头仍待验证 |
| B8 | 已实现 | clean build + 85 tests 全绿；80–200px NCC 偏移误差 0px，透明 PNG 全像素/CRC 校验、5000 行分块、取消/原子替换；1920×10000 编码阶段峰值 RSS 约 42MB | 真页面接缝、辅助功能拒绝后的手动交互仍需授权环境走查 |
| B9 | 已实现，验收进行中 | 2026-10-12 23:45 最终候选 clean build + 149 tests、0 failures、0 编译警告 | 首跑三步/真截图/CLI 常驻/重复进程/原生设置已走查；正常退出全部资源计数 0；性能长采样、VoiceOver、其他权限、真实账号及 Developer ID 未全部完成 |

## 当前环境

- macOS 15.7.7，Apple Silicon；Xcode 26.3 / Swift 6.2.4。
- 本机代码签名查询返回 0 个有效身份，开发构建使用 ad hoc 签名。
- Developer ID 分发、公证必须由有证书的环境完成，不能以 ad hoc 构建替代。
- 最终纯 Release 应用 6,168 KiB，包含 arm64/x86_64；ad hoc 开发 ZIP 3,116 KiB，签名完整性校验通过。主二进制 SHA256：`cbe6aa0e0819cb5c9746194f130e9357012261628366b6d8a1ff04967b4921b1`。

## 已取得的原生证据

- `build/evidence/B9-idle-lazy.json`：菜单及热键注册就绪 381.22ms；30 秒 fresh idle RSS 峰值 30,528 KiB，CPU 全部 0%；下一独立进程 `B9-idle-lifecycle.json` 就绪 353.98ms，20 秒 RSS 峰值 32,144 KiB。它们不能替代两小时或使用后的空闲验收。
- `build/evidence/B9-window.png`：实际 ScreenCaptureKit 窗口截图 2800×1896；13 行原生中英日公开测试文字。`B9-real-OCR.txt` 为修复前结果；修复后回归保留中文和英文并补全原生候选的日文假名。
- `build/evidence/B9-native.mp4`：实际 ScreenCaptureKit 区域录制，指定 MP4 输出，系统音频开、麦克风和摄像头关。HUD 在 2:08 暂停，继续后仍为 2:08，最终约 2:24 停止；精确暂停墙钟未采样，不能从静止画面推断。
- `build/evidence/B9-ui-lifecycle.teardown.json`：做过截图、OCR、录屏后正常 Command+Q；选择窗口/监听、倒计时、display links、热键、OCR/输出任务、音视频 stream/pipeline、摄像头、自动化 observer/operation/draining/process observer 和可见原生窗口全部为 0，PID 已退出。
- `build/evidence/B9-ui-lifecycle.capture.json`：单块 5120×2880 屏幕第一次区域覆盖准备 403.91ms；这是 5K、单次结果，不是物理热键或 4K 预算通过证据。显示刷新实测约 74.82fps，上限 75Hz，不能用于宣称 120Hz 通过。
- `build/evidence/B9-cli-cold-concurrent.json`：两个真实 CLI 同时冷启动，均成功且返回相同 OCR 文本，启动约 612ms，常驻只留下一个 PID。安装脚本 10 项真实本机检查覆盖带空格路径、幂等、错误参数和防误覆盖。
- `build/evidence/B9-annotated.png`：实际历史编辑、绘图、撤销/重做、原生保存面板得到 2800×1896 PNG。最终新增 8 项纯键盘回归，覆盖 12 工具、原图 1px/Shift10px 步进、原生文字/便签字体、导出像素与 modal 退出；历史宽度适配另有原图尺寸断言。
- 新增 3 项贴图生命周期测试与 1 项选择会话真实渲染取消测试，等待复制、解码、索引原子写入及旧预览实际结束后资源归零，不靠提前清任务引用达成。
- `build/custom-rest-network-probe/network-tests.log`：3 项真实 loopback HTTP/URLSession 测试、5 次本机 HTTP 请求；中文/换行/引号与字面 `$KEY`、429/502 原始错误和取消后连接清理通过。凭据为内存 fixture，不代表 Keychain 或第三方账号成功。
- `build/evidence/B9-idle-before-signing-fix.json`：前一候选 21 分钟空闲峰值 RSS 31,984 KiB、CPU 全部 0%；有道 Unicode 签名问题修复后正常退出，因此明确记录为中断。其退出新增贴图/标注任务计数全部归零，保存在同名前缀的 `.teardown.json`；不是两小时通过。
- 有道采用官方 Python3 示例的码点/UTF-8 签名，新增独立 Python 标准库固定哈希向量覆盖组合字符、非 BMP、ZWJ 及 20/21 边界；官方 JavaScript 的 UTF-16 差异和真实账号验收边界见配置指南。
- `build/evidence/B9-idle-two-hours.json`：最终候选 PID 88833，从 2026-10-12 23:48:51 开始 7200 秒空闲采样，保持不操作应用；首次 MenuReady 427.74ms，超过 B9 的 400ms 预算，旧候选较快的结果不能覆盖这次结果。

## 当前未达标或外部验收条件

使用截图、OCR、录屏并关闭所有窗口后，旧 Release 进程 RSS 仍为 381,984 KiB，超过 40MB。框架缓存、已释放分配页与原图驻留正分别核对；即使 fresh idle 达标，也不会把这个结果标成使用后达标。为修正真实混排，原生 Vision 第二语言复核在独立冷探针中从约 811ms / 146.1MiB RSS 增至约 2356ms / 270.4MiB RSS；这是准确性修复的实测成本，不能用 autoreleasepool 宣称系统模型缓存已释放。

本机只有一块 75Hz、2x 显示器，无法确认双屏异 DPI、拔插屏、ProMotion 120Hz 或 macOS 14 真机。百度、有道有效测试账号未配置；Google/DeepL 当前为协议 mock，不能宣称四家真实成功。辅助功能、麦克风、摄像头需得到当次确认后才能增加本机权限；签名查询为 0 个有效身份，Developer ID 公证仍需对应证书环境。

以上项目维持 P0 验收范围；没有因为环境缺失而删除功能或将其改成后续路线图。
