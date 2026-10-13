# 版本发布与官网部署

应用以 `vMAJOR.MINOR.PATCH` 标签发布正式 GitHub Release，版本号与 `project.yml` 的 `MARKETING_VERSION` 一致。下载入口使用 [Latest Release](https://github.com/baogutang/niko-shot/releases/latest)，官网地址为 [baogutang.github.io/niko-shot](https://baogutang.github.io/niko-shot/)。

## 安装包与版本身份

支持 macOS 14 或更新版本。Apple Silicon 与 Intel 各自独立构建，不分发 Universal 安装包。

| 适用芯片 | 安装包 | 构建信息 |
|---|---|---|
| M 芯片 · arm64 | `niko-shot-arm64.dmg`、`niko-shot-arm64.zip` | `release-info-arm64.json` |
| Intel · x86_64 | `niko-shot-x86_64.dmg`、`niko-shot-x86_64.zip` | `release-info-x86_64.json` |
| 公共文件 | `SHA256SUMS` | `release-info.json` |

每个版本包含上述 8 个文件。SHA256SUMS 覆盖 4 个安装包与 3 份 manifest，汇总 manifest 使用 schema 2，`variants.arm64` 与 `variants.x86_64` 保存单架构身份和主二进制哈希。两份 manifest 的 version、build、bundleIdentifier、minimumMacOS、commit、sourceProvenance、runUrl、signing、teamIdentifier、notarized 必须一致。

官网读取 GitHub 的 `/releases/latest`，仅接受正常版本标签、`draft: false`、`prerelease: false`，并确认 8 个资产均完整上传、非空、名称唯一、下载地址属于同一版本。检查通过后同时启用两种芯片的下载。读取失败时保留正式 Release 入口；无 JavaScript 时仍提供两种芯片的入口。

## 发布步骤

1. 完成代码修改，更新 `project.yml` 的版本号。
2. 在 `docs/releases/v版本号.md` 编写面向用户的更新说明。
3. 推送 main，检查代码与官网工作流结果。
4. 创建与该提交对应的版本标签，例如 `v0.1.3`，再推送标签。
5. 等待版本工作流完成，核对公开 Release、Latest 指向、8 个资产及 SHA256。

`build.yml` 对 main、PR 和版本标签执行干净 Debug 构建与全部 hosted tests，使用 Swift 6 完整并发检查，并将编译警告作为错误。仅版本标签会导入分发凭据、分别构建优化的 arm64 与 x86_64 Release、打包和发布。标签格式、应用版本与版本说明在构建前校验。

发布任务先核对完整包的哈希、版本与源码提交，再创建未公开的 Release，上传全部资产，核对 GitHub 返回的大小与 SHA256 后一次公开。发布状态为 `draft: false`、`prerelease: false`。新版本设为 Latest；发布较旧版本不会回退 Latest。正式标签与安装包不滚动覆盖。既有发布不会自动替换本机应用。

## GitHub Actions

| 流程 | 触发 | 输出 | 可写权限 |
|---|---|---|---|
| `build.yml` 测试 | main 推送、面向 main 的 PR、版本标签、手动运行 | 构建日志、测试与 xcresult | 仅读仓库 |
| `build.yml` 打包与发布 | 通过测试的版本标签 | 分芯片安装包、manifest、校验文件、正式 Release | 仅发布 job 的 `contents: write` |
| `pages.yml` 验证 | main 推送、面向 main 的 PR、手动运行 | 静态文件、资源及下载逻辑检查 | 仅读仓库 |
| `pages.yml` 部署 | main 的验证通过后 | GitHub Pages 官网 | `pages: write`、`id-token: write` |

PR 不导入签名凭据、不发布、不部署。版本发布任务串行，避免同时更改 Latest。Actions 的诊断与安装包 artifacts 保留 14 天，公开 Release 资产独立保存。

构建环境使用 `macos-15` 与 `/Applications/Xcode_26.3.app/Contents/Developer`，构建期安装 XcodeGen。应用运行时不增加第三方依赖。测试在 runner 的原生 arm64 上执行，Intel 安装包独立交叉构建；自动测试、构建与具体设备上的验证分别记录在 [ACCEPTANCE.md](ACCEPTANCE.md)。

官方 Actions 均固定到完整 commit SHA：

| Action | 版本 | SHA |
|---|---|---|
| checkout | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| upload-artifact | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| download-artifact | v8.0.2 | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |
| configure-pages | v6.0.0 | `45bfe0192ca1faeb007ade9deae92b16b8254a0d` |
| upload-pages-artifact | v5.0.0 | `fc324d3547104276b827a68afc52ff2a11cc49c9` |
| deploy-pages | v5.0.1 | `368f82528645a54fb793d4d04e342629a3f51346` |

## 签名与 Apple 公证

GitHub 正式 Release 的发布状态与 Apple 的签名、公证状态分别记录。当前未配置 Developer ID 凭据，安装包使用 ad hoc 签名，`notarized: false`。发布元数据和 DMG 内的安装说明保留实际状态；不会把 Release 标签视为 Apple 已公证。

维护者可使用现有 Developer ID Application 证书及公证账户配置以下 Actions secrets：

| Secret | 用途 |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | 含私钥的 Developer ID Application P12 的 Base64 |
| `MACOS_CERTIFICATE_PASSWORD` | P12 导出密码，无密码时可为空 |
| `DEVELOPER_ID_APPLICATION` | 完整的 `Developer ID Application: 名称 (TEAMID)` 身份 |
| `APPLE_ID` | 公证账户 |
| `APPLE_APP_PASSWORD` | 公证的 app-specific password |
| `APPLE_TEAM_ID` | Developer Team ID |

证书前三项启用 Developer ID 签名；公证账户三项必须完整。混合或缺失配置会使任务失败。私钥仅在版本构建的临时 Keychain 中导入，成功或失败后都清理。

启用公证时，先提交应用 ZIP 并要求 `Accepted`，再 staple 和校验应用；随后提交已签名 DMG，staple 并校验 DMG。最终 ZIP 包含已 staple 的应用。只有本次实际完成后才记录 `notarized: true`。[Apple 公证文档](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 本机分架构打包

```sh
xcodegen generate
xcodebuild -scheme niko-shot -configuration Release -derivedDataPath build/Release-arm64 ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
xcodebuild -scheme niko-shot -configuration Release -derivedDataPath build/Release-x86_64 ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build
scripts/ci-package.sh build/Release-arm64/Build/Products/Release/niko-shot.app build/local-ci-packages arm64
scripts/ci-package.sh build/Release-x86_64/Build/Products/Release/niko-shot.app build/local-ci-packages x86_64
python3 scripts/release-manifest.py build/local-ci-packages
python3 scripts/release-manifest.py build/local-ci-packages --verify
```

本机打包不执行远程发布。`scripts/distribute.sh` 可对两份应用执行同样的分架构打包与汇总；`NOTARY_PROFILE` 用于已配置的本机公证凭据。
