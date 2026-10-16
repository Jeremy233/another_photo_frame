/// 几何计算的参数错误。`code` 是稳定的机器可读错误码（规范 §10.1）。
public enum GeometryError: Error, Hashable, Sendable {
    case invalidCanvas(PixelSize)
    case invalidSource(PixelSize)
    case invalidMargin(Int)
    /// 最小边距使可用内框宽或高 ≤ 0。
    case marginTooLarge(margin: Int, canvas: PixelSize)
    case invalidVerticalMargin(Int)
    case invalidSlideCount(Int)
    case invalidAspectRatio(AspectRatio)
    case invalidAnchor(Point)

    public var code: String {
        switch self {
        case .invalidCanvas: "geometry.invalid_canvas"
        case .invalidSource: "geometry.invalid_source"
        case .invalidMargin: "geometry.invalid_margin"
        case .marginTooLarge: "geometry.margin_too_large"
        case .invalidVerticalMargin: "geometry.invalid_vertical_margin"
        case .invalidSlideCount: "geometry.invalid_slide_count"
        case .invalidAspectRatio: "geometry.invalid_aspect_ratio"
        case .invalidAnchor: "geometry.invalid_anchor"
        }
    }

    public var message: String {
        switch self {
        case .invalidCanvas(let s): "画布尺寸必须为正：\(s)"
        case .invalidSource(let s): "源图尺寸必须为正：\(s)"
        case .invalidMargin(let m): "边距不能为负：\(m)"
        case .marginTooLarge(let m, let c): "边距 \(m) px 对画布 \(c) 过大，没有可放置照片的区域"
        case .invalidVerticalMargin(let v): "切片上下边距无效：\(v)"
        case .invalidSlideCount(let n): "切片张数必须 ≥ 1：\(n)"
        case .invalidAspectRatio(let r): "裁切比例无效：\(r)"
        case .invalidAnchor(let p): "裁切位置必须在 0…1 之间：(\(p.x), \(p.y))"
        }
    }
}
