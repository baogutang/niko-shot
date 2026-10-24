# niko-shot 官网设计与维护

官网要和应用看起来是同一个产品：一个原生 Mac 工具，而不是营销落地页。

## 方向

**颜色**：系统中性色加一个品牌色。品牌色是应用图标里的琥珀色 `#E8A333`，只用在主按钮、选中状态、链接和图标上。填充琥珀时文字用 `#1C1710`；琥珀色当文字时，浅色模式用加深的 `#AD7111`，深色模式直接用 `#E8A333`。浅色和深色都在 `styles.css` 的 `:root` 中成对定义，`[data-theme]` 覆盖与系统深色媒体查询保持一致：

| 角色 | 浅色 | 深色 |
|---|---|---|
| canvas | `#FFFFFF` | `#111113` |
| surface | `#F5F5F7` | `#1C1C1E` |
| elevated | `#FFFFFF` | `#2C2C2E` |
| text | `#1D1D1F` | `#F5F5F7` |
| muted | `#6E6E73` | `#98989D` |
| line | `#D2D2D7` | `#38383A` |
| tint（约 14% 琥珀叠在 surface 上） | `#F3EADC` | `#392F21` |

不再使用纸张暖色、朱砂红或第二个强调色。新增颜色先问能否用现有变量表达。`site.js` 里截图练习画布的选区、标注和遮罩颜色也属于这套色板。

**文案**：用简短、具体的中文说明功能，参考 Apple 或 CleanShot 的功能说明写法。标题直接写功能名（「截图和标注」「长截图」「文字识别和翻译」「录屏」「下载」），每段一到两句。不写口号，不加 eyebrow 小标签，不用 `<br>` 拼两行诗句式标题，不用「·」串列表。版本相关的事实（默认快捷键、设置窗口标签、命令行开关）要和应用及 README 一致。

**版式**：系统字体，标题字距接近默认，字重 600–700。卡片只用 surface 底色和细线，不加装饰动画。保留可交互的截图练习画布，它是页面上唯一的演示；动效只有进入时的淡入和按需的操作反馈，开启「减少动态效果」或「降低透明度」时相应停用。

## 组成

首屏是应用图标、产品名和一句说明。之后依次是截图练习画布、截图和标注、长截图与录屏、文字识别和翻译、应用界面预览、快捷键与隐私、下载和常见问题。

官网是原始静态 HTML / CSS / JavaScript，由 GitHub Pages 原样部署，不引入框架、外部字体、统计脚本或追踪像素。只有下载模块会读取 GitHub 公共 Release API，读取失败时保留发布页链接。

## 素材

- `app-*.png`：当前应用窗口的离屏渲染，浅色和深色成对，另有 `-compact` 半尺寸版本。「应用界面」各标签的像素尺寸和替代文字写在 `site.js` 的 `previewImages` 中；替换截图时只需更新那里的 `width`、`height` 和 `compactWidth`。首屏 HTML 中的 OCR 图片尺寸由 `scripts/verify-website.py` 校验。
- `app-icon.png`、`niko-mark.svg` 与 `readme-hero.svg`：应用图标、标识和 README 横幅。
- `capture-sample.svg`：截图练习画布使用的原创示例图。
- `capture-sculpture*.jpg`：旧版首屏图，校验脚本仍要求保留。
- `icons.svg`：Tabler 图标，许可证见 `TABLER-LICENSE.txt`。

## 接入指南的唯一来源

网页指南从 `niko-shot/Core/Translate/ProviderSetupGuide.swift` 导出，五类服务均保留三个步骤、凭据类型、官方入口、产品区别与核对日期。修改应用内指南后，执行：

```sh
mkdir -p build/tools
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  niko-shot/Core/Translate/TranslationService.swift \
  niko-shot/Core/Translate/ProviderSetupGuide.swift \
  scripts/generate-website-guide.swift -o build/tools/generate-website-guide
build/tools/generate-website-guide
python3 scripts/verify-website.py
```

`guide-data.json` 记录来源哈希；CI 拒绝源数据已改、网页未更新的提交。核对日期指公开文档核验，不能替代真实账号与配额测试。`guide.html` 的页头和页脚文案也写在生成脚本的模板里，两处需要保持一致。

## 预览与发布

```sh
python3 -m http.server 48765 --bind 127.0.0.1 --directory website
```

预览地址 `http://127.0.0.1:48765/`。提交到 main 后，独立 Pages 工作流先验证静态链接、资源、指南哈希和真实分发说明，再部署。应用工作流先干净构建和测试，再构建双架构 Release 并发布安装候选。详见 [发布说明](../RELEASES.md)；网页上线和应用通过完整 DoD 是两个独立结论。
