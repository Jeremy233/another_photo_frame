# PhotoFrameCore

画布几何计算：Fit 布局、比例裁切、全景无缝切片。纯 Swift，macOS 26+，不依赖 SwiftUI、AppKit、Core Image（规范 §10.1）。

## 运行测试

```bash
swift test
```

> 如果仓库放在 iCloud 同步的目录（如 `~/Desktop`）下，File Provider 会给构建产物加上扩展属性，
> 导致测试包 ad-hoc 签名失败（`resource fork, Finder information, or similar detritus not allowed`）。
> 这时把构建目录放到同步目录之外即可：
> `swift test --scratch-path "$TMPDIR/PhotoFrameCore-build"`

## 坐标约定

- 原点在左上，x 向右，y 向下（规范 §5.1）。
- 所有布局都使用 **EXIF 方向校正后的显示尺寸**：`SourceImage(storedSize:orientation:).displaySize`，方向 5…8 交换宽高。
- 整数类型 `PixelSize` / `PixelRect` / `PixelInsets` 是最终栅格上的像素**边缘**坐标，`PixelRect` 覆盖 `x..<x+width`。
- 浮点类型 `Size` / `Point` / `Rect` 是连续设计坐标。
- `ScaleTranslateTransform`：`目标 = 源 × scale + translate`，把源图显示坐标映射到画布（或切片）像素坐标。

## API

| 类型 | 用途 |
|---|---|
| `FitLayout(canvas:minimumMargin:source:)` | §5.2 单页／封面 Fit。输出 `exactRect`（精确）、`pixelRect`（栅格）、`margins`、`transform`。 |
| `CropLayout(canvas:minimumMargin:source:aspectRatio:anchor:)` | D-21 可选比例裁切。`aspectRatio` 缺省为内框比例；`anchor` 取 0…1，(0.5, 0.5) 居中。输出源图中的 `cropRect`，以及裁切结果的 `fit` 和完整的 `transform`。 |
| `PanoramaLayout(tile:source:coverMinimumMargin:verticalMargin:slideCount:maxCarouselItems:)` | §5.3 Cover + Seamless Slides。输出 `cover`（Fit）、`automaticSlideCount`、`slideCount`、`stripSize`、长卷中的 `exactImageRect` / `pixelImageRect`、全局 `transform`、`slices`、`warnings`。 |
| `PanoramaSlice` | 每张切片：`frame`（长卷中 `[kW,(k+1)W)`）、本地 `imageRect`、`backgroundLeft/Right`、本地 `transform`（= 全局变换平移 −kW）、`sourceRegion`（本切片用到的源图区域，供按区域解码）。 |
| `PanoramaWarning` | `notLandscape`、`notWideEnough`、`exceedsCarouselLimit`、`increasedSlideCount`；每个都带稳定 `code`。 |
| `GeometryError` | 参数错误，带稳定 `code` 和中文 `message`。 |
| `OverlayGeometry` | §7.1 装饰图层参数：九宫格 `anchor`、`reference`（`.photo(.outside)` 默认／`.photo(.inside)`／`.canvas`）、`offset`（px）、`size`（`.fixed` 或 `.fitting(内容, maximum:)`）、`visibility`（`.coverOnly` 默认／`.allSlides`／`.selectedSlides`）。 |
| `OverlayPlacement(fit:geometry:)` / `(crop:geometry:)` / `(canvas:photoRect:geometry:)` | 图层在画布中的像素矩形 `rect` 和 `warnings`（`OverlayWarning`：`exceedsCanvas`、`overlapsPhoto`、`insufficientMargin`）。 |
| `PanoramaLayout.overlayPlan(for:)` | 图层在封面与各切片上的位置；`missingPages` 列出超出实际页数的指定页码。 |
| `OverlayError` | 图层参数错误，带稳定 `code` 和中文 `message`。 |

示例：

