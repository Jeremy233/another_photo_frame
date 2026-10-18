/// 比例裁切布局（D-21 的可选模式，默认不启用）。
///
/// 先在源图中取目标比例下最大的裁切框，再把裁切结果按 Fit 放进画布。
/// 裁切框位置由 `anchor` 决定：(0, 0) 贴住左上，(1, 1) 贴住右下，默认 (0.5, 0.5) 居中。
/// 只有在源图比例与目标比例不同的方向上才会裁掉内容，另一方向保持完整。
public struct CropLayout: Hashable, Sendable, Codable {
    public var source: PixelSize
    public var aspectRatio: AspectRatio
    public var anchor: Point
    /// 源图显示坐标中的裁切框（整数像素）。
    public var cropRect: PixelRect
    /// 裁切后的图像放入画布的 Fit 布局。
    public var fit: FitLayout
    /// 源图显示坐标 → 画布像素坐标（已包含裁切偏移）。
    public var transform: ScaleTranslateTransform

    public static let centered = Point(x: 0.5, y: 0.5)

    /// - Parameters:
    ///   - aspectRatio: 裁切比例；为 nil 时用画布扣除最小边距后的内框比例，裁切结果正好填满内框。
    public init(
        canvas: PixelSize,
        minimumMargin: Int,
        source: PixelSize,
        aspectRatio: AspectRatio? = nil,
        anchor: Point = CropLayout.centered
    ) throws(GeometryError) {
        guard canvas.isPositive else { throw .invalidCanvas(canvas) }
        guard source.isPositive else { throw .invalidSource(source) }
        guard minimumMargin >= 0 else { throw .invalidMargin(minimumMargin) }
        // 先确认 W − 2m > 0（写成 m < W − m，边距极大时不溢出），再算内框。
        guard minimumMargin < canvas.width - minimumMargin, minimumMargin < canvas.height - minimumMargin else {
            throw .marginTooLarge(margin: minimumMargin, canvas: canvas)
        }
        let inner = PixelSize(
            width: canvas.width - 2 * minimumMargin, height: canvas.height - 2 * minimumMargin)
        let ratio = aspectRatio ?? AspectRatio(inner)
        guard ratio.isValid else { throw .invalidAspectRatio(ratio) }
        guard (0...1).contains(anchor.x), (0...1).contains(anchor.y) else {
            throw .invalidAnchor(anchor)
        }

        let crop = Self.cropRect(source: source, aspectRatio: ratio.value, anchor: anchor)
        let fit = try FitLayout(canvas: canvas, minimumMargin: minimumMargin, source: crop.size)

        self.source = source
        self.aspectRatio = ratio
        self.anchor = anchor
        self.cropRect = crop
        self.fit = fit
        self.transform = fit.transform.translatedBy(
            x: -Double(crop.x) * fit.transform.scaleX,
            y: -Double(crop.y) * fit.transform.scaleY)
    }

    public init(
        canvas: PixelSize,
        minimumMargin: Int,
        source: SourceImage,
        aspectRatio: AspectRatio? = nil,
        anchor: Point = CropLayout.centered
    ) throws(GeometryError) {
        try self.init(
            canvas: canvas, minimumMargin: minimumMargin, source: source.displaySize,
            aspectRatio: aspectRatio, anchor: anchor)
    }

    /// 裁切框尺寸四舍五入到整数像素；偏移量 = anchor × 可移动范围，四舍五入。
    static func cropRect(source: PixelSize, aspectRatio target: Double, anchor: Point) -> PixelRect {
        let sw = Double(source.width), sh = Double(source.height)
        var w = source.width, h = source.height
        if sw / sh > target {
            w = min(max(Int((sh * target).rounded()), 1), source.width)
        } else {
            h = min(max(Int((sw / target).rounded()), 1), source.height)
        }
        let x = Int((anchor.x * Double(source.width - w)).rounded())
        let y = Int((anchor.y * Double(source.height - h)).rounded())
        return PixelRect(x: x, y: y, width: w, height: h)
    }
}
