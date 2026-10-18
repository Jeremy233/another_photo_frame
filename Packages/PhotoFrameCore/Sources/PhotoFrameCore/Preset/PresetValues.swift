/// 以两元素 JSON 数组编码的值对，例如 `"sizePx": [48, 48]`、`"anchor": [0.5, 0.5]`。
public struct Pair<T: Codable & Hashable & Sendable>: Hashable, Sendable, Codable {
    public var first: T
    public var second: T

    public init(_ first: T, _ second: T) {
        self.first = first
        self.second = second
    }

    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        first = try c.decode(T.self)
        second = try c.decode(T.self)
        guard c.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "应为两个元素的数组")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(first)
        try c.encode(second)
    }
}

/// 预设中的颜色：带色彩空间声明的十六进制值（§5.1：`#FAFAF8` 解释为 sRGB 编码）。
public struct PresetColor: Hashable, Sendable, Codable {
    /// 目前只支持 `sRGB`；其他值在校验时报 `preset.unsupported_color_space`。
    public var colorSpace: String
    /// `#RRGGBB`。不带 alpha：透明度统一用图层的 `opacity`（D-35）。
    public var hex: String
    public var extensions: ExtensionFields

    public init(colorSpace: String = "sRGB", hex: String, extensions: ExtensionFields = [:]) {
        self.colorSpace = colorSpace
        self.hex = hex
        self.extensions = extensions
    }

    /// 默认背景 `#FAFAF8`（§2.2）。
    public static let defaultBackground = PresetColor(hex: "#FAFAF8")

    /// 十六进制格式是否合法。只认 ASCII 数字和字母：`Character.isHexDigit` 对全角的「０」「Ａ」也为真，
    /// 渲染时却解析不了。
    public var isValidHex: Bool {
        guard hex.first == "#" else { return false }
        let digits = hex.dropFirst()
        return digits.count == 6 && digits.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case colorSpace, hex }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colorSpace = try c.decodeIfPresent(String.self, forKey: .colorSpace) ?? "sRGB"
        hex = try c.decode(String.self, forKey: .hex)
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(colorSpace, forKey: .colorSpace)
        try c.encode(hex, forKey: .hex)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }
}
