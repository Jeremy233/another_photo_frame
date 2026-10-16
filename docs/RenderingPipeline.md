# 渲染管线（PhotoFrameRendering）

> 对应规范 §5、§6、§7、§9.1、§13.2。代码在 `Packages/PhotoFrameRendering`，依赖 `PhotoFrameCore`（几何、预设模型）与 `PhotoFrameStorage`（素材解析结果）。
> 色彩相关的每条规则都来自[色彩 PoC 报告](color-poc-report.md)，文中的「坑 N」指报告 §5 的编号。

## 1. 对外接口

```swift
let renderer = PhotoFrameRenderer()          // 可被多个任务并发使用
let result = try await renderer.render(job: RenderJob(
    sourceURL: source,                       // 只读
    preset: presetSnapshot,                  // 排队时的预设快照（§8.3）
    assets: assets,                          // slotId → RenderAsset(fileURL, format)
    skippedLayerIds: skipped,                // SlotResolution.skippedLayerIds
    outputDirectory: tempDir,                // 调用方创建的临时目录
    sourceColorOverride: nil,                // D-04：按源图或任务覆盖输入色彩空间
    maxCarouselItems: platform.maxCarouselItems,
    metadataOverrides: ["camera": "Mamiya 7"]
)) { progress in … }                        // decoding → rendering → encoding

result.outputs      // [RenderedOutput]：角色、文件、尺寸、动态范围、ICC、headroom、字节数、照片矩形、图层矩形
result.diagnostics  // RenderDiagnostics：源格式、方向、位深、ICC 来源、HDR 类型、tone map 方法、颜色变换步骤
result.warnings     // [RenderWarning]：稳定 code + 中文 message + 页码 / 图层
```

- `RenderJob.assets(from: SlotResolution, fileURL:)` 把 `SlotResolver` 的结果和素材库路径拼成素材表。
- 渲染器只把成品写进 `outputDirectory`，文件名固定：单页／封面 `00.<ext>`，切片 k 为 `<k+1 两位数>.<ext>`。
  命名、冲突处理、校验后原子发布由 PhotoFrameApplication 负责（§9.2）。目标文件已存在时不覆盖，报 `render.write_failed`。
- 取消：在阶段之间和每一页之前检查 `Task.isCancelled`；取消或出错时删除本次写出的文件，再抛出 `CancellationError` / `RenderError`。
- 错误：`RenderError(code, message, hint)`，code 稳定（`render.*`，几何与图层错误沿用 Core 的 `geometry.*`、`overlay.*`）。

预览（§11.2 `renderPreview`，详见 2.7）：

```swift
let preview = try await renderer.renderPreview(PreviewRequest(
    sourceURL: source, preset: presetSnapshot,
    size: .maxLongEdge(1200),                // 或 .scale(0.25)；不大于导出尺寸
    assets: assets, skippedLayerIds: skipped,
    pages: [0],                              // 只渲染封面；nil = 全部
    color: .sRGB                             // 或 .extendedRange（HDR 显示）
))                                           // 也可 PreviewRequest(job: renderJob, size:)

preview.pages     // [PreviewPage]：角色、CGImage、预览／导出尺寸、照片矩形、图层矩形（预览与导出两套坐标）
preview.roles     // 导出会写出的全部页，供 [Cover] [Slide 1] … 切换
preview.scaleX / scaleY, preview.diagnostics, preview.warnings
```

只读入口（§11.2 `inspectSource`、`validate`）：

```swift
let info = try renderer.inspect(source)       // InspectedSource：格式、尺寸、方向、位深、ICC 来源、HDR 判定（D-62）、EXIF 摘要、有无 GPS / 作者
let plan = try renderer.plan(sourceURL: source, preset: presetSnapshot, maxCarouselItems: 20)
plan.pages                                    // [PlannedPage]：与 render(job:) 相同的版式，只读文件属性、不解码像素
```

应用层通过 `PhotoFrameEngine.RenderingBackend` 使用这些入口（任务队列的 `JobRenderer`、服务的 `ImageAnalyzer`）。

## 2. 流程

```text
probe（读属性：尺寸、方向）
  → PageLayout：FitLayout / CropLayout / PanoramaLayout（PhotoFrameCore，不重算几何）
  → 解码（按输出所需尺寸的 2 倍降采样，D-18）→ 输入颜色决策 → HDR 识别
  → 图层：内容 → OverlayLayer.geometry → OverlayPlacement / overlayPlan（Core）→ 绘制
  → 每页：背景 + 照片 + 图层，在工作空间合成
  → 编码：SDR（sRGB 8-bit → ImageIO）或 HDR（CI gain map JPEG）→ 补 ICC → 写临时文件
```

