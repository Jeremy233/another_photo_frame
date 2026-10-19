/// 画布设置（§5.2、§8.1 `canvas`）。
public struct CanvasSettings: Hashable, Sendable, Codable {
    public enum Mode: String, Hashable, Sendable, Codable, CaseIterable {
        /// 完整嵌入，不裁切（默认，D-21）。
        case fit
        /// 用户主动开启的比例裁切（D-21），参数见 ``CanvasSettings/crop``。
        case crop
    }

    public var width: Int
    public var height: Int
    public var background: PresetColor
    public var minMarginPx: Int
    public var mode: Mode
    /// `mode == .crop` 时的裁切参数；为 nil 时使用默认值（内框比例、居中）。
    public var crop: CropSettings?
    public var extensions: ExtensionFields

    public init(
        width: Int, height: Int,
        background: PresetColor = .defaultBackground,
        minMarginPx: Int = 60,
        mode: Mode = .fit,
        crop: CropSettings? = nil,
        extensions: ExtensionFields = [:]
    ) {
        self.width = width
        self.height = height
        self.background = background
        self.minMarginPx = minMarginPx
        self.mode = mode
        self.crop = crop
        self.extensions = extensions
    }

    public var size: PixelSize { PixelSize(width: width, height: height) }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case width, height, background, minMarginPx, mode, crop
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        background = try c.decodeIfPresent(PresetColor.self, forKey: .background) ?? .defaultBackground
        minMarginPx = try c.decodeIfPresent(Int.self, forKey: .minMarginPx) ?? 60
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .fit
        crop = try c.decodeIfPresent(CropSettings.self, forKey: .crop)
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(background, forKey: .background)
        try c.encode(minMarginPx, forKey: .minMarginPx)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(crop, forKey: .crop)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }
}

/// 比例裁切参数（D-21），与 ``CropLayout`` 的参数一一对应。
public struct CropSettings: Hashable, Sendable, Codable {
    /// 裁切比例 `[宽, 高]`；nil 表示取内框比例 (W − 2m) : (H − 2m)。
    public var aspectRatio: Pair<Double>?
    /// 裁切框在可移动范围内的相对位置，`[x, y]` 取 0…1，默认居中。
    public var anchor: Pair<Double>
    public var extensions: ExtensionFields

    public init(aspectRatio: Pair<Double>? = nil, anchor: Pair<Double> = Pair(0.5, 0.5), extensions: ExtensionFields = [:]) {
        self.aspectRatio = aspectRatio
        self.anchor = anchor
        self.extensions = extensions
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case aspectRatio, anchor }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspectRatio = try c.decodeIfPresent(Pair<Double>.self, forKey: .aspectRatio)
        anchor = try c.decodeIfPresent(Pair<Double>.self, forKey: .anchor) ?? Pair(0.5, 0.5)
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try c.encode(anchor, forKey: .anchor)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }
}

/// 全景设置（§5.3、§8.1 `panorama`）。
public struct PanoramaSettings: Hashable, Sendable, Codable {
    /// 切片张数：自动（最少张数）或手动指定（只能 ≥ 自动值，D-11）。
    public enum TileCount: Hashable, Sendable, Codable {
        case auto
        case fixed(Int)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) {
                self = .fixed(n)
            } else if try c.decode(String.self) == "auto" {
                self = .auto
            } else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "tileCount 应为 \"auto\" 或整数")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .auto: try c.encode("auto")
            case .fixed(let n): try c.encode(n)
            }
        }
    }

    /// 全景永远不裁切（§5.3、D-21），目前只有一个取值。
    public enum CropPolicy: String, Hashable, Sendable, Codable, CaseIterable {
        case never
    }

    /// 长卷两端的补边颜色。
    public enum PadColor: Hashable, Sendable, Codable {
        case canvasBackground
        case color(PresetColor)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                guard s == "canvasBackground" else {
                    throw DecodingError.dataCorruptedError(in: c, debugDescription: "padColor 应为 \"canvasBackground\" 或颜色对象")
                }
                self = .canvasBackground
            } else {
                self = .color(try c.decode(PresetColor.self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .canvasBackground: try c.encode("canvasBackground")
            case .color(let color): try c.encode(color)
            }
        }
    }

    /// 照片在长卷里的水平位置：多出来的底色放在哪一端。
    public enum Alignment: String, Hashable, Sendable, Codable, CaseIterable {
        /// 照片贴住长卷左端，底色都在右端。
        case left
        /// 底色平分在两端（默认）。
        case center
        /// 照片贴住长卷右端，底色都在左端。
        case right
    }

    public var enabled: Bool
    /// 是否输出 Slide 0 完整封面。
    public var cover: Bool
    public var tileCount: TileCount
    public var cropPolicy: CropPolicy
    /// 切片铺满可用高度（不套封面边距）。
    public var fitHeight: Bool
    public var padColor: PadColor
    /// 所有切片共用的上下边距 v（D-10），默认 0。`autoVerticalMargin` 打开时不使用。
    public var verticalMarginPx: Int
    public var alignment: Alignment
    /// 自动算上下边距，使它等于长卷两端的底色宽度（见 ``PanoramaLayout/equalizedVerticalMargin``），默认关闭。
    public var autoVerticalMargin: Bool
    public var extensions: ExtensionFields

    public init(
        enabled: Bool,
        cover: Bool = true,
        tileCount: TileCount = .auto,
        cropPolicy: CropPolicy = .never,
        fitHeight: Bool = true,
        padColor: PadColor = .canvasBackground,
        verticalMarginPx: Int = 0,
        alignment: Alignment = .center,
        autoVerticalMargin: Bool = false,
        extensions: ExtensionFields = [:]
    ) {
        self.enabled = enabled
        self.cover = cover
        self.tileCount = tileCount
        self.cropPolicy = cropPolicy
        self.fitHeight = fitHeight
        self.padColor = padColor
        self.verticalMarginPx = verticalMarginPx
        self.alignment = alignment
        self.autoVerticalMargin = autoVerticalMargin
        self.extensions = extensions
    }

    public static let disabled = PanoramaSettings(enabled: false)

    enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled, cover, tileCount, cropPolicy, fitHeight, padColor, verticalMarginPx, alignment, autoVerticalMargin
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        cover = try c.decodeIfPresent(Bool.self, forKey: .cover) ?? true
        tileCount = try c.decodeIfPresent(TileCount.self, forKey: .tileCount) ?? .auto
        cropPolicy = try c.decodeIfPresent(CropPolicy.self, forKey: .cropPolicy) ?? .never
        fitHeight = try c.decodeIfPresent(Bool.self, forKey: .fitHeight) ?? true
        padColor = try c.decodeIfPresent(PadColor.self, forKey: .padColor) ?? .canvasBackground
        verticalMarginPx = try c.decodeIfPresent(Int.self, forKey: .verticalMarginPx) ?? 0
        alignment = try c.decodeIfPresent(Alignment.self, forKey: .alignment) ?? .center
        autoVerticalMargin = try c.decodeIfPresent(Bool.self, forKey: .autoVerticalMargin) ?? false
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(cover, forKey: .cover)
        try c.encode(tileCount, forKey: .tileCount)
        try c.encode(cropPolicy, forKey: .cropPolicy)
        try c.encode(fitHeight, forKey: .fitHeight)
        try c.encode(padColor, forKey: .padColor)
        try c.encode(verticalMarginPx, forKey: .verticalMarginPx)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(autoVerticalMargin, forKey: .autoVerticalMargin)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }
}
