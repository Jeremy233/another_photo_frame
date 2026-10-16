import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameStorage

// `--json` 的输出格式。这里的类型是 CLI 的公开契约（docs/CLI.md），与内部模型分开定义：
// 内部类型改名或加字段不会意外改变脚本看到的 JSON。改动格式时递增 `formatVersion`。

enum JSONOutput {
    static let formatVersion = 1

    static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 所有 JSON 输出的外层：`formatVersion`、`command`、`ok`、`exitCode`，加上各命令自己的字段。
struct Envelope<Body: Encodable>: Encodable {
    var command: String
    var exitCode: PhotoFrameExitCode
    var body: Body?
    var error: ErrorJSON?

    enum CodingKeys: String, CodingKey { case formatVersion, command, ok, exitCode, error }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(JSONOutput.formatVersion, forKey: .formatVersion)
        try c.encode(command, forKey: .command)
        try c.encode(exitCode == .success, forKey: .ok)
        try c.encode(exitCode.rawValue, forKey: .exitCode)
        try c.encodeIfPresent(error, forKey: .error)
        try body?.encode(to: encoder)
    }
}

struct NoBody: Encodable {}

struct ErrorJSON: Encodable, Equatable {
    var code: String
    var message: String
    var hint: String?

    init(_ error: ApplicationError) {
        code = error.code
        message = error.message
        hint = error.hint
    }
}

struct WarningJSON: Encodable, Equatable {
    var code: String
    var message: String

    init(_ warning: ApplicationWarning) {
        code = warning.code
        message = warning.message
    }
}

struct SizeJSON: Encodable, Equatable {
    var width: Int
    var height: Int

    init(_ size: PixelSize) {
        width = size.width
        height = size.height
    }
}

struct PresetRefJSON: Encodable {
    var presetId: String
    var name: String
}

// MARK: - export

struct ExportOutputJSON: Encodable {
    /// `cover` 或 `slide`。
    var role: String
    /// 轮播位置：0 = 封面，切片 k 为 k + 1（D-27）。
    var position: Int
    var path: String
    var fileName: String
    var width: Int
    var height: Int
    var colorProfile: String?
    var bytes: Int64
    var sha256: String?

    init(_ item: OutputManifestItem) {
        role = item.role.kindName
        position = item.role.carouselPosition
        path = item.fileURL.path
        fileName = item.fileName
        width = item.pixelSize.width
        height = item.pixelSize.height
        colorProfile = item.colorProfile
        bytes = item.fileSizeBytes
        sha256 = item.sha256
    }
}

struct ExportJobJSON: Encodable {
    var jobId: String
    var source: String
    var preset: PresetRefJSON
    /// `completed`、`failed`、`canceled`。
    var status: String
    /// 作品目录；没有成功时为 null。
    var directory: String?
    var outputs: [ExportOutputJSON]
    var warnings: [WarningJSON]
    var error: ErrorJSON?
    var durationSeconds: Double?

    init(_ record: JobRecord) {
        jobId = record.jobId.description
        source = record.spec.source.fileURL.path
        preset = PresetRefJSON(presetId: record.spec.preset.presetId.uuidString, name: record.spec.preset.name)
        status = record.status.rawValue
        let manifest = record.status == .completed ? record.manifest : nil
        directory = manifest?.directory.path
        outputs = manifest?.items.map(ExportOutputJSON.init) ?? []
        warnings = record.currentAttempt.warnings.map(WarningJSON.init)
        error = record.error.map(ErrorJSON.init)
        durationSeconds = manifest.map { ($0.duration * 1000).rounded() / 1000 }
    }
}

struct ExportResultJSON: Encodable {
    var dryRun = false
    var jobs: [ExportJobJSON]
}

struct PlannedFileJSON: Encodable {
    var role: String
    var position: Int
    var fileName: String
    var width: Int
    var height: Int

    init(_ file: ValidationItem.PlannedFile) {
        role = file.role.kindName
        position = file.role.carouselPosition
        fileName = file.fileName
        width = file.pixelSize.width
        height = file.pixelSize.height
    }
}

struct DryRunJobJSON: Encodable {
    var source: String
    var preset: PresetRefJSON
    var directory: String
    var outputs: [PlannedFileJSON]
    var warnings: [WarningJSON]
    var errors: [ErrorJSON]

    init(_ item: ValidationItem) {
        source = item.sourceURL.path
        preset = PresetRefJSON(presetId: item.presetId.uuidString, name: item.presetName)
        directory = item.directory.path
        outputs = item.outputs.map(PlannedFileJSON.init)
        warnings = item.warnings.map(WarningJSON.init)
        errors = item.errors.map(ErrorJSON.init)
    }
}

struct DryRunResultJSON: Encodable {
    var dryRun = true
    var valid: Bool
    var jobs: [DryRunJobJSON]
}

// MARK: - preset list

struct PresetJSON: Encodable {
    var presetId: String
    var name: String
    var slug: String
    var platform: String?
    var platformName: String?
    /// `builtIn`、`user`、`imported`、`file`。
    var origin: String
    var readOnly: Bool
    var canvas: SizeJSON
    var mode: String
    var background: String
    var minMarginPx: Int
    var panorama: CatalogPresetSummary.Panorama?
    var format: String
    var quality: Int
    var dynamicRange: String
    var layerCount: Int
    var slotIds: [String]

