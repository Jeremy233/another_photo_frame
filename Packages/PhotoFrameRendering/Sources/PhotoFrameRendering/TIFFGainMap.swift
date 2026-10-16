import Foundation

// Lightroom「最大化兼容性」HDR TIFF（规范 §6.2，色彩 PoC 坑 19、§8.6）。
//
// 结构：IFD0 = Lightroom 的 SDR 版本；IFD0 的 SubIFD（标签 330）= gain map，Photometric = 52553，
// 私有标签 52557 = ISO 21496-1 二进制元数据（Lightroom 在标准数据前多写 4 个字节）。
// ImageIO 不读 SubIFD，HDR 会被静默丢掉，所以这里自己解析 TIFF 结构，按 ISO 21496-1 还原 HDR。
// 只支持经典 TIFF、未压缩、交错存储、条带布局；其他情况由调用方按 SDR 读入并提示「HDR 部分未读取」。
//
// 文件是不可信输入：所有偏移都做边界检查，越界一律抛错，不崩溃。

struct TIFFError: Error, CustomStringConvertible {
    var description: String
    init(_ s: String) { description = s }
}

struct TIFFFile {
    struct Entry {
        var type: Int
        var count: Int
        /// 值在文件中的位置（≤ 4 字节时就在目录项里）。
        var valueOffset: Int
    }

    struct IFD {
        var tags: [Int: Entry] = [:]
    }

    let data: Data
    let little: Bool

    init(_ data: Data) throws {
        self.data = Data(data)
        guard self.data.count >= 8 else { throw TIFFError("文件过短") }
        switch (self.data[0], self.data[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: throw TIFFError("不是 TIFF")
        }
        guard try u16(2) == 42 else { throw TIFFError("不支持 BigTIFF") }
    }

    func u8(_ o: Int) throws -> Int {
        guard o >= 0, o < data.count else { throw TIFFError("偏移越界") }
        return Int(data[o])
    }

    func u16(_ o: Int) throws -> Int {
        guard o >= 0, o + 2 <= data.count else { throw TIFFError("偏移越界") }
        let a = Int(data[o]), b = Int(data[o + 1])
        return little ? a | b << 8 : a << 8 | b
    }

    func u32(_ o: Int) throws -> Int {
        let a = try u16(o), b = try u16(o + 2)
        return little ? a | b << 16 : a << 16 | b
    }

    var ifd0: IFD? { try? ifd(at: u32(4)) }

    func ifd(at offset: Int) throws -> IFD {
        let n = try u16(offset)
        guard n > 0, n < 4096 else { throw TIFFError("IFD 项数异常") }
        var r = IFD()
        for i in 0..<n {
            let e = offset + 2 + i * 12
            let tag = try u16(e), type = try u16(e + 2), count = try u32(e + 4)
            let size = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4][type] ?? 1
            guard count >= 0, count < 1 << 28 else { throw TIFFError("标签 \(tag) 数量异常") }
            let total = size * count
            let valueOffset = total <= 4 ? e + 8 : try u32(e + 8)
            guard valueOffset + total <= data.count else { throw TIFFError("标签 \(tag) 越界") }
            r.tags[tag] = Entry(type: type, count: count, valueOffset: valueOffset)
        }
        return r
    }

    func ints(_ ifd: IFD, _ tag: Int) throws -> [Int]? {
        guard let t = ifd.tags[tag] else { return nil }
        return try (0..<t.count).map { i in
            switch t.type {
            case 1, 7: try u8(t.valueOffset + i)
            case 3: try u16(t.valueOffset + 2 * i)
            case 4, 13: try u32(t.valueOffset + 4 * i)
            default: throw TIFFError("标签 \(tag) 不是整数类型")
            }
        }
    }

    func int(_ ifd: IFD, _ tag: Int) throws -> Int? { try ints(ifd, tag)?.first }

