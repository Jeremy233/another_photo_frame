// 装饰图层（签名、水印、相机图标、EXIF 文字）的定位参数（规范 §7.1、D-12）。
//
// 这里只描述图层「放在哪、多大、出现在哪几页」，不涉及绘制内容。
// 所有长度都是输出画布上的整数像素。

/// 九宫格中某一轴上的对齐位置。
public enum OverlayAlignment: String, Hashable, Sendable, Codable, CaseIterable {
    /// 左／上。
    case start
    case center
    /// 右／下。
    case end
}

/// 九宫格锚点。
public struct OverlayAnchor: Hashable, Sendable, Codable, CustomStringConvertible {
    public var horizontal: OverlayAlignment
    public var vertical: OverlayAlignment

    public init(horizontal: OverlayAlignment, vertical: OverlayAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let topLeft = OverlayAnchor(horizontal: .start, vertical: .start)
    public static let top = OverlayAnchor(horizontal: .center, vertical: .start)
    public static let topRight = OverlayAnchor(horizontal: .end, vertical: .start)
    public static let left = OverlayAnchor(horizontal: .start, vertical: .center)
    public static let center = OverlayAnchor(horizontal: .center, vertical: .center)
    public static let right = OverlayAnchor(horizontal: .end, vertical: .center)
    public static let bottomLeft = OverlayAnchor(horizontal: .start, vertical: .end)
    public static let bottom = OverlayAnchor(horizontal: .center, vertical: .end)
    public static let bottomRight = OverlayAnchor(horizontal: .end, vertical: .end)

    /// 按行（上→下）、列（左→右）排列的九个锚点。
    public static let allCases: [OverlayAnchor] = [
        .topLeft, .top, .topRight,
        .left, .center, .right,
        .bottomLeft, .bottom, .bottomRight,
    ]

    /// 预设 JSON 中的名称，例如 `bottomRight`。
    public var name: String {
        switch (vertical, horizontal) {
        case (.start, .start): "topLeft"
        case (.start, .center): "top"
        case (.start, .end): "topRight"
        case (.center, .start): "left"
        case (.center, .center): "center"
        case (.center, .end): "right"
        case (.end, .start): "bottomLeft"
        case (.end, .center): "bottom"
        case (.end, .end): "bottomRight"
        }
    }

    public init?(name: String) {
        guard let anchor = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = anchor
    }

    public var description: String { name }

    // 在 JSON 中编码为名称字符串（D-23：预设与几何计算共用这一个类型）。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let name = try c.decode(String.self)
        guard let anchor = OverlayAnchor(name: name) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "不认识的锚点：\(name)")
        }
        self = anchor
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}

/// 相对照片放在内侧还是外侧。
public enum OverlaySide: String, Hashable, Sendable, Codable {
    /// 照片外侧，即留白区域（默认，§7.1「不遮挡照片」）。
    case outside
    /// 照片内侧，叠在照片上。
    case inside
}

/// 定位参照物。
public enum OverlayReference: Hashable, Sendable, Codable {
    /// 以照片边缘为参照（默认，D-12），图层跟随照片移动。
    case photo(OverlaySide)
    /// 以画布边缘为参照，图层放在画布内侧。
    case canvas

    public static let `default` = OverlayReference.photo(.outside)

    /// 是否处于「留白模式」：图层不应遮挡照片。只有 `.photo(.inside)` 明确允许叠在照片上。
    public var avoidsPhoto: Bool { self != .photo(.inside) }
}

/// 偏移（px）。每个轴的含义取决于该轴的对齐方式和内外侧：
///
/// - 照片外侧方向（例如锚点为下、外侧时的竖直轴）：图层与照片边缘之间的间隙，正值远离照片。
/// - 对齐到边缘的轴（start／end，内侧或参照画布）：图层与该边缘的距离，正值向参照矩形中心收。
/// - 居中的轴：直接平移，正值向右／向下。
///
/// 这样切换锚点时同一个偏移仍表示「离边缘多远」，预设可以直接复用。
public struct OverlayOffset: Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public static let zero = OverlayOffset(x: 0, y: 0)
}

/// 图层尺寸。
public enum OverlaySize: Hashable, Sendable, Codable {
    /// 固定尺寸。
    case fixed(PixelSize)
    /// 内容本身的尺寸（素材像素或排版后的文字框），超过最大尺寸时等比缩小，不放大。
    case fitting(PixelSize, maximum: PixelSize)
}

/// 图层显示在哪些页。页码是轮播位置：0 = 封面，1…N = 全景切片（切片序号 k 对应 k + 1）。
public enum OverlayVisibility: Hashable, Sendable, Codable {
    /// 只在封面（默认，§5.3、§7.2）。
    case coverOnly
    /// 封面和所有切片。
    case allSlides
    /// 指定页码（可以包含 0 = 封面）。
    case selectedSlides(Set<Int>)

    /// 页码 `page` 是否显示。
    public func includes(page: Int) -> Bool {
        switch self {
        case .coverOnly: page == 0
        case .allSlides: true
        case .selectedSlides(let pages): pages.contains(page)
        }
    }
}

/// 一个装饰图层的几何参数。
public struct OverlayGeometry: Hashable, Sendable, Codable {
    public var anchor: OverlayAnchor
    public var reference: OverlayReference
    public var offset: OverlayOffset
    public var size: OverlaySize
    public var visibility: OverlayVisibility

    public init(
        anchor: OverlayAnchor,
        reference: OverlayReference = .default,
        offset: OverlayOffset = .zero,
        size: OverlaySize,
        visibility: OverlayVisibility = .coverOnly
    ) {
        self.anchor = anchor
        self.reference = reference
        self.offset = offset
        self.size = size
        self.visibility = visibility
    }
}

/// 图层参数错误。`code` 是稳定的机器可读错误码。
public enum OverlayError: Error, Hashable, Sendable {
    case invalidSize(PixelSize)
    case invalidMaximumSize(PixelSize)
    /// 居中锚点没有「外侧」方向。
    case centerAnchorOutside
    case invalidPage(Int)
    case invalidCanvas(PixelSize)
    case invalidPhotoRect(PixelRect)
    /// 图层既没有固定尺寸，也没有提供内容尺寸。
    case missingSize

    public var code: String {
        switch self {
        case .invalidSize: "overlay.invalid_size"
        case .invalidMaximumSize: "overlay.invalid_maximum_size"
        case .centerAnchorOutside: "overlay.center_anchor_outside"
        case .invalidPage: "overlay.invalid_page"
        case .invalidCanvas: "overlay.invalid_canvas"
        case .invalidPhotoRect: "overlay.invalid_photo_rect"
        case .missingSize: "overlay.missing_size"
        }
    }

    public var message: String {
        switch self {
        case .invalidSize(let s): "图层尺寸必须为正：\(s)"
        case .invalidMaximumSize(let s): "图层最大尺寸必须为正：\(s)"
        case .centerAnchorOutside: "居中锚点不能放在照片外侧；请改为内侧或选择其他锚点"
        case .invalidPage(let p): "页码不能为负：\(p)"
        case .invalidCanvas(let s): "画布尺寸必须为正：\(s)"
        case .invalidPhotoRect(let r): "照片矩形必须为正且位于画布内：\(r)"
        case .missingSize: "图层没有 sizePx，渲染时也没有提供内容尺寸"
        }
    }
}
