import Foundation
import PhotoFrameCore
import PhotoFrameStorage

/// 预设从哪里来。JSON：`{"kind": "builtIn"}`、`{"kind": "file", "path": "/…/Minimal.photoframe"}`、`{"kind": "library"}`。
public enum CatalogPresetOrigin: Hashable, Sendable, Codable {
    /// 应用内置（`BuiltInPresets`）。
    case builtIn
    /// 直接从 `.photoframe` 文件读取，没有安装进预设库（CLI `--preset ./x.photoframe`）。
    case file(URL)
    /// 用户预设库（以后由 PhotoFrameStorage 的预设库提供）。
    case library

    enum CodingKeys: String, CodingKey { case kind, path }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "builtIn": self = .builtIn
        case "library": self = .library
        case "file": self = .file(URL(filePath: try c.decode(String.self, forKey: .path)))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "未知的预设来源 \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtIn: try c.encode("builtIn", forKey: .kind)
        case .library: try c.encode("library", forKey: .kind)
        case .file(let url):
            try c.encode("file", forKey: .kind)
            try c.encode(url.path, forKey: .path)
        }
    }
}

/// 一个可用的预设及其来源。
public struct CatalogPreset: Hashable, Sendable {
    public var preset: ExportPreset
    public var origin: CatalogPresetOrigin
    /// 读取时的非阻止性问题（例如从旧 schema 迁移、HDR 待实测）。
    public var warnings: [ApplicationWarning]

    public init(preset: ExportPreset, origin: CatalogPresetOrigin, warnings: [ApplicationWarning] = []) {
        self.preset = preset
        self.origin = origin
        self.warnings = warnings
    }
}

/// 预设来源。现阶段只有内置预设；用户预设库以后实现这个协议接进来（§8、§11.2 `listPresets`）。
public protocol PresetProvider: Sendable {
    func presets() async throws(ApplicationError) -> [CatalogPreset]
}

/// 内置预设（D-31、D-32），画布尺寸取自平台配置。
public struct BuiltInPresetProvider: PresetProvider {
    public var catalog: PlatformCatalog

    public init(catalog: PlatformCatalog) {
        self.catalog = catalog
    }

    public func presets() async throws(ApplicationError) -> [CatalogPreset] {
        BuiltInPresets.all(catalog: catalog).map { CatalogPreset(preset: $0, origin: .builtIn) }
    }
}

/// 按顺序合并多个来源；ID 重复时保留先出现的一个。
public struct CompositePresetProvider: PresetProvider {
    public var providers: [any PresetProvider]

    public init(_ providers: [any PresetProvider]) {
        self.providers = providers
    }

    public func presets() async throws(ApplicationError) -> [CatalogPreset] {
        var seen: Set<UUID> = []
        var all: [CatalogPreset] = []
        for provider in providers {
            for entry in try await provider.presets() where seen.insert(entry.preset.presetId).inserted {
                all.append(entry)
            }
        }
        return all
    }
}

/// 怎样指定一个预设：ID、名称或 `.photoframe` 文件（CLI `--preset <id|名称|文件>`）。
public enum PresetReference: Hashable, Sendable, Codable {
    case id(UUID)
    /// 名称，不区分大小写；空格、下划线与连字符等价（`instagram-panorama` = `Instagram Panorama`）。
    case name(String)
    case file(URL)

