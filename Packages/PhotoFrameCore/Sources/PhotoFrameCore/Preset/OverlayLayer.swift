/// 一个排版图层（§7.1）。拖动图层时修改的就是这些可序列化参数。
public struct OverlayLayer: Hashable, Sendable, Codable {
    public enum LayerType: String, Hashable, Sendable, Codable, CaseIterable {
        case text, asset, metadataText, cameraBadge

        /// 是否需要通过 `slotId` 绑定本地素材。
        public var usesAssetSlot: Bool { self == .asset || self == .cameraBadge }
        /// 是否有文本内容。
        public var usesText: Bool { self == .text || self == .metadataText }
    }

    /// 适用页面。默认只在封面（§7.2）。
    public enum Visibility: String, Hashable, Sendable, Codable, CaseIterable {
        case coverOnly, allSlides, selectedSlides
    }

    /// 定位参照：照片边缘（默认，D-12）或画布。
    public enum Reference: String, Hashable, Sendable, Codable, CaseIterable {
        case photo, canvas
    }

    /// 允许绘制的区域：留白（默认，不遮挡照片）、照片或整张画布。
    public enum Region: String, Hashable, Sendable, Codable, CaseIterable {
        case margin, photo, canvas
    }

    public var layerId: String
    public var type: LayerType
    public var enabled: Bool
    public var visibleOn: Visibility
    /// `visibleOn == .selectedSlides` 时的轮播位置；0 是封面，k + 1 是第 k 张切片。
    public var slides: [Int]?
    public var anchor: Anchor
    public var reference: Reference
    public var region: Region
    /// 相对锚点的偏移（px），`[x, y]`，x 向右、y 向下。
    public var offsetPx: Pair<Int>
    /// 固定尺寸 `[宽, 高]`（素材图层常用）。
    public var sizePx: Pair<Int>?
    /// 最大外框 `[宽, 高]`（文字图层常用）。
    public var maxBoundsPx: Pair<Int>?
    public var opacity: Double
    public var zIndex: Int
    /// `asset` / `cameraBadge` 图层绑定的素材槽。
    public var slotId: String?
    /// `text` / `metadataText` 图层的文字与样式。
    public var text: TextStyle?
    public var extensions: ExtensionFields

    public init(
        layerId: String,
        type: LayerType,
        enabled: Bool = true,
        visibleOn: Visibility = .coverOnly,
        slides: [Int]? = nil,
        anchor: Anchor = .bottomRight,
        reference: Reference = .photo,
        region: Region = .margin,
        offsetPx: Pair<Int> = Pair(0, 0),
        sizePx: Pair<Int>? = nil,
        maxBoundsPx: Pair<Int>? = nil,
        opacity: Double = 1,
        zIndex: Int = 0,
        slotId: String? = nil,
        text: TextStyle? = nil,
        extensions: ExtensionFields = [:]
    ) {
        self.layerId = layerId
        self.type = type
        self.enabled = enabled
        self.visibleOn = visibleOn
        self.slides = slides
        self.anchor = anchor
        self.reference = reference
        self.region = region
        self.offsetPx = offsetPx
        self.sizePx = sizePx
        self.maxBoundsPx = maxBoundsPx
        self.opacity = opacity
        self.zIndex = zIndex
        self.slotId = slotId
        self.text = text
        self.extensions = extensions
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case layerId, type, enabled, visibleOn, slides, anchor, reference, region
        case offsetPx, sizePx, maxBoundsPx, opacity, zIndex, slotId, text
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layerId = try c.decode(String.self, forKey: .layerId)
        type = try c.decode(LayerType.self, forKey: .type)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        visibleOn = try c.decodeIfPresent(Visibility.self, forKey: .visibleOn) ?? .coverOnly
        slides = try c.decodeIfPresent([Int].self, forKey: .slides)
        anchor = try c.decodeIfPresent(Anchor.self, forKey: .anchor) ?? .bottomRight
        reference = try c.decodeIfPresent(Reference.self, forKey: .reference) ?? .photo
        region = try c.decodeIfPresent(Region.self, forKey: .region) ?? .margin
        offsetPx = try c.decodeIfPresent(Pair<Int>.self, forKey: .offsetPx) ?? Pair(0, 0)
        sizePx = try c.decodeIfPresent(Pair<Int>.self, forKey: .sizePx)
        maxBoundsPx = try c.decodeIfPresent(Pair<Int>.self, forKey: .maxBoundsPx)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        zIndex = try c.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        slotId = try c.decodeIfPresent(String.self, forKey: .slotId)
        text = try c.decodeIfPresent(TextStyle.self, forKey: .text)
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(layerId, forKey: .layerId)
        try c.encode(type, forKey: .type)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(visibleOn, forKey: .visibleOn)
        try c.encodeIfPresent(slides, forKey: .slides)
        try c.encode(anchor, forKey: .anchor)
        try c.encode(reference, forKey: .reference)
        try c.encode(region, forKey: .region)
        try c.encode(offsetPx, forKey: .offsetPx)
        try c.encodeIfPresent(sizePx, forKey: .sizePx)
        try c.encodeIfPresent(maxBoundsPx, forKey: .maxBoundsPx)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(zIndex, forKey: .zIndex)
        try c.encodeIfPresent(slotId, forKey: .slotId)
        try c.encodeIfPresent(text, forKey: .text)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }
}