    func bytes(_ ifd: IFD, _ tag: Int) -> Data? {
        guard let t = ifd.tags[tag] else { return nil }
        let size = [1: 1, 2: 1, 7: 1][t.type] ?? 0
        guard size > 0 else { return nil }
        return data.subdata(in: t.valueOffset..<(t.valueOffset + t.count))
    }

    /// 未压缩、交错、条带布局的像素读取器。返回各通道的归一化值（整数 / 最大值，浮点原值）。
    struct Raster {
        var width: Int
        var height: Int
        var channels: Int
        var read: (_ x: Int, _ y: Int, _ c: Int) -> Float
    }

    func raster(_ ifd: IFD) throws -> Raster {
        guard try int(ifd, 259) ?? 1 == 1 else { throw TIFFError("压缩的 TIFF") }
        guard try int(ifd, 284) ?? 1 == 1 else { throw TIFFError("非交错存储") }
        guard ifd.tags[322] == nil else { throw TIFFError("分块（tile）布局") }
        guard let w = try int(ifd, 256), let h = try int(ifd, 257), w > 0, h > 0, w < 1 << 17, h < 1 << 17 else {
            throw TIFFError("尺寸缺失或异常")
        }
        let spp = try int(ifd, 277) ?? 1
        let bps = try int(ifd, 258) ?? 1
        let sampleFormat = try int(ifd, 339) ?? 1
        guard [1, 3, 4].contains(spp) else { throw TIFFError("通道数 \(spp)") }
        guard [8, 16, 32].contains(bps), bps == 32 || sampleFormat == 1, sampleFormat == 1 || sampleFormat == 3 else {
            throw TIFFError("位深 \(bps) / 采样格式 \(sampleFormat)")
        }
        guard let offsets = try ints(ifd, 273), let counts = try ints(ifd, 279), offsets.count == counts.count else {
            throw TIFFError("条带信息缺失")
        }
        let rowsPerStrip = min(try int(ifd, 278) ?? h, h)
        guard rowsPerStrip > 0 else { throw TIFFError("RowsPerStrip 异常") }
        let bytesPerSample = bps / 8
        let rowBytes = w * spp * bytesPerSample
        let strips = (h + rowsPerStrip - 1) / rowsPerStrip
        guard offsets.count >= strips else { throw TIFFError("条带数不足") }
        for s in 0..<strips {
            let rows = min(rowsPerStrip, h - s * rowsPerStrip)
            guard counts[s] >= rows * rowBytes, offsets[s] >= 0, offsets[s] + rows * rowBytes <= data.count else {
                throw TIFFError("条带 \(s) 越界")
            }
        }
        let data = self.data, little = self.little, isFloat = sampleFormat == 3
        let base = data.startIndex
        return Raster(width: w, height: h, channels: spp) { x, y, c in
            let o = base + offsets[y / rowsPerStrip] + (y % rowsPerStrip) * rowBytes + (x * spp + c) * bytesPerSample
            switch bytesPerSample {
            case 1:
                return Float(data[o]) / 255
            case 2:
                let a = UInt16(data[o]), b = UInt16(data[o + 1])
                return Float(little ? a | b << 8 : a << 8 | b) / 65535
            default:
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(data[o + k]) << (little ? 8 * k : 8 * (3 - k)) }
                return isFloat ? Float(bitPattern: v) : Float(Double(v) / Double(UInt32.max))
            }
        }
    }
}

/// ISO 21496-1 gain map 元数据（二进制形式）。headroom、min、max 都是 log2 值。
struct GainMapMetadata: Hashable {
    var multiChannel = false
    var useBaseColorSpace = true
    var baseHeadroom = 0.0
    var alternateHeadroom = 0.0
    var gainMapMin: [Double] = []
    var gainMapMax: [Double] = []
    var gamma: [Double] = []
    var baseOffset: [Double] = []
    var alternateOffset: [Double] = []

