import Foundation

/// 生成 ZIP。输出是确定性的：固定时间戳（1980-01-01 00:00）、固定权限，同样输入得到同样字节。
///
/// `Entry` 里以 `override` 结尾的参数只供测试构造畸形文件，正式代码不使用。
struct ZipWriter {
    struct Entry {
        var name: String
        var data: Data
        var compress: Bool = true
        /// 写入中央目录与本地头的「解压后大小」，用于伪造 ZIP 炸弹。
        var uncompressedSizeOverride: UInt32? = nil
        var crc32Override: UInt32? = nil
        var flagsOverride: UInt16? = nil
        var methodOverride: UInt16? = nil
        /// Unix st_mode，默认普通文件 0644。
        var unixMode: UInt32 = ZipFormat.modeRegular | 0o644
        /// 本地头里写入的文件名；默认与中央目录相同。
        var localNameOverride: String? = nil
    }

    private(set) var entries: [Entry] = []
    /// 中央目录结尾记录中的条目数；nil 时取实际条目数。
    var declaredEntryCountOverride: UInt16? = nil

    mutating func add(_ entry: Entry) {
        entries.append(entry)
    }

    mutating func add(name: String, data: Data) {
        entries.append(Entry(name: name, data: data))
    }

    func finish() -> Data {
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = (0 << 9) | (1 << 5) | 1  // 1980-01-01
        var out = Data()
        var central = Data()

        for e in entries {
            let crc = e.crc32Override ?? CRC32.checksum(e.data)
            let deflated = e.compress ? Deflate.compress(e.data) : nil
            let payload = deflated ?? e.data
            let method = e.methodOverride ?? (deflated != nil ? ZipFormat.methodDeflate : ZipFormat.methodStored)
            let flags = e.flagsOverride ?? ZipFormat.flagUTF8
            let size = e.uncompressedSizeOverride ?? UInt32(e.data.count)
            let name = Data(e.name.utf8)
            let localName = Data((e.localNameOverride ?? e.name).utf8)
            let localOffset = UInt32(out.count)

            out.appendUInt32(ZipFormat.localHeaderSignature)
            out.appendUInt16(20)  // version needed: 2.0
            out.appendUInt16(flags)
            out.appendUInt16(method)
            out.appendUInt16(dosTime)
            out.appendUInt16(dosDate)
            out.appendUInt32(crc)
            out.appendUInt32(UInt32(payload.count))
            out.appendUInt32(size)
            out.appendUInt16(UInt16(localName.count))
            out.appendUInt16(0)
            out.append(localName)
            out.append(payload)

            central.appendUInt32(ZipFormat.centralHeaderSignature)
            central.appendUInt16(UInt16(ZipFormat.hostUnix) << 8 | 20)  // made by: Unix, 2.0
            central.appendUInt16(20)
            central.appendUInt16(flags)
            central.appendUInt16(method)
            central.appendUInt16(dosTime)
            central.appendUInt16(dosDate)
            central.appendUInt32(crc)
            central.appendUInt32(UInt32(payload.count))
            central.appendUInt32(size)
            central.appendUInt16(UInt16(name.count))
            central.appendUInt16(0)  // extra
            central.appendUInt16(0)  // comment
            central.appendUInt16(0)  // disk start
            central.appendUInt16(0)  // internal attributes
            central.appendUInt32(e.unixMode << 16)
            central.appendUInt32(localOffset)
            central.append(name)
        }

        let cdOffset = UInt32(out.count)
        out.append(central)
        let count = declaredEntryCountOverride ?? UInt16(entries.count)
        out.appendUInt32(ZipFormat.endOfCentralDirectorySignature)
        out.appendUInt16(0)
        out.appendUInt16(0)
        out.appendUInt16(count)
        out.appendUInt16(count)
        out.appendUInt32(UInt32(central.count))
        out.appendUInt32(cdOffset)
        out.appendUInt16(0)  // comment length
        return out
    }
}
