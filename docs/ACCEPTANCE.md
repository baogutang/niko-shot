# 验收记录

唯一功能来源：[PROMPT.md](../PROMPT.md)。全部 B0–B9 保持必交付。

构建与自动测试使用 `scripts/verify.sh Bn`；完整原始日志保存在 `build/evidence`。
自动测试、实机交互、账号连通和性能采样分开记录。构建成功不等于产品验收通过。

| 阶段 | 实现 | 自动构建与测试 | 实机验收 |
|---|---|---|---|
| B0 | 已实现 | clean build + 5 tests 全绿 | 本机启动采样已运行；人工冲突提示走查待验证 |
| B1 | 已实现 | clean build + 9 tests 全绿 | 双屏异 DPI、Retina、全屏空间需实机走查 |
| B2 | 已实现 | clean build + 12 tests 全绿 | 重叠窗口循环、放大镜、延时需 UI 走查 |
| B3 | 已实现 | clean build + 15 tests 全绿，全部 12 工具及原图像素方向 | 全工具键盘与 HUD 需交互走查 |
| B4 | 已实现 | clean build + 17 tests 全绿，四格式实际编解码及中文 FTS5 | Finder/聊天拖拽、贴图手势需 UI 走查 |
| B5 | 已实现 | clean build + 19 tests 全绿，真实 Vision 识别及文字整理 | 实际中英日混排、区块操作与重 OCR 需走查 |
| B6 | 待实现 | 待运行 | 五家账号连通 |
| B7 | 待实现 | 待运行 | 系统音频与麦克风、暂停、GIF |
| B8 | 待实现 | 待运行 | 真页面接缝、辅助功能拒绝 |
| B9 | 待实现 | 待运行 | 性能、VoiceOver、权限、签名 |

## 当前环境

- macOS 15.7.7，Apple Silicon；Xcode 26.3 / Swift 6.2.4。
- 本机代码签名查询返回 0 个有效身份，开发构建使用 ad hoc 签名。
- Developer ID 分发、公证必须由有证书的环境完成，不能以 ad hoc 构建替代。
