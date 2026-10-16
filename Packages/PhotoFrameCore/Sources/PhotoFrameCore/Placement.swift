// 等比、居中、不裁切地把源图放进容器内框，并给出连续矩形与像素矩形。
//
// 舍入策略（D-22，Fit 与全景长卷共用）——「不动照片，只动 padding」：
// 1. 先按规范公式算出连续坐标下的精确矩形 `exactRect`。
// 2. 每个轴的像素尺寸 = 精确值四舍五入到最近的整数（.5 进位），再限制在 [1, 内框] 之间。
//    精确值本身是整数时（如 AC-03 的 2925）就原样使用；贴住内框的那个轴正好等于内框尺寸。
// 3. 剩余空间全部交给留白：左／上 = floor((容器 − 像素尺寸) / 2)，右／下 = 剩余部分。
//    因此两侧相差 0 或 1 px，多出的 1 px 总在右／下；且因像素尺寸 ≤ 内框，两侧都 ≥ 边距。

struct Placement {
    var scale: Double
    var exactRect: Rect
    var pixelRect: PixelRect
}

/// 离 `exact` 最近的整数（.5 进位），限制在 1…`limit`。
func snapNearest(_ exact: Double, limit: Int) -> Int {
    min(max(Int(exact.rounded(.toNearestOrAwayFromZero)), 1), limit)
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

    let w = snapNearest(exactWidth, limit: availableWidth)
    let h = snapNearest(exactHeight, limit: availableHeight)
    // 非负整数除法即 floor。
    let pixelRect = PixelRect(
        x: (container.width - w) / 2,
        y: (container.height - h) / 2,
        width: w,
        height: h)

    return Placement(scale: scale, exactRect: exactRect, pixelRect: pixelRect)
}
