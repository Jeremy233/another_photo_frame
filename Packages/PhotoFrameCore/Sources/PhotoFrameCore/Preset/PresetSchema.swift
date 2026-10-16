import Foundation

/// 预设 JSON 的读取错误。`code` 是稳定的机器可读错误码（规范 §10.1）。
public enum PresetError: Error, Hashable, Sendable {
    case invalidJSON(String)
    case notAnObject
    case missingSchemaVersion
    case invalidSchemaVersion(String)
    /// 文件来自更新的 PhotoFrame（D-15：提示升级，不默默丢字段）。
    case newerSchemaVersion(found: Int, supported: Int)
    /// 版本低于支持范围，或缺少某一步迁移。
    case unsupportedSchemaVersion(found: Int)
    case migrationFailed(from: Int, reason: String)
    /// 字段缺失、类型错误或取值不认识。`path` 形如 `layers[1].anchor`。
    case invalidField(path: String, reason: String)

    public var code: String {
        switch self {
        case .invalidJSON: "preset.invalid_json"
        case .notAnObject: "preset.not_an_object"
        case .missingSchemaVersion: "preset.missing_schema_version"
        case .invalidSchemaVersion: "preset.invalid_schema_version"
        case .newerSchemaVersion: "preset.newer_schema_version"
        case .unsupportedSchemaVersion: "preset.unsupported_schema_version"
        case .migrationFailed: "preset.migration_failed"
        case .invalidField: "preset.invalid_field"
        }
    }

    public var message: String {
        switch self {
        case .invalidJSON(let d): "预设不是合法的 JSON：\(d)"
        case .notAnObject: "预设顶层必须是 JSON 对象"
        case .missingSchemaVersion: "预设缺少 schemaVersion"
        case .invalidSchemaVersion(let v): "schemaVersion 必须是正整数：\(v)"
        case .newerSchemaVersion(let found, let supported):
            "该预设使用 schema 版本 \(found)，当前程序只支持到 \(supported)"
        case .unsupportedSchemaVersion(let v): "不支持 schema 版本 \(v)"
        case .migrationFailed(let from, let reason): "从 schema 版本 \(from) 迁移失败：\(reason)"
        case .invalidField(let path, let reason): "字段 \(path.isEmpty ? "(根)" : path) 无效：\(reason)"
        }
    }

    /// 给用户的修复建议。
    public var hint: String? {
        switch self {
        case .newerSchemaVersion: "请升级 PhotoFrame 后再导入"
        case .unsupportedSchemaVersion: "请用较新的 PhotoFrame 重新导出该预设"
        default: nil
        }
    }
}

/// 一步 schema 迁移：把 `fromVersion` 的 manifest 改写成 `fromVersion + 1`。
///
/// 迁移在未定型的 JSON 上进行，因此旧字段可以改名、拆分、补默认值；
/// 迁移函数不需要处理 `schemaVersion` 本身，由 ``PresetMigrator`` 更新。
public struct PresetMigration: Sendable {
    public var fromVersion: Int
    public var transform: @Sendable (inout [String: JSONValue]) throws -> Void

    public init(from fromVersion: Int, transform: @escaping @Sendable (inout [String: JSONValue]) throws -> Void) {
        self.fromVersion = fromVersion
        self.transform = transform
    }
}

/// 按顺序把旧版本 manifest 迁移到 `targetVersion`。
public struct PresetMigrator: Sendable {
    public var targetVersion: Int
    public var minimumVersion: Int
    private var steps: [Int: PresetMigration]

