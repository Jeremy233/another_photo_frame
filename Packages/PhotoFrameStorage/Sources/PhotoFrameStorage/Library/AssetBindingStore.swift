import Foundation
import PhotoFrameCore

/// 持久化「预设本地绑定」和「用户默认绑定」（D-14 的后两级）。单任务绑定由调用方随任务传入，不存这里。
///
/// 文件 `<root>/bindings.json`：`{"storageFormat": 1, "presetLocal": {...}, "userGlobal": {...}}`。
/// 只存在本机，**不**写进 `.photoframe`。
///
/// - 每次修改都在跨进程文件锁内「读 → 改 → 原子写」，GUI 与 CLI 同时修改不会互相覆盖。
/// - 文件损坏：读取时当作空表并警告；下一次修改前把坏文件改名为 `bindings.corrupt-<时间>.json` 留底，再写新文件。
/// - 格式版本比当前程序新：读取时当作空表并警告，拒绝修改（避免丢数据）。
public struct AssetBindingStore: Sendable {
    public let fileURL: URL
    let lockURL: URL

    public static let storageFormatVersion = 1
    static let maxFileBytes = 4 << 20

    public init(fileURL: URL, lockURL: URL? = nil) {
        self.fileURL = fileURL
        self.lockURL = lockURL ?? fileURL.deletingLastPathComponent().appending(path: ".lock")
    }

    /// `<root>/bindings.json`。
    public init(root: URL) {
        self.init(fileURL: root.appending(path: "bindings.json"))
    }

    public struct Loaded: Hashable, Sendable {
        public var table: AssetBindingTable
        public var warnings: [LibraryWarning]
    }

    public func load() -> Loaded {
        switch read() {
        case .success(let t): Loaded(table: t ?? AssetBindingTable(), warnings: [])
        case .failure(let w): Loaded(table: AssetBindingTable(), warnings: [w])
        }
    }

    /// 在锁内读改写。`body` 抛错时不写入。
    @discardableResult
    public func modify(_ body: (inout AssetBindingTable) throws(LibraryError) -> Void) throws(LibraryError) -> AssetBindingTable {
        try LibraryFiles.withLock(lockURL) { () throws(LibraryError) -> AssetBindingTable in
            var table: AssetBindingTable
            switch read() {
            case .success(let t):
                table = t ?? AssetBindingTable()
            case .failure(let w):
                if w.code == "library.newer_storage_format" {
                    throw .newerStorageFormat(file: fileURL.lastPathComponent, found: newerVersion() ?? 0,
                                              supported: Self.storageFormatVersion)
                }
                try backUpCorruptFile()
                table = AssetBindingTable()
            }
            let before = table
            try body(&table)
            if table != before { try write(table) }
            return table
        }
    }

    // MARK: 便捷操作

    /// 设置或清除（`assetId == nil`）某个预设的本地绑定。
    public func setPresetBinding(presetId: UUID, slotId: String, assetId: UUID?) throws(LibraryError) {
        try modify { t in
            if let assetId {
                t.bindForPreset(presetId, slotId: slotId, assetId: assetId)
            } else {
                t.presetLocal[presetId.uuidString]?[slotId] = nil
                if t.presetLocal[presetId.uuidString]?.isEmpty == true { t.presetLocal[presetId.uuidString] = nil }
            }
        }
    }

    /// 设置或清除用户默认绑定。
    public func setDefaultBinding(slotId: String, assetId: UUID?) throws(LibraryError) {
        try modify { t in t.userGlobal[slotId] = assetId }
    }

    public func removePresetBindings(presetId: UUID) throws(LibraryError) {
        try modify { t in t.presetLocal[presetId.uuidString] = nil }
    }

    /// 把一个预设的本地绑定复制给另一个（复制预设时用）。目标已有的同名 slot 绑定被覆盖。
    public func copyPresetBindings(from source: UUID, to target: UUID) throws(LibraryError) {
        try modify { t in
            guard let src = t.presetLocal[source.uuidString], !src.isEmpty else { return }
            t.presetLocal[target.uuidString, default: [:]].merge(src) { _, new in new }
        }
    }

    /// 指向某个素材的所有持久绑定，按 scope、presetId、slotId 排序。
    public func bindings(referencing assetId: UUID) -> [PersistedBinding] {
        load().table.persistedBindings.filter { $0.assetId == assetId }
    }

