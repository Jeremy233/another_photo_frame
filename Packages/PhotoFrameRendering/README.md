# PhotoFrameRendering

从源图文件到成品文件的完整渲染：解码（ICC、EXIF、方向、HDR）→ 合成（缩放、背景、全景切片、图层）→ 编码（JPEG / PNG，SDR / HDR gain map）。
GUI 预览用同一条管线的预览模式（降采样，返回内存中的位图）。
依赖 `PhotoFrameCore`（几何、预设）和 `PhotoFrameStorage`（素材解析结果），使用 ImageIO、Core Image、Core Graphics、Core Text。

设计与每一步的颜色规则见 [docs/RenderingPipeline.md](../../docs/RenderingPipeline.md)。
实现时提出的 14 个问题已由用户确认，对应规范 D-56 … D-69（列表见该文档 §4）。

## 运行测试

```bash
swift test --scratch-path "$TMPDIR/PhotoFrameRendering-build"
```

仓库在 iCloud 同步目录下时必须加 `--scratch-path`，原因见 `PhotoFrameCore/README.md`。

## 文件一览

| 文件 | 内容 |
|---|---|
| `RenderJob.swift` | 对外类型：`RenderJob`、`RenderAsset`、`RenderProgress`、`RenderedOutput`、`RenderDiagnostics`、`RenderWarning`、`RenderError` |
| `PhotoFrameRenderer.swift` | 入口 `render(job:progress:)` 与 `renderPreview(_:)`：共用的前半段、阶段、进度、取消、清理 |
| `Preview.swift` | 预览类型：`PreviewRequest`、`PreviewSize`、`PreviewColorMode`、`PreviewResult`、`PreviewPage`；导出 → 预览坐标映射 |
| `PageLayout.swift` | 预设 → 每页参数（调用 Core 的 Fit / Crop / Panorama / OverlayPlacement）；图层内容准备 |
| `SourceDecoder.swift` | 解码、降采样、输入 ICC 决策、HDR 识别、画面峰值 |
| `FileInspection.swift` | 文件头识别、ICC 是否真的存在、JPEG 段遍历 |
| `ICCProfile.swift` | 最小 ICC 读写：TRC 求值、参数曲线改写（PoC 坑 20）、线性化配置文件 |
| `TIFFGainMap.swift` | 经典 TIFF 解析、ISO 21496-1 元数据、「最大化兼容性」TIFF 的 HDR 还原 |
| `PageComposer.swift` | 照片缩放（Lanczos）、tone map、页面合成 |
| `OverlayContent.swift` | 文字（Core Text）、PNG、SVG 绘制成工作空间图像 |
| `RestrictedSVG.swift` | 受限 SVG 解析与绘制（D-09） |
| `Metadata.swift` | `metadataText` 占位符；输出元数据策略（D-06） |
| `OutputEncoder.swift` | SDR / HDR 编码、JPEG ICC 补插、HDR 元数据合并 |
| `WorkingColor.swift` | 工作空间（D-03）、CIContext、预设颜色 |