```swift
let p = try PanoramaLayout(
    tile: PixelSize(width: 1080, height: 1440),
    source: SourceImage(storedSize: PixelSize(width: 6500, height: 2400)),
    maxCarouselItems: 20)
p.slideCount          // 4
p.pixelImageRect      // (210, 0, 3900×1440)
p.slices[0].backgroundLeft  // 210
```

## 舍入策略（D-22：不动照片，只动 padding）

Fit 和全景长卷共用一套规则（`Placement.swift`）：

1. 按规范公式算出连续的 `scale` 和精确矩形 `exactRect`。
2. 每个轴的像素尺寸 = 精确值**四舍五入到最近的整数**（.5 进位），再限制在 `[1, 内框]` 之间。
   精确值是整数时（例如贴住内框的一边，或 AC-03 的 2925）原样使用，照片不做额外缩放；否则误差 ≤ 0.5 px。
3. 剩余空间全部交给留白：**左／上 = floor((容器 − 像素尺寸) / 2)，右／下 = 剩余部分**。
   两侧相差 0 或 1 px，多出的 1 px 固定在右／下。因为像素尺寸 ≤ 内框，两侧都 ≥ 最小边距，照片也不会越出长卷。
4. `transform` 按 `pixelRect` 计算。x、y 两个方向的缩放可能有极小差别（< 0.5 px）。

全景额外的规则：

- **自动张数** `N = ceil((renderWidth − ε) / W)`，ε = 0.01 px（`slideCountTolerance`，可调）。只超出浮点噪声量级时仍取整数张，例如本该 4 张的不会算成 5 张；真实超出（如 3001×1000 → 超出 1.44 px）仍会多算一张。
- 照片在长卷中只栅格化**一次**（`pixelImageRect`），切片只是把它按 `x = kW` 切开。所有切片共用同一缩放，平移量恰好相差 kW，因此接缝两侧的像素来自同一个全局映射，没有缝隙也没有重叠。
- N ≥ 自动张数，照片总是铺满渲染高度 `H − 2v`，宽度不足的部分只在长卷两端补底色。
- AC-03（65:24 → 小红书）：照片宽 2925，左右补边精确值 157.5，栅格化为左 157、右 158。

## 装饰图层定位（§7.1、D-12）

- **参照物**：默认以照片边缘为参照（D-12），照片因比例变化移动时图层跟着走；也可以以画布为参照。
- **内侧／外侧**：外侧 = 留白区域（默认）。锚点在上、下两行时向上／下伸出照片，水平方向仍按左、中、右对齐照片边缘（「照片右下角下方 16 px」= `.bottomRight`、外侧、`offset (0, 16)`）；中间行的左、右锚点向左／右伸出；正中锚点没有外侧，抛 `overlay.center_anchor_outside`。
- **偏移**：伸出方向上是与照片的间隙，正值远离照片；对齐到边缘的方向上是离该边的距离，正值向中心收；居中的方向上是直接平移，正值向右／下。换锚点时偏移的含义不变。
- **取整**：照片矩形、偏移、尺寸都是整数，只有居中需要取整：左／上 = floor((参照长度 − 图层长度) / 2)，多出的 1 px 在右／下，与 D-22 一致（图层比参照宽时向负无穷取整）。`.fitting` 缩小后的尺寸取最近整数（.5 进位），不超过最大尺寸。
- **警告**：`exceedsCanvas` 给出各边超出的像素；`overlapsPhoto` 只在留白模式（`.photo(.outside)` 和 `.canvas`）下检查，恰好贴住照片边缘不算遮挡；`insufficientMargin` 只在照片外侧检查伸出方向，需要量 = 偏移 + 图层尺寸。恰好贴住画布边缘没有警告。
- **全景切片**：页码是轮播位置，0 = 封面，切片 k 是第 k + 1 页（与预览栏 `[Cover] [1] … [N]` 一致）。
  在切片上以照片为参照时，参照的是**这张切片里的照片部分**（`PanoramaSlice.imageRect`），不是整张切片：
  这样「照片内侧右下角」在最外侧切片上会落在照片结束处，而不是落在补边的底色上。整张都是底色的切片上，
  以照片为参照的图层不绘制（`placement == nil`）；以画布为参照时参照整张切片，照常绘制。
  切片默认铺满高度（v = 0），照片外侧上下没有留白，会报 `insufficientMargin`；要在切片上显示，一般选照片内侧或画布参照。