    /// Lightroom 的 52557 标签在标准数据前多 4 个字节；两种都试，取能完整解析的那个。
    static func parse(_ data: Data) throws -> GainMapMetadata {
        var lastError: Error = TIFFError("gain map 元数据为空")
        for skip in [4, 0] where data.count > skip {
            do { return try GainMapMetadata(data, skip: skip) } catch { lastError = error }
        }
        throw lastError
    }

    init(_ raw: Data, skip: Int) throws {
        let d = Data(raw)
        var o = skip
        func need(_ n: Int) throws { guard o + n <= d.count else { throw TIFFError("gain map 元数据长度不足") } }
        func u16() throws -> Int { try need(2); defer { o += 2 }; return d.be16(o) }
        func u32() throws -> UInt32 { try need(4); defer { o += 4 }; return UInt32(d.be32(o)) }
        func s32() throws -> Int32 { Int32(bitPattern: try u32()) }
        func ratio(signed: Bool) throws -> Double {
            let n = signed ? Double(try s32()) : Double(try u32())
            let den = Double(try u32())
            guard den != 0 else { throw TIFFError("分母为 0") }
            return n / den
        }
        guard try u16() == 0 else { throw TIFFError("minimum_version 不是 0") }
        _ = try u16() // writer_version
        try need(1)
        let flags = d[o]; o += 1
        multiChannel = flags & 0x80 != 0
        useBaseColorSpace = flags & 0x40 != 0
        let channels = multiChannel ? 3 : 1
        if flags & 0x08 != 0 {
            // 公分母形式
            let den = Double(try u32())
            guard den != 0 else { throw TIFFError("分母为 0") }
            baseHeadroom = Double(try u32()) / den
            alternateHeadroom = Double(try u32()) / den
            for _ in 0..<channels {
                gainMapMin.append(Double(try s32()) / den)
                gainMapMax.append(Double(try s32()) / den)
                gamma.append(Double(try u32()) / den)
                baseOffset.append(Double(try s32()) / den)
                alternateOffset.append(Double(try s32()) / den)
            }
        } else {
            baseHeadroom = try ratio(signed: false)
            alternateHeadroom = try ratio(signed: false)
            for _ in 0..<channels {
                gainMapMin.append(try ratio(signed: true))
                gainMapMax.append(try ratio(signed: true))
                gamma.append(try ratio(signed: false))
                baseOffset.append(try ratio(signed: true))
                alternateOffset.append(try ratio(signed: true))
            }
        }
        guard o == d.count else { throw TIFFError("元数据长度不符：解析到 \(o)，共 \(d.count) 字节") }
        guard gamma.allSatisfy({ $0 > 0 }) else { throw TIFFError("gamma 必须为正") }
    }

    /// HDR headroom（线性倍数）。Lightroom 32 位文件会把两个 headroom 写反（PoC §8.6），所以取较大者。
    var headroom: Double { pow(2, max(baseHeadroom, alternateHeadroom)) }

    /// 按 ISO 21496-1 把线性 SDR 底图值完全展开为 HDR（weight = 1）。
    func apply(base: SIMD3<Float>, gain: SIMD3<Float>) -> SIMD3<Float> {
        var out = SIMD3<Float>()
        for c in 0..<3 {
            let i = multiChannel ? c : 0
            let g = pow(Double(max(gain[i], 0)), 1 / gamma[i])
            let logBoost = gainMapMin[i] + (gainMapMax[i] - gainMapMin[i]) * g
            out[c] = Float((Double(base[c]) + baseOffset[i]) * pow(2, logBoost) - alternateOffset[i])
        }
        return out
    }
}

/// 一份「最大化兼容性」TIFF 的解析结果。
struct GainMapTIFF {
    var file: TIFFFile
    var base: TIFFFile.IFD
    var gainMap: TIFFFile.IFD
    var metadata: GainMapMetadata