### 2.1 解码与输入颜色（§6.2、D-04）

| 步骤 | 做法 | 依据 |
|---|---|---|
| 格式 | 自己看文件头；HEIC 报 `render.unsupported_format` | D-02；坑 18（ImageIO 会把 gain map JPEG 报成 HEIC） |
| 有没有 ICC | 自己解析：JPEG APP2、PNG `iCCP`/`sRGB`/`cICP`/`gAMA+cHRM`、TIFF 34675 | 坑 1 |
| 缺 ICC | 按 sRGB 解释，警告 `source.profile_missing`；可用 `sourceColorOverride` 覆盖 | D-04 |
| 降采样 | ImageIO 缩略图 API（保留颜色空间、位深，应用方向）；不需要缩小时完整解码 | D-18，PoC §4 |
| 浮点源 | 先用 CG 转成 RGBAh 再交给 CI | 坑 15，§6.2 |
| BT.709/2020 参数曲线 ICC | TRC 为 `para` type 3、g≈2.222、d≈0.081 时改写成 4096 点 `curv`，按 ICC 本身解码 | 坑 20（ColorSync 当 γ2.4 解码，偏暗约 16%） |

### 2.2 HDR 识别与 SDR 版本（§6.7）

| 源 | 识别 | SDR 输出 | HDR headroom |
|---|---|---|---|
| gain map JPEG（ISO 21496-1 / Apple） | ImageIO 辅助数据 | 文件底图（不 tone map） | 文件元数据（CI 展开后的 `contentHeadroom`） |
| Lightroom「最大化兼容性」TIFF | 自己解析 SubIFD（Photometric 52553、标签 52557） | IFD0 主图 | 元数据两个 headroom 取大者（Lightroom 32 位文件会写反） |
| PQ / HLG PNG、TIFF | 颜色空间使用 ITU-R 2100 传递函数 | `CIToneMapHeadroom`，source = 画面峰值，target = 1 | 画面峰值 |
| 浮点 TIFF，峰值 > 1 | `IsFloat` 且数据超过 SDR 白 | 同上 | 画面峰值 |

**「明确是 HDR」的判定（D-62）**：源文件满足下面任一条才按 HDR 处理，否则按 SDR。

1. 带 gain map：JPEG 的 ISO 21496-1 或 Apple gain map 辅助数据；TIFF 的 SubIFD gain map（Photometric 52553 或标签 52557）。
2. 颜色描述使用 HDR 传递函数：ICC 或 PNG `cICP` 为 PQ / HLG（`CGColorSpaceUsesITUR_2100TF` 或 `isHDR()`）。
3. 浮点数据（16 / 32 位 float）里有超过 SDR 白的值（画面峰值 > 1.0001）。数据本身超出 SDR 范围就是 HDR 内容，
   按 SDR 处理只能硬截断，违反 §6.7 第 4 条；Lightroom 32 位 HDR TIFF 也没有任何 HDR 标记（坑 16），只能靠这一条识别。

没有标记的整数图（8 / 16 位）一律按 SDR；没有标记、峰值 ≤ 1 的浮点图按 SDR。
标为 HDR（第 1、2 条）但画面峰值 ≤ SDR 白时：仍记为 HDR 源，headroom 取 1；SDR 输出直接用图像本身、不做 tone map
（headroom 1 时曲线没有意义，`sdrMethod = none`）；请求 HDR 输出时改写 SDR，警告 `output.hdr_no_headroom`
（gain map 的增益全为 1 时没有意义）。

- 画面峰值 = 线性 sRGB 分量最大值的 99.95 分位（降到长边 1024 统计），不用 PQ 元数据的默认 4.93。
- 兼容 TIFF：只支持经典 TIFF、未压缩、交错、条带布局；底图按 ICC 曲线自己线性化（同样绕开坑 20），与 gain map 一起按 `step × step` 盒式平均降采样后按 ISO 21496-1 完全展开（weight = 1）。解析失败时按 SDR 读入，警告 `source.hdr_not_read`。
- tone map 只作用于照片图层；背景、水印、文字是 SDR 元素，按参考白放置（§6.7 第 3 条、坑 10）。

### 2.3 合成（§6.4、§6.5、§5）

