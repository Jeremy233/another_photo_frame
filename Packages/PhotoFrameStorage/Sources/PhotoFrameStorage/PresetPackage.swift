import Foundation
import PhotoFrameCore

/// `.photoframe` 读写错误。`code` 是稳定的机器可读错误码。
public enum PresetPackageError: Error, Hashable, Sendable {
    case archive(ArchiveError)
    case missingManifest
    case schema(PresetError)
    /// 预设内容有错误（重复 ID、悬空引用、不认识的字段等）。
    case invalidPreset([PresetIssue])
    /// 导出时发现疑似本地路径等私人信息（§8.2、§17）。值是 JSON 字段路径。
    case privateData([String])
    case io(String)

    public var code: String {
        switch self {
        case .archive(let e): e.code
        case .missingManifest: "package.missing_manifest"
        case .schema(let e): e.code
        case .invalidPreset: "package.invalid_preset"
        case .privateData: "package.private_data"
        case .io: "package.io"
        }
    }

    public var message: String {
        switch self {
        case .archive(let e): e.message
        case .missingManifest: "压缩包根目录缺少 manifest.json"
        case .schema(let e): e.message
        case .invalidPreset(let issues): "预设内容无效：" + issues.errors.map(\.message).joined(separator: "；")
        case .privateData(let paths): "预设中疑似包含本地路径，已拒绝导出：" + paths.joined(separator: ", ")
        case .io(let d): "读写文件失败：\(d)"
        }
    }

    public var hint: String? {
        switch self {
        case .schema(let e): e.hint
        case .privateData: "请删除这些字段中的本地路径；素材应通过素材槽绑定，而不是写进预设"
        default: nil
        }
    }
}

/// 遇到不认识（且不以 `x-` 开头）的字段时怎么办。
public enum UnknownFieldPolicy: Sendable, Hashable {
    /// 拒绝导入（默认）：同一 schema 版本下出现未定义字段说明文件被手改或损坏。
    case reject
    /// 保留字段并给出警告。
    case keep
}

public struct PresetImportOptions: Sendable {
    public var limits: ArchiveLimits
    public var unknownFields: UnknownFieldPolicy
    /// 已安装的预设 ID，用于提示 ID 冲突。
    public var existingPresetIds: Set<UUID>
    /// 用于检查目标平台能力；nil 时跳过平台检查。
    public var platforms: PlatformCatalog?

    public init(
        limits: ArchiveLimits = .presetPackage,
        unknownFields: UnknownFieldPolicy = .reject,
        existingPresetIds: Set<UUID> = [],
        platforms: PlatformCatalog? = nil
    ) {
        self.limits = limits
        self.unknownFields = unknownFields
        self.existingPresetIds = existingPresetIds
        self.platforms = platforms
    }
}

/// 导入成功的结果。
public struct ImportedPreset: Sendable, Hashable {
    public var preset: ExportPreset
    public var originalSchemaVersion: Int
    /// 不阻止导入的警告（已迁移、ID 冲突、HDR 待实测等）。
    public var warnings: [PresetIssue]
    /// 与已安装预设 ID 冲突时的可选处理方式，第一项是默认（D-39）。
    public var idConflictResolutions: [PresetIdConflictResolution]
}

/// `.photoframe` 预设包：ZIP 容器，根目录只有 `manifest.json`（D-07）。
public enum PresetPackage {
    public static let manifestName = "manifest.json"
    public static let fileExtension = "photoframe"

    // MARK: 导出

    /// 生成 `.photoframe` 字节。会先校验预设，并拒绝疑似包含本地路径的预设。
    public static func export(_ preset: ExportPreset) throws(PresetPackageError) -> Data {
        let issues = preset.validate()
        guard issues.errors.isEmpty else { throw .invalidPreset(issues) }
        let manifest: Data
        do {
            manifest = try PresetSchema.encode(preset)
        } catch {
            throw .io(String(describing: error))
        }
        let leaks = privatePathFields(in: manifest)
        guard leaks.isEmpty else { throw .privateData(leaks) }
        var zip = ZipWriter()
        zip.add(name: manifestName, data: manifest)
        return zip.finish()
    }

