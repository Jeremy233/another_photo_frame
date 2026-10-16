import Foundation

/// 最小的 ICC 读写：读标签表、描述文字、TRC 曲线，并能替换 TRC 标签后重建文件。
///
/// 用途是绕开色彩 PoC 坑 20：ColorSync 对 TRC 为 BT.709 / BT.2020 逆 OETF 形状的参数曲线（`para` type 3，
/// g ≈ 1/0.45、d ≈ 0.081）不按曲线本身解码，而是当作 BT.1886（γ2.4）显示 EOTF，线性值只有正确值的 84% 左右。
/// Lightroom 16 位 Rec.2020 TIFF 和 Apple 自己的 `itur_2020` 配置文件都会这样。按 ICC 字面含义解码才与
/// Lightroom 自己的 SDR 版本一致，所以把这类参数曲线改写成 4096 点采样曲线（`curv`）再交给 ColorSync。
struct ICCProfile {
    struct Tag {
        var signature: String
        var data: Data
    }

    var header: Data
    var tags: [Tag]

    init?(_ data: Data) {
        let d = Data(data)
        guard d.count >= 132, d.be32(36) == 0x6163_7370 /* 'acsp' */ else { return nil }
        let count = d.be32(128)
        guard count < 1000, d.count >= 132 + count * 12 else { return nil }
        var tags: [Tag] = []
        for i in 0..<count {
            let o = 132 + i * 12
            let offset = d.be32(o + 4), length = d.be32(o + 8)
            guard offset >= 0, length >= 0, offset + length <= d.count else { return nil }
            tags.append(Tag(signature: d.fourCC(o), data: d.subdata(in: offset..<offset + length)))
        }
        header = d.subdata(in: 0..<128)
        self.tags = tags
    }

    func tag(_ signature: String) -> Data? { tags.first { $0.signature == signature }?.data }

    /// `desc` 标签的文字（v2 `desc` 或 v4 `mluc`）。
    var descriptionText: String? {
        guard let d = tag("desc"), d.count >= 12 else { return nil }
        switch d.fourCC(0) {
        case "desc":
            let n = d.be32(8)
            guard n > 0, d.count >= 12 + n else { return nil }
            return String(decoding: d.subdata(in: 12..<12 + n - 1), as: UTF8.self)
        case "mluc":
            guard d.be32(8) > 0, d.count >= 28 else { return nil }
            let length = d.be32(20), offset = d.be32(24)
            guard offset + length <= d.count else { return nil }
            return String(data: d.subdata(in: offset..<offset + length), encoding: .utf16BigEndian)
        default:
            return nil
        }
    }

    /// RGB 三条 TRC 都是参数曲线且形状是 BT.709 / BT.2020 逆 OETF 时，返回参数 (g, a, b, c, d)。
    var bt709FamilyParametricTRC: [Double]? {
        var first: [Double]?
        for sig in ["rTRC", "gTRC", "bTRC"] {
            guard let d = tag(sig), d.count >= 12, d.fourCC(0) == "para", d.be16(8) == 3, d.count >= 12 + 20 else { return nil }
            let p = (0..<5).map { d.s15Fixed16(12 + 4 * $0) }
            // g = 1/0.45 ≈ 2.222，阈值 d = 0.081（BT.709 / BT.2020 的 4.5 × 0.018）。
            guard abs(p[0] - 1 / 0.45) < 0.01, abs(p[4] - 0.081) < 0.002 else { return nil }
            if let first, zip(first, p).contains(where: { abs($0 - $1) > 1e-4 }) { return nil }
            first = p
        }
        return first
    }

    /// 把三条 TRC 换成同一条采样曲线，返回新的 ICC 数据。
    func replacingTRC(samples: [UInt16]) -> Data {
        var curv = Data("curv".utf8) + Data(count: 4)
        curv.appendBE32(samples.count)
        for s in samples { curv.append(UInt8(s >> 8)); curv.append(UInt8(s & 0xFF)) }
        let newTags = tags.map { ["rTRC", "gTRC", "bTRC"].contains($0.signature) ? Tag(signature: $0.signature, data: curv) : $0 }
        return Self.build(header: header, tags: newTags)
    }