    public init(targetVersion: Int, minimumVersion: Int = 1, migrations: [PresetMigration]) {
        self.targetVersion = targetVersion
        self.minimumVersion = minimumVersion
        self.steps = Dictionary(migrations.map { ($0.fromVersion, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// 读出 manifest 的 schemaVersion，不做其他检查。
    public static func schemaVersion(of manifest: [String: JSONValue]) throws(PresetError) -> Int {
        guard let raw = manifest["schemaVersion"] else { throw .missingSchemaVersion }
        guard let v = raw.intValue, v >= 1 else { throw .invalidSchemaVersion(String(describing: raw)) }
        return v
    }

    /// 检查版本并迁移。返回迁移后的 manifest（`schemaVersion == targetVersion`）以及原始版本。
    public func migrate(_ manifest: [String: JSONValue]) throws(PresetError) -> (manifest: [String: JSONValue], originalVersion: Int) {
        let original = try Self.schemaVersion(of: manifest)
        if original > targetVersion { throw .newerSchemaVersion(found: original, supported: targetVersion) }
        if original < minimumVersion { throw .unsupportedSchemaVersion(found: original) }
        var current = manifest
        var version = original
        while version < targetVersion {
            guard let step = steps[version] else { throw .unsupportedSchemaVersion(found: original) }
            do {
                try step.transform(&current)
            } catch let e as PresetError {
                throw e
            } catch {
                throw .migrationFailed(from: version, reason: String(describing: error))
            }
            version += 1
            current["schemaVersion"] = .number(Double(version))
        }
        return (current, original)
    }
}

/// 解码结果。
public struct DecodedPreset: Hashable, Sendable {
    public var preset: ExportPreset
    /// 迁移前的版本；未迁移时等于当前版本。
    public var originalSchemaVersion: Int
    /// 不认识、也不以 `x-` 开头的字段路径（它们已保存在对应对象的 `extensions` 中）。
    public var unknownFieldPaths: [String]

    public var wasMigrated: Bool { originalSchemaVersion != preset.schemaVersion }
}

/// 预设 JSON 的版本、迁移与编解码入口。
public enum PresetSchema {
    /// 当前 schema 版本（D-15：整数）。
    public static let currentVersion = 1

    /// 当前版本的迁移表。新增版本时在这里追加 `PresetMigration(from: n) { … }`。
    public static let standardMigrator = PresetMigrator(targetVersion: currentVersion, migrations: [])

    /// 把 manifest 解析为未定型的 JSON 对象。
    public static func parseManifest(_ data: Data) throws(PresetError) -> [String: JSONValue] {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw .invalidJSON(describeDecodingError(error))
        }
        guard let object = value.objectValue else { throw .notAnObject }
        return object
    }

    /// 解析、迁移并解码。
    public static func decode(_ data: Data, migrator: PresetMigrator = standardMigrator) throws(PresetError) -> DecodedPreset {
        let (manifest, original) = try migrator.migrate(parseManifest(data))
        let migratedData: Data
        do {
            migratedData = try JSONEncoder().encode(JSONValue.object(manifest))
        } catch {
            throw .invalidJSON(String(describing: error))
        }
        let log = UnknownFieldLog()
        let decoder = JSONDecoder()
        decoder.userInfo[.presetUnknownFieldLog] = log
        do {
            let preset = try decoder.decode(ExportPreset.self, from: migratedData)
            return DecodedPreset(preset: preset, originalSchemaVersion: original, unknownFieldPaths: log.paths.sorted())
        } catch {
            throw mapDecodingError(error)
        }
    }

    /// 编码为稳定排序的、带缩进的 JSON。
    public static func encode(_ preset: ExportPreset) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(preset)
    }

    static func mapDecodingError(_ error: any Error) -> PresetError {
        guard let e = error as? DecodingError else { return .invalidJSON(String(describing: error)) }
        switch e {
        case .keyNotFound(let key, let ctx):
            return .invalidField(path: describe(ctx.codingPath + [key]), reason: "缺少必填字段")
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return .invalidField(path: describe(ctx.codingPath), reason: ctx.debugDescription)
        @unknown default:
            return .invalidJSON(String(describing: e))
        }
    }

    static func describeDecodingError(_ error: any Error) -> String {
        if case .dataCorrupted(let ctx)? = error as? DecodingError {
            return ctx.debugDescription
        }
        return String(describing: error)
    }
}
