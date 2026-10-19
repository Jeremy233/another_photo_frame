/// 切片张数：自动取最少张数，或用户手动指定（D-11：只能 ≥ 自动张数）。
public enum SlideCount: Hashable, Sendable, Codable {
    case automatic
    case manual(Int)
}

/// 全景布局的提示。全部是警告，不阻止计算；是否禁止导出由上层决定。
public enum PanoramaWarning: Hashable, Sendable, Codable {
    /// 竖图或方图（R ≤ 1），全景切片通常没有意义（§5.3 关键边界）。
    case notLandscape(aspectRatio: Double)
    /// 横图，但渲染宽度不超过 2 张切片宽（自动张数 ≤ 2，即 R ≤ 2·W/(H−2v)），切片意义不大。
    case notWideEnough(automaticSlideCount: Int)
    /// 封面 + 切片总数超过平台轮播上限（§5.3、D-18）。不输出封面时只算切片。
    case exceedsCarouselLimit(totalItems: Int, limit: Int)
    /// 手动张数多于自动张数：长卷两端补更多底色（D-11）。
    case increasedSlideCount(automatic: Int, requested: Int)

    public var code: String {
        switch self {
        case .notLandscape: "panorama.not_landscape"
        case .notWideEnough: "panorama.not_wide_enough"
        case .exceedsCarouselLimit: "panorama.exceeds_carousel_limit"
        case .increasedSlideCount: "panorama.increased_slide_count"
        }
    }
}

/// 一张切片。坐标中「全局」指虚拟长卷坐标，「本地」指这张切片自己的画布坐标。
public struct PanoramaSlice: Hashable, Sendable, Codable {
    /// 切片序号 k（0 起）。轮播中的位置是 k + 1，第 0 位是封面。
    public var index: Int
    /// 在长卷中的位置：`[kW, (k+1)W) × [0, H)`。
    public var frame: PixelRect
    /// 照片在本切片中占据的像素矩形（本地坐标）；整张都是底色时为 nil。
    public var imageRect: PixelRect?
    /// 本切片左、右两侧的底色宽度（px）。只有长卷最外侧的切片才可能非 0。
    public var backgroundLeft: Int
    public var backgroundRight: Int
    /// 源图显示坐标 → 本地切片坐标。等于全局变换平移 −kW，所有切片缩放相同。
    public var transform: ScaleTranslateTransform
    /// 本切片用到的源图区域（源图显示坐标，连续值），供按区域解码；无照片时为 nil。
    public var sourceRegion: Rect?
}

/// 全景模式：Cover + Seamless Slides（规范 §5.3）。
public struct PanoramaLayout: Hashable, Sendable, Codable {
    public var tile: PixelSize
    public var source: PixelSize
    public var verticalMargin: Int
    /// 封面（Slide 0）：完整原图普通 Fit。
    public var cover: FitLayout
    /// 按 `H − 2v` 渲染高度算出的最少张数。
    public var automaticSlideCount: Int
    /// 实际使用的张数 N。
    public var slideCount: Int
    /// 虚拟长卷尺寸 `N·W × H`。
    public var stripSize: PixelSize
    /// 连续坐标下照片在长卷中的精确矩形。
    public var exactImageRect: Rect
    /// 栅格化用的照片矩形（全局坐标，D-22）：左右补边相差 ≤ 1 px，多出的在右侧。
    public var pixelImageRect: PixelRect
    /// 源图显示坐标 → 长卷全局坐标。所有切片共用。
    public var transform: ScaleTranslateTransform
    public var slices: [PanoramaSlice]
    public var warnings: [PanoramaWarning]

    /// 精确左右补边（可能为半像素，如 157.5）。
    public var exactPadding: (left: Double, right: Double) {
        (exactImageRect.minX, Double(stripSize.width) - exactImageRect.maxX)
    }

    /// 栅格化后的左右补边（左 = floor，右 = 剩余）。
    public var pixelPadding: (left: Int, right: Int) {
        (pixelImageRect.minX, stripSize.width - pixelImageRect.maxX)
    }

    /// 自动张数的容差（px）：渲染宽度只超出 N·W 不到这么多时仍取 N，
    /// 避免浮点误差把本该 4 张算成 5 张。
    public static let defaultSlideCountTolerance = 0.01

