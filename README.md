# AnotherPhotoFrame

**Create once. Export anywhere.**

[![CI](https://github.com/Jeremy233/another_photo_frame/actions/workflows/ci.yml/badge.svg)](https://github.com/Jeremy233/another_photo_frame/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

[中文](#中文) · [English](#english)

---

## 中文

AnotherPhotoFrame 是一个免费、开源、完全在本地运行的 macOS 摄影发布工具。它只处理已经在 Lightroom、Photoshop、Capture One 等软件里修完并导出的成片，把「后期完成 → 发布成品」这一段流程做成可重复的预设：一次设置，批量导出到 Instagram、小红书、抖音。它不是修图软件，也不依赖任何在线服务。

### 功能概览（V1 目标）

- **完整嵌入画布**：照片按比例完整放进目标画布，保证最小留白，不裁切。
- **留白与背景**：精确控制边距和背景色。
- **全景无缝切片**：超宽幅照片生成封面 + 连续切片，在轮播里左右滑动时接缝处像素连续。
- **水印与 EXIF 图层**：统一的图层模型，支持文字、水印、器材与拍摄参数。
- **摄影级色彩管理**：保留 ICC，色彩管线可测试；SDR / HDR 输出边界明确。
- **预设与本地素材库**：预设可分享，但不携带你的私有素材。
- **批量任务与原子导出**：任务队列、进度、取消与重试。
- **CLI 与本地 MCP**：GUI 能做的每件事都能用命令行完成，方便脚本和 AI 调用。

系统要求：macOS 26 或更高版本，仅支持 Apple Silicon。

### 开发状态

项目目前处于**规范阶段**，还没有可用的应用。

| 模块 | 状态 |
|---|---|
| 产品与技术规范 | 审阅中（Draft） |
| `PhotoFrameCore`：画布几何（Fit、比例裁切、全景切片） | ✅ 已完成 |
| `PhotoFrameStorage`：`.photoframe` 预设包、素材绑定（SlotResolver）、平台配置、内置预设 | ✅ 已完成 |
| `PhotoFrameApplication`：任务队列、原子导出、PhotoFrameService（预设、检查、校验、预览、提交、状态、取消）；接入渲染模块，GUI / CLI / MCP 共用 | ✅ 已完成 |
| `PhotoFrameRendering`：解码、色彩管理、合成、全景切片、图层、JPEG / PNG（SDR / HDR）编码、预览 | ✅ 已完成 |
| CLI `photoframe`（`Tools/photoframe`）：`export`、`preview`、`image inspect`、`preset …`（列出、导入、导出、复制、重命名、删除）、`asset …`（素材库与绑定），见 [docs/CLI.md](docs/CLI.md) | ✅ 已完成 |
| MCP、GUI | 未开始 |

Alpha / Beta 版本不做代码签名；V1.0 发布前再决定是否公证。

### 构建与测试

需要 macOS 26+、Apple Silicon，以及 Xcode 26（Swift 6.2 或更高）。

每个模块都是 `Packages/` 下一个独立的 Swift Package，命令行工具在 `Tools/photoframe`，分别构建和测试：

```bash
cd Packages/PhotoFrameCore
swift test
```

> **iCloud 同步目录**：如果仓库放在 iCloud 同步的目录（如 `~/Desktop`、`~/Documents`）下，File Provider 会给构建产物加上扩展属性，测试包 ad-hoc 签名会失败（`resource fork, Finder information, or similar detritus not allowed`）。这时把构建目录放到同步目录之外：
>
> ```bash
> swift test --scratch-path "$TMPDIR/PhotoFrameCore-build"
> ```

**持续集成**：GitHub Actions 在每次 push 和 Pull Request 时，对 `Packages/` 下的每个 Package 运行 `swift test`。运行环境是 GitHub 托管的 `macos-26` runner（macOS 26，Apple Silicon），使用 **Xcode 26.6**。配置见 [`.github/workflows/ci.yml`](.github/workflows/ci.yml)。

### 文档

- [产品与技术规范](PhotoFrame_V1_Specification.md)
- [UI 设计](Another%20Photo%20Frame%20UI%20Design.md)
- [规范插图](docs/illustrations/README.md)
- [PhotoFrameCore 说明](Packages/PhotoFrameCore/README.md)
- [PhotoFrameStorage 说明](Packages/PhotoFrameStorage/README.md)
- [PhotoFrameRendering 说明](Packages/PhotoFrameRendering/README.md)与[渲染管线](docs/RenderingPipeline.md)

### 参与贡献

欢迎提交代码和预设，**不接受任何素材**（Logo、线稿、字体、图片等）。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

### 素材与版权

AnotherPhotoFrame 不内置任何相机品牌的 Logo 或线稿。你导入的照片、Logo、字体等素材的版权由你自己负责。

### 支持项目

AnotherPhotoFrame 免费使用。如果它对你有帮助，欢迎自愿打赏：

- <!-- TODO: 打赏渠道 1 -->（待补充）
- <!-- TODO: 打赏渠道 2 -->（待补充）

打赏完全自愿，不会解锁任何额外功能。

### 许可证

[Apache License 2.0](LICENSE)。Copyright 2026 Jeremy233。

---

## English

AnotherPhotoFrame is a free, open-source macOS publishing tool for photographers that runs entirely on your Mac. It works only on finished photos you have already edited and exported from Lightroom, Photoshop, Capture One and similar apps, and turns the "edit done → ready to post" step into repeatable presets: set it up once, then batch-export for Instagram, Xiaohongshu (RedNote) and Douyin. It is not a photo editor and does not depend on any online service.

### Features (V1 goals)

- **Full-fit canvas**: the whole photo is placed in the target canvas with guaranteed minimum margins, never cropped.
- **Margins and background**: precise control over padding and background color.
- **Seamless panorama slices**: ultra-wide photos become a cover plus continuous slides whose pixels line up across every seam in a carousel.
- **Watermark and EXIF layers**: one overlay model for text, watermarks, gear and shooting parameters.
- **Photographic color management**: ICC profiles are preserved, the color pipeline is testable, and SDR / HDR output boundaries are explicit.
- **Presets and a local asset library**: presets can be shared without carrying your private assets.
- **Batch jobs and atomic export**: job queue, progress, cancel and retry.
- **CLI and local MCP**: everything the GUI can do is also available from the command line, for scripts and AI tools.

Requirements: macOS 26 or later, Apple Silicon only.

### Status

The project is in the **specification stage**; there is no usable app yet.

| Module | Status |
|---|---|
| Product and technical specification | In review (draft) |
| `PhotoFrameCore`: canvas geometry (fit, aspect crop, panorama slicing) | ✅ Done |
| `PhotoFrameStorage`: `.photoframe` preset packages, asset binding (SlotResolver), platform catalog, built-in presets | ✅ Done |
| `PhotoFrameApplication`: job queue, atomic export, PhotoFrameService (presets, inspect, validate, preview, submit, status, cancel); wired to the rendering module, shared by GUI / CLI / MCP | ✅ Done |
| `PhotoFrameRendering`: decoding, color management, compositing, panorama slicing, overlays, JPEG / PNG (SDR / HDR) encoding, preview | ✅ Done |
| CLI `photoframe` (`Tools/photoframe`): `export`, `preview`, `image inspect`, `preset …` (list, import, export, duplicate, rename, delete), `asset …` (asset library and bindings); see [docs/CLI.md](docs/CLI.md) | ✅ Done |
| MCP, GUI | Not started |

Alpha / Beta builds are not code-signed; whether to notarize will be decided before V1.0.

### Build and test

Requires macOS 26+, Apple Silicon and Xcode 26 (Swift 6.2 or later).

Each module is a standalone Swift Package under `Packages/`, and the command-line tool lives in `Tools/photoframe`; each is built and tested on its own:

```bash
cd Packages/PhotoFrameCore
swift test
```

> **iCloud-synced folders**: if the repository lives in an iCloud-synced folder (such as `~/Desktop` or `~/Documents`), File Provider adds extended attributes to build products and ad-hoc signing of the test bundle fails (`resource fork, Finder information, or similar detritus not allowed`). Put the build directory outside the synced folder:
>
> ```bash
> swift test --scratch-path "$TMPDIR/PhotoFrameCore-build"
> ```

**Continuous integration**: GitHub Actions runs `swift test` for every package under `Packages/` on each push and pull request. It uses the GitHub-hosted `macos-26` runner (macOS 26, Apple Silicon) with **Xcode 26.6**. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

### Documentation

The documents are currently written in Chinese.

- [Product and technical specification](PhotoFrame_V1_Specification.md)
- [UI design](Another%20Photo%20Frame%20UI%20Design.md)
- [Specification illustrations](docs/illustrations/README.md)
- [PhotoFrameCore notes](Packages/PhotoFrameCore/README.md)
- [PhotoFrameStorage notes](Packages/PhotoFrameStorage/README.md)
- [PhotoFrameRendering notes](Packages/PhotoFrameRendering/README.md) and [rendering pipeline](docs/RenderingPipeline.md)

### Contributing

Code and presets are welcome; **assets of any kind are not accepted** (logos, line art, fonts, images, …). See [CONTRIBUTING.md](CONTRIBUTING.md). Please report security issues privately as described in [SECURITY.md](SECURITY.md).

### Assets and copyright

AnotherPhotoFrame does not bundle any camera brand logos or line art. You are responsible for the rights to any photos, logos, fonts or other assets you import.

### Support the project

AnotherPhotoFrame is free. If it helps you, voluntary donations are welcome:

- <!-- TODO: donation channel 1 -->(to be added)
- <!-- TODO: donation channel 2 -->(to be added)

Donations are entirely optional and unlock nothing.

### License

[Apache License 2.0](LICENSE). Copyright 2026 Jeremy233.
