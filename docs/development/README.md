# 开发说明

这里是给开发者和贡献者的技术信息：模块结构、开发状态、构建与测试、持续集成。使用说明见仓库根目录的 [README](../../README.md)。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `Packages/PhotoFrameCore` | 画布几何（完整嵌入、比例裁切、全景切片）、图层定位、预设模型 |
| `Packages/PhotoFrameStorage` | `.photoframe` 预设包、预设库、素材库与绑定、平台配置、内置预设 |
| `Packages/PhotoFrameRendering` | 解码、色彩管理、合成、图层、JPEG / PNG（SDR / HDR）编码、预览 |
| `Packages/PhotoFrameApplication` | 任务队列、原子导出、`PhotoFrameService`（GUI / CLI / MCP 共用） |
| `Tools/photoframe` | 命令行工具 `photoframe` 与本地 MCP 服务器 `photoframe mcp serve` |
| `Apps/PhotoFrameMac` | macOS 应用（SwiftUI + AppKit），界面代码在 `PhotoFrameMacKit` 包里；图标素材在 `Design/AppIcon` |
| `Experiments/ColorPoC` | 色彩 PoC 工具，结论见 [color-poc-report.md](color-poc-report.md) |
| `docs/` | 文档，索引见 [docs/README.md](../README.md) |

## 开发状态（v0.9.1）

| 模块 | 状态 |
|---|---|
| 产品与技术规范（[PhotoFrame_V1_Specification.md](../design/PhotoFrame_V1_Specification.md)，决策 D-01…D-128） | 审阅中（Draft） |
| `PhotoFrameCore` | ✅ 已完成 |
| `PhotoFrameStorage` | ✅ 已完成 |
| `PhotoFrameRendering`（[渲染管线](RenderingPipeline.md)） | ✅ 已完成 |
| `PhotoFrameApplication` | ✅ 已完成 |
| CLI `photoframe`（[CLI.md](../usage/CLI.md)） | ✅ 已完成 |
| 本地 stdio MCP（[MCP.md](../usage/MCP.md)） | ✅ 已完成 |
| GUI `AnotherPhotoFrame.app` | ✅ 可用，持续打磨中 |
| 代码签名与公证（D-21） | 未定；v0.9.1 未签名 |
| 平台实测：小红书、抖音的 HDR、PNG 与文件大小上限（D-17、D-30） | 待实测 |

v1.0 发布前还要完成：签名方式、平台实测、色彩验收阈值定稿（D-19）。

## 构建与测试

需要 macOS 26+、Apple Silicon、Xcode 26（Swift 6.2 或更高）。

每个模块都是独立的 Swift Package，分别构建和测试：

```bash
cd Packages/PhotoFrameCore
swift test
```

> **iCloud 同步目录**：仓库如果放在 iCloud 同步的目录（如 `~/Desktop`、`~/Documents`）下，File Provider 会给构建产物加上扩展属性，测试包的 ad-hoc 签名会失败（`resource fork, Finder information, or similar detritus not allowed`）。把构建目录放到同步目录之外：
>
> ```bash
> swift test --scratch-path "$TMPDIR/PhotoFrameCore-build"
> ```

构建应用（不签名）：

```bash
xcodebuild -project Apps/PhotoFrameMac/PhotoFrameMac.xcodeproj -scheme PhotoFrameMac \
  -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Release/AnotherPhotoFrame.app
```

Xcode 工程由 `Apps/PhotoFrameMac/project.yml` 用 XcodeGen 生成，改了 `project.yml` 之后运行 `xcodegen generate` 并提交生成的工程。图标改动见 [Apps/PhotoFrameMac/Design/AppIcon](../../Apps/PhotoFrameMac/Design/AppIcon/README.md)。

构建命令行工具：

```bash
swift build -c release --package-path Tools/photoframe
```

## 发布

在签名方式（D-21）定下来之前，发布包用 **ad-hoc 签名**。只用 `CODE_SIGNING_ALLOWED=NO` 构建的应用只有链接器给可执行文件加的签名，资源文件（图标、`Assets.car`）没有签名清单（`Contents/_CodeSignature` 不存在）。用户下载后 macOS 会说应用「已损坏」，而且「隐私与安全性」里不会出现「仍要打开」。v0.9.0 第一次上传的包就是这样，后来已经替换。

```bash
xcodebuild -project Apps/PhotoFrameMac/PhotoFrameMac.xcodeproj -scheme PhotoFrameMac \
  -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
APP=build/Build/Products/Release/AnotherPhotoFrame.app

# ad-hoc 签名：给资源生成签名清单，并开启 hardened runtime
codesign --force --deep --options runtime --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"   # 必须显示 valid on disk

# 打包，并在解压后的副本上再验证一次
ditto -c -k --sequesterRsrc --keepParent "$APP" AnotherPhotoFrame-<版本>-macOS.zip

# 命令行工具：只有一个可执行文件，平台配置编译在程序里（D-126），不再带 .bundle
swift build -c release --package-path Tools/photoframe --scratch-path "$TMPDIR/photoframe-release"
ditto -c -k --keepParent "$TMPDIR/photoframe-release/release/photoframe" photoframe-<版本>-macOS.zip
```

上传到 GitHub Release 之前，把两个 zip 解压到另一个目录检查：应用再运行一次 `codesign --verify --deep --strict`；命令行工具解压后只有 `photoframe` 一个文件，在那个目录里运行 `./photoframe --version` 和 `./photoframe preset list`。`spctl -a` 对 ad-hoc 签名的应用总是返回 `rejected`，这是正常的：没有经过 Apple 公证。用户第一次打开时，到「系统设置 → 隐私与安全性」点「仍要打开」，或者运行 `xattr -dr com.apple.quarantine`。

## 持续集成

GitHub Actions 在每次 push 和 Pull Request 时，对 `Packages/`、`Tools/`、`Apps/` 下的每个 Swift Package 运行 `swift test`，并不签名构建一次应用。运行环境是 GitHub 托管的 `macos-26` runner（Apple Silicon），使用 Xcode 26.6，比开发机的编译器旧，写代码时避免过于复杂的单行表达式。配置见 [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)。

## 参与贡献

见 [CONTRIBUTING.md](../CONTRIBUTING.md)；安全问题按 [SECURITY.md](../SECURITY.md) 私下报告。