    /// - Parameters:
    ///   - tile: 单张切片尺寸 W × H，同时也是封面画布尺寸。
    ///   - coverMinimumMargin: 封面 Fit 的最小边距。
    ///   - verticalMargin: 所有切片共用的上下边距 v（D-10），渲染高度为 H − 2v。
    ///   - slideCount: 自动或手动张数；手动值小于自动张数时抛出 `slideCountBelowMinimum`（D-11）。
    ///   - maxCarouselItems: 平台轮播最多项数（含封面）；nil 表示不检查。
    ///   - includesCover: 轮播里有没有封面（预设 `panorama.cover`）。没有封面时只按切片张数检查轮播上限。
    ///   - alignment: 照片在长卷里靠左、居中还是靠右；靠左／靠右时照片贴边，底色都在另一端。
    public init(
        tile: PixelSize,
        source: PixelSize,
        coverMinimumMargin: Int = 60,
        verticalMargin: Int = 0,
        slideCount: SlideCount = .automatic,
        maxCarouselItems: Int? = nil,
        includesCover: Bool = true,
        alignment: PanoramaSettings.Alignment = .center,
        slideCountTolerance: Double = PanoramaLayout.defaultSlideCountTolerance
    ) throws(GeometryError) {
        guard tile.isPositive else { throw .invalidCanvas(tile) }
        guard source.isPositive else { throw .invalidSource(source) }
        // 即 H − 2v > 0；写成 v < H − v，边距极大时不溢出。
        guard verticalMargin >= 0, verticalMargin < tile.height - verticalMargin else {
            throw .invalidVerticalMargin(verticalMargin)
        }
        if case .manual(let n) = slideCount, n < 1 { throw .invalidSlideCount(n) }

        let cover = try FitLayout(canvas: tile, minimumMargin: coverMinimumMargin, source: source)

        let renderHeight = Double(tile.height - 2 * verticalMargin)
        let aspect = source.aspectRatio
        let renderWidth = aspect * renderHeight
        let automatic = max(
            1, Int(((renderWidth - slideCountTolerance) / Double(tile.width)).rounded(.up)))
        let n: Int
        switch slideCount {
        case .automatic: n = automatic
        case .manual(let requested):
            guard requested >= automatic else {
                throw .slideCountBelowMinimum(requested: requested, minimum: automatic)
            }
            n = requested
        }

        // 长卷内框 = 宽 N·W、高 H − 2v。N ≥ 自动张数，所以高度贴边；
        // 取 min 只是为了吸收容差内的超出（如 4320.00001 → 4320），不会出现上下补底色。
        let strip = PixelSize(width: n * tile.width, height: tile.height)
        var placement = centeredPlacement(
            source: source, container: strip, insetX: 0, insetY: verticalMargin)
        switch alignment {
        case .center: break
        case .left:
            placement.exactRect.x = 0
            placement.pixelRect.x = 0
        case .right:
            placement.exactRect.x = Double(strip.width) - placement.exactRect.width
            placement.pixelRect.x = strip.width - placement.pixelRect.width
        }
        let transform = ScaleTranslateTransform.mapping(source: source, into: placement.pixelRect)

        var warnings: [PanoramaWarning] = []
        if aspect <= 1 {
            warnings.append(.notLandscape(aspectRatio: aspect))
        } else if automatic <= 2 {
            warnings.append(.notWideEnough(automaticSlideCount: automatic))
        }
        if n > automatic {
            warnings.append(.increasedSlideCount(automatic: automatic, requested: n))
        }
        let carouselItems = n + (includesCover ? 1 : 0)
        if let limit = maxCarouselItems, carouselItems > limit {
            warnings.append(.exceedsCarouselLimit(totalItems: carouselItems, limit: limit))
        }

        self.tile = tile
        self.source = source
        self.verticalMargin = verticalMargin
        self.cover = cover
        self.automaticSlideCount = automatic
        self.slideCount = n
        self.stripSize = strip
        self.exactImageRect = placement.exactRect
        self.pixelImageRect = placement.pixelRect
        self.transform = transform
        self.warnings = warnings
        self.slices = (0..<n).map { k in
            Self.slice(index: k, tile: tile, image: placement.pixelRect, transform: transform)
        }
    }

