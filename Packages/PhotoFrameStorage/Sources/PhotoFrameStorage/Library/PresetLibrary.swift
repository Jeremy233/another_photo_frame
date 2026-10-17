import Foundation
import PhotoFrameCore

/// 预设来自哪里，对应左栏的三个分组（UI 设计文档第 7 节）。
public enum PresetOrigin: String, Hashable, Sendable, Codable, CaseIterable {
    /// 程序内置，只读。
    case builtIn
    /// 用户新建、复制或保存的。
    case user
    /// 从 `.photoframe` 导入的。
    case imported
}

/// ``PresetLibrary/edit(_:_:)`` 的结果。
public struct PresetEditResult: Hashable, Sendable {
    public var entry: PresetEntry
    /// 不阻止保存的问题（例如 HDR 待实测）。
    public var warnings: [PresetIssue]
}

/// 库中的一个预设。
public struct PresetEntry: Hashable, Sendable, Identifiable {
    public var preset: ExportPreset
    public var origin: PresetOrigin
    /// 内置预设为 nil。
    public var createdAt: Date?
    public var modifiedAt: Date?
    /// 不阻止使用的问题（例如文件里有不认识的字段、内容校验未通过）。
    public var warnings: [LibraryWarning]

    public var id: UUID { preset.presetId }
    public var presetId: UUID { preset.presetId }
    public var name: String { preset.name }
    public var isReadOnly: Bool { origin == .builtIn }
    /// 给 CLI 用的短名，例如 `Instagram Panorama` → `instagram-panorama`（§11.3）。
    public var slug: String { PresetLibrary.slug(for: preset.name) }
}

/// `preset list --json`、MCP `list_presets` 用的精简条目，不含任何本地路径。
public struct PresetListItem: Hashable, Sendable, Codable, Identifiable {
    public var presetId: UUID
    public var name: String
    public var slug: String
    public var origin: PresetOrigin
    public var readOnly: Bool
    public var platform: String?
    public var canvas: PixelSize
    public var panorama: Bool
    public var format: OutputSettings.Format
    public var dynamicRange: OutputSettings.DynamicRange
    public var slotIds: [String]
    public var modifiedAt: Date?

    public var id: UUID { presetId }

    public init(_ e: PresetEntry) {
        presetId = e.presetId
        name = e.name
        slug = e.slug
        origin = e.origin
        readOnly = e.isReadOnly
        platform = e.preset.platform
        canvas = e.preset.canvas.size
        panorama = e.preset.panorama.enabled
        format = e.preset.output.format
        dynamicRange = e.preset.output.dynamicRange
        slotIds = e.preset.assetSlots.map(\.slotId)
        modifiedAt = e.modifiedAt
    }
}

/// `list()` 的结果：三个分组 + 被跳过的文件。
public struct PresetListing: Hashable, Sendable {
    public var builtIn: [PresetEntry]
    public var user: [PresetEntry]
    public var imported: [PresetEntry]
    /// 无法读取而被跳过的文件（损坏、schema 版本过新等），以及条目自身的警告。
    public var warnings: [LibraryWarning]
    /// 读不出来的预设文件对应的 ID（文件名）。导入时把它们也算作已占用，避免意外覆盖。
    public var unreadableIds: Set<UUID>

    /// 按分组顺序排列的全部预设。
    public var all: [PresetEntry] { builtIn + user + imported }

    public func entry(_ id: UUID) -> PresetEntry? { all.first { $0.presetId == id } }
}

/// 导入结果。
public struct PresetImportResult: Hashable, Sendable {
    public var entry: PresetEntry
    /// 发生 ID 冲突时实际采用的处理方式；没有冲突时为 nil。
    public var conflictResolution: PresetIdConflictResolution?
    /// 导入时的警告（已迁移、平台能力等）。
    public var warnings: [PresetIssue]
}

/// 用户预设库（§8.1、§8.3，UI 设计文档第 7 节）。
///
/// - 内置预设来自 ``BuiltInPresets``，只读；要修改请先 ``duplicate(_:name:)``。
/// - 用户预设每个一个文件 `Presets/<presetId>.json`，原子写入。
/// - 读库时某个文件损坏、schema 版本过新：跳过它并在 ``PresetListing/warnings`` 里说明，**不改动、不删除**该文件。
///
/// 不缓存：每次调用都从磁盘读取，因此 GUI、CLI、MCP 多个进程同时使用同一个库也能看到彼此的修改。
public struct PresetLibrary: Sendable {
    /// 存放用户预设的目录（`<root>/Presets`）。
    public let directory: URL
    public let builtIns: [ExportPreset]
    /// 用于导入预览的平台能力检查；nil 时跳过。
    public let platforms: PlatformCatalog?