    /// 解析命令行参数：以 `.photoframe` 结尾或含路径分隔符的是文件；能解析成 UUID 的是 ID；其余按名称。
    public init(argument: String, relativeTo base: URL = URL(filePath: FileManager.default.currentDirectoryPath)) {
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasSuffix(".\(PresetPackage.fileExtension)") || trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(filePath: expanded) : base.appending(path: expanded)
            self = .file(url.standardizedFileURL)
        } else if let uuid = UUID(uuidString: trimmed) {
            self = .id(uuid)
        } else {
            self = .name(trimmed)
        }
    }

    /// 名称比较用的形式：小写，空白、下划线、连字符折叠成一个 `-`。
    public static func normalizedName(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in name.lowercased() {
            if ch.isWhitespace || ch == "_" || ch == "-" {
                pendingDash = !out.isEmpty
            } else {
                if pendingDash { out.append("-") }
                pendingDash = false
                out.append(ch)
            }
        }
        return out
    }

    /// 在已知预设中查找（不处理 `.file`）。
    public func match(in entries: [CatalogPreset]) throws(ApplicationError) -> CatalogPreset {
        switch self {
        case .id(let id):
            guard let hit = entries.first(where: { $0.preset.presetId == id }) else { throw .presetNotFound(id.uuidString) }
            return hit
        case .name(let name):
            let key = Self.normalizedName(name)
            let hits = entries.filter { Self.normalizedName($0.preset.name) == key }
            guard let first = hits.first else { throw .presetNotFound(name) }
            guard hits.count == 1 else { throw .presetAmbiguous(name, hits.map(\.preset.presetId.uuidString)) }
            return first
        case .file(let url):
            throw .presetNotFound(url.path)
        }
    }
}

/// 直接读取 `.photoframe` 文件（只读，不安装）。导入检查与预设库相同（§8.3、D-26、D-33、D-34）。
public enum PresetFileLoader {
    public static func load(_ url: URL, platforms: PlatformCatalog?) throws(ApplicationError) -> CatalogPreset {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw .presetFileNotFound(url.path)
        }
        do {
            let data = try PresetPackage.readFile(at: url)
            let imported = try PresetPackage.importPreset(data, options: PresetImportOptions(platforms: platforms))
            return CatalogPreset(
                preset: imported.preset, origin: .file(url),
                warnings: imported.warnings.map { ApplicationWarning(code: $0.code, message: "\($0.path)：\($0.message)") })
        } catch {
            throw ApplicationError(code: error.code, message: "\(url.lastPathComponent)：\(error.message)", hint: error.hint)
        }
    }
}

/// `listPresets` 返回的摘要（§11.2 `PresetSummary`），可直接 JSON 输出给 CLI / MCP。
public struct CatalogPresetSummary: Hashable, Sendable, Codable {
    public struct Panorama: Hashable, Sendable, Codable {
        public var cover: Bool
        /// 固定张数；nil 为自动（D-11）。
        public var slideCount: Int?
        public var verticalMarginPx: Int
    }

    public var presetId: UUID
    public var name: String
    /// 可以直接传给 `--preset` 的短名称，例如 `instagram-panorama`。
    public var slug: String
    public var platform: String?
    public var platformName: String?
    public var origin: CatalogPresetOrigin
    public var canvas: PixelSize
    public var mode: CanvasSettings.Mode
    public var background: String
    public var minMarginPx: Int
    /// 全景关闭时为 nil。
    public var panorama: Panorama?
    public var format: OutputSettings.Format
    public var quality: Int
    public var dynamicRange: OutputSettings.DynamicRange
    public var layerCount: Int
    public var slotIds: [String]

    public init(_ entry: CatalogPreset, catalog: PlatformCatalog?) {
        let p = entry.preset
        presetId = p.presetId
        name = p.name
        slug = PresetReference.normalizedName(p.name)
        platform = p.platform
        platformName = p.platform.flatMap { catalog?.profile(id: $0)?.displayName }
        origin = entry.origin
        canvas = p.canvas.size
        mode = p.canvas.mode
        background = p.canvas.background.hex
        minMarginPx = p.canvas.minMarginPx
        if p.panorama.enabled {
            let fixed: Int? = if case .fixed(let n) = p.panorama.tileCount { n } else { nil }
            panorama = Panorama(cover: p.panorama.cover, slideCount: fixed, verticalMarginPx: p.panorama.verticalMarginPx)
        }
        format = p.output.format
        quality = p.output.quality
        dynamicRange = p.output.dynamicRange
        layerCount = p.layers.count
        slotIds = p.assetSlots.map(\.slotId)
    }
}