- 工作空间 extended linear Rec.2020，`workingFormat = RGBAh`，`cacheIntermediates = false`（D-03）。
- 照片缩放：`clampedToExtent` → `CILanczosScaleTransform`（x、y 分别缩放到 D-22 的像素尺寸）→ 裁回整数矩形（坑 7）。比例裁切先在源图里平移到裁切框再缩放。
- 全景：照片在长卷里只缩放一次（`pixelImageRect` 尺寸），每张切片做整数平移后裁出 `[kW, (k+1)W)`。测试验证切片拼起来与整条长卷逐像素相同。
- 背景：预设 hex 按 sRGB 编码构造 `CIColor`，由 CI 转入工作空间；无损 PNG 输出精确等于原值（测试验证 `#FAFAF8` → `(250,250,248)`）。全景切片用 `padColor`。
- 图层：按 `zIndex` 升序（同值按预设顺序）。
  - 文字：Core Text 画进 extended linear Rec.2020 的 RGBAh 上下文（坑 8）；框比文字小时等比缩小，不放大；水平对齐跟随锚点，竖直居中。
  - PNG：先用 CG 画成预乘 RGBAh，再双线性缩放（坑 7；CI 直接对非预乘 PNG 采样会在浅色背景上出现灰边，测试 `alphaHalo` 覆盖）；等比放进图层框并居中。
  - SVG：受限解析（下节），矢量直接画到最终尺寸。
  - 不透明度：只缩放 alpha（CI 颜色滤镜在非预乘值上运算）；50% 白叠在 `#202020` 上得到 189（线性光），不是 144（gamma 空间）。

### 2.4 受限 SVG（D-09）

支持 `svg`、`g`、`path`（全部命令，含圆弧）、`rect`、`circle`、`ellipse`、`line`、`polyline`、`polygon`；属性 `fill`、`stroke`、`stroke-width`、各种 `opacity`、`fill-rule`、线帽线接、`transform`、`style` 中的同名声明。
整个文件拒绝（`render.svg_rejected`）：DOCTYPE / ENTITY、`script`、`foreignObject`、`image`、`use`、`iframe`、`style` 元素、任何 `href`、`on*` 属性、`url(` / `javascript:` / `data:` 取值、超过 2 MiB 或 20 000 个元素。`title`、`desc`、`metadata` 忽略；其他元素（渐变、文字、滤镜）连同子树跳过并警告 `overlay.svg_partial`。

### 2.5 `metadataText` 占位符

`{camera}`、`{make}`、`{model}`、`{lens}`、`{focalLength}`、`{focalLength35}`、`{aperture}`、`{shutter}`、`{iso}`、`{date}`，取自 EXIF / TIFF 字典；`RenderJob.metadataOverrides` 优先。缺失的字段连同它旁边多余的分隔符一起去掉（D-64），并警告 `overlay.metadata_missing`：

- 分隔符是两个占位符之间的文字；有值的占位符按原顺序拼接，每个值前面用它自己左侧的分隔符，第一个有值的不带分隔符。`{a} · {b} · {c}` 缺 b → `A · C`。
- 前缀跟随第一个占位符、后缀跟随最后一个占位符，对应的值缺失时一起去掉：`Shot on {camera} ({lens})` 缺 lens → `Shot on Z 8`。
- 逐行处理；一个值都没有的行整行去掉。整段都空了就不画这个图层（另有 `overlay.empty_text` 警告）。

### 2.6 编码与元数据（§6.8、D-06）

- SDR：CI 把页面渲染成 sRGB 8-bit（超出 sRGB 的颜色逐通道截断），再交给 ImageIO 编码（坑 3：只有 sRGB 8-bit 输入时 ImageIO 不改像素）。JPEG 质量 = `quality / 100`（默认 Q100）。
- HDR（只支持 JPEG）：`CIContext.jpegRepresentation` + `.hdrImage`，HDR 图显式 `settingContentHeadroom(源 headroom)`，`.hdrGainMapAsRGB`（坑 4、5、17）。源图不是 HDR 时按 SDR 输出并警告 `output.hdr_source_not_hdr`；HDR + PNG 报 `render.hdr_format_unsupported`。
- ICC：ImageIO 写 sRGB JPEG 不嵌 ICC（坑 2），写完检查，缺了就在 JFIF / EXIF 段之后插入 APP2 `ICC_PROFILE`（插在 MPF 段之前，gain map 偏移不受影响，测试验证）。PNG 由 ImageIO 写 `sRGB` 块。
- 元数据默认全部不写出；方向不写（像素已校正）。三个独立开关（预设 `output.metadata`）：
  - `keepShootingInfo`「保留拍摄参数」：Make、Model 与曝光／镜头相关的 EXIF 键。
  - `keepGps`「保留 GPS」：GPS 字典。
  - `keepAuthorAndCopyright`「保留作者和版权」（D-63，默认 false，旧预设缺字段时为 false）：作者取 TIFF Artist → IPTC By-line → XMP `dc:creator` 中第一个非空值，版权取 TIFF Copyright → IPTC CopyrightNotice → XMP `dc:rights`；写成 TIFF Artist / Copyright 与 IPTC By-line / CopyrightNotice。ImageIO 写文件时把 Artist 存成 XMP `dc:creator`，读回时要看 XMP。
  - 序列号、机主、MakerNote、用户注释、其他 XMP / IPTC 字段、缩略图从不复制。
