import Foundation

/// 由文件头判断的输入格式。ImageIO 的类型判断不可靠（PoC 坑 18：读过属性后会把 gain map JPEG 报成 HEIC），
/// 所以自己看魔数。
enum SourceFileFormat: String {
    case jpeg, png, tiff

    static func sniff(_ data: Data) throws(RenderError) -> SourceFileFormat {
        let b = [UInt8](data.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        if b.count >= 8, b[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if b.count >= 4, (b[0..<4] == [0x49, 0x49, 0x2A, 0x00] || b[0..<4] == [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if b.count >= 4, (b[0..<4] == [0x49, 0x49, 0x2B, 0x00] || b[0..<4] == [0x4D, 0x4D, 0x00, 0x2B]) { return .tiff } // BigTIFF
        if b.count >= 12, String(decoding: b[4..<8], as: UTF8.self) == "ftyp" {
            throw .unsupportedFormat("HEIC / HEIF（暂不支持）")
        }
        throw .unsupportedFormat("无法识别的文件头")
    }

    /// 文件里有没有真正的颜色描述（PoC 坑 1：ImageIO 无法区分「无 ICC」和「sRGB」）。
    ///
    /// - JPEG：APP2 `ICC_PROFILE` 段。
    /// - PNG：`iCCP`、`sRGB`、`cICP`，或 `gAMA` + `cHRM` 同时存在（等价的标准描述）。
    /// - TIFF：IFD0 的 34675（InterColorProfile）标签（经典 TIFF 与 BigTIFF）。
    static func hasEmbeddedColorDescription(_ data: Data, format: SourceFileFormat) -> Bool {
        switch format {
        case .jpeg:
            return JPEGSegments.contains(data, marker: 0xE2, prefix: Data("ICC_PROFILE\0".utf8))
        case .png:
            var chunks = Set<String>()
            var i = 8
            while i + 8 <= data.count {
                let length = data.be32(i)
                let type = data.fourCC(i + 4)
                if type == "IDAT" || type == "IEND" { break }
                chunks.insert(type)
                guard length >= 0, i + 12 + length <= data.count else { break }
                i += 12 + length
            }
            return !chunks.isDisjoint(with: ["iCCP", "sRGB", "cICP"]) || chunks.isSuperset(of: ["gAMA", "cHRM"])
        case .tiff:
            guard let tiff = try? TIFFFile(data) else { return bigTIFFIFD0Contains(data, tag: 34675) }
            guard let ifd0 = tiff.ifd0 else { return false }
            return ifd0.tags[34675] != nil
        }
    }

    /// BigTIFF（版本 43）的 IFD0 里有没有某个值不越界的标签。只为找 ICC；gain map TIFF 仍只支持经典 TIFF。
    /// 结构：头 16 字节（偏移宽度 8），IFD = u64 项数 + 20 字节的目录项（标签 u16、类型 u16、数量 u64、值或偏移 8 字节）。
    /// 与经典 TIFF 相同：项数异常或目录表越界时整个 IFD0 无效，单个标签越界只跳过它。
    static func bigTIFFIFD0Contains(_ data: Data, tag wanted: Int) -> Bool {
        let d = data.startIndex == 0 ? data : Data(data)
        guard d.count >= 16 else { return false }
        let little: Bool
        switch (d[0], d[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return false
        }
        /// 偏移 o 处 n 字节的无符号整数；越界或超出 Int 时为 nil。
        func uint(_ o: Int, _ n: Int) -> Int? {
            guard o >= 0, o <= d.count - n else { return nil }
            var v: UInt64 = 0
            for k in 0..<n { v |= UInt64(d[o + k]) << (little ? 8 * k : 8 * (n - 1 - k)) }
            return v <= UInt64(Int.max) ? Int(v) : nil
        }
        guard uint(2, 2) == 43, uint(4, 2) == 8, uint(6, 2) == 0, let first = uint(8, 8), let n = uint(first, 8),
              n > 0, n < 4096, first <= d.count - 8 - n * 20
        else { return false }
        let sizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4, 16: 8, 17: 8, 18: 8]
        for i in 0..<n {
            let e = first + 8 + i * 20
            guard uint(e, 2) == wanted, let type = uint(e + 2, 2), let count = uint(e + 4, 8) else { continue }
            let (total, overflow) = (sizes[type] ?? 1).multipliedReportingOverflow(by: count)
            guard !overflow, let valueOffset = total <= 8 ? e + 12 : uint(e + 12, 8), valueOffset <= d.count - total else { continue }
            return true
        }
        return false
    }
}

/// JPEG 段遍历（只看 SOS 之前的头部段）。
enum JPEGSegments {
    struct Segment {
        var marker: UInt8
        /// 段在文件中的起点（指向 0xFF）。
        var offset: Int
        /// 包括 2 字节长度字段在内的段长度。
        var length: Int
        var payloadRange: Range<Int> { (offset + 4)..<(offset + 2 + length) }
    }

    static func headerSegments(_ data: Data) -> [Segment] {
        var result: [Segment] = []
        // 只有切片才复制（偏移从 0 起算）；整个文件（内存映射）直接用，不复制。
        let d = data.startIndex == 0 ? data : Data(data)
        var i = 2
        while i + 4 <= d.count, d[i] == 0xFF {
            let marker = d[i + 1]
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) || marker == 0x01 { i += 2; continue }
            if marker == 0xFF { i += 1; continue }
            let length = d.be16(i + 2)
            guard length >= 2, i + 2 + length <= d.count else { break }
            result.append(Segment(marker: marker, offset: i, length: length))
            if marker == 0xDA { break } // SOS：之后是熵编码数据
            i += 2 + length
        }
        return result
    }

    static func contains(_ data: Data, marker: UInt8, prefix: Data) -> Bool {
        let d = data.startIndex == 0 ? data : Data(data)
        return headerSegments(d).contains { s in
            s.marker == marker && d.subdata(in: s.payloadRange).starts(with: prefix)
        }
    }
}
