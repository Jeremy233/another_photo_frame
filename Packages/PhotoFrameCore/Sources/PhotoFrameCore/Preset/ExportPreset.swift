import Foundation

/// 一个可分享的导出预设（§8.1、§11.1）。纯数据，不含本地路径或私人素材。
///
/// 读写 JSON 请用 ``PresetSchema``：它负责版本检查、迁移和不认识字段的登记。
public struct ExportPreset: Hashable, Sendable, Codable, Identifiable {
    public var schemaVersion: Int
    public var presetId: UUID
    public var name: String
    /// 目标平台 ID（见 ``PlatformProfile/platformId``），用于轮播上限和 HDR 格式；nil 表示通用画布。
    public var platform: String?
    public var canvas: CanvasSettings
    public var panorama: PanoramaSettings
    public var layers: [OverlayLayer]
    public var assetSlots: [AssetSlot]
    public var output: OutputSettings
    public var extensions: ExtensionFields

    public var id: UUID { presetId }

    public init(
        schemaVersion: Int = PresetSchema.currentVersion,
        presetId: UUID = UUID(),
        name: String,
        platform: String? = nil,
        canvas: CanvasSettings,
        panorama: PanoramaSettings = .disabled,
        layers: [OverlayLayer] = [],
        assetSlots: [AssetSlot] = [],
        output: OutputSettings = OutputSettings(),
        extensions: ExtensionFields = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.presetId = presetId
        self.name = name
        self.platform = platform
        self.canvas = canvas
        self.panorama = panorama
        self.layers = layers
        self.assetSlots = assetSlots
        self.output = output
        self.extensions = extensions
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, presetId, name, platform, canvas, panorama, layers, assetSlots, output
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        presetId = try c.decode(UUID.self, forKey: .presetId)
        name = try c.decode(String.self, forKey: .name)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        canvas = try c.decode(CanvasSettings.self, forKey: .canvas)
        panorama = try c.decodeIfPresent(PanoramaSettings.self, forKey: .panorama) ?? .disabled
        layers = try c.decodeIfPresent([OverlayLayer].self, forKey: .layers) ?? []
        assetSlots = try c.decodeIfPresent([AssetSlot].self, forKey: .assetSlots) ?? []
        output = try c.decodeIfPresent(OutputSettings.self, forKey: .output) ?? OutputSettings()
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(presetId, forKey: .presetId)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(platform, forKey: .platform)
        try c.encode(canvas, forKey: .canvas)
        try c.encode(panorama, forKey: .panorama)
        try c.encode(layers, forKey: .layers)
        try c.encode(assetSlots, forKey: .assetSlots)
        try c.encode(output, forKey: .output)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }

    /// 被启用图层引用的素材槽 ID。
    public var referencedSlotIds: Set<String> {
        Set(layers.filter { $0.enabled && $0.type.usesAssetSlot }.compactMap(\.slotId))
    }
}