- ImageIO 必写的结构性 EXIF（ColorSpace、像素尺寸）不算 D-06 的「元数据」（D-57）。
- HDR 文件只有在不丢 gain map 的前提下才写入元数据，做不到时省略并警告 `output.metadata_dropped`（D-66）。

### 2.7 预览模式（§6.1 第 3 条、§6.6、§11.2、D-18）

预览与导出共用前半段 `prepare`：校验 → `PageLayout` → `SourceDecoder` → `OverlayPlanner` → HDR 决策，之后才分开。只有采样分辨率与输出方式不同，颜色规则完全相同。

- **版式**：在导出分辨率上由 PhotoFrameCore 计算（与导出逐项相同），再映射到预览像素。预览画布 = 导出画布 × 缩放后四舍五入到整像素，每个方向的缩放是有理数「预览边长 / 导出边长」（两者相差不到半个像素）。
  矩形的四条边分别用整数运算映射、四舍五入（.5 向上），所以每条边与「导出坐标 × 缩放」相差 ≤ 0.5 px，相邻的矩形仍然相邻；全景切片原点 kW 正好映射到 k × 预览宽度。
- **解码**：按「导出所需尺寸 × 缩放」的 2 倍降采样（D-18 的同一条规则），不按原图分辨率渲染预览。
- **照片**：同一个 Lanczos 缩放（`PageComposer.scaledPhoto`），目标直接是映射后的预览矩形，不先合成大图再缩小。
- **图层**：排版仍按导出像素（字号、内边距不变，D-45），绘制时把整个图层框缩放进预览矩形：文字、SVG 按矢量重画，PNG 从原图一次缩放。
- **颜色**：`.sRGB`（默认，§6.6 的输出预览）与 SDR 导出编码前的像素相同；HDR 输出时是文件里的 SDR 底图。`.extendedRange` 是 extended sRGB 半浮点，输出写 HDR 时为 HDR 页面并带 content headroom，否则是同一 SDR 页面但不截断色域外颜色（不能用来软打样 SDR 文件）。
- **一致性**：缩放系数为 1 时，`.sRGB` 预览与 PNG 导出逐像素相同（测试验证）。
- **取消**：在阶段之间和每一页之前检查，抛出 `CancellationError`；不写任何文件。参数变化时 GUI 取消旧的预览任务即可。
- 错误：预览尺寸无效（≤ 0、NaN）报 `render.invalid_preview_size`；其余与导出相同。

## 3. 测试（Swift Testing）

```bash
cd Packages/PhotoFrameRendering
swift test --scratch-path "$TMPDIR/PhotoFrameRendering-build"
```

测试只用代码合成的图片和 `Experiments/ColorPoC/fixtures` 里的合成 fixture。

| 文件 | 覆盖 |
|---|---|
| `ColorManagementTests` | §6.9：四种 ICC 色卡 ΔE（16 位 TIFF 与 8 位 JPEG，D-19 暂定阈值）、缺 ICC 警告与覆盖、`#FAFAF8` 精确、16 位精度、透明素材无黑边白边、线性光不透明度、方向 1/3/6/8（含降采样解码）、输出 ICC、坑 20、广色域截断 |
| `LayoutRenderingTests` | Fit、比例裁切、AC-01 / AC-02 / AC-03、全景切片按位重建长卷、手动张数 |
| `HDRTests` | gain map 底图、PQ tone map、浮点 TIFF、HDR 输出读回（比例与背景）、HDR 回退、合成的「最大化兼容性」TIFF 及其解析失败降级 |
| `OverlayAndJobTests` | 文字位置、EXIF 占位符、SVG 渲染与拒绝、缺素材、全景页码可见性、元数据策略、进度、取消清理、不覆盖、HEIC 拒绝 |
| `GoldenTests` + `Golden/*.json` | §13.2：内置预设下的尺寸、照片与图层矩形、颜色采样（容差 3）、背景、元数据、警告列表 |
| `PreviewTests` | 预览：1/4 缩放下画布、照片与图层矩形与导出按比例一致（Fit、裁切、65:24 全景）且位图与矩形相符、补边取整、最大长边、缩放 1 时与 PNG 导出逐像素相同、背景与补边色、照片颜色、HDR 的 extendedRange、页面筛选、由 `RenderJob` 预览、无效尺寸、取消（开始前与进行中） |

