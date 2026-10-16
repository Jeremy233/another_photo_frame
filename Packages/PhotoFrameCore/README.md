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
| `PanoramaWarning` | `notLandscape`、`fitsSingleSlide`、`exceedsCarouselLimit`、`reducedSlideCount`、`increasedSlideCount`；每个都带稳定 `code`。 |
| `GeometryError` | 参数错误，带稳定 `code` 和中文 `message`。 |

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

## 舍入策略

Fit 和全景长卷共用一套规则（`Placement.swift`）：

1. 按规范公式算出连续的 `scale` 和精确矩形 `exactRect`。
2. 每个轴的像素尺寸取**与容器（画布或长卷）同奇偶、且离精确值最近的整数**；距离相等时取较小的。
   内框 = 容器 − 2×边距，它和容器同奇偶，所以结果永远 ≤ 内框，**不会压到最小边距，也不会越出长卷**。
3. 像素原点 = (容器 − 像素尺寸) / 2。因为同奇偶，这个值一定是整数，**左右、上下留白严格相等**，不会差 1 px。
4. 贴住内框的那个轴，精确值本身就是整数，像素尺寸和它完全一致；另一个轴误差 ≤ 1 px。
   像素矩形与精确矩形的宽高比偏差小于 1 px，渲染器把源图拉伸进 `pixelRect` 即可（`transform` 已按 `pixelRect` 计算，x、y 两个方向的缩放可能有极小差别）。
5. 退化情况：精确尺寸 < 2 px 时，至少给 1 px（奇数容器）或 2 px（偶数容器）。

全景额外的规则：

- **自动张数** `N = ceil((renderWidth − ε) / W)`，ε = 0.01 px（`slideCountTolerance`，可调）。只超出浮点噪声量级时仍取整数张，例如本该 4 张的不会算成 5 张；真实超出（如 3001×1000 → 超出 1.44 px）仍会多算一张。
- 照片在长卷中只栅格化**一次**（`pixelImageRect`），切片只是把它按 `x = kW` 切开。所有切片共用同一缩放，平移量恰好相差 kW，因此接缝两侧的像素来自同一个全局映射，没有缝隙也没有重叠。
- 用 `scale = min((H − 2v) / S_h, N·W / S_w)` 统一处理三种情况：自动或改多时高度贴边、两端补底色；改少时宽度贴边、上下补底色。
- AC-03（65:24 → 小红书）：精确宽 2925、左右各 157.5；栅格化后宽 2924、左右各 158。

## 待确认

以下是实现过程中发现规范没有写明的地方。代码里先按括号中的做法实现，规范本身没有改动：

1. **半像素补边的栅格化方式**（§5.3、AC-03）。规范只说"一致舍入"。当前做法是：照片宽度向同奇偶取整（2925 → 2924），保证左右补边相等，代价是照片横向缩放约 0.03%。另一种做法是保持 2925 px 宽、左右补边 157 / 158 不对称；还有一种是保留 157.5 的亚像素位置，让边缘那一列像素抗锯齿混色。需要选定一种。
2. **Fit 非贴边方向的取整**。同样采用同奇偶取整（例如 65:24 的封面高度 354.46 → 354）。如果更看重严格等比、能接受上下留白差 1 px，可以改成直接四舍五入。
3. **"改少"时照片的竖直位置**。当前在 `[v, H − v]` 区间内上下居中，等同于在整张切片高度内居中。规范没有说是否允许顶部或底部对齐。
4. **轮播上限的计数**。按规范"包括封面"，以 `N + 1 > 上限` 判断。如果某个平台允许不发封面，需要在平台配置里另加说明。
5. **"R 很小"的判定**。当前规则：`R ≤ 1` 报 `notLandscape`；`R > 1` 但自动张数只有 1 张时报 `fitsSingleSlide`。像 4:3 横图发 IG 会被切成 2 张，且不会报警。是否需要更高的阈值（例如 `R ≤ 2 × W / H`）？
6. **比例裁切的默认比例与"裁切位置"的含义**。当前默认比例取内框比例 (W − 2m) : (H − 2m)，裁切结果正好填满内框。`anchor` 取 0…1，表示裁切框在可移动范围内的相对位置。规范没有定义比例裁切后是否仍保留最小边距，当前保留。
7. **自动张数的容差**。规范只要求"使用数值容差"，没有给出具体值。当前取 0.01 px：超出量小于 0.01 px 时视为没有超出，大于等于 0.01 px 才多加一张。