    init(_ p: CatalogPresetSummary) {
        presetId = p.presetId.uuidString
        name = p.name
        slug = p.slug
        platform = p.platform
        platformName = p.platformName
        origin = p.origin.kind
        readOnly = p.readOnly
        canvas = SizeJSON(p.canvas)
        mode = p.mode.rawValue
        background = p.background
        minMarginPx = p.minMarginPx
        panorama = p.panorama
        format = p.format.rawValue
        quality = p.quality
        dynamicRange = p.dynamicRange.rawValue
        layerCount = p.layerCount
        slotIds = p.slotIds
    }
}

struct PresetListJSON: Encodable {
    var presets: [PresetJSON]
    var warnings: [WarningJSON]
}

/// `preset import` / `duplicate` / `rename` 的结果。
struct PresetResultJSON: Encodable {
    var preset: PresetJSON
    /// 只有 `preset import` 有：ID 冲突时的处理，`saveAsCopy` 或 `replace`。
    var conflictResolution: String?
    var warnings: [WarningJSON] = []
}

struct PresetRefResultJSON: Encodable {
    var preset: PresetRefJSON
    /// `preset export` 写出的文件。
    var path: String?
}

// MARK: - asset

struct AssetJSON: Encodable {
    var assetId: String
    var name: String
    /// `signature`、`watermark`、`camera-badge`。
    var category: String
    var format: String
    var width: Int
    var height: Int
    var bytes: Int
    var sha256: String
    var importedAt: String
    var importWarnings: [String]

    init(_ a: AssetInfo) {
        assetId = a.assetId.uuidString
        name = a.displayName
        category = AssetCategoryArgument(a.category).rawValue
        format = a.format.rawValue
        width = a.pixelSize.width
        height = a.pixelSize.height
        bytes = a.byteCount
        sha256 = a.sha256
        importedAt = ISO8601DateFormatter().string(from: a.importedAt)
        importWarnings = a.importWarnings
    }
}

struct AssetListJSON: Encodable {
    var assets: [AssetJSON]
    var warnings: [WarningJSON]
}

struct AssetResultJSON: Encodable {
    var asset: AssetJSON
    /// 只有 `asset import` 有：库里内容相同的素材（D-88）。
    var duplicateOf: [String]?
    var warnings: [WarningJSON] = []
}

struct BindingJSON: Encodable {
    /// `preset`（预设本地绑定）或 `default`（用户默认绑定）。
    var scope: String
    var presetId: String?
    var slotId: String
    var assetId: String

    init(_ b: PersistedBinding) {
        scope = b.scope == .presetLocal ? "preset" : "default"
        presetId = b.presetId?.uuidString
        slotId = b.slotId
        assetId = b.assetId.uuidString
    }
}

struct BindingListJSON: Encodable {
    var bindings: [BindingJSON]
    var warnings: [WarningJSON]
}

struct AssetDeleteJSON: Encodable {
    var assetId: String
    /// 仍指向这个素材的绑定（保留，D-83）。
    var bindings: [BindingJSON]
}

// MARK: - image inspect

struct InspectJSON: Encodable {
    struct Image: Encodable {
        var path: String
        var fileSizeBytes: Int64?
        var format: String
        var pixelSize: SizeJSON
        var orientation: Int
        var displaySize: SizeJSON
        var bitDepth: Int
        var isFloat: Bool
        var hasAlpha: Bool
        var colorProfile: SourceInspection.ColorProfile
        var hdr: SourceInspection.HDR
        var metadata: [String: String]
        var hasGPS: Bool
        var hasAuthorOrCopyright: Bool
        var warnings: [WarningJSON]
    }

    var image: Image

    init(_ s: SourceInspection) {
        image = Image(
            path: s.fileURL.path, fileSizeBytes: s.fileSizeBytes, format: s.format, pixelSize: SizeJSON(s.pixelSize),
            orientation: s.orientation, displaySize: SizeJSON(s.displaySize), bitDepth: s.bitDepth, isFloat: s.isFloat,
            hasAlpha: s.hasAlpha, colorProfile: s.colorProfile, hdr: s.hdr, metadata: s.metadata, hasGPS: s.hasGPS,
            hasAuthorOrCopyright: s.hasAuthorOrCopyright, warnings: s.warnings.map(WarningJSON.init))
    }
}

// MARK: - preview

struct PreviewFileJSON: Encodable {
    var role: String
    var position: Int
    var path: String
    var width: Int
    var height: Int
    var exportWidth: Int
    var exportHeight: Int
}

struct PreviewJSON: Encodable {
    var source: String
    var preset: PresetRefJSON
    var files: [PreviewFileJSON]
    /// 导出会写出的全部轮播位置。
    var positions: [Int]
    var warnings: [WarningJSON]
}

extension JobOutputRole {
    var kindName: String {
        switch self {
        case .cover: "cover"
        case .slide: "slide"
        }
    }
}
