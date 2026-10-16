import CryptoKit
import Foundation
import PhotoFrameCore

/// 素材分组（UI 设计文档第 7 节：签名、水印、相机图标）。只用于整理和显示，不影响绑定。
public enum AssetCategory: String, Hashable, Sendable, Codable, CaseIterable {
    case signature
    case watermark
    case cameraBadge
}

/// 素材元信息。**不含任何文件路径**，可以直接交给 CLI `--json` 和 MCP `list_assets`。
public struct AssetInfo: Hashable, Sendable, Codable, Identifiable {
    public var assetId: UUID
    public var displayName: String
    public var category: AssetCategory
    public var format: AssetSlot.Format
    /// PNG 的像素尺寸；SVG 的固有尺寸。
    public var pixelSize: PixelSize
    public var byteCount: Int
    /// 内容的 SHA-256（十六进制），可用来提示重复导入。
    public var sha256: String
    public var importedAt: Date
    public var modifiedAt: Date
    /// 导入时的提示（例如 SVG 里渲染时会跳过的元素）。
    public var importWarnings: [String]

    public var id: UUID { assetId }

    /// 给 ``SlotResolver`` 用的记录。
    public var record: AssetRecord { AssetRecord(assetId: assetId, format: format, displayName: displayName) }
}

public struct AssetListing: Hashable, Sendable {
    /// 按分组（签名、水印、相机图标）再按名称排序。
    public var assets: [AssetInfo]
    /// 被跳过的条目（元信息损坏、内容文件丢失等）。
    public var warnings: [LibraryWarning]

    public func assets(in category: AssetCategory) -> [AssetInfo] { assets.filter { $0.category == category } }
}

public struct AssetImportResult: Hashable, Sendable {
    public var asset: AssetInfo
    /// 库里已有内容完全相同的素材（仍会导入为新素材）。
    public var duplicateOf: [UUID]
    public var warnings: [String]
}

/// 本地素材库（§8.2）。导入时校验并复制进库，之后只按 `assetId` 引用。
///
/// - 每个素材一个目录 `Assets/<assetId>/`，内有 `asset.json` 与 `content.png|svg`。
///   导入时先在 `Assets/.staging/` 里写好整个目录，再一次改名到位；删除时先改名移走再删。
/// - ``list(category:)``、``info(_:)`` 只返回元信息；真实文件路径只通过 ``contentURL(for:)`` 给渲染器。
/// - 实现 ``AssetLookup``：元信息损坏或内容文件不在、大小不符的素材视为不存在，
///   绑定到它们时 ``SlotResolver`` 会警告并回退（D-28）。
public struct AssetLibrary: AssetLookup, Sendable {
    public let directory: URL
    public let limits: AssetImportLimits

    public static let storageFormatVersion = 1
    static let metadataName = "asset.json"
    static let stagingName = ".staging"

    public init(directory: URL, limits: AssetImportLimits = .default) {
        self.directory = directory
        self.limits = limits
    }

    /// `<root>/Assets`。
    public init(root: URL, limits: AssetImportLimits = .default) {
        self.init(directory: root.appending(path: "Assets", directoryHint: .isDirectory), limits: limits)
    }

    // MARK: 读取