    /// 文件封装格式版本（不是预设的 schemaVersion）。
    public static let storageFormatVersion = 1
    /// 单个预设文件的读取上限，与预设包单条解压上限一致（D-34）。
    public static let maxFileBytes = ArchiveLimits.presetPackage.maxEntryUncompressedBytes

    public init(directory: URL, builtIns: [ExportPreset], platforms: PlatformCatalog?) {
        self.directory = directory
        self.builtIns = builtIns
        self.platforms = platforms
    }

    /// `<root>/Presets`，内置预设按平台配置生成。
    public init(root: URL, platforms: PlatformCatalog) {
        self.init(directory: root.appending(path: "Presets", directoryHint: .isDirectory),
                  builtIns: BuiltInPresets.all(catalog: platforms), platforms: platforms)
    }

    // MARK: 读取

    public func list() -> PresetListing {
        var listing = PresetListing(
            builtIn: builtIns.map { PresetEntry(preset: $0, origin: .builtIn, warnings: []) },
            user: [], imported: [], warnings: [], unreadableIds: [])
        let builtInIds = Set(builtIns.map(\.presetId))
        for url in LibraryFiles.regularFiles(in: directory) where url.pathExtension == "json" {
            let name = url.lastPathComponent
            guard let fileId = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                listing.warnings.append(LibraryWarning(code: "library.unexpected_file", item: name, message: "忽略不认识的文件"))
                continue
            }
            switch loadFile(url, expectedId: fileId) {
            case .success(let entry):
                if builtInIds.contains(fileId) {
                    listing.warnings.append(LibraryWarning(code: "library.shadows_builtin", item: name,
                                                           message: "用户预设与内置预设 ID 相同，已忽略"))
                    continue
                }
                listing.warnings += entry.warnings
                if entry.origin == .imported { listing.imported.append(entry) } else { listing.user.append(entry) }
            case .failure(let warning):
                listing.warnings.append(warning)
                listing.unreadableIds.insert(fileId)
            }
        }
        listing.user.sort(by: Self.displayOrder)
        listing.imported.sort(by: Self.displayOrder)
        return listing
    }

    public func entry(_ id: UUID) throws(LibraryError) -> PresetEntry {
        if let b = builtIns.first(where: { $0.presetId == id }) {
            return PresetEntry(preset: b, origin: .builtIn, warnings: [])
        }
        let url = fileURL(id)
        guard LibraryFiles.isRegularFile(url) else { throw .presetNotFound(id) }
        switch loadFile(url, expectedId: id) {
        case .success(let e): return e
        case .failure(let w): throw .unreadableItem(id: id.uuidString, reason: w.message)
        }
    }

    /// 按 CLI 的引用方式查找预设：UUID、完整名称（不区分大小写）或短名（`instagram-panorama`）。
    public func find(_ reference: String) throws(LibraryError) -> PresetEntry {
        let listing = list()
        if let id = UUID(uuidString: reference) {
            if let e = listing.entry(id) { return e }
            if listing.unreadableIds.contains(id) { return try entry(id) }
            throw .presetNotFound(id)
        }
        let byName = listing.all.filter { $0.name.compare(reference, options: [.caseInsensitive]) == .orderedSame }
        let matches = byName.isEmpty ? listing.all.filter { $0.slug == Self.slug(for: reference) } : byName
        switch matches.count {
        case 1: return matches[0]
        case 0: throw .presetReferenceNotFound(reference)
        default: throw .ambiguousPresetReference(reference, matches.map(\.presetId))
        }
    }

    // MARK: 修改

    /// 新建：以 `template` 为底（例如某个内置预设），生成新 UUID。
    @discardableResult
    public func create(name: String, from template: ExportPreset) throws(LibraryError) -> PresetEntry {
        var p = template
        p.presetId = UUID()
        p.name = try Self.checkedName(name)
        return try write(p, origin: .user, createdAt: nil, mustBeNew: true)
    }

    /// 加入一个已有 presetId 的预设（ID 已存在时报错）。
    @discardableResult
    public func add(_ preset: ExportPreset, origin: PresetOrigin = .user) throws(LibraryError) -> PresetEntry {
        guard origin != .builtIn else { throw .builtInReadOnly(preset.presetId) }
        return try write(preset, origin: origin, createdAt: nil, mustBeNew: true)
    }

    /// 复制（内置预设也可以复制）。副本是用户预设，生成新 UUID；`name` 为 nil 时命名为「原名 Copy」「原名 Copy 2」…
    @discardableResult
    public func duplicate(_ id: UUID, name: String? = nil) throws(LibraryError) -> PresetEntry {
        let source = try entry(id)
        var p = source.preset
        p.presetId = UUID()
        p.name = try name.map { n throws(LibraryError) in try Self.checkedName(n) }
            ?? Self.copyName(for: source.name, existing: Set(list().all.map(\.name)))
        return try write(p, origin: .user, createdAt: nil, mustBeNew: true)
    }

    @discardableResult
    public func rename(_ id: UUID, to name: String) throws(LibraryError) -> PresetEntry {
        var e = try mutableEntry(id)
        e.preset.name = try Self.checkedName(name)
        return try write(e.preset, origin: e.origin, createdAt: e.createdAt, mustBeNew: false)
    }

    /// 保存修改。预设必须已经在库里且不是内置预设；分组（来源）和创建时间保持不变（D-81：导入的预设编辑后仍在「导入」组）。
    @discardableResult
    public func update(_ preset: ExportPreset) throws(LibraryError) -> PresetEntry {
        let e = try mutableEntry(preset.presetId)
        return try write(preset, origin: e.origin, createdAt: e.createdAt, mustBeNew: false)
    }

    /// 逐项修改（D-93）：在 manifest 上按字段路径应用 `edits`，改完的整份预设走一遍与导入相同的检查
    /// （schema、不认识的字段、取值与引用、平台能力、大小上限），通过后原子写入。任何一项失败都不改动文件。
    /// 内置预设只读（先复制）；presetId、schemaVersion 不能改；分组和创建时间不变（D-81）。
    @discardableResult
    public func edit(_ id: UUID, _ edits: [PresetEdit]) throws(LibraryError) -> PresetEditResult {
        let e = try mutableEntry(id)
        let manifest: JSONValue
        do {
            manifest = try LibraryFiles.jsonDecoder.decode(JSONValue.self, from: PresetSchema.encode(e.preset))
        } catch {
            throw .io("编码预设失败：\(error)")
        }
        let edited: JSONValue
        do {
            edited = try PresetEditor.apply(edits, to: manifest)
        } catch {
            throw .edit(error)
        }
        let data: Data
        do {
            data = try LibraryFiles.jsonEncoder.encode(edited)
        } catch {
            throw .io("编码预设失败：\(error)")
        }
        let checked: ImportedPreset
        do {
            checked = try PresetPackage.validateManifest(data, options: PresetImportOptions(platforms: platforms))
        } catch {
            throw .package(error)
        }
        let entry = try update(checked.preset)
        return PresetEditResult(entry: entry, warnings: checked.warnings)
    }

    /// 在「用户保存」和「导入」两组之间移动（GUI 拖放用，D-81）。内容、创建与修改时间都不变；
    /// 已经在目标组时什么也不做。内置预设不能移动，也不能移进内置组。
    @discardableResult
    public func move(_ id: UUID, to group: PresetOrigin) throws(LibraryError) -> PresetEntry {
        let e = try mutableEntry(id)
        guard group != .builtIn else { throw .builtInReadOnly(id) }
        guard e.origin != group else { return e }
        return try write(e.preset, origin: group, createdAt: e.createdAt, modifiedAt: e.modifiedAt, mustBeNew: false)
    }

    /// 删除用户预设。读不出来的文件也可以删除。
    public func delete(_ id: UUID) throws(LibraryError) {
        guard !BuiltInPresets.isBuiltIn(id), !builtIns.contains(where: { $0.presetId == id }) else { throw .builtInReadOnly(id) }
        let url = fileURL(id)
        guard LibraryFiles.isRegularFile(url) else { throw .presetNotFound(id) }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw .io("删除预设失败：\(LibraryFiles.describe(error))")
        }
    }

    // MARK: 导入 / 导出

    /// 导入前预览（§8.3）。已有的 presetId（含读不出来的文件）都算冲突。
    public func previewImport(_ data: Data, unknownFields: UnknownFieldPolicy = .reject) throws(LibraryError) -> PresetImportPreview {
        do {
            return try PresetPackage.preview(data, options: importOptions(unknownFields))
        } catch {
            throw .package(error)
        }
    }

    /// 导入。presetId 冲突时按 `onConflict` 处理，默认另存为副本（D-39）；内置预设不能被替换。
    @discardableResult
    public func importPackage(
        _ data: Data,
        onConflict: PresetIdConflictResolution = .saveAsCopy,
        unknownFields: UnknownFieldPolicy = .reject
    ) throws(LibraryError) -> PresetImportResult {
        let options = importOptions(unknownFields)
        let imported: ImportedPreset
        do {
            imported = try PresetPackage.importPreset(data, options: options)
        } catch {
            throw .package(error)
        }
        var preset = imported.preset
        var applied: PresetIdConflictResolution?
        if options.existingPresetIds.contains(preset.presetId) {
            applied = onConflict
            switch onConflict {
            case .saveAsCopy:
                // D-80：留在「导入」组，名称按复制预设的规则加 Copy 后缀。
                preset.presetId = UUID()
                preset.name = Self.copyName(for: preset.name, existing: Set(list().all.map(\.name)))
            case .replace:
                if builtIns.contains(where: { $0.presetId == preset.presetId }) { throw .builtInReadOnly(preset.presetId) }
            }
        }
        let entry = try write(preset, origin: .imported, createdAt: nil, mustBeNew: applied != .replace)
        return PresetImportResult(entry: entry, conflictResolution: applied, warnings: imported.warnings)
    }

    public func importPackage(
        fileAt url: URL,
        onConflict: PresetIdConflictResolution = .saveAsCopy,
        unknownFields: UnknownFieldPolicy = .reject
    ) throws(LibraryError) -> PresetImportResult {
        let data: Data
        do { data = try PresetPackage.readFile(at: url) } catch { throw .package(error) }
        return try importPackage(data, onConflict: onConflict, unknownFields: unknownFields)
    }

    /// 导出为 `.photoframe` 字节。会做内容校验和隐私检查（D-37）。内置预设也可以导出。
    public func exportPackage(_ id: UUID) throws(LibraryError) -> Data {
        let e = try entry(id)
        do {
            return try PresetPackage.export(e.preset)
        } catch {
            throw .package(error)
        }
    }

    /// 导出并原子写入 `url`（已存在时替换）。
    public func exportPackage(_ id: UUID, to url: URL) throws(LibraryError) {
        let data = try exportPackage(id)
        try LibraryFiles.atomicWrite(data, to: url)
    }

    /// 导出文件的建议文件名，例如 `My Landscape.photoframe`。去掉路径分隔符和控制字符。
    public static func suggestedFileName(for name: String) -> String {
        let cleaned = name.unicodeScalars.map { s -> String in
            CharacterSet.controlCharacters.contains(s) || "/\\:".unicodeScalars.contains(s) ? "-" : String(s)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return (cleaned.isEmpty ? "Preset" : String(cleaned.prefix(120))) + "." + PresetPackage.fileExtension
    }

    // MARK: - 内部

    func fileURL(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }

    private func importOptions(_ unknownFields: UnknownFieldPolicy) -> PresetImportOptions {
        let listing = list()
        let existing = Set(listing.all.map(\.presetId)).union(listing.unreadableIds)
        return PresetImportOptions(unknownFields: unknownFields, existingPresetIds: existing, platforms: platforms)
    }

    private func mutableEntry(_ id: UUID) throws(LibraryError) -> PresetEntry {
        if BuiltInPresets.isBuiltIn(id) || builtIns.contains(where: { $0.presetId == id }) { throw .builtInReadOnly(id) }
        return try entry(id)
    }

    private func write(_ preset: ExportPreset, origin: PresetOrigin, createdAt: Date?, modifiedAt: Date? = nil,
                       mustBeNew: Bool) throws(LibraryError) -> PresetEntry {
        let id = preset.presetId
        if BuiltInPresets.isBuiltIn(id) || builtIns.contains(where: { $0.presetId == id }) { throw .builtInReadOnly(id) }
        _ = try Self.checkedName(preset.name)
        let issues = preset.validate()
        guard issues.errors.isEmpty else { throw .invalidPreset(issues) }
        let url = fileURL(id)
        if mustBeNew, FileManager.default.fileExists(atPath: url.path) { throw .presetAlreadyExists(id) }
        let now = LibraryFiles.now()
        let file = LibraryPresetFile(origin: origin, createdAt: createdAt ?? now, modifiedAt: modifiedAt ?? now)
        try LibraryFiles.atomicWrite(try file.encode(preset), to: url)
        return PresetEntry(preset: preset, origin: origin, createdAt: file.createdAt, modifiedAt: file.modifiedAt, warnings: [])
    }

    private func loadFile(_ url: URL, expectedId: UUID) -> Result<PresetEntry, LibraryWarning> {
        let item = url.lastPathComponent
        func fail(_ code: String, _ message: String) -> Result<PresetEntry, LibraryWarning> {
            .failure(LibraryWarning(code: code, item: item, message: message))
        }
        let data: Data
        do { data = try LibraryFiles.read(url, maxBytes: Self.maxFileBytes) } catch { return fail("library.unreadable_preset", error.message) }
        let decoded: (LibraryPresetFile, DecodedPreset)
        do {
            decoded = try LibraryPresetFile.decode(data)
        } catch let e as LibraryError {
            return fail(e.code == "library.newer_storage_format" ? e.code : "library.unreadable_preset", e.message)
        } catch let e as PresetError {
            return fail(e.code == "preset.newer_schema_version" ? "library.newer_schema_version" : "library.unreadable_preset",
                        e.message)
        } catch {
            return fail("library.unreadable_preset", String(describing: error))
        }
        let (meta, d) = decoded
        guard d.preset.presetId == expectedId else {
            return fail("library.id_mismatch", "文件名与 presetId 不一致")
        }
        var warnings: [LibraryWarning] = []
        if !d.unknownFieldPaths.isEmpty {
            warnings.append(LibraryWarning(code: "library.unknown_fields", item: item,
                                           message: "保留了不认识的字段：" + d.unknownFieldPaths.joined(separator: ", ")))
        }
        if d.wasMigrated {
            warnings.append(LibraryWarning(code: "library.migrated", item: item,
                                           message: "预设从 schema 版本 \(d.originalSchemaVersion) 升级，下次保存时写入新版本"))
        }
        let errors = d.preset.validate().errors
        if !errors.isEmpty {
            warnings.append(LibraryWarning(code: "library.invalid_preset", item: item,
                                           message: errors.map(\.message).joined(separator: "；")))
        }
        let origin = meta.origin == .builtIn ? .user : meta.origin
        return .success(PresetEntry(preset: d.preset, origin: origin, createdAt: meta.createdAt,
                                    modifiedAt: meta.modifiedAt, warnings: warnings))
    }

    static func checkedName(_ name: String) throws(LibraryError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidName("名称不能为空") }
        guard trimmed.count <= 200 else { throw .invalidName("名称不能超过 200 个字符") }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw .invalidName("名称不能包含控制字符")
        }
        return trimmed
    }

    static func copyName(for name: String, existing: Set<String>) -> String {
        let base = String(name.prefix(180))
        var candidate = "\(base) Copy"
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(base) Copy \(n)"
            n += 1
        }
        return candidate
    }

    /// 小写，字母数字以外的连续字符换成一个 `-`。
    public static func slug(for name: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                out.append(ch)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return out
    }

    static func displayOrder(_ a: PresetEntry, _ b: PresetEntry) -> Bool {
        let c = a.name.localizedStandardCompare(b.name)
        if c != .orderedSame { return c == .orderedAscending }
        return a.presetId.uuidString < b.presetId.uuidString
    }
}

