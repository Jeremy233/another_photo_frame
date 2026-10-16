import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd

// MARK: - Lightroom "Maximize Compatibility" HDR TIFF：自己读取 SubIFD 里的 gain map 并按 ISO 21496-1 还原 HDR
//
// 文件结构（实测）：IFD0 = Lightroom 的 SDR 版本；IFD0 的 SubIFD = gain map，
// Photometric = 52553，私有标签 52557 = ISO 21496-1 二进制元数据（前面多 4 个字节）。
// ImageIO 不读 SubIFD，所以这里只解析 TIFF 结构，像素直接从（未压缩的）条带里取。

/// 极简 TIFF 读取器：经典 TIFF（非 BigTIFF），只支持未压缩、交错（chunky）存储。
struct TIFFFile {
    let data: Data
    let little: Bool

    struct IFD {
        var tags: [UInt16: (type: UInt16, count: Int, valueOffset: Int)] = [:]   // valueOffset 为文件内值的位置
    }

    init(_ url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count > 8 else { throw PoCError("不是 TIFF") }
        little = data[0] == 0x49
        guard u16(2) == 42 else { throw PoCError("不支持 BigTIFF 或不是 TIFF") }
    }

    func u16(_ o: Int) -> Int { little ? Int(data[o]) | Int(data[o + 1]) << 8 : Int(data[o]) << 8 | Int(data[o + 1]) }
    func u32(_ o: Int) -> Int { little ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2) }

    func ifd(at off: Int) -> IFD {
        var r = IFD()
        let n = u16(off)
        for i in 0..<n {
            let e = off + 2 + i * 12
            let type = UInt16(u16(e + 2)), count = u32(e + 4)
            let size = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 11: 4, 12: 8, 16: 8][Int(type)] ?? 1
            r.tags[UInt16(u16(e))] = (type, count, size * count <= 4 ? e + 8 : u32(e + 8))
        }
        return r
    }

    var ifd0: IFD { ifd(at: u32(4)) }

    func ints(_ d: IFD, _ tag: UInt16) -> [Int]? {
        guard let t = d.tags[tag] else { return nil }
        return (0..<t.count).map { t.type == 3 ? u16(t.valueOffset + 2 * $0) : u32(t.valueOffset + 4 * $0) }
    }

    func bytes(_ d: IFD, _ tag: UInt16) -> Data? {
        guard let t = d.tags[tag] else { return nil }
        return data.subdata(in: t.valueOffset..<t.valueOffset + t.count)
    }

    /// 像素访问器：返回 (x, y) 的 RGB（16-bit 归一化到 0…1，float32 原值）。
    func sampler(_ d: IFD) throws -> (w: Int, h: Int, px: (Int, Int) -> SIMD3<Float>) {
        guard ints(d, 259)?.first ?? 1 == 1 else { throw PoCError("压缩的 TIFF 需要 libtiff（这里只支持未压缩）") }
        guard ints(d, 284)?.first ?? 1 == 1 else { throw PoCError("只支持交错存储") }
        let w = ints(d, 256)![0], h = ints(d, 257)![0], spp = ints(d, 277)?.first ?? 3
        let bps = ints(d, 258)![0], isFloat = ints(d, 339)?.first == 3
        let offs = ints(d, 273)!, rps = ints(d, 278)?.first ?? h
        let bpp = spp * bps / 8, rowBytes = w * bpp
        let little = self.little
        return (w, h, { x, y in
            let o = offs[y / rps] + (y % rps) * rowBytes + x * bpp
            return self.data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> SIMD3<Float> in
                func c(_ i: Int) -> Float {
                    if bps == 16 {
                        let a = UInt16(p[o + 2 * i]), b = UInt16(p[o + 2 * i + 1])
                        return Float(little ? a | b << 8 : a << 8 | b) / 65535
                    }
                    var v: UInt32 = 0
                    for k in 0..<4 { v |= UInt32(p[o + 4 * i + k]) << (little ? 8 * k : 8 * (3 - k)) }
                    return isFloat ? Float(bitPattern: v) : Float(v) / Float(UInt32.max)
                }
                return SIMD3(c(0), c(1), c(2))
            }
        })
    }
}