    public init(
        tile: PixelSize,
        source: SourceImage,
        coverMinimumMargin: Int = 60,
        verticalMargin: Int = 0,
        slideCount: SlideCount = .automatic,
        maxCarouselItems: Int? = nil,
        includesCover: Bool = true,
        alignment: PanoramaSettings.Alignment = .center,
        slideCountTolerance: Double = PanoramaLayout.defaultSlideCountTolerance
    ) throws(GeometryError) {
        try self.init(
            tile: tile, source: source.displaySize, coverMinimumMargin: coverMinimumMargin,
            verticalMargin: verticalMargin, slideCount: slideCount,
            maxCarouselItems: maxCarouselItems, includesCover: includesCover, alignment: alignment,
            slideCountTolerance: slideCountTolerance)
    }

    /// 「自动上下边距」：让上下边距 v 等于长卷端部的底色宽度。
    ///
    /// 照片宽高比 R、切片 W × H、张数 N 时，总底色宽 G = N·W − R·(H − 2v)。居中时每端 G/2，
    /// 靠左／靠右时只有一端、宽 G。令 v = G / k（居中 k = 2，否则 k = 1），解得
    /// `v = (R·H − N·W) / (2R − k)`。v 变大会让照片变窄、底色变宽，所以自动张数时取
    /// N = floor(R·H / W)，比不加边距时少一张，才能有 v ≥ 0 的解。
    ///
    /// 竖图／方图、算出的 v 无效（≤ 0、不小于 H − v，或这个 v 下自动张数不是 N），以及手动张数多到
    /// 无解时返回 0，即不加上下边距。结果向下取整。
    public static func equalizedVerticalMargin(
        tile: PixelSize,
        source: PixelSize,
        slideCount: SlideCount = .automatic,
        alignment: PanoramaSettings.Alignment = .center,
        slideCountTolerance: Double = PanoramaLayout.defaultSlideCountTolerance
    ) -> Int {
        guard tile.isPositive, source.isPositive else { return 0 }
        let r = source.aspectRatio
        guard r > 1 else { return 0 }
        let w = Double(tile.width), h = Double(tile.height)
        let n: Int = switch slideCount {
        case .automatic: Int(((r * h + slideCountTolerance) / w).rounded(.down))
        case .manual(let requested): requested
        }
        guard n >= 1 else { return 0 }
        let k: Double = alignment == .center ? 2 : 1
        let exact = (r * h - Double(n) * w) / (2 * r - k)
        guard exact > 0 else { return 0 }
        let v = Int(exact.rounded(.down))
        guard v < tile.height - v else { return 0 }
        if case .automatic = slideCount {
            let automatic = max(1, Int(((r * Double(tile.height - 2 * v) - slideCountTolerance) / w).rounded(.up)))
            guard automatic == n else { return 0 }
        }
        return v
    }

    static func slice(
        index k: Int, tile: PixelSize, image: PixelRect, transform: ScaleTranslateTransform
    ) -> PanoramaSlice {
        let x0 = k * tile.width
        let x1 = x0 + tile.width
        let frame = PixelRect(x: x0, y: 0, width: tile.width, height: tile.height)
        let local = transform.translatedBy(x: -Double(x0), y: 0)

        let left = max(image.minX, x0)
        let right = min(image.maxX, x1)
        guard right > left else {
            // 整张都是底色：位于照片左侧则底色记在左边，否则记在右边。
            let isLeftOfImage = x1 <= image.minX
            return PanoramaSlice(
                index: k, frame: frame, imageRect: nil,
                backgroundLeft: isLeftOfImage ? tile.width : 0,
                backgroundRight: isLeftOfImage ? 0 : tile.width,
                transform: local, sourceRegion: nil)
        }
        let imageRect = PixelRect(x: left - x0, y: image.y, width: right - left, height: image.height)
        return PanoramaSlice(
            index: k, frame: frame, imageRect: imageRect,
            backgroundLeft: left - x0, backgroundRight: x1 - right,
            transform: local, sourceRegion: local.invert(imageRect.rect))
    }
}

extension PanoramaSettings {
    /// 预设里的切片张数换成版式计算用的 ``SlideCount``。
    public var slideCount: SlideCount {
        switch tileCount {
        case .auto: .automatic
        case .fixed(let n): .manual(n)
        }
    }

    /// 实际使用的上下边距：打开「自动」时按这张源图算（``PanoramaLayout/equalizedVerticalMargin``），否则用 `verticalMarginPx`。
    public func resolvedVerticalMargin(tile: PixelSize, source: PixelSize) -> Int {
        guard autoVerticalMargin else { return verticalMarginPx }
        return PanoramaLayout.equalizedVerticalMargin(
            tile: tile, source: source, slideCount: slideCount, alignment: alignment)
    }
}