/// 用户预设文件：`{"storageFormat": 1, "origin": …, "createdAt": …, "modifiedAt": …, "preset": {manifest}}`。
///
/// `preset` 与 `.photoframe` 里的 `manifest.json` 完全相同，按 ``PresetSchema`` 读写（迁移、扩展字段都适用）。
struct LibraryPresetFile: Codable {
    var storageFormat: Int = PresetLibrary.storageFormatVersion
    var origin: PresetOrigin
    var createdAt: Date
    var modifiedAt: Date

    init(origin: PresetOrigin, createdAt: Date, modifiedAt: Date) {
        self.origin = origin
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    func encode(_ preset: ExportPreset) throws(LibraryError) -> Data {
        do {
            let manifest = try LibraryFiles.jsonDecoder.decode(JSONValue.self, from: PresetSchema.encode(preset))
            var object = try LibraryFiles.jsonDecoder.decode([String: JSONValue].self, from: LibraryFiles.jsonEncoder.encode(self))
            object["preset"] = manifest
            return try LibraryFiles.jsonEncoder.encode(object)
        } catch {
            throw .io("编码预设失败：\(error)")
        }
    }

    static func decode(_ data: Data) throws -> (LibraryPresetFile, DecodedPreset) {
        let object = try LibraryFiles.jsonDecoder.decode([String: JSONValue].self, from: data)
        if let v = object["storageFormat"]?.intValue, v > PresetLibrary.storageFormatVersion {
            throw LibraryError.newerStorageFormat(file: "预设文件", found: v, supported: PresetLibrary.storageFormatVersion)
        }
        guard let manifest = object["preset"] else { throw LibraryError.io("缺少 preset 字段") }
        var meta = object
        meta["preset"] = nil
        let file = try LibraryFiles.jsonDecoder.decode(LibraryPresetFile.self, from: LibraryFiles.jsonEncoder.encode(meta))
        let decoded = try PresetSchema.decode(LibraryFiles.jsonEncoder.encode(manifest))
        return (file, decoded)
    }
}