## 已确定

以下规则已由用户确认（2026-10-16），规范 §5.2、§5.3、D-11、D-22 已同步更新：

1. **栅格取整（D-22）**：不动照片，只动 padding。像素尺寸取精确值最近的整数（.5 进位，不超过内框）；左／上留白取 floor，右／下取剩余，两侧可相差 1 px。
2. **Fit 非贴边方向**：同上，例如 65:24 的封面高度 354.46 → 354，上 543、下 543。
3. **手动张数只能改多（D-11）**：手动值小于自动张数时抛出 `GeometryError.slideCountBelowMinimum`（`geometry.slide_count_below_minimum`），不再缩小全景。上下边距 v 会改变自动张数，所以同一个手动值可能因为 v 变大而变成非法。
4. **轮播上限包括封面**：`N + 1 > maxCarouselItems` 时报 `exceedsCarouselLimit`。
5. **不适合切片的警告**：`R ≤ 1` 报 `notLandscape`（`panorama.not_landscape`）；`R > 1` 但自动张数 ≤ 2（即 `R ≤ 2·W/(H−2v)`）报 `notWideEnough`（`panorama.not_wide_enough`，取代原来的 `fitsSingleSlide`）。两者都只是提示，布局照常计算。
6. **比例裁切保留最小边距**：默认比例取内框比例 (W − 2m) : (H − 2m)，`anchor` 取 0…1，表示裁切框在可移动范围内的相对位置。
7. **自动张数容差**：0.01 px。

## 预设模型

`Sources/PhotoFrameCore/Preset/` 定义可分享预设的数据模型（规范 §7.1、§8.1、§11.1）：
`ExportPreset`（画布、全景、图层、素材槽、输出）、`OverlayLayer`、`AssetSlot`、`OutputSettings`、`PlatformProfile`。
全部是 `Codable`、`Sendable` 的纯数据。读写 JSON 用 `PresetSchema`（版本检查、迁移、不认识字段的登记），
内容校验用 `ExportPreset.validate()`。`.photoframe` 打包、导入检查和素材绑定在 `PhotoFrameStorage`，
字段命名的待确认项见 `PhotoFrameStorage/README.md`。

## 待确认

以下是实现装饰图层定位时发现的规范歧义，目前按括号中的方式实现，未改规范：

1. **角锚点放在外侧时朝哪个方向伸出**（按竖直方向：上／下）。§7.1 只说九宫格 + 外侧，D-12 的例子「照片右下角下方」是竖直方向。是否需要让用户选择水平伸出（照片右侧、底边对齐）或对角伸出？
2. **以画布为参照时是否算「留白模式」**（算：仍检查是否遮挡照片）。§7.1 把「渲染空间」（画布／留白／照片）和「参照物」（照片／画布）分成两个字段，本实现只用 `reference` 表达：`.photo(.inside)` 对应「照片」渲染空间，其余都按「留白，不遮挡照片」检查。是否需要独立的渲染空间字段，例如以画布为参照但允许叠在照片上？
3. **偏移的符号约定**（见上文「偏移」）。规范只说 offset 以 px 为单位，没有说正方向。
4. **全景切片上的参照**（这张切片里的照片部分）。§5.3 只规定默认不在切片上显示；如果改为参照整张切片，外侧锚点在 v = 0 时没有意义。
5. **`selectedSlides` 的页码基准**（轮播位置，0 = 封面）。规范和 §8.1 示例 `"visibleOn": "coverOnly"` 没有给出指定页的格式；手动张数改动后超出范围的页码目前只在 `missingPages` 中列出，不报错。
6. **图层尺寸是否随画布缩放**（不缩放，固定 px）。§8.1 示例 `"sizePx": [48, 48]` 是固定像素；同一预设用于 1080 宽以外的画布时是否按比例缩放，规范未说明。