    /// 原子写入文件。
    public static func export(_ preset: ExportPreset, to url: URL) throws(PresetPackageError) {
        let data = try export(preset)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    // MARK: 导入

    /// 导入前预览（§8.3）。只有压缩包本身不安全或不完整时才抛错；预设内容的问题列在 `issues` 里。
    public static func preview(_ data: Data, options: PresetImportOptions = .init()) throws(PresetPackageError) -> PresetImportPreview {
        try analyze(data, options: options).preview
    }

    /// 读取并导入。任何 error 级问题都会抛出。
    public static func importPreset(_ data: Data, options: PresetImportOptions = .init()) throws(PresetPackageError) -> ImportedPreset {
        try imported(analyze(data, options: options))
    }

    /// 对一份 manifest（不是 ZIP）做与导入完全相同的检查（D-93：逐项修改后的预设必须能通过导入）。
    /// 任何 error 级问题都会抛出。
    public static func validateManifest(_ manifestData: Data, options: PresetImportOptions = .init()) throws(PresetPackageError) -> ImportedPreset {
        guard manifestData.count <= options.limits.maxEntryUncompressedBytes else {
            throw .archive(.entryTooLarge(name: manifestName, bytes: manifestData.count, limit: options.limits.maxEntryUncompressedBytes))
        }
        return try imported(analyzeManifest(manifestData, issues: [], options: options))
    }

    /// 有 error 级问题时抛出，否则返回导入结果。
    private static func imported(_ result: Analysis) throws(PresetPackageError) -> ImportedPreset {
        if let schemaError = result.schemaError { throw .schema(schemaError) }
        let errors = result.preview.issues.errors
        guard errors.isEmpty, let decoded = result.decoded else { throw .invalidPreset(result.preview.issues) }
        return ImportedPreset(
            preset: decoded.preset,
            originalSchemaVersion: decoded.originalSchemaVersion,
            warnings: result.preview.issues.warnings,
            idConflictResolutions: result.preview.idConflictResolutions)
    }

    /// 从文件读取。先检查文件大小，避免把超大文件读进内存。
    public static func readFile(at url: URL, limits: ArchiveLimits = .presetPackage) throws(PresetPackageError) -> Data {
        do {
            // 符号链接按它指向的文件计算大小（链接自己的 `.fileSizeKey` 只是链接本身的大小）。
            let size = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= limits.maxArchiveBytes else {
                throw PresetPackageError.archive(.archiveTooLarge(bytes: size, limit: limits.maxArchiveBytes))
            }
            return try Data(contentsOf: url)
        } catch let e as PresetPackageError {
            throw e
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    // MARK: - 内部

    struct Analysis {
        var preview: PresetImportPreview
        var decoded: DecodedPreset?
        var schemaError: PresetError?
    }

    static func analyze(_ data: Data, options: PresetImportOptions) throws(PresetPackageError) -> Analysis {
        let zip: ZipReader
        let manifestData: Data
        var issues: [PresetIssue] = []
        do {
            zip = try ZipReader(data: data, limits: options.limits)
            guard let manifestEntry = zip.entry(named: manifestName) else { throw PresetPackageError.missingManifest }
            manifestData = try zip.contents(of: manifestEntry)
        } catch let e as ArchiveError {
            throw .archive(e)
        } catch let e as PresetPackageError {
            throw e
        } catch {
            throw .io(String(describing: error))
        }
        // 其他文件（未来可能的素材等）不读取、不解压，只提示。
        for entry in zip.entries where entry.name != manifestName && !entry.isDirectory {
            issues.append(PresetIssue(.warning, code: "package.ignored_entry", path: entry.name,
                                      message: "忽略预设包中的额外文件：\(entry.name)"))
        }
        return analyzeManifest(manifestData, issues: issues, options: options)
    }

    /// 检查 `manifest.json` 的内容：schema、不认识的字段、取值与引用、平台能力。导入和逐项修改（D-93）共用。
    static func analyzeManifest(_ manifestData: Data, issues: [PresetIssue], options: PresetImportOptions) -> Analysis {
        var issues = issues
        var preview = PresetImportPreview(currentSchemaVersion: PresetSchema.currentVersion)
        // 先读出未定型的基本信息，这样即使版本较新或内容有误，预览也能显示名称和版本。
        do {
            let raw = try PresetSchema.parseManifest(manifestData)
            preview.schemaVersion = raw["schemaVersion"]?.intValue
            preview.name = raw["name"]?.stringValue
            preview.presetId = raw["presetId"]?.stringValue
        } catch {
            // 下面的 decode 会给出同样的错误。
        }

        let decoded: DecodedPreset
        do {
            decoded = try PresetSchema.decode(manifestData)
        } catch {
            preview.requiresNewerApp = if case .newerSchemaVersion = error { true } else { false }
            preview.issues = issues + [PresetIssue(.error, code: error.code, path: fieldPath(of: error), message: error.message)]
            return Analysis(preview: preview, decoded: nil, schemaError: error)
        }

        let preset = decoded.preset
        if decoded.wasMigrated {
            issues.append(PresetIssue(.warning, code: "package.migrated", path: "schemaVersion",
                                      message: "预设已从 schema 版本 \(decoded.originalSchemaVersion) 升级到 \(preset.schemaVersion)"))
        }
        for path in decoded.unknownFieldPaths {
            switch options.unknownFields {
            case .reject:
                issues.append(PresetIssue(.error, code: "package.unknown_field", path: path, message: "不认识的字段：\(path)"))
            case .keep:
                issues.append(PresetIssue(.warning, code: "package.unknown_field", path: path, message: "不认识的字段，已原样保留：\(path)"))
            }
        }
        issues += preset.validate()
        if options.existingPresetIds.contains(preset.presetId) {
            issues.append(PresetIssue(.warning, code: "package.preset_id_exists", path: "presetId",
                                      message: "已有相同 ID 的预设，默认另存为副本，也可以替换"))
            preview.idConflictResolutions = [.saveAsCopy, .replace]
        }
        var platformName: String?
        if let platformId = preset.platform, let catalog = options.platforms {
            if let profile = catalog.profile(id: platformId) {
                platformName = profile.displayName
                issues += profile.check(preset)
            } else {
                issues.append(PresetIssue(.warning, code: "platform.unknown", path: "platform",
                                          message: "不认识的目标平台：\(platformId)"))
            }
        }
        preview.summary = PresetSummary(preset, platformName: platformName)
        preview.issues = issues
        return Analysis(preview: preview, decoded: decoded, schemaError: nil)
    }

    private static func fieldPath(of error: PresetError) -> String {
        switch error {
        case .invalidField(let path, _): path
        case .missingSchemaVersion, .invalidSchemaVersion, .newerSchemaVersion, .unsupportedSchemaVersion: "schemaVersion"
        default: ""
        }
    }

    /// 找出看起来像本地绝对路径或文件 URL 的字符串字段。
    static func privatePathFields(in manifest: Data) -> [String] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: manifest) else { return [] }
        let prefixes = ["/Users/", "/Volumes/", "/private/", "/home/", "/var/", "~/", "file:"]
        var hits: [String] = []
        func walk(_ value: JSONValue, _ path: String) {
            switch value {
            case .string(let s):
                let lower = s.lowercased()
                if prefixes.contains(where: { lower.hasPrefix($0.lowercased()) }) || s.contains(":\\") {
                    hits.append(path)
                }
            case .array(let a):
                for (i, v) in a.enumerated() { walk(v, "\(path)[\(i)]") }
            case .object(let o):
                for (k, v) in o.sorted(by: { $0.key < $1.key }) { walk(v, path.isEmpty ? k : "\(path).\(k)") }
            default:
                break
            }
        }
        walk(root, "")
        return hits
    }
}
