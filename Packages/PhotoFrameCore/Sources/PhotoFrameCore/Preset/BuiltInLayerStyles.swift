/// `brandLogo` 装饰的设置（D-132、D-137）：按源图的相机品牌画内置 logo。
///
/// JSON 写在图层的 `logo` 字段里：`brand`、`fallback`、`variant`、`heightPx`、`colorMode`、`color`。
public struct BrandLogoStyle: Hashable, Sendable, Codable {
    /// 认不出品牌时画什么。
    public enum Fallback: String, Hashable, Sendable, Codable, CaseIterable {
        /// 什么都不画（默认，D-132）。
        case none
        /// 画品牌文字（`{brand}`）。
        case text
    }

    /// 同一品牌有字标和标志两种时用哪一种（目前只有 Nikon 两种都有）。
    public enum Variant: String, Hashable, Sendable, Codable, CaseIterable {
        case wordmark, emblem
    }

    public enum ColorMode: String, Hashable, Sendable, Codable, CaseIterable {
        /// 品牌自己的颜色；单色 logo 没有自己的颜色，按画布深浅用黑或白。
        case original
        /// 浅色画布用深色、深色画布用浅色。
        case auto
        /// 用 `color`。
        case custom
    }

    /// 「自动」时写 `auto`；用素材槽里的素材时写 `slot`（D-139）；否则是 `brands.json` 里的品牌 ID。
    public var brand: String
    public var fallback: Fallback
    public var variant: Variant
    /// logo 高度（px）。接近正方形的 logo 由渲染层放大，见 D-132。
    public var heightPx: Double
    public var colorMode: ColorMode
    /// `colorMode` 为 `custom` 时用的颜色。
    public var color: PresetColor?
    public var extensions: ExtensionFields

    /// `brand` 写这个值时按源图的相机品牌自动选。
    public static let automatic = "auto"
    /// `brand` 写这个值时画图层素材槽（`slotId`）里绑定的素材，内置的或自己导入的都可以（D-139）。
    public static let fromSlot = "slot"

    public init(
        brand: String = BrandLogoStyle.automatic,
        fallback: Fallback = .none,
        variant: Variant = .wordmark,
        heightPx: Double = 56,
        colorMode: ColorMode = .original,
        color: PresetColor? = nil,
        extensions: ExtensionFields = [:]
    ) {
        self.brand = brand
        self.fallback = fallback
        self.variant = variant
        self.heightPx = heightPx
        self.colorMode = colorMode
        self.color = color
        self.extensions = extensions
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case brand, fallback, variant, heightPx, colorMode, color
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brand = try c.decodeIfPresent(String.self, forKey: .brand) ?? Self.automatic
        fallback = try c.decodeIfPresent(Fallback.self, forKey: .fallback) ?? .none
        variant = try c.decodeIfPresent(Variant.self, forKey: .variant) ?? .wordmark
        heightPx = try c.decodeIfPresent(Double.self, forKey: .heightPx) ?? 56
        colorMode = try c.decodeIfPresent(ColorMode.self, forKey: .colorMode) ?? .original
        color = try c.decodeIfPresent(PresetColor.self, forKey: .color)
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(brand, forKey: .brand)
        try c.encode(fallback, forKey: .fallback)
        try c.encode(variant, forKey: .variant)
        try c.encode(heightPx, forKey: .heightPx)
        try c.encode(colorMode, forKey: .colorMode)
        try c.encodeIfPresent(color, forKey: .color)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }
}

/// `filmIcon` 装饰的设置（D-134、D-137）：按源图填的胶卷画内置图标和文字。文字样式在图层的 `text` 里，模板默认 `{film}`。
///
/// JSON 写在图层的 `filmIcon` 字段里：`film`、`show`、`iconSizePx`、`noIcon`。
public struct FilmIconStyle: Hashable, Sendable, Codable {
    public enum Show: String, Hashable, Sendable, Codable, CaseIterable {
        case iconAndText, icon, text
    }

    /// 这种胶卷没有图标时画什么。
    public enum NoIcon: String, Hashable, Sendable, Codable, CaseIterable {
        /// 胶卷名以某个内置品牌开头时用这个品牌的 logo（默认）。
        case brandLogo
        /// 只画文字。
        case text
        /// 不画。
        case none
    }

    /// 「自动」时写 `auto`（按源图填的胶卷）；用素材槽里的图标时写 `slot`（D-139）；否则是 `films.json` 里的胶卷 ID。
    public var film: String
    public var show: Show
    /// 图标边长（px）。
    public var iconSizePx: Double
    public var noIcon: NoIcon
    public var extensions: ExtensionFields

    public static let automatic = "auto"
    /// `film` 写这个值时图标用图层素材槽（`slotId`）里绑定的素材（D-139）。
    public static let fromSlot = "slot"
    /// 胶卷装饰的默认文字模板。
    public static let defaultTemplate = "{film}"
    /// 图层没有 `text` 时胶卷文字的样式：渲染按它画，界面按它显示、修改（D-137）。
    public static let defaultTextStyle = TextStyle(template: defaultTemplate, fontWeight: .medium, fontSizePx: 20, letterSpacingPx: 1,
                                                   colorMode: .auto)

    public init(
        film: String = FilmIconStyle.automatic,
        show: Show = .iconAndText,
        iconSizePx: Double = 72,
        noIcon: NoIcon = .brandLogo,
        extensions: ExtensionFields = [:]
    ) {
        self.film = film
        self.show = show
        self.iconSizePx = iconSizePx
        self.noIcon = noIcon
        self.extensions = extensions
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case film, show, iconSizePx, noIcon
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        film = try c.decodeIfPresent(String.self, forKey: .film) ?? Self.automatic
        show = try c.decodeIfPresent(Show.self, forKey: .show) ?? .iconAndText
        iconSizePx = try c.decodeIfPresent(Double.self, forKey: .iconSizePx) ?? 72
        noIcon = try c.decodeIfPresent(NoIcon.self, forKey: .noIcon) ?? .brandLogo
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(film, forKey: .film)
        try c.encode(show, forKey: .show)
        try c.encode(iconSizePx, forKey: .iconSizePx)
        try c.encode(noIcon, forKey: .noIcon)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }
}
