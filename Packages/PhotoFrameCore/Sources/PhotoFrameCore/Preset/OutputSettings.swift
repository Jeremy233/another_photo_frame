/// 输出设置（§6.8、§8.1 `output`）。
///
/// 这里的色彩字段只描述**输出意图**（写出的文件是什么色彩空间、SDR 还是 HDR），
/// 不涉及内部工作空间（D-03）。
public struct OutputSettings: Hashable, Sendable, Codable {
    /// V1 只输出 JPEG 和 PNG（D-36）。
    public enum Format: String, Hashable, Sendable, Codable, CaseIterable {
        case jpeg, png
    }

    public enum DynamicRange: String, Hashable, Sendable, Codable, CaseIterable {
        /// 强制 SDR。
        case sdr
        /// 强制 HDR 输出（D-05）；具体编码（如 gain map JPEG）由平台配置决定（D-17）。源图不是 HDR 时按 SDR 输出并警告。
        case hdr
        /// 跟随源图（D-125）：源图是 HDR 且输出格式支持 HDR（JPEG gain map）时输出 HDR，否则安静地输出 SDR。
        case auto
    }

    /// 输出元数据开关（D-06：默认全部不写出）。
    public struct Metadata: Hashable, Sendable, Codable {
        public var keepShootingInfo: Bool
        /// 打开时 UI 须显示隐私警告。
        public var keepGps: Bool
        /// 保留作者和版权（TIFF Artist / Copyright，IPTC 与 XMP 中对应的作者、版权字段），与拍摄参数分开控制。
        /// JSON 字段 `keepAuthorAndCopyright`；旧预设没有这个字段时为 false。
        public var keepAuthorAndCopyright: Bool
        public var extensions: ExtensionFields

        public init(
            keepShootingInfo: Bool = false, keepGps: Bool = false, keepAuthorAndCopyright: Bool = false,
            extensions: ExtensionFields = [:]
        ) {
            self.keepShootingInfo = keepShootingInfo
            self.keepGps = keepGps
            self.keepAuthorAndCopyright = keepAuthorAndCopyright
            self.extensions = extensions
        }

        enum CodingKeys: String, CodingKey, CaseIterable { case keepShootingInfo, keepGps, keepAuthorAndCopyright }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keepShootingInfo = try c.decodeIfPresent(Bool.self, forKey: .keepShootingInfo) ?? false
            keepGps = try c.decodeIfPresent(Bool.self, forKey: .keepGps) ?? false
            keepAuthorAndCopyright = try c.decodeIfPresent(Bool.self, forKey: .keepAuthorAndCopyright) ?? false
            extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(keepShootingInfo, forKey: .keepShootingInfo)
            try c.encode(keepGps, forKey: .keepGps)
            try c.encode(keepAuthorAndCopyright, forKey: .keepAuthorAndCopyright)
            try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
        }
    }

    public var format: Format
    /// 1…100，默认 100（D-06）。PNG 忽略。
    public var quality: Int
    /// 输出文件的色彩空间。目前只支持 `sRGB`。
    public var colorSpace: String
    public var dynamicRange: DynamicRange
    public var metadata: Metadata
    public var extensions: ExtensionFields

    public init(
        format: Format = .jpeg,
        quality: Int = 100,
        colorSpace: String = "sRGB",
        dynamicRange: DynamicRange = .auto,
        metadata: Metadata = Metadata(),
        extensions: ExtensionFields = [:]
    ) {
        self.format = format
        self.quality = quality
        self.colorSpace = colorSpace
        self.dynamicRange = dynamicRange
        self.metadata = metadata
        self.extensions = extensions
    }

    /// 实际写出的动态范围（只有 `.sdr` 或 `.hdr`）。`sourceHasHDR`：源图是 HDR，且有超过 SDR 白的内容。
    /// 强制 HDR 也只在源图是 HDR、格式是 JPEG 时写 HDR（PNG + 强制 HDR 是预设错误，渲染前就会拒绝）。
    public func effectiveDynamicRange(sourceHasHDR: Bool) -> DynamicRange {
        dynamicRange != .sdr && format == .jpeg && sourceHasHDR ? .hdr : .sdr
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case format, quality, colorSpace, dynamicRange, metadata
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Format.self, forKey: .format) ?? .jpeg
        quality = try c.decodeIfPresent(Int.self, forKey: .quality) ?? 100
        colorSpace = try c.decodeIfPresent(String.self, forKey: .colorSpace) ?? "sRGB"
        // 缺字段的旧预设保持原来的含义（SDR）；新建预设的默认值是 auto（D-125）。
        dynamicRange = try c.decodeIfPresent(DynamicRange.self, forKey: .dynamicRange) ?? .sdr
        metadata = try c.decodeIfPresent(Metadata.self, forKey: .metadata) ?? Metadata()
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(quality, forKey: .quality)
        try c.encode(colorSpace, forKey: .colorSpace)
        try c.encode(dynamicRange, forKey: .dynamicRange)
        try c.encode(metadata, forKey: .metadata)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }
}
