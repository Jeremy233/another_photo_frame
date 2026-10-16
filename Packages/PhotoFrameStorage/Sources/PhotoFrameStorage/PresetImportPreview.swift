import PhotoFrameCore

/// presetId 冲突时的处理方式（D-39）。实际执行由 Application 层负责。
public enum PresetIdConflictResolution: String, Hashable, Sendable, Codable {
    /// 生成新 UUID，另存为副本（默认）。
    case saveAsCopy
    /// 替换已有预设。
    case replace
}

/// 导入前预览（§8.3）：尺寸、图层、slots、目标格式、schema 版本及可能不可用的能力。
///
/// 可直接序列化给 CLI `--json` 和 MCP 使用。
public struct PresetImportPreview: Hashable, Sendable, Codable {
    /// 文件里写的 schemaVersion；无法读取时为 nil。
    public var schemaVersion: Int?
    public var currentSchemaVersion: Int
    public var presetId: String?
    public var name: String?
    /// 文件来自更新的 PhotoFrame，需要升级后再导入（D-15）。
    public var requiresNewerApp: Bool = false
    /// 预设能解码时的内容摘要。
    public var summary: PresetSummary?
    /// 所有问题，包括不可用的能力（例如 HDR 待实测、平台不支持的格式）。
    public var issues: [PresetIssue] = []
    /// presetId 与已安装的预设冲突时，可选的处理方式，第一项是默认（D-39）。没有冲突时为空。
    public var idConflictResolutions: [PresetIdConflictResolution] = []

    public init(currentSchemaVersion: Int) {
        self.currentSchemaVersion = currentSchemaVersion
    }

    public var canImport: Bool { summary != nil && issues.errors.isEmpty }
}

public struct PresetSummary: Hashable, Sendable, Codable {
    public struct Layer: Hashable, Sendable, Codable {
        public var layerId: String
        public var type: OverlayLayer.LayerType
        public var enabled: Bool
        public var visibility: OverlayVisibility
        public var slotId: String?
    }

    public struct Slot: Hashable, Sendable, Codable {
        public var slotId: String
        public var kind: AssetSlot.Kind
        public var required: Bool
        public var label: String?
    }

    public struct Panorama: Hashable, Sendable, Codable {
        public var cover: Bool
        /// nil 表示自动张数。
        public var tileCount: Int?
        public var verticalMarginPx: Int
    }

    public var canvas: PixelSize
    public var mode: CanvasSettings.Mode
    public var minMarginPx: Int
    public var background: String
    public var platform: String?
    public var platformName: String?
    /// 未启用全景时为 nil。
    public var panorama: Panorama?
    public var layers: [Layer]
    public var slots: [Slot]
    public var format: OutputSettings.Format
    public var quality: Int
    public var dynamicRange: OutputSettings.DynamicRange
    public var keepShootingInfo: Bool
    public var keepGps: Bool
    public var keepAuthorAndCopyright: Bool
    /// 各层 `x-` 扩展字段的总数。
    public var extensionFieldCount: Int

    init(_ p: ExportPreset, platformName: String?) {
        canvas = p.canvas.size
        mode = p.canvas.mode
        minMarginPx = p.canvas.minMarginPx
        background = p.canvas.background.hex
        platform = p.platform
        self.platformName = platformName
        if p.panorama.enabled {
            let count: Int? = if case .fixed(let n) = p.panorama.tileCount { n } else { nil }
            panorama = Panorama(cover: p.panorama.cover, tileCount: count, verticalMarginPx: p.panorama.verticalMarginPx)
        }
        layers = p.layers.map { Layer(layerId: $0.layerId, type: $0.type, enabled: $0.enabled, visibility: $0.visibility, slotId: $0.slotId) }
        slots = p.assetSlots.map { Slot(slotId: $0.slotId, kind: $0.kind, required: $0.required, label: $0.label) }
        format = p.output.format
        quality = p.output.quality
        dynamicRange = p.output.dynamicRange
        keepShootingInfo = p.output.metadata.keepShootingInfo
        keepGps = p.output.metadata.keepGps
        keepAuthorAndCopyright = p.output.metadata.keepAuthorAndCopyright
        extensionFieldCount = Self.countExtensions(p)
    }

    private static func countExtensions(_ p: ExportPreset) -> Int {
        func x(_ e: ExtensionFields) -> Int { e.keys.filter { $0.hasPrefix(extensionFieldPrefix) }.count }
        var n = x(p.extensions) + x(p.canvas.extensions) + x(p.canvas.background.extensions)
            + x(p.panorama.extensions) + x(p.output.extensions) + x(p.output.metadata.extensions)
        n += p.canvas.crop.map { x($0.extensions) } ?? 0
        for l in p.layers { n += x(l.extensions) + (l.text.map { x($0.extensions) + x($0.color.extensions) } ?? 0) }
        for s in p.assetSlots { n += x(s.extensions) }
        return n
    }
}