更新黄金文件：`PHOTOFRAME_RECORD_GOLDEN=1 swift test --scratch-path "$TMPDIR/PhotoFrameRendering-build" --filter Golden`，再检查 JSON 的 diff。

**Golden 基准（D-68）**：以用户本机（macOS 27）为标定基准，只在这台机器上重录，不按其他系统版本重录。每个黄金文件的 `recordedOn` 记录录制时的系统版本（如 `macOS 27.0.1`）。

- 当前系统的**主版本号**与 `recordedOn` 相同：严格比较，结构不同或采样超出容差（3 个码值）时测试失败。
- 主版本号不同（例如 CI 的 macOS 26）：只把差异打印成 `[golden 仅报告] …`，测试不失败。其他测试照常。
- 环境变量 `PHOTOFRAME_GOLDEN_STRICT=1` 强制严格比较。

## 4. 已确定的决策（D-56 … D-69）

实现时提出的 14 个问题已由用户确认，规范 §16 中的编号如下：

| 编号 | 决策 |
|---|---|
| D-56 | JPEG 始终嵌入 sRGB ICC（ImageIO 不嵌时自己插入 APP2） |
| D-57 | ImageIO 必写的结构性 EXIF（ColorSpace、像素尺寸）不算 D-06 的元数据 |
| D-58 | TRC 为 BT.709 / BT.2020 逆 OETF 参数曲线的 ICC，按文件里的曲线解码（改写为采样曲线，不用 ColorSync 的 γ2.4 解释） |
| D-59 | 超出 sRGB 的颜色逐通道截断，作为 V1 策略 |
| D-60 | HDR headroom：gain map 源用文件值，PQ / HLG / 浮点源用画面实测峰值 |
| D-61 | SDR 源请求 HDR 输出 → 输出 SDR 并警告；HDR + PNG 报错 |
| D-62 | 「明确是 HDR」才按 HDR，否则 SDR；判定规则见 §2.2 |
| D-63 | 新增独立开关「保留作者和版权」`keepAuthorAndCopyright`，默认关闭 |
| D-64 | EXIF 文字缺失字段连同多余分隔符一起去掉；整行为空则不画图层，仍警告 |
| D-65 | 文字、素材在图层框内的排布：文字只缩小不放大、水平对齐跟随锚点、竖直居中、找不到字体用系统字体并警告；PNG / SVG 等比放入并居中 |
| D-66 | HDR 输出只有在 gain map 能保住时才写入元数据，否则去掉元数据并警告 |
| D-67 | 全景预设设置了比例裁切 → 忽略裁切并警告 |
| D-68 | Golden 以用户本机 macOS 27 为基准；其他主版本只报告差异 |
| D-69 | 压缩的「最大化兼容性」TIFF 按 SDR 读入，提示「HDR 部分未读取」 |

## 5. 尚未实现

- 预览缓存（§12.1「缩略图缓存」）：每次 `renderPreview` 都重新解码源图。只改图层或背景时可以复用解码结果，留给 GUI／Application 层按需要加。
- gain map JPEG 的 HDR 版本由 `CIImage(expandToHDR:)` 按原图分辨率展开（导出同样如此），`.extendedRange` 预览这类源图比 `.sRGB` 慢。可改用 ImageIO 的 HDR 解码请求在解码时降采样。
- PQ / HLG / 浮点源的画面峰值在降采样后的解码图上统计，预览很小时峰值可能略低于导出，tone map 后的 SDR 预览会稍有差别。
- 超出 sRGB 色域的感知映射（目前逐通道截断，§6.9、坑 11）。
- 压缩的「最大化兼容性」TIFF（需要 LZW / ZIP 解压）。
- 16 位输出（届时按任务改用 RGBAf，D-03）。