    /// 检测文件是否带 SubIFD gain map。没有时返回 nil；有但无法解析时抛错（由调用方降级为 SDR 并警告）。
    static func detect(_ data: Data) throws -> GainMapTIFF? {
        guard let file = try? TIFFFile(data), let ifd0 = file.ifd0 else { return nil }
        guard let subOffsets = try? file.ints(ifd0, 330) else { return nil }
        for offset in subOffsets {
            guard let sub = try? file.ifd(at: offset) else { continue }
            let photometric = try? file.int(sub, 262)
            guard photometric == 52553 || sub.tags[52557] != nil else { continue }
            guard let raw = file.bytes(sub, 52557) else { throw TIFFError("gain map 缺少 52557 元数据标签") }
            return GainMapTIFF(file: file, base: ifd0, gainMap: sub, metadata: try GainMapMetadata.parse(raw))
        }
        return nil
    }

    /// 底图（SDR 版本）与 HDR 的线性像素，按 `step × step` 盒式平均降采样（D-18：按输出所需尺寸解码）。
    /// - Parameter linearize: 把底图编码值转成线性值（按底图 ICC 的 TRC）。
    /// - Returns: 两个 RGBA half 缓冲，alpha = 1，宽高 = 原尺寸 / step（向下取整）。
    func reconstruct(step: Int, linearize: @escaping @Sendable (_ value: Float, _ channel: Int) -> Float) throws
        -> (width: Int, height: Int, sdr: [Float16], hdr: [Float16])
    {
        let base = try file.raster(self.base)
        let gain = try file.raster(gainMap)
        guard base.channels >= 3 else { throw TIFFError("底图不是 RGB") }
        guard gain.channels == 1 || gain.channels >= 3 else { throw TIFFError("gain map 通道数 \(gain.channels)") }
        let step = max(1, step)
        let w = base.width / step, h = base.height / step
        guard w > 0, h > 0 else { throw TIFFError("降采样后尺寸为 0") }
        let meta = metadata
        let sdr = UnsafeMutableBufferPointer<Float16>.allocate(capacity: w * h * 4)
        let hdr = UnsafeMutableBufferPointer<Float16>.allocate(capacity: w * h * 4)
        defer { sdr.deallocate(); hdr.deallocate() }
        let gainChannels = gain.channels
        let gw = gain.width, gh = gain.height, bw = base.width, bh = base.height
        let n = Float(step * step)
        nonisolated(unsafe) let sdrOut = sdr, hdrOut = hdr
        DispatchQueue.concurrentPerform(iterations: h) { y in
            for x in 0..<w {
                var s = SIMD3<Float>(), v = SIMD3<Float>()
                for dy in 0..<step {
                    for dx in 0..<step {
                        let sx = x * step + dx, sy = y * step + dy
                        let b = SIMD3(linearize(base.read(sx, sy, 0), 0), linearize(base.read(sx, sy, 1), 1), linearize(base.read(sx, sy, 2), 2))
                        let gx = min(sx * gw / bw, gw - 1), gy = min(sy * gh / bh, gh - 1)
                        let g = gainChannels == 1
                            ? SIMD3(repeating: gain.read(gx, gy, 0))
                            : SIMD3(gain.read(gx, gy, 0), gain.read(gx, gy, 1), gain.read(gx, gy, 2))
                        s += b
                        v += meta.apply(base: b, gain: g)
                    }
                }
                let i = (y * w + x) * 4
                s /= n; v /= n
                sdrOut[i] = Float16(s.x); sdrOut[i + 1] = Float16(s.y); sdrOut[i + 2] = Float16(s.z); sdrOut[i + 3] = 1
                hdrOut[i] = Float16(v.x); hdrOut[i + 1] = Float16(v.y); hdrOut[i + 2] = Float16(v.z); hdrOut[i + 3] = 1
            }
        }
        return (w, h, Array(sdr), Array(hdr))
    }
}
