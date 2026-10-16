import Foundation

/// 读取 ZIP 时的安全上限（§8.3）。
public struct ArchiveLimits: Hashable, Sendable {
    /// 压缩包文件本身的最大字节数。
    public var maxArchiveBytes: Int
    /// 条目（含目录）最大数量。
    public var maxEntryCount: Int
    /// 所有条目解压后的总字节数上限。
    public var maxTotalUncompressedBytes: Int
    /// 单个条目解压后的最大字节数。
    public var maxEntryUncompressedBytes: Int

    public init(maxArchiveBytes: Int, maxEntryCount: Int, maxTotalUncompressedBytes: Int, maxEntryUncompressedBytes: Int) {
        self.maxArchiveBytes = maxArchiveBytes
        self.maxEntryCount = maxEntryCount
        self.maxTotalUncompressedBytes = maxTotalUncompressedBytes
        self.maxEntryUncompressedBytes = maxEntryUncompressedBytes
    }

    /// `.photoframe` 默认上限：manifest 通常只有几 KB。
    public static let presetPackage = ArchiveLimits(
        maxArchiveBytes: 4 << 20,
        maxEntryCount: 32,
        maxTotalUncompressedBytes: 8 << 20,
        maxEntryUncompressedBytes: 1 << 20)
}

/// ZIP 层面的错误。都表示文件不安全或已损坏，不能继续导入。
public enum ArchiveError: Error, Hashable, Sendable {
    case archiveTooLarge(bytes: Int, limit: Int)
    case notAZipArchive
    case corrupted(String)
    case unsupportedFeature(String)
    case tooManyEntries(count: Int, limit: Int)
    case entryTooLarge(name: String, bytes: Int, limit: Int)
    case totalSizeTooLarge(bytes: Int, limit: Int)
    /// 路径穿越、绝对路径、反斜杠、控制字符等。
    case unsafePath(String)
    case symbolicLink(String)
    /// 同名条目（大小写不敏感、Unicode 规范化后比较）。
    case duplicateEntry(String)
    /// 实际解压大小与声明不符（常见于 ZIP 炸弹）或 Deflate 数据损坏。
    case sizeMismatch(String)
    case checksumMismatch(String)

    public var code: String {
        switch self {
        case .archiveTooLarge: "archive.too_large"
        case .notAZipArchive: "archive.not_zip"
        case .corrupted: "archive.corrupted"
        case .unsupportedFeature: "archive.unsupported_feature"
        case .tooManyEntries: "archive.too_many_entries"
        case .entryTooLarge: "archive.entry_too_large"
        case .totalSizeTooLarge: "archive.total_size_too_large"
        case .unsafePath: "archive.unsafe_path"
        case .symbolicLink: "archive.symbolic_link"
        case .duplicateEntry: "archive.duplicate_entry"
        case .sizeMismatch: "archive.size_mismatch"
        case .checksumMismatch: "archive.checksum_mismatch"
        }
    }

    public var message: String {
        switch self {
        case .archiveTooLarge(let b, let l): "文件过大：\(b) 字节，上限 \(l) 字节"
        case .notAZipArchive: "不是 ZIP 格式的 .photoframe 文件"
        case .corrupted(let d): "文件已损坏：\(d)"
        case .unsupportedFeature(let d): "不支持的 ZIP 特性：\(d)"
        case .tooManyEntries(let c, let l): "包含 \(c) 个条目，上限 \(l) 个"
        case .entryTooLarge(let n, let b, let l): "条目 \(n) 解压后 \(b) 字节，上限 \(l) 字节"
        case .totalSizeTooLarge(let b, let l): "解压后总大小 \(b) 字节，上限 \(l) 字节"
        case .unsafePath(let p): "不安全的条目路径：\(p)"
        case .symbolicLink(let p): "不允许符号链接：\(p)"
        case .duplicateEntry(let p): "重复的条目：\(p)"
        case .sizeMismatch(let p): "条目 \(p) 的实际大小与声明不符"
        case .checksumMismatch(let p): "条目 \(p) 校验和不符"
        }
    }
}

