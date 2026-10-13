# 构建、候选下载与官网部署

自动化流程只生成可安装的开发候选，不代表 [完整验收](ACCEPTANCE.md) 或整体 DoD 已通过。当前源码版本为 **0.1.3**；最低 macOS 14，M 芯片 `arm64` 和 Intel `x86_64` 分别提供独立安装包，不再分发 Universal。当前没有 Developer ID 证书，默认产物是 **ad hoc 开发签名、未公证**；签名完整性校验不能替代 Apple 公证。本机 202 项回归测试通过；每个公开候选由 GitHub 独立干净构建、测试和打包，候选身份与完成状态以对应 Actions 记录和 manifest 为准。自动测试不替代最终候选的真实屏幕、账号与外设验收。

## 下载与安装

公开仓库的 [Nightly 导航页](https://github.com/baogutang/niko-shot/releases/tag/nightly) 提供两种芯片的安装包与构建信息。全部 8 个文件指向同一个独立 `candidate-*` 发布，其资产不再替换，下载无需登录 Actions。

| 适用芯片 | 安装包 | 独立构建信息 |
|---|---|---|
| M 芯片 · Apple Silicon | `niko-shot-arm64.dmg`、`niko-shot-arm64.zip` | `release-info-arm64.json` |
| Intel | `niko-shot-x86_64.dmg`、`niko-shot-x86_64.zip` | `release-info-x86_64.json` |
| 同候选公共文件 | `SHA256SUMS` | `release-info.json`（schema 2） |

在苹果菜单「关于本机」查看芯片或处理器，选择对应一行。官网默认明确标注 M 芯片，支持键盘切换 Intel；不把浏览器的 `MacIntel` 字符串当硬件检测。关闭 JavaScript 时保留两套带完整文件名的 GitHub 候选导航。

导航需要仓库公开且第一次发布任务实际成功；工作流文件存在或本机打包成功都不会让下载地址提前生效。私有仓库的 Release 需要仓库访问权限，不能作为免登录公开下载。官网从导航页读取候选标记，确认该候选的 8 个资产均处于 uploaded 状态、文件非空且下载 URL 属于该候选，才同时启用两种芯片的 DMG、ZIP 与公共文件链接。任一资产缺失或读取失败时保留导航页，不使用旧 Universal 安装包补齐。

打开匹配芯片的 DMG，将 `niko-shot.app` 拖入 Applications；也可解压对应 ZIP 后复制应用。首次尝试打开时 macOS 可能拦截未公证的候选。先确认发布来源；例如 M 芯片 ZIP 可运行 `shasum -a 256 niko-shot-arm64.zip`，Intel ZIP 可运行 `shasum -a 256 niko-shot-x86_64.zip`，与同候选 SHA256SUMS 的相应文件行对照。确认要运行后，按 [Apple 官方说明](https://support.apple.com/102445)在系统设置「隐私与安全性」中允许本次打开。不要为此关闭系统整体安全检查。运行后再按原生向导授权屏幕录制；辅助功能只用于自动滚动，麦克风和摄像头按需授权。

每次成功的 main 构建保存独立的 `candidate-运行号-重跑次数-提交短SHA` 预发布及资产，完整 SHA 保存在 release-info.json 和发布正文。Nightly 的正文一次更新为该候选的完整链接，不滚动替换文件。较新的 main 失败不会阻止较早成功候选提供下载；运行号与重跑次数较旧的任务不会回退已发布导航。导航标签更新和正文更新是两次 GitHub API 操作；源代码身份始终以正文中的独立候选标签与 manifest 为准，下载的一整套文件不会因此混用。

汇总 `release-info.json` 的 `schemaVersion` 为 2，`variants.arm64`、`variants.x86_64` 各保存完整单架构 manifest，包括唯一架构、包文件名、主二进制哈希、签名与公证状态。公共 version、build、bundleIdentifier、minimumMacOS、commit、sourceProvenance、runUrl，以及 signing、teamIdentifier、notarized 必须在两份 manifest 中一致。任一架构构建、签名、打包或汇总校验失败都不能发布完整候选。历史 Universal 性能与体积数据仅保留为历史测量，不替代当前分包数据。

## GitHub Actions

| 流程 | 触发 | 门禁与产物 | 可写权限 |
|---|---|---|---|
| `build.yml` 构建任务 | main 每次推送、面向 main 的 PR、手动运行 | XcodeGen；干净 Debug build/test；Swift 6 完整并发检查，编译警告作为错误；arm64 与 x86_64 独立 Release；8 个候选资产；日志和 xcresult | 仅读仓库 |
| `build.yml` 发布任务 | 通过上一步的 main 推送或 main 手动运行 | 独立 candidate 预发布和固定 nightly 导航入口 | 仅此 job 的 `contents: write` |
| `pages.yml` 验证任务 | main 推送、面向 main 的 PR、手动运行 | `python3 scripts/verify-website.py`；上传 `website/` 原始静态文件，无 Node 构建 | 仅读仓库 |
| `pages.yml` 部署任务 | 通过验证的 main 推送或 main 手动运行 | GitHub Pages 官网 | 仅此 job 的 `pages: write`、`id-token: write` |

PR 不执行签名凭据导入、不创建 Release、不部署 Pages。流程不使用 path filters，首次提交以及仅更新文档、官网的 main 提交也会触发完整流程；同一分支的运行串行，避免 nightly 发布相互交错。诊断与安装 Actions artifacts 保留 14 天，公开 Release 的候选资产不依赖该保留期。

运行环境明确使用 `macos-15` 与 `/Applications/Xcode_26.3.app/Contents/Developer`，匹配本机 Xcode 26.3 / Swift 6.2.x。目前该标准标签对应 Apple Silicon M1；测试在原生 arm64 执行，Release 分别限定 `ARCHS=arm64` 与 `ARCHS=x86_64` 构建，不把 Intel 交叉构建当成 Intel 真机运行验收。Homebrew 只安装构建期 XcodeGen，版本记录在日志；应用不增加第三方运行时。runner 上验证不等于 macOS 14 真机、账号、权限与外设验收。[官方 runner 标签](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

`.github/workflows` 内全部官方 Actions 固定到核验过的 40 位 commit SHA。2026-10-13 核验版本如下；更新时同时核对官方 tag、commit 与 action.yml，不只改版本注释：

| 官方 Action | 版本 | 固定 SHA |
|---|---|---|
| [checkout](https://github.com/actions/checkout/releases/tag/v7.0.1) | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| [upload-artifact](https://github.com/actions/upload-artifact/releases/tag/v7.0.2) | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| [download-artifact](https://github.com/actions/download-artifact/releases/tag/v8.0.2) | v8.0.2 | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |
| [configure-pages](https://github.com/actions/configure-pages/releases/tag/v6.0.0) | v6.0.0 | `45bfe0192ca1faeb007ade9deae92b16b8254a0d` |
| [upload-pages-artifact](https://github.com/actions/upload-pages-artifact/releases/tag/v5.0.0) | v5.0.0 | `fc324d3547104276b827a68afc52ff2a11cc49c9` |
| [deploy-pages](https://github.com/actions/deploy-pages/releases/tag/v5.0.1) | v5.0.1 | `368f82528645a54fb793d4d04e342629a3f51346` |

资料：[官方 macOS 15 ARM runner 软件列表](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)、[GitHub 工作流安全与最小权限](https://docs.github.com/en/actions/reference/security/secure-use)、[Pages 自定义工作流](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)。

## 首次启用

仓库维护者需创建公开仓库、提交本目录中的完整源代码并推送 main，在 Settings → Pages 中将 Source 设为 **GitHub Actions**。`configure-pages` 默认不代替维护者创建 Pages，也不使用管理员 PAT。官网地址为 `https://baogutang.github.io/niko-shot/`；首次 Pages 任务成功后才算实际上线。

检查 Build and publish candidate 的 build、publish 两个 job 均成功，打开 Release 确认表中全部 8 个资产存在，再用匿名下载核对相应包的哈希。Pages 的部署需要独立确认；官网上线不会证明应用发布成功，官网应保留真实签名状态并处理下载暂不可用的情形。

## 可选 Developer ID 与公证

未配置任何 secret 时继续生成 ad hoc 未公证候选。将合法现有证书导出为含私钥的 P12 后，可在仓库 Actions secrets 中配置：

| Secret | 用途 |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Developer ID Application P12 的 Base64 |
| `MACOS_CERTIFICATE_PASSWORD` | P12 导出密码；无密码 P12 可为空 |
| `DEVELOPER_ID_APPLICATION` | 完整证书身份，形如 `Developer ID Application: 名称 (TEAMID)` |
| `APPLE_ID` | 可提交公证的 Developer Apple ID |
| `APPLE_APP_PASSWORD` | 该账户为公证创建的 app-specific password |
| `APPLE_TEAM_ID` | Developer Team ID |

前三项启用 Developer ID 签名；没有公证账户三项时发布说明明确标注「已签名、未公证」。公证账户三项需全部提供；缺失或混合配置会使任务失败，不静默降为 ad hoc。签名身份只在 main 构建的专用临时 Keychain 中导入，结束或失败后删除 Keychain 与 P12。

配置齐全时，脚本先提交应用 ZIP，要求 `notarytool` 返回 `Accepted`，再 staple 并校验应用；随后创建并签名 DMG，提交 DMG 公证，再 staple 并校验 DMG。最终 ZIP 包含已 staple 的应用。发布说明只有读取本次 `release-info.json` 的 `notarized: true` 才声称公证完成，未实际配置的凭据不会被当成已有能力。[Apple 公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

本机分别生成纯 arm64、x86_64 Release，再在同一输出目录打包并汇总：

```sh
xcodebuild -scheme niko-shot -configuration Release -derivedDataPath build/Release-arm64 ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
xcodebuild -scheme niko-shot -configuration Release -derivedDataPath build/Release-x86_64 ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build
scripts/ci-package.sh build/Release-arm64/Build/Products/Release/niko-shot.app build/local-ci-packages arm64
scripts/ci-package.sh build/Release-x86_64/Build/Products/Release/niko-shot.app build/local-ci-packages x86_64
scripts/release-manifest.py build/local-ci-packages
scripts/release-manifest.py build/local-ci-packages --verify
```

`ci-package.sh APP OUTPUT arm64|x86_64` 校验输入只含指定架构，使用私有临时副本签名，保留原应用；发现目标目录已有该架构同名资产时拒绝覆盖。`release-manifest.py OUTPUT` 核对两架构并生成汇总与校验文件，`--verify` 只核验已有的完整资产集。当前发布统一使用此流程，Developer ID 与公证凭据按上表注入。
