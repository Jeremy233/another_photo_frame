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
            throw .unsupportedFormat("HEIC / HEIF（V1 不支持，D-02）")
        }
        throw .unsupportedFormat("无法识别的文件头")
    }

    /// 文件里有没有真正的颜色描述（PoC 坑 1：ImageIO 无法区分「无 ICC」和「sRGB」）。
    ///
    /// - JPEG：APP2 `ICC_PROFILE` 段。
    /// - PNG：`iCCP`、`sRGB`、`cICP`，或 `gAMA` + `cHRM` 同时存在（等价的标准描述）。
    /// - TIFF：IFD0 的 34675（InterColorProfile）标签。
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
            guard let tiff = try? TIFFFile(data), let ifd0 = tiff.ifd0 else { return false }
            return ifd0.tags[34675] != nil
        }
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
        let d = Data(data)
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
        let d = Data(data)
        return headerSegments(d).contains { s in
            s.marker == marker && d.subdata(in: s.payloadRange).starts(with: prefix)
        }
    }
}