/// 中央目录中的一个条目。
struct ZipEntry: Hashable, Sendable {
    var name: String
    var method: UInt16
    var flags: UInt16
    var crc32: UInt32
    var compressedSize: Int
    var uncompressedSize: Int
    var localHeaderOffset: Int
    var isDirectory: Bool { name.hasSuffix("/") }
}

/// 只读 ZIP。初始化时完成全部结构与安全检查；条目内容按需解压。
///
/// 从不写入磁盘，因此路径检查是为了拒绝可疑文件，而不是保护解压目录。
struct ZipReader {
    let data: Data
    let limits: ArchiveLimits
    let entries: [ZipEntry]

    init(data: Data, limits: ArchiveLimits) throws(ArchiveError) {
        guard data.count <= limits.maxArchiveBytes else {
            throw .archiveTooLarge(bytes: data.count, limit: limits.maxArchiveBytes)
        }
        self.data = data
        self.limits = limits
        self.entries = try Self.readCentralDirectory(data, limits: limits)
    }

    func entry(named name: String) -> ZipEntry? {
        entries.first { $0.name == name }
    }

    /// 解压一个条目并校验大小与 CRC。
    func contents(of entry: ZipEntry) throws(ArchiveError) -> Data {
        let o = entry.localHeaderOffset
        guard data.readUInt32(at: o) == ZipFormat.localHeaderSignature,
              let nameLength = data.readUInt16(at: o + 26),
              let extraLength = data.readUInt16(at: o + 28),
              let localName = data.slice(at: o + ZipFormat.localHeaderSize, length: Int(nameLength))
        else { throw .corrupted("本地文件头无效：\(entry.name)") }
        // 本地头与中央目录的文件名必须一致，防止两套解析器看到不同的文件。
        guard String(data: localName, encoding: .utf8) == entry.name else {
            throw .corrupted("本地文件头与中央目录的文件名不一致：\(entry.name)")
        }
        let start = o + ZipFormat.localHeaderSize + Int(nameLength) + Int(extraLength)
        guard let raw = data.slice(at: start, length: entry.compressedSize) else {
            throw .corrupted("条目数据越界：\(entry.name)")
        }
        let output: Data
        switch entry.method {
        case ZipFormat.methodStored:
            guard raw.count == entry.uncompressedSize else { throw .sizeMismatch(entry.name) }
            output = raw
        case ZipFormat.methodDeflate:
            guard let inflated = Deflate.decompress(raw, expectedSize: entry.uncompressedSize) else {
                throw .sizeMismatch(entry.name)
            }
            output = inflated
        default:
            throw .unsupportedFeature("压缩方式 \(entry.method)")
        }
        guard CRC32.checksum(output) == entry.crc32 else { throw .checksumMismatch(entry.name) }
        return output
    }

    // MARK: - 中央目录

    private static func readCentralDirectory(_ data: Data, limits: ArchiveLimits) throws(ArchiveError) -> [ZipEntry] {
        guard data.count >= ZipFormat.endOfCentralDirectorySize else { throw .notAZipArchive }
        guard let eocd = findEndOfCentralDirectory(data) else { throw .notAZipArchive }

        guard let diskNumber = data.readUInt16(at: eocd + 4),
              let cdDisk = data.readUInt16(at: eocd + 6),
              let entriesOnDisk = data.readUInt16(at: eocd + 8),
              let totalEntries = data.readUInt16(at: eocd + 10),
              let cdSize = data.readUInt32(at: eocd + 12),
              let cdOffset = data.readUInt32(at: eocd + 16)
        else { throw .corrupted("中央目录结尾记录不完整") }

        if totalEntries == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            throw .unsupportedFeature("ZIP64")
        }
        guard diskNumber == 0, cdDisk == 0, entriesOnDisk == totalEntries else {
            throw .unsupportedFeature("分卷 ZIP")
        }
        guard Int(totalEntries) <= limits.maxEntryCount else {
            throw .tooManyEntries(count: Int(totalEntries), limit: limits.maxEntryCount)
        }
        guard Int(cdOffset) + Int(cdSize) <= eocd else { throw .corrupted("中央目录越界") }

