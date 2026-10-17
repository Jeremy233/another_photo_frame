/// 文字图层的内容与样式（§7.1）。字体样式字段 `fontWeight`、`italic`、`letterSpacingPx` 由 D-111 加入，
/// 旧预设缺少时取默认值（常规、非斜体、0），schemaVersion 不变。
public struct TextStyle: Hashable, Sendable, Codable {
    /// 字重，取值与系统字重一一对应。找不到对应字重时渲染用最接近的。
    public enum FontWeight: String, Hashable, Sendable, Codable, CaseIterable {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
    }

    /// `text` 图层的固定文字，例如签名。
    public var content: String?
    /// `metadataText` 图层的模板，例如 `"{camera} · {focalLength} · {aperture}"`。占位符的取值规则由渲染层定义。
    public var template: String?
    public var fontFamily: String?
    public var fontWeight: FontWeight
    public var italic: Bool
    public var fontSizePx: Double
    /// 字间距（px，可为负）。
    public var letterSpacingPx: Double
    /// 行距倍数。
    public var lineHeight: Double
    public var color: PresetColor
    public var paddingPx: Int
    public var extensions: ExtensionFields

    public init(
        content: String? = nil,
        template: String? = nil,
        fontFamily: String? = nil,
        fontWeight: FontWeight = .regular,
        italic: Bool = false,
        fontSizePx: Double = 14,
        letterSpacingPx: Double = 0,
        lineHeight: Double = 1.2,
        color: PresetColor = PresetColor(hex: "#3A3A38"),
        paddingPx: Int = 0,
        extensions: ExtensionFields = [:]
    ) {
        self.content = content
        self.template = template
        self.fontFamily = fontFamily
        self.fontWeight = fontWeight
        self.italic = italic
        self.fontSizePx = fontSizePx
        self.letterSpacingPx = letterSpacingPx
        self.lineHeight = lineHeight
        self.color = color
        self.paddingPx = paddingPx
        self.extensions = extensions
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case content, template, fontFamily, fontWeight, italic, fontSizePx, letterSpacingPx, lineHeight, color, paddingPx
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        template = try c.decodeIfPresent(String.self, forKey: .template)
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        fontWeight = try c.decodeIfPresent(FontWeight.self, forKey: .fontWeight) ?? .regular
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        fontSizePx = try c.decodeIfPresent(Double.self, forKey: .fontSizePx) ?? 14
        letterSpacingPx = try c.decodeIfPresent(Double.self, forKey: .letterSpacingPx) ?? 0
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
        try c.encode(fontWeight, forKey: .fontWeight)
        try c.encode(italic, forKey: .italic)
        try c.encode(fontSizePx, forKey: .fontSizePx)
        try c.encode(letterSpacingPx, forKey: .letterSpacingPx)
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