    public func list(category: AssetCategory? = nil) -> AssetListing {
        var assets: [AssetInfo] = []
        var warnings: [LibraryWarning] = []
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = dir.lastPathComponent
            guard let id = UUID(uuidString: name), LibraryFiles.isDirectory(dir) else {
                warnings.append(LibraryWarning(code: "library.unexpected_file", item: name, message: "忽略不认识的文件"))
                continue
            }
            switch load(id) {
            case .success(let info): assets.append(info)
            case .failure(let w): warnings.append(w)
            }
        }
        if let category { assets = assets.filter { $0.category == category } }
        let order = Dictionary(uniqueKeysWithValues: AssetCategory.allCases.enumerated().map { ($1, $0) })
        assets.sort {
            if $0.category != $1.category { return order[$0.category]! < order[$1.category]! }
            let c = $0.displayName.localizedStandardCompare($1.displayName)
            return c == .orderedSame ? $0.assetId.uuidString < $1.assetId.uuidString : c == .orderedAscending
        }
        return AssetListing(assets: assets, warnings: warnings)
    }

    public func info(_ id: UUID) throws(LibraryError) -> AssetInfo {
        guard LibraryFiles.isDirectory(assetDirectory(id)) else { throw .assetNotFound(id) }
        switch load(id) {
        case .success(let info): return info
        case .failure(let w): throw .unreadableItem(id: id.uuidString, reason: w.message)
        }
    }

    /// 内容文件的位置。**只给需要读文件的调用方**（渲染器）；素材不存在或已损坏时为 nil。
    public func contentURL(for id: UUID) -> URL? {
        guard case .success(let info) = load(id) else { return nil }
        return contentFile(id, info.format)
    }

    /// 与 PhotoFrameRendering 的 `RenderJob.assets(from:fileURL:)` 对接。
    public func contentURL(for record: AssetRecord) -> URL? { contentURL(for: record.assetId) }

    // MARK: AssetLookup

    public func asset(withId id: UUID) -> AssetRecord? {
        guard case .success(let info) = load(id) else { return nil }
        return info.record
    }

    /// 读一次磁盘，得到内存中的素材表，用于一次解析多个 slot。
    public func snapshot() -> InMemoryAssetLibrary {
        InMemoryAssetLibrary(list().assets.map(\.record))
    }

    // MARK: 导入

    /// 从文件导入。按扩展名（`png` / `svg`）确定格式，再按内容校验；`displayName` 为 nil 时用文件名（不含扩展名）。
    @discardableResult
    public func importAsset(fileAt url: URL, category: AssetCategory, displayName: String? = nil) throws(LibraryError) -> AssetImportResult {
        let ext = url.pathExtension.lowercased()
        guard let format = AssetSlot.Format(rawValue: ext) else { throw .assetRejected(.unsupportedType(ext)) }
        let limit = format == .png ? limits.maxPNGBytes : limits.maxSVGBytes
        let data: Data
        do {
            // 允许用户选的文件是符号链接（Finder 别名以外的普通链接），但最终必须是普通文件。
            let resolved = url.resolvingSymlinksInPath()
            guard LibraryFiles.isRegularFile(resolved) else { throw LibraryError.io("\(url.lastPathComponent) 不是普通文件") }
            let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= limit else { throw LibraryError.assetRejected(.tooLarge(bytes: size, limit: limit)) }
            data = try LibraryFiles.read(resolved, maxBytes: limit)
        } catch let e as LibraryError {
            throw e
        } catch {
            throw .io(LibraryFiles.describe(error))
        }
        let name = displayName ?? url.deletingPathExtension().lastPathComponent
        return try importAsset(data, format: format, category: category, displayName: name)
    }

    /// 从内存导入（MCP、拖放、测试）。
    @discardableResult
    public func importAsset(_ data: Data, format: AssetSlot.Format, category: AssetCategory, displayName: String) throws(LibraryError) -> AssetImportResult {
        let name = try PresetLibrary.checkedName(displayName)
        let validated = try AssetValidator.validate(data, format: format, limits: limits)
        let digest = SHA256.hash(data: validated.data).map { String(format: "%02x", $0) }.joined()
        let duplicates = list().assets.filter { $0.sha256 == digest }.map(\.assetId)

        let now = LibraryFiles.now()
        let info = AssetInfo(
            assetId: UUID(), displayName: name, category: category, format: validated.format,
            pixelSize: validated.pixelSize, byteCount: validated.data.count, sha256: digest,
            importedAt: now, modifiedAt: now, importWarnings: validated.warnings)

        let staging = directory.appending(path: Self.stagingName, directoryHint: .isDirectory)
        cleanStaleStaging(staging)
        let work = staging.appending(path: info.assetId.uuidString, directoryHint: .isDirectory)
        try LibraryFiles.ensureDirectory(work)
        do {
            try LibraryFiles.atomicWrite(validated.data, to: work.appending(path: "content.\(info.format.rawValue)"))
            try LibraryFiles.atomicWrite(try encode(info), to: work.appending(path: Self.metadataName))
            try LibraryFiles.move(work, to: assetDirectory(info.assetId), what: "把素材移入库中")
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
        return AssetImportResult(asset: info, duplicateOf: duplicates, warnings: validated.warnings)
    }

    // MARK: 修改

    @discardableResult
    public func rename(_ id: UUID, to name: String) throws(LibraryError) -> AssetInfo {
        var info = try info(id)
        info.displayName = try PresetLibrary.checkedName(name)
        return try saveMetadata(info)
    }

    /// 改变分组（例如把误放进「水印」的签名移到「签名」）。
    @discardableResult
    public func setCategory(_ id: UUID, to category: AssetCategory) throws(LibraryError) -> AssetInfo {
        var info = try info(id)
        info.category = category
        return try saveMetadata(info)
    }

    /// 删除素材（读不出元信息的也可以删）。指向它的绑定不在这里处理：解析时按 D-28 警告并回退。
    public func delete(_ id: UUID) throws(LibraryError) {
        let dir = assetDirectory(id)
        guard LibraryFiles.isDirectory(dir) else { throw .assetNotFound(id) }
        let staging = directory.appending(path: Self.stagingName, directoryHint: .isDirectory)
        try LibraryFiles.ensureDirectory(staging)
        let trash = staging.appending(path: "deleted-\(id.uuidString)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try LibraryFiles.move(dir, to: trash, what: "删除素材")
        try? FileManager.default.removeItem(at: trash)
    }

    /// 重新校验已入库素材的内容（例如校验规则升级后）。返回新的提示；不通过时抛出原因。
    public func revalidate(_ id: UUID) throws(LibraryError) -> [String] {
        let info = try info(id)
        let data = try LibraryFiles.read(contentFile(id, info.format), maxBytes: max(limits.maxPNGBytes, limits.maxSVGBytes))
        return try AssetValidator.validate(data, format: info.format, limits: limits).warnings
    }

    // MARK: - 内部

    func assetDirectory(_ id: UUID) -> URL { directory.appending(path: id.uuidString, directoryHint: .isDirectory) }

    func contentFile(_ id: UUID, _ format: AssetSlot.Format) -> URL {
        assetDirectory(id).appending(path: "content.\(format.rawValue)")
    }

    private struct MetadataFile: Codable {
        var storageFormat: Int
        var asset: AssetInfo
    }

    private func encode(_ info: AssetInfo) throws(LibraryError) -> Data {
        do {
            return try LibraryFiles.jsonEncoder.encode(MetadataFile(storageFormat: Self.storageFormatVersion, asset: info))
        } catch {
            throw .io("编码素材信息失败：\(error)")
        }
    }

    private func saveMetadata(_ info: AssetInfo) throws(LibraryError) -> AssetInfo {
        var info = info
        info.modifiedAt = LibraryFiles.now()
        try LibraryFiles.atomicWrite(try encode(info), to: assetDirectory(info.assetId).appending(path: Self.metadataName))
        return info
    }

    private func load(_ id: UUID) -> Result<AssetInfo, LibraryWarning> {
        let item = id.uuidString
        func fail(_ code: String, _ message: String) -> Result<AssetInfo, LibraryWarning> {
            .failure(LibraryWarning(code: code, item: item, message: message))
        }
        let data: Data
        do {
            data = try LibraryFiles.read(assetDirectory(id).appending(path: Self.metadataName), maxBytes: 1 << 20)
        } catch {
            return fail("asset.unreadable_metadata", "素材信息无法读取：\(error.message)")
        }
        let object: [String: JSONValue]
        do { object = try LibraryFiles.jsonDecoder.decode([String: JSONValue].self, from: data) } catch {
            return fail("asset.unreadable_metadata", "素材信息已损坏")
        }
        if let v = object["storageFormat"]?.intValue, v > Self.storageFormatVersion {
            return fail("library.newer_storage_format", "素材信息的格式版本是 \(v)，当前程序只支持到 \(Self.storageFormatVersion)")
        }
        guard let file = try? LibraryFiles.jsonDecoder.decode(MetadataFile.self, from: data) else {
            return fail("asset.unreadable_metadata", "素材信息已损坏")
        }
        let info = file.asset
        guard info.assetId == id else { return fail("asset.unreadable_metadata", "目录名与 assetId 不一致") }
        let content = contentFile(id, info.format)
        guard LibraryFiles.isRegularFile(content) else { return fail("asset.missing_file", "素材文件不见了") }
        let size = (try? content.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard size == info.byteCount else { return fail("asset.size_mismatch", "素材文件大小与记录不符，可能已被改动") }
        return .success(info)
    }

    /// 清理一小时前崩溃留下的导入、删除残留。别的进程正在进行的导入不会这么老。
    private func cleanStaleStaging(_ staging: URL) {
        let cutoff = Date().addingTimeInterval(-3600)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: item) }
        }
    }
}