        var entries: [ZipEntry] = []
        var seen = Set<String>()
        var totalUncompressed = 0
        var offset = Int(cdOffset)
        for _ in 0..<totalEntries {
            guard data.readUInt32(at: offset) == ZipFormat.centralHeaderSignature,
                  let versionMadeBy = data.readUInt16(at: offset + 4),
                  let flags = data.readUInt16(at: offset + 8),
                  let method = data.readUInt16(at: offset + 10),
                  let crc = data.readUInt32(at: offset + 16),
                  let compressed = data.readUInt32(at: offset + 20),
                  let uncompressed = data.readUInt32(at: offset + 24),
                  let nameLength = data.readUInt16(at: offset + 28),
                  let extraLength = data.readUInt16(at: offset + 30),
                  let commentLength = data.readUInt16(at: offset + 32),
                  let externalAttributes = data.readUInt32(at: offset + 38),
                  let localOffset = data.readUInt32(at: offset + 42),
                  let nameData = data.slice(at: offset + ZipFormat.centralHeaderSize, length: Int(nameLength))
            else { throw .corrupted("中央目录条目不完整") }
            offset += ZipFormat.centralHeaderSize + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard offset <= eocd else { throw .corrupted("中央目录越界") }

            guard let name = String(data: nameData, encoding: .utf8) else {
                throw .unsafePath("文件名不是合法的 UTF-8")
            }
            try validatePath(name)
            if UInt8(versionMadeBy >> 8) == ZipFormat.hostUnix,
               (externalAttributes >> 16) & ZipFormat.modeTypeMask == ZipFormat.modeSymlink {
                throw .symbolicLink(name)
            }
            if flags & ZipFormat.flagEncrypted != 0 { throw .unsupportedFeature("加密条目 \(name)") }
            guard method == ZipFormat.methodStored || method == ZipFormat.methodDeflate else {
                throw .unsupportedFeature("压缩方式 \(method)（\(name)）")
            }
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw .unsupportedFeature("ZIP64")
            }
            guard Int(localOffset) < Int(cdOffset) else { throw .corrupted("本地文件头越界：\(name)") }

            let key = name.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(key).inserted else { throw .duplicateEntry(name) }

            let size = Int(uncompressed)
            guard size <= limits.maxEntryUncompressedBytes else {
                throw .entryTooLarge(name: name, bytes: size, limit: limits.maxEntryUncompressedBytes)
            }
            totalUncompressed += size
            guard totalUncompressed <= limits.maxTotalUncompressedBytes else {
                throw .totalSizeTooLarge(bytes: totalUncompressed, limit: limits.maxTotalUncompressedBytes)
            }
            entries.append(ZipEntry(
                name: name, method: method, flags: flags, crc32: crc,
                compressedSize: Int(compressed), uncompressedSize: size, localHeaderOffset: Int(localOffset)))
        }
        return entries
    }

    /// 从文件尾向前找中央目录结尾记录（之后最多跟 65535 字节注释）。
    private static func findEndOfCentralDirectory(_ data: Data) -> Int? {
        let last = data.count - ZipFormat.endOfCentralDirectorySize
        let first = max(0, last - 0xFFFF)
        var i = last
        while i >= first {
            if data.readUInt32(at: i) == ZipFormat.endOfCentralDirectorySignature,
               let commentLength = data.readUInt16(at: i + 20),
               i + ZipFormat.endOfCentralDirectorySize + Int(commentLength) == data.count {
                return i
            }
            i -= 1
        }
        return nil
    }

    /// 只接受「相对、正斜杠分隔、没有 . / .. / 空段、没有控制字符」的路径。
    static func validatePath(_ name: String) throws(ArchiveError) {
        guard !name.isEmpty, name.utf8.count <= 255 else { throw .unsafePath(name) }
        if name.hasPrefix("/") || name.contains("\\") || name.contains(":") { throw .unsafePath(name) }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { throw .unsafePath(name) }
        var components = name.split(separator: "/", omittingEmptySubsequences: false)
        if name.hasSuffix("/") { components.removeLast() }  // 目录条目
        for c in components where c.isEmpty || c == "." || c == ".." {
            throw .unsafePath(name)
        }
    }
}
