// 等比、居中、不裁切地把源图放进容器内框，并给出连续矩形与像素矩形。
//
// 舍入策略（Fit 与全景长卷共用）：
// 1. 先按规范公式算出连续坐标下的精确矩形 `exactRect`。
// 2. 像素尺寸取「与容器同奇偶、且最接近精确值」的整数；距离相等时取较小者。
//    内框尺寸 = 容器 − 2×边距，与容器同奇偶，所以结果永远 ≤ 内框，不会越过最小边距。
// 3. 像素原点 = (容器 − 像素尺寸) / 2，因同奇偶而必为整数，两侧留白严格相等。
// 每个轴的像素尺寸与精确值之差 ≤ 1 px（因此宽高比偏差在 1 px 以内）。
// 贴边的那个轴精确值就等于内框尺寸，像素尺寸与之完全一致。

struct Placement {
    var scale: Double
    var exactRect: Rect
    var pixelRect: PixelRect
}

/// 吸附时把浮点误差看作「正好相等」的宽度（单位：px）。
let snapEpsilon = 1e-6

/// 与 `container` 同奇偶、≤ `limit`、最接近 `exact` 的正整数；平局取小。
func snapSameParity(_ exact: Double, container: Int, limit: Int) -> Int {
    let parity = container & 1
    // n = parity + 2k；把 ties 推向较小的 k。
    let k = ((exact - Double(parity)) / 2 - 0.5 - snapEpsilon).rounded(.up)
    var n = parity + 2 * Int(k)
    n = min(n, limit)
    let minimum = parity == 1 ? 1 : 2
    if n < minimum { n = min(minimum, limit) }
    return n
}

func centeredPlacement(
    source: PixelSize,
    container: PixelSize,
    insetX: Int,
    insetY: Int
) -> Placement {
    let availableWidth = container.width - 2 * insetX
    let availableHeight = container.height - 2 * insetY
    let scale = min(
        Double(availableWidth) / Double(source.width),
        Double(availableHeight) / Double(source.height))

    let exactWidth = Double(source.width) * scale
    let exactHeight = Double(source.height) * scale
    let exactRect = Rect(
        x: (Double(container.width) - exactWidth) / 2,
        y: (Double(container.height) - exactHeight) / 2,
        width: exactWidth,
        height: exactHeight)

    let w = snapSameParity(exactWidth, container: container.width, limit: availableWidth)
    let h = snapSameParity(exactHeight, container: container.height, limit: availableHeight)
    let pixelRect = PixelRect(
        x: (container.width - w) / 2,
        y: (container.height - h) / 2,
        width: w,
        height: h)

    return Placement(scale: scale, exactRect: exactRect, pixelRect: pixelRect)
}