/// ISO 21496-1 gain map 元数据（二进制形式）。gainMapMin / Max 为 log2 值，headroom 为 log2 值。
struct GainMapMetadata: CustomStringConvertible {
    var multiChannel = false, useBaseColorSpace = false
    var baseHeadroom = 0.0, alternateHeadroom = 0.0
    var gainMapMin = [Double](), gainMapMax = [Double](), gamma = [Double](), baseOffset = [Double](), alternateOffset = [Double]()

    /// `skip`：Lightroom 的 52557 标签在标准数据前多 4 个字节。
    init(_ d: Data, skip: Int = 4) throws {
        var o = d.startIndex + skip
        func u16() -> Int { defer { o += 2 }; return Int(d[o]) << 8 | Int(d[o + 1]) }
        func u32() -> UInt32 { defer { o += 4 }; return d[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func s32() -> Int32 { Int32(bitPattern: u32()) }
        func frac(signed: Bool) -> Double { let n = signed ? Double(s32()) : Double(u32()); let dd = Double(u32()); return n / dd }
        _ = u16(); _ = u16()                       // minimum_version, writer_version
        let flags = d[o]; o += 1
        multiChannel = flags & 0x80 != 0; useBaseColorSpace = flags & 0x40 != 0
        guard flags & 0x04 == 0 else { throw PoCError("common denominator 形式暂未实现") }
        baseHeadroom = frac(signed: false); alternateHeadroom = frac(signed: false)
        for _ in 0..<(multiChannel ? 3 : 1) {
            gainMapMin.append(frac(signed: true)); gainMapMax.append(frac(signed: true))
            gamma.append(frac(signed: false)); baseOffset.append(frac(signed: true)); alternateOffset.append(frac(signed: true))
        }
        guard o == d.endIndex else { throw PoCError("元数据长度不符：解析到 \(o - d.startIndex)，共 \(d.count) 字节") }
    }

    var description: String {
        "多通道 \(multiChannel)，在底图颜色空间中应用 \(useBaseColorSpace)，headroom 底图 \(f3(baseHeadroom)) / 目标 \(f3(alternateHeadroom))（log2，约 \(f2(pow(2, alternateHeadroom)))×）\n"
        + (0..<gainMapMin.count).map { "   通道\($0)：min \(f3(gainMapMin[$0])) max \(f3(gainMapMax[$0])) gamma \(f3(gamma[$0])) offset \(f4(baseOffset[$0]))/\(f4(alternateOffset[$0]))" }.joined(separator: "\n")
    }

    /// 按 ISO 21496-1 把线性 SDR 底图值还原为 HDR（weight = 1，即完全展开到 alternate headroom）。
    func apply(base: SIMD3<Float>, gain: SIMD3<Float>, weight: Double = 1) -> V3 {
        var out = V3(0, 0, 0)
        for c in 0..<3 {
            let i = multiChannel ? c : 0
            let g = pow(Double(max(gain[multiChannel ? c : 0], 0)), 1 / gamma[i])
            let logBoost = gainMapMin[i] + (gainMapMax[i] - gainMapMin[i]) * g
            out[c] = (Double(base[c]) + baseOffset[i]) * pow(2, logBoost * weight) - alternateOffset[i]
        }
        return out
    }
}

func runGainMapTIFF(_ url: URL, truth: URL?, reference: URL?, full: Bool = false, env: Env) throws {
    print("== \(url.lastPathComponent)")
    let t = try TIFFFile(url)
    let d0 = t.ifd0
    guard let sub = t.ints(d0, 330)?.first else { print("没有 SubIFD：不是带 gain map 的 TIFF"); return }
    let gm = t.ifd(at: sub)
    print("SubIFD Photometric = \(t.ints(gm, 262)?.first ?? -1)，NewSubfileType = \(t.ints(gm, 254)?.first ?? -1)")
    guard let raw = t.bytes(gm, 52557) else { print("SubIFD 没有 52557 元数据标签"); return }
    let meta = try GainMapMetadata(raw)
    print("ISO 21496-1 元数据（\(raw.count) 字节，前 25 字节 \(raw.prefix(25).map { String(format: "%02x", $0) }.joined(separator: " "))）：\(meta)")

    // 底图的线性化方式：32-bit float 原值即线性；16-bit 按 ICC 里的逆 BT.709/2020 OETF 自己线性化（绕开坑 20）
    let base = try t.sampler(d0), gain = try t.sampler(gm)
    let baseIsFloat = t.ints(d0, 339)?.first == 3
    func linear(_ v: SIMD3<Float>) -> SIMD3<Float> {
        guard !baseIsFloat else { return v }
        func f(_ e: Float) -> Float { e < 0.081 ? e / 4.5 : pow((e + 0.099) / 1.099, 1 / 0.45) }
        return SIMD3(f(v.x), f(v.y), f(v.z))
    }
    print("底图 \(base.w)×\(base.h) \(baseIsFloat ? "32-bit float 线性" : "16-bit，按逆 OETF 线性化")；gain map \(gain.w)×\(gain.h)")
    func hdr(_ x: Int, _ y: Int) -> V3 {
        meta.apply(base: linear(base.px(x, y)), gain: gain.px(x * gain.w / base.w, y * gain.h / base.h))
    }

    // 1) 逐像素对比真值（Lightroom 不勾选 Maximize Compatibility 导出的 32-bit 纯 HDR TIFF）
    if let truth {
        let tt = try TIFFFile(truth)
        let ts = try tt.sampler(tt.ifd0)
        guard ts.w == base.w, ts.h == base.h else { throw PoCError("真值尺寸不同") }
        var rel: [Double] = [], relHi: [Double] = [], duv: [Double] = []
        var n = 0
        for k in 0..<400_000 {
            let x = (k &* 7919) % base.w, y = (k &* 104_729) % base.h
            let a = hdr(x, y), b = V3(ts.px(x, y))
            let ya = (Spaces.linear2020.toXYZ * a).y, yb = (Spaces.linear2020.toXYZ * b).y
            guard yb > 0.01 else { continue }
            n += 1
            rel.append(abs(ya / yb - 1))
            if yb > 1 {
                relHi.append(abs(ya / yb - 1))
                duv.append(simd_length(uvPrime(Spaces.linear2020.toXYZ * a) - uvPrime(Spaces.linear2020.toXYZ * b)))
            }
        }
        let sa = Stats(rel), sh = Stats(relHi), su = Stats(duv)
        print("对比真值 \(truth.lastPathComponent)（\(n) 个采样点，亮度 > 0.01）：")
        print("   全部像素 亮度相对误差 中位 \(f4(sa.median)) / P95 \(f4(sa.p95)) / max \(f3(sa.max))")
        print("   高光（真值 Y > 1，\(relHi.count) 点）相对误差 中位 \(f4(sh.median)) / P95 \(f4(sh.p95))；Δu′v′ 中位 \(f4(su.median)) / P95 \(f4(su.p95))")
    }

    // 2) 还原出的 HDR 降到 1/4 分辨率，写成 HDR gain map JPEG，供在 HDR 屏幕上目视对比
    // full = true：全分辨率，headroom 元数据取文件里的值、底图用 Display P3，尽量与 Lightroom 的 HDR JPEG 条件一致，便于目视 A/B
    let step = full ? 1 : 4, w = base.w / step, h = base.h / step
    // 先拿到裸指针再并行写（各行互不重叠），避免对 Swift 数组的并发独占访问
    let hb = UnsafeMutableBufferPointer<Float16>.allocate(capacity: w * h * 4), sb = UnsafeMutableBufferPointer<Float16>.allocate(capacity: w * h * 4)
    defer { hb.deallocate(); sb.deallocate() }
    hb.initialize(repeating: 1); sb.initialize(repeating: 1)
    DispatchQueue.concurrentPerform(iterations: h) { y in
        for x in 0..<w {
            let v = hdr(x * step, y * step), b = linear(base.px(x * step, y * step))
            let i = (y * w + x) * 4
            hb[i] = Float16(v.x); hb[i + 1] = Float16(v.y); hb[i + 2] = Float16(v.z)
            sb[i] = Float16(b.x); sb[i + 1] = Float16(b.y); sb[i + 2] = Float16(b.z)
        }
    }
    let hdrBuf = Array(hb), sdrBuf = Array(sb)
    var peak = 1.0
    for i in Swift.stride(from: 0, to: hdrBuf.count, by: 4 * 97) {
        peak = max(peak, 0.2627 * Double(hdrBuf[i]) + 0.6780 * Double(hdrBuf[i + 1]) + 0.0593 * Double(hdrBuf[i + 2]))
    }
    let p = Pipeline(WorkingSpace.all[2])
    func image(_ buf: [Float16]) -> CIImage {
        let data = buf.withUnsafeBufferPointer { Data(buffer: $0) }
        let info = CGImageAlphaInfo.last.rawValue | CGBitmapInfo.floatComponents.rawValue | CGImageByteOrderInfo.order16Little.rawValue
        return CIImage(cgImage: CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: p.ws.cg,
                                        bitmapInfo: CGBitmapInfo(rawValue: info), provider: CGDataProvider(data: data as CFData)!,
                                        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!)
    }
    let hdrImage = image(hdrBuf), sdrImage = image(sdrBuf)   // 底图同样自己线性化
    let fileHeadroom = Float(pow(2, max(meta.baseHeadroom, meta.alternateHeadroom)))   // 两个字段可能写反，取较大者
    let outURL = env.out.appendingPathComponent("gainmap-tiff/\(url.deletingPathExtension().lastPathComponent)_reconstructed_hdr\(full ? "_full" : "").jpg")
    try p.writeJPEG(sdrImage, to: outURL, colorSpace: full ? CGColorSpace(name: CGColorSpace.displayP3)! : sRGB,
                    hdr: hdrImage.settingContentHeadroom(full ? fileHeadroom : Float(min(peak, Double(fileHeadroom)))), rgbGainMap: true)
    print("已写出 \(outURL.path)（\(full ? "全分辨率，headroom \(f2(Double(fileHeadroom)))，P3 底图" : "1/4 分辨率")，峰值约 \(f2(peak))×）")

    // 3) 和 Lightroom 自己的 HDR JPEG（Apple 展开 gain map）在同一块全分辨率区域逐像素比较
    if let reference {
        let ref = p.load(reference)
        let crop = CGRect(x: 3000, y: 2000, width: 1024, height: 768)        // 左上原点
        let ciRect = CGRect(x: crop.minX, y: ref.extent.height - crop.maxY, width: crop.width, height: crop.height)
        let rf = p.renderFloat(ref, rect: ciRect)
        var rel: [Double] = [], relHi: [Double] = []
        for y in 0..<Int(crop.height) { for x in 0..<Int(crop.width) {
            let a = hdr(Int(crop.minX) + x, Int(crop.minY) + y)
            let ya = (Spaces.linear2020.toXYZ * a).y, yb = (Spaces.linear2020.toXYZ * rf.rgb(x, y)).y
            guard yb > 0.01 else { continue }
            rel.append(abs(ya / yb - 1))
            if yb > 1 { relHi.append(abs(ya / yb - 1)) }
        } }
        let s = Stats(rel), sh = Stats(relHi)
        print("对比 Lightroom HDR JPEG（\(reference.lastPathComponent)，Apple 展开 gain map，全分辨率 1024×768 区域）：")
        print("   亮度相对误差 中位 \(f4(s.median)) / P95 \(f4(s.p95))；高光（\(relHi.count) 点）中位 \(f4(sh.median)) / P95 \(f4(sh.p95))")
    }
}