    /// 删除指向某个素材的所有持久绑定，返回被删的绑定。
    @discardableResult
    public func removeBindings(referencing assetId: UUID) throws(LibraryError) -> [PersistedBinding] {
        var removed: [PersistedBinding] = []
        try modify { t in
            removed = t.persistedBindings.filter { $0.assetId == assetId }
            for b in removed {
                switch b.scope {
                case .presetLocal:
                    if let p = b.presetId { t.presetLocal[p.uuidString]?[b.slotId] = nil
                        if t.presetLocal[p.uuidString]?.isEmpty == true { t.presetLocal[p.uuidString] = nil }
                    }
                case .userGlobal: t.userGlobal[b.slotId] = nil
                case .job: break
                }
            }
        }
        return removed
    }

    // MARK: - 内部

    private struct FileContents: Codable {
        var storageFormat: Int
        var presetLocal: [String: [String: UUID]]
        var userGlobal: [String: UUID]
    }

    /// 文件不存在时为 `.success(nil)`。
    private func read() -> Result<AssetBindingTable?, LibraryWarning> {
        let item = fileURL.lastPathComponent
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .success(nil) }
        let data: Data
        do { data = try LibraryFiles.read(fileURL, maxBytes: Self.maxFileBytes) } catch {
            return .failure(LibraryWarning(code: "binding.unreadable", item: item, message: "绑定文件无法读取：\(error.message)"))
        }
        if let v = Self.storageFormat(of: data), v > Self.storageFormatVersion {
            return .failure(LibraryWarning(code: "library.newer_storage_format", item: item,
                                           message: "绑定文件的格式版本是 \(v)，当前程序只支持到 \(Self.storageFormatVersion)，暂不使用"))
        }
        guard let file = try? LibraryFiles.jsonDecoder.decode(FileContents.self, from: data) else {
            return .failure(LibraryWarning(code: "binding.unreadable", item: item, message: "绑定文件已损坏，暂按没有绑定处理"))
        }
        return .success(AssetBindingTable(presetLocal: file.presetLocal, userGlobal: file.userGlobal))
    }

    private func write(_ table: AssetBindingTable) throws(LibraryError) {
        let file = FileContents(storageFormat: Self.storageFormatVersion, presetLocal: table.presetLocal, userGlobal: table.userGlobal)
        let data: Data
        do { data = try LibraryFiles.jsonEncoder.encode(file) } catch { throw .io("编码绑定失败：\(error)") }
        // 与预设、asset.json 相同：超过读取上限的写进去也读不回来，不写。
        try LibraryFiles.checkWritable(data, name: fileURL.lastPathComponent, maxBytes: Self.maxFileBytes)
        try LibraryFiles.atomicWrite(data, to: fileURL)
    }

    private func newerVersion() -> Int? {
        (try? Data(contentsOf: fileURL)).flatMap(Self.storageFormat(of:))
    }

    private static func storageFormat(of data: Data) -> Int? {
        (try? LibraryFiles.jsonDecoder.decode([String: JSONValue].self, from: data))?["storageFormat"]?.intValue
    }

    private func backUpCorruptFile() throws(LibraryError) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backup = fileURL.deletingLastPathComponent().appending(path: "bindings.corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        try LibraryFiles.move(fileURL, to: backup, what: "备份损坏的绑定文件")
    }
}

/// 一条持久绑定（预设本地或用户默认），用于列表显示和删除素材时的提示。
public struct PersistedBinding: Hashable, Sendable, Codable {
    public var scope: BindingScope
    /// `scope == .presetLocal` 时是所属预设。
    public var presetId: UUID?
    public var slotId: String
    public var assetId: UUID
}

extension AssetBindingTable {
    /// 表中所有绑定，排序稳定。presetLocal 里键不是合法 UUID 的条目跳过。
    public var persistedBindings: [PersistedBinding] {
        var out: [PersistedBinding] = []
        for (preset, slots) in presetLocal.sorted(by: { $0.key < $1.key }) {
            guard let pid = UUID(uuidString: preset) else { continue }
            for (slot, asset) in slots.sorted(by: { $0.key < $1.key }) {
                out.append(PersistedBinding(scope: .presetLocal, presetId: pid, slotId: slot, assetId: asset))
            }
        }
        for (slot, asset) in userGlobal.sorted(by: { $0.key < $1.key }) {
            out.append(PersistedBinding(scope: .userGlobal, presetId: nil, slotId: slot, assetId: asset))
        }
        return out
    }
}
