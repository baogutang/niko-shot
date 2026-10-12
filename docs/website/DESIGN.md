# niko-shot 官网设计与维护

面向每天使用截图工作流的 Mac 用户，以原生产品体验和可直接上手的演示建立信任，并把下载与翻译接入放在明确位置。

## 方向与参考

参考 [vibe-island 官方网站](https://vibeisland.app/) 的完整产品叙事、主视觉占比、可交互演示和细致动效。采用自己的苹果风格方向：系统字体、蓝色强调色、光学玻璃与金属、充足留白、浅深色完整配对。参考网页只作为视觉研究，未复制其代码、图像、商标或产品画面，也不以主观“超越”作为已经验证的结论。

设计参数：DESIGN_VARIANCE **7**（错落的功能构图，避免同规格卡片铺满）；MOTION_INTENSITY **6**（进入、选区、扫描反馈与按需交互各有用途，无自动循环）；VISUAL_DENSITY **3**（首屏克制，详细步骤单独展开到指南）。使用自动外观作为页面唯一主题，用户切换后整页同步，所有区域保持同一蓝色与圆角体系。

## 组成

首屏为原创光学雕塑与两行标题。接着是可以键盘操作、绘制并导出 PNG 的真实网页画布；功能构图、原生界面预览、翻译入口、处理边界、下载与 FAQ 使用不同布局节奏。原生预览来自当前应用的离屏渲染，使用公开样例，明确标注非活动控件；不把概念图当作真实软件运行证据。

官网为原始静态 HTML / CSS / JavaScript，GitHub Pages 原样部署，避免为展示页引入运行时框架或构建依赖。它与原生 Swift 应用的运行时相互独立。无外部字体、分析脚本、追踪像素或嵌入式视频；仅下载模块向 GitHub 公共 Release API 读取构建信息。读取失败时保留公开 Release 入口。

## 素材与动效

- `website/assets/capture-sculpture.png`：为本项目生成的原创光学雕塑视觉，亦用作画布公开样例。
- `app-*.png`：当前 AppKit / SwiftUI 窗口离屏预览，浅深色成对；不含个人屏幕或账号信息。
- `app-icon.png` 与 `readme-hero.svg`：应用图标和项目字标横幅。
- `icons.svg`：Tabler 官方图标，许可证随文件存放在 `TABLER-LICENSE.txt`。

入场过渡帮助建立阅读顺序；工具选择、选区和导出显示当前操作状态；扫描只在主动播放时出现。鼠标经过录屏和长截图构图时提供有限的状态反馈。动画使用 transform / opacity，滚动观察使用 IntersectionObserver，不监听高频 scroll，不添加自定义光标、自动跑马灯或持续渲染循环。页面离开、隐藏及用户开启减少动态效果时清理动画；减少透明度时停用导航模糊。

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

`guide-data.json` 记录来源哈希；CI 拒绝源数据已改、网页未更新的提交。核对日期指公开文档核验，不能替代真实账号与配额测试。

## 预览与发布

```sh
python3 -m http.server 48765 --bind 127.0.0.1 --directory website
```

预览地址 `http://127.0.0.1:48765/`。提交到 main 后，独立 Pages 工作流先验证静态链接、资源、指南哈希和真实分发说明，再部署。应用工作流先干净构建和测试，再构建双架构 Release 并发布安装候选。详见 [发布说明](../RELEASES.md)；网页上线和应用通过完整 DoD 是两个独立结论。