    static func build(header: Data, tags: [Tag]) -> Data {
        var table = Data(), body = Data()
        let base = 128 + 4 + tags.count * 12
        // 相同内容的标签（如三条 TRC）共用一份数据，和常见 ICC 写法一致。
        var written: [Data: Int] = [:]
        for tag in tags {
            let offset: Int
            if let existing = written[tag.data] {
                offset = existing
            } else {
                while (base + body.count) % 4 != 0 { body.append(0) }
                offset = base + body.count
                body += tag.data
                written[tag.data] = offset
            }
            table += Data(tag.signature.utf8)
            table.appendBE32(offset)
            table.appendBE32(tag.data.count)
        }
        var out = header
        out.appendBE32(tags.count)
        out += table
        out += body
        while out.count % 4 != 0 { out.append(0) }
        out.replaceSubrange(0..<4, with: Data.be32(out.count))
        out.replaceSubrange(84..<100, with: Data(count: 16)) // profile ID（MD5）置零 = 未计算
        return out
    }

    /// 三条 TRC 的求值函数（编码值 0…1 → 线性值），用于自己线性化像素。不认识的曲线类型返回 nil。
    var trcFunctions: [@Sendable (Float) -> Float]? {
        var result: [@Sendable (Float) -> Float] = []
        for sig in ["rTRC", "gTRC", "bTRC"] {
            guard let d = tag(sig), let f = Self.curveFunction(d) else { return nil }
            result.append(f)
        }
        return result
    }

    static func curveFunction(_ d: Data) -> (@Sendable (Float) -> Float)? {
        guard d.count >= 12 else { return nil }
        switch d.fourCC(0) {
        case "curv":
            let n = d.be32(8)
            guard d.count >= 12 + 2 * n else { return nil }
            if n == 0 { return { $0 } }
            if n == 1 {
                let g = Float(d.be16(12)) / 256
                return { pow(max($0, 0), g) }
            }
            let table = (0..<n).map { Float(d.be16(12 + 2 * $0)) / 65535 }
            return { x in
                let t = min(max(x, 0), 1) * Float(n - 1)
                let i = min(Int(t), n - 2)
                return table[i] + (table[i + 1] - table[i]) * (t - Float(i))
            }
        case "para":
            let type = d.be16(8)
            let counts = [0: 1, 1: 3, 2: 4, 3: 5, 4: 7]
            guard let k = counts[type], d.count >= 12 + 4 * k else { return nil }
            let p = (0..<k).map { Float(d.s15Fixed16(12 + 4 * $0)) }
            switch type {
            case 0: return { pow(max($0, 0), p[0]) }
            case 1: return { $0 >= -p[2] / p[1] ? pow(max(p[1] * $0 + p[2], 0), p[0]) : 0 }
            case 2: return { $0 >= -p[2] / p[1] ? pow(max(p[1] * $0 + p[2], 0), p[0]) + p[3] : p[3] }
            case 3: return { $0 >= p[4] ? pow(max(p[1] * $0 + p[2], 0), p[0]) : p[3] * $0 }
            default: return { $0 >= p[4] ? pow(max(p[1] * $0 + p[2], 0), p[0]) + p[5] : p[3] * $0 + p[6] }
            }
        default:
            return nil
        }
    }

    /// 同一配置文件的线性版本（TRC 换成恒等曲线），用于给已经自己线性化的像素打标签。
    var linearized: Data {
        var identity = Data("curv".utf8) + Data(count: 4)
        identity.appendBE32(0)
        let newTags = tags.map { ["rTRC", "gTRC", "bTRC"].contains($0.signature) ? Tag(signature: $0.signature, data: identity) : $0 }
        return Self.build(header: header, tags: newTags)
    }

    /// ICC `para` type 3：x ≥ d 时 (a·x + b)^g，否则 c·x。
    static func evaluateType3(_ p: [Double], _ x: Double) -> Double {
        x >= p[4] ? pow(max(p[1] * x + p[2], 0), p[0]) : p[3] * x
    }

    static func sampledCurve(_ p: [Double], count: Int = 4096) -> [UInt16] {
        (0..<count).map { i in
            let v = evaluateType3(p, Double(i) / Double(count - 1))
            return UInt16(min(max(v, 0), 1) * 65535 + 0.5)
        }
    }
}

extension Data {
    func be16(_ o: Int) -> Int { Int(self[startIndex + o]) << 8 | Int(self[startIndex + o + 1]) }
    func be32(_ o: Int) -> Int { be16(o) << 16 | be16(o + 2) }
    func fourCC(_ o: Int) -> String { String(decoding: self[(startIndex + o)..<(startIndex + o + 4)], as: UTF8.self) }
    func s15Fixed16(_ o: Int) -> Double { Double(Int32(bitPattern: UInt32(be32(o)))) / 65536 }

    static func be32(_ v: Int) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    mutating func appendBE32(_ v: Int) { append(Data.be32(v)) }
}
