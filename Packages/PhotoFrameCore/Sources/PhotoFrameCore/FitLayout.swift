/// 单页／封面 Fit 布局（规范 §5.2）：等比、居中、不裁切，四周留白 ≥ 最小边距。
public struct FitLayout: Hashable, Sendable, Codable {
    public var canvas: PixelSize
    public var minimumMargin: Int
    /// 源图显示尺寸（已做方向校正）。
    public var source: PixelSize
    /// 规范公式的连续缩放系数。
    public var scale: Double
    /// 连续坐标下的精确照片矩形。
    public var exactRect: Rect
    /// 栅格化用的整数照片矩形（D-22）：尺寸为精确值四舍五入，留白 ≥ 最小边距，
    /// 两侧相差 ≤ 1 px，多出的 1 px 在右／下。
    public var pixelRect: PixelRect
    /// 源图显示坐标 → 画布像素坐标，与 `pixelRect` 一致。
    public var transform: ScaleTranslateTransform

    /// 实际四周留白（≥ minimumMargin，非贴边方向可能更大）。
    public var margins: PixelInsets {
        PixelInsets(
            top: pixelRect.minY,
            left: pixelRect.minX,
            bottom: canvas.height - pixelRect.maxY,
            right: canvas.width - pixelRect.maxX)
    }

    public init(canvas: PixelSize, minimumMargin: Int, source: PixelSize) throws(GeometryError) {
        guard canvas.isPositive else { throw .invalidCanvas(canvas) }
        guard source.isPositive else { throw .invalidSource(source) }
        guard minimumMargin >= 0 else { throw .invalidMargin(minimumMargin) }
        guard canvas.width - 2 * minimumMargin > 0, canvas.height - 2 * minimumMargin > 0 else {
            throw .marginTooLarge(margin: minimumMargin, canvas: canvas)
        }

        let placement = centeredPlacement(
            source: source, container: canvas, insetX: minimumMargin, insetY: minimumMargin)
        self.canvas = canvas
        self.minimumMargin = minimumMargin
        self.source = source
        self.scale = placement.scale
        self.exactRect = placement.exactRect
        self.pixelRect = placement.pixelRect
        self.transform = .mapping(source: source, into: placement.pixelRect)
    }

    public init(canvas: PixelSize, minimumMargin: Int, source: SourceImage) throws(GeometryError) {
        try self.init(canvas: canvas, minimumMargin: minimumMargin, source: source.displaySize)
    }
}