/// 文字图层的内容与样式（§7.1）。
public struct TextStyle: Hashable, Sendable, Codable {
    /// `text` 图层的固定文字，例如签名。
    public var content: String?
    /// `metadataText` 图层的模板，例如 `"{camera} · {focalLength} · {aperture}"`。占位符的取值规则由渲染层定义。
    public var template: String?
    public var fontFamily: String?
    public var fontSizePx: Double
    /// 行距倍数。
    public var lineHeight: Double
    public var color: PresetColor
    public var paddingPx: Int
    public var extensions: ExtensionFields

    public init(
        content: String? = nil,
        template: String? = nil,
        fontFamily: String? = nil,
        fontSizePx: Double = 14,
        lineHeight: Double = 1.2,
        color: PresetColor = PresetColor(hex: "#3A3A38"),
        paddingPx: Int = 0,
        extensions: ExtensionFields = [:]
    ) {
        self.content = content
        self.template = template
        self.fontFamily = fontFamily
        self.fontSizePx = fontSizePx
        self.lineHeight = lineHeight
        self.color = color
        self.paddingPx = paddingPx
        self.extensions = extensions
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case content, template, fontFamily, fontSizePx, lineHeight, color, paddingPx
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        template = try c.decodeIfPresent(String.self, forKey: .template)
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        fontSizePx = try c.decodeIfPresent(Double.self, forKey: .fontSizePx) ?? 14
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.2
        color = try c.decodeIfPresent(PresetColor.self, forKey: .color) ?? PresetColor(hex: "#3A3A38")
        paddingPx = try c.decodeIfPresent(Int.self, forKey: .paddingPx) ?? 0
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(template, forKey: .template)
        try c.encodeIfPresent(fontFamily, forKey: .fontFamily)
        try c.encode(fontSizePx, forKey: .fontSizePx)
        try c.encode(lineHeight, forKey: .lineHeight)
        try c.encode(color, forKey: .color)
        try c.encode(paddingPx, forKey: .paddingPx)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }
}

/// 素材占位符（§8.2）。只描述作用和要求，不含任何本地路径；具体素材由 AssetBinding 决定。
public struct AssetSlot: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case image
    }

    /// 素材格式（D-09：PNG 与受限 SVG）。
    public enum Format: String, Hashable, Sendable, Codable, CaseIterable {
        case png, svg
    }

    public var slotId: String
    public var kind: Kind
    /// 缺失时：false → 警告并跳过图层；true → 阻止输出。
    public var required: Bool
    /// 给用户看的用途说明，例如「相机线稿」。
    public var label: String?
    public var acceptedFormats: [Format]
    public var extensions: ExtensionFields

    public init(
        slotId: String,
        kind: Kind = .image,
        required: Bool = false,
        label: String? = nil,
        acceptedFormats: [Format] = Format.allCases,
        extensions: ExtensionFields = [:]
    ) {
        self.slotId = slotId
        self.kind = kind
        self.required = required
        self.label = label
        self.acceptedFormats = acceptedFormats
        self.extensions = extensions
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case slotId, kind, required, label, acceptedFormats
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slotId = try c.decode(String.self, forKey: .slotId)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .image
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        label = try c.decodeIfPresent(String.self, forKey: .label)
        acceptedFormats = try c.decodeIfPresent([Format].self, forKey: .acceptedFormats) ?? Format.allCases
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(slotId, forKey: .slotId)
        try c.encode(kind, forKey: .kind)
        try c.encode(required, forKey: .required)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(acceptedFormats, forKey: .acceptedFormats)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }
}
