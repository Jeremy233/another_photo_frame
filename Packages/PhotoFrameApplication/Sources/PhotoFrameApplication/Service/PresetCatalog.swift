import Foundation
import PhotoFrameCore
import PhotoFrameStorage

/// 预设从哪里来。JSON：`{"kind": "builtIn"}`、`{"kind": "user"}`、`{"kind": "imported"}`、
/// `{"kind": "file", "path": "/…/Minimal.photoframe"}`。
public enum CatalogPresetOrigin: Hashable, Sendable, Codable {
    /// 应用内置（D-31、D-32）。
    case builtIn
    /// 预设库：用户保存的（D-81）。
    case user
    /// 预设库：导入的（D-81）。
    case imported
    /// 直接从 `.photoframe` 文件读取，没有放进预设库（CLI `--preset ./x.photoframe`）。
    case file(URL)

    init(_ origin: PresetOrigin) {
        switch origin {
        case .builtIn: self = .builtIn
        case .user: self = .user
        case .imported: self = .imported
        }
    }

    public var kind: String {
        switch self {
        case .builtIn: "builtIn"
        case .user: "user"
        case .imported: "imported"
        case .file: "file"
        }
    }

    enum CodingKeys: String, CodingKey { case kind, path }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "builtIn": self = .builtIn
        case "user": self = .user
        case "imported": self = .imported
        case "file": self = .file(URL(filePath: try c.decode(String.self, forKey: .path)))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "未知的预设来源 \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        if case .file(let url) = self { try c.encode(url.path, forKey: .path) }
    }
}

/// 一个可用的预设及其来源。
public struct CatalogPreset: Hashable, Sendable {
    public var preset: ExportPreset
    public var origin: CatalogPresetOrigin
    /// 读取时的非阻止性问题（例如从旧 schema 迁移、HDR 待实测、存储文件有不认识的字段）。
    public var warnings: [ApplicationWarning]

    public init(preset: ExportPreset, origin: CatalogPresetOrigin, warnings: [ApplicationWarning] = []) {
        self.preset = preset
        self.origin = origin
        self.warnings = warnings
    }

    init(_ entry: PresetEntry) {
        self.init(preset: entry.preset, origin: CatalogPresetOrigin(entry.origin), warnings: entry.warnings.map(ApplicationWarning.init))
    }
}

/// 怎样指定一个预设（CLI `--preset <id|名称|文件>`，D-76）。
public enum PresetReference: Hashable, Sendable, Codable {
    /// 预设库里的预设：UUID、完整名称（不区分大小写）或短名（`instagram-panorama`），由 `PresetLibrary.find(_:)` 匹配。
    case library(String)
    /// `.photoframe` 文件：只读取、不放进预设库。
    case file(URL)

    /// 解析命令行参数：以 `.photoframe` 结尾或含路径分隔符的是文件，其余交给预设库匹配。
    public init(argument: String, relativeTo base: URL = URL(filePath: FileManager.default.currentDirectoryPath)) {
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasSuffix(".\(PresetPackage.fileExtension)") || trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(filePath: expanded) : base.appending(path: expanded)
            self = .file(url.standardizedFileURL)
        } else {
            self = .library(trimmed)
        }
    }
}

/// 直接读取 `.photoframe` 文件（只读，不放进预设库）。导入检查与预设库相同（§8.3、D-26、D-33、D-34）。
enum PresetFileLoader {
    static func load(_ url: URL, platforms: PlatformCatalog?) throws(ApplicationError) -> CatalogPreset {
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
    /// 可以直接传给 `--preset` 的短名（`PresetLibrary.slug(for:)`），例如 `instagram-panorama`。
    public var slug: String
    public var platform: String?
    public var platformName: String?
    public var origin: CatalogPresetOrigin
    /// 内置预设和文件预设不能在库里修改。
    public var readOnly: Bool
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
        slug = PresetLibrary.slug(for: p.name)
        platform = p.platform
        platformName = p.platform.flatMap { catalog?.profile(id: $0)?.displayName }
        origin = entry.origin
        switch entry.origin {
        case .user, .imported: readOnly = false
        case .builtIn, .file: readOnly = true
        }
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

/// `listPresets` 的结果：内置、用户保存、导入（D-81、D-82 的顺序），加上读库时的警告（跳过的损坏文件等）。
public struct CatalogPresetList: Hashable, Sendable, Codable {
    public var presets: [CatalogPresetSummary]
    public var warnings: [ApplicationWarning]
}

/// `importPreset` 的结果。
public struct CatalogPresetImport: Hashable, Sendable, Codable {
    public var preset: CatalogPresetSummary
    /// 与已有预设 ID 冲突时实际采用的处理：`saveAsCopy`（默认，D-39、D-80）或 `replace`；没有冲突时为 nil。
    public var conflictResolution: String?
    public var warnings: [ApplicationWarning]
}

/// `updatePreset` 的结果（D-93）。
public struct CatalogPresetUpdate: Hashable, Sendable {
    public var preset: CatalogPresetSummary
    /// 修改后的完整预设。
    public var content: ExportPreset
    public var warnings: [ApplicationWarning]
}

// MARK: - 素材

/// `listAssets` 的结果。`AssetInfo` 不含文件路径（§11.4 `list_assets`）。
public struct CatalogAssetList: Hashable, Sendable, Codable {
    public var assets: [AssetInfo]
    public var warnings: [ApplicationWarning]
}

/// `importAsset` 的结果。
public struct CatalogAssetImport: Hashable, Sendable, Codable {
    public var asset: AssetInfo
    /// 库里内容相同的素材（D-88：仍然导入，只提示）。
    public var duplicateOf: [UUID]
    public var warnings: [ApplicationWarning]
}

/// 持久绑定（预设本地 + 用户默认，D-14 的后两级）。
public struct CatalogBindingList: Hashable, Sendable, Codable {
    public var bindings: [PersistedBinding]
    public var warnings: [ApplicationWarning]
}

/// 素材库作为队列和渲染器的素材来源：每次校验任务时取当前的绑定与素材，渲染时给出内容文件。
extension LocalLibrary: AssetProvider {
    public func slotResolver() -> SlotResolver { makeSlotResolver().resolver }
    public func fileURL(for asset: AssetRecord) -> URL? { assets.contentURL(for: asset) }
}

extension ApplicationError {
    init(_ error: LibraryError) {
        self.init(code: error.code, message: error.message, hint: error.hint)
    }
}

extension ApplicationWarning {
    init(_ warning: LibraryWarning) {
        self.init(code: warning.code, message: "\(warning.item)：\(warning.message)")
    }
}
