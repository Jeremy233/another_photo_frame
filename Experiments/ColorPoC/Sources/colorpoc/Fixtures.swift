import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

// 测试图定义。测量代码复用这里的定义来计算"真值"，因此不需要另存 JSON。

struct Patch {
    var rect: CGRect      // 在源图（显示方向）中的像素位置
    var xyz: V3           // 真值，D65，Y=1 为 SDR 参考白
}

enum Chart {
    static let w = 960, h = 640, cell = 80, cols = 12, rows = 8

    static let colorChecker: [(Int, Int, Int)] = [
        (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
        (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
        (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
        (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
    ]

    /// 96 个 sRGB 色域内的颜色（sRGB 编码值，连续值）。
    static let colors: [V3] = {
        var c = colorChecker.map { V3(Double($0.0), Double($0.1), Double($0.2)) / 255 }
        for g in [0.0, 0.02, 0.05, 0.1, 0.2, 0.3, 0.45, 0.6, 0.75, 0.9, 0.98, 1.0] { c.append(V3(g, g, g)) }
        for s in [1.0, 0.6] {
            c += [V3(s, 0, 0), V3(0, s, 0), V3(0, 0, s), V3(0, s, s), V3(s, 0, s), V3(s, s, 0)]
        }
        var seed: UInt64 = 0x5EED
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        while c.count < cols * rows { c.append(V3(rnd(), rnd(), rnd())) }
        return c
    }()

    static var patches: [Patch] {
        colors.enumerated().map { i, c in
            Patch(rect: CGRect(x: (i % cols) * cell, y: (i / cols) * cell, width: cell, height: cell),
                  xyz: Spaces.srgb.xyz(fromEncoded: c))
        }
    }

    static func render(_ patches: [Patch], w: Int = w, h: Int = h, encode: (V3) -> V3) -> FImage {
        var img = FImage(w: w, h: h, fill: 1)
        for p in patches {
            let e = encode(p.xyz)
            for y in Int(p.rect.minY)..<Int(p.rect.maxY) {
                for x in Int(p.rect.minX)..<Int(p.rect.maxX) {
                    img[x, y] = SIMD4(Float(e.x), Float(e.y), Float(e.z), 1)
                }
            }
        }
        return img
    }
}

/// 广色域图：在某个宽色域空间里取 {0, .35, .7, 1}³ 的立方体网格加若干灰阶，
/// 其中不少颜色超出 sRGB / P3 / Rec.2020，用来统计中途截断。
enum WideChart {
    static func patches(in space: RGBSpace) -> [Patch] {
        let levels = [0.0, 0.35, 0.7, 1.0]
        var enc: [V3] = []
        for r in levels { for g in levels { for b in levels { enc.append(V3(r, g, b)) } } }
        for i in 0..<32 { let v = Double(i) / 31; enc.append(V3(v, v * 0.5, 1 - v)) }
        return enc.enumerated().map { i, e in
            Patch(rect: CGRect(x: (i % Chart.cols) * Chart.cell, y: (i / Chart.cols) * Chart.cell,
                               width: Chart.cell, height: Chart.cell), xyz: space.xyz(fromEncoded: e))
        }
    }
}

/// HDR 场景：线性值相对 SDR 参考白（Y=1）。
enum HDRScene {
    static let w = 960, h = 640, cell = 80
    static let neutralLevels: [Double] = [0.05, 0.18, 0.5, 0.75, 1.0, 1.5, 2, 3, 4, 5, 6, 8]
    static let peak = 8.0
    static let rampTop = 480, rampMid = 560

    /// 第 0 行中性灰阶（含高光）；第 1 行彩色高光；第 2–5 行 SDR 色卡。
    static var patches: [Patch] {
        var p: [Patch] = []
        func add(_ col: Int, _ row: Int, _ xyz: V3) {
            p.append(Patch(rect: CGRect(x: col * cell, y: row * cell, width: cell, height: cell), xyz: xyz))
        }
        for (i, y) in neutralLevels.enumerated() { add(i, 0, whiteD65 * y) }
        let colored: [(RGBSpace, V3, Double)] = [
            (Spaces.linearSRGB, V3(1, 0, 0), 2), (Spaces.linearP3, V3(1, 0, 0), 2), (Spaces.linear2020, V3(1, 0, 0), 2),
            (Spaces.linearSRGB, V3(0, 1, 0), 3), (Spaces.linearP3, V3(0, 1, 0), 3), (Spaces.linear2020, V3(0, 1, 0), 1),
            (Spaces.linearSRGB, V3(0, 0, 1), 4), (Spaces.linearP3, V3(1, 0.5, 0), 4), (Spaces.linear2020, V3(0, 0.3, 1), 2),
            (Spaces.linearSRGB, V3(1, 0.8, 0.6), 6), (Spaces.linearP3, V3(0, 1, 1), 1.5), (Spaces.linear2020, V3(1, 0, 1), 1),
        ]
        for (i, c) in colored.enumerated() { add(i, 1, c.0.toXYZ * (c.1 * c.2)) }
        for i in 0..<24 {
            let c = Chart.colorChecker[i]
            add(i % 12, 2 + i / 12, Spaces.srgb.xyz(fromEncoded: V3(Double(c.0), Double(c.1), Double(c.2)) / 255))
        }
        for i in 0..<24 { add(i % 12, 4 + i / 12, whiteD65 * (Double(i + 1) / 24 * 0.9)) }
        return p
    }

    /// 底部两条渐变：0→peak 中性，0→peak 橙色（Display P3 原色混合）。
    static func xyz(x: Int, y: Int) -> V3? {
        guard y >= rampTop else { return nil }
        let t = Double(x) / Double(w - 1) * peak
        if y < rampMid { return whiteD65 * t }
        return Spaces.p3M * (V3(1, 0.45, 0.05) * t)
    }

    static func groundTruth() -> [V3] {
        var out = [V3](repeating: V3(0, 0, 0), count: w * h)
        for p in patches {
            for y in Int(p.rect.minY)..<Int(p.rect.maxY) { for x in Int(p.rect.minX)..<Int(p.rect.maxX) { out[y * w + x] = p.xyz } }
        }
        for y in rampTop..<h { for x in 0..<w { out[y * w + x] = xyz(x: x, y: y)! } }
        return out
    }

    static func render(_ toEncoded: (V3) -> V3) -> FImage {
        let gt = groundTruth()
        var img = FImage(w: w, h: h, fill: 1)
        for i in 0..<(w * h) {
            let e = toEncoded(gt[i])
            img.px[i * 4] = Float(e.x); img.px[i * 4 + 1] = Float(e.y); img.px[i * 4 + 2] = Float(e.z)
        }
        return img
    }
}

enum Orientation {
    static let w = 300, h = 200
    static let quadrants: [(Int, Int, Int)] = [(220, 40, 40), (40, 180, 60), (40, 60, 200), (230, 200, 40)] // TL TR BL BR

    static func canonical(_ x: Int, _ y: Int) -> V3 {
        let q = (y < h / 2 ? 0 : 2) + (x < w / 2 ? 0 : 1)
        let c = quadrants[q]
        return V3(Double(c.0), Double(c.1), Double(c.2)) / 255
    }

    /// 生成存储像素：按 EXIF 方向 o 显示后应得到 canonical 图。
    static func stored(_ o: Int) -> FImage {
        let (sw, sh) = (o == 6 || o == 8) ? (h, w) : (w, h)
        var img = FImage(w: sw, h: sh, fill: 1)
        for sy in 0..<sh {
            for sx in 0..<sw {
                let c: V3
                switch o {
                case 3: c = canonical(w - 1 - sx, h - 1 - sy)
                case 6: c = canonical(w - 1 - sy, sx)
                case 8: c = canonical(sy, h - 1 - sx)
                default: c = canonical(sx, sy)
                }
                img[sx, sy] = SIMD4(Float(c.x), Float(c.y), Float(c.z), 1)
            }
        }
        return img
    }
}

enum Watermark {
    static let w = 400, h = 160
    /// (覆盖率, 直通 RGB)：在 8×8 超采样下计算边缘覆盖率。透明像素 RGB 故意写成黑色。
    static func sample(_ fx: Double, _ fy: Double) -> (Double, V3) {
        let white = V3(1, 1, 1)
        let d = hypot(fx - 80, fy - 80)
        if d <= 60 && d >= 40 { return (1, white) }
        if fx >= 160.3 && fx < 379.6 && fy >= 30.4 && fy < 60.7 { return (1, white) }
        if fx >= 160 && fx < 260 && fy >= 80 && fy < 140 { return (128.0 / 255, white) }
        if fx >= 280 && fx < 380 && fy >= 80 && fy < 140 { return (128.0 / 255, V3(200, 30, 30) / 255) }
        return (0, V3(0, 0, 0))
    }

    static func render() -> FImage {
        var img = FImage(w: w, h: h, fill: 0)
        for y in 0..<h {
            for x in 0..<w {
                var a = 0.0, c = V3(0, 0, 0)
                for j in 0..<8 { for i in 0..<8 {
                    let (sa, sc) = sample(Double(x) + (Double(i) + 0.5) / 8, Double(y) + (Double(j) + 0.5) / 8)
                    a += sa / 64; c += sc * (sa / 64)
                } }
                let rgb = a > 0 ? c / a : V3(0, 0, 0)
                img[x, y] = SIMD4(Float(rgb.x), Float(rgb.y), Float(rgb.z), Float(a))
            }
        }
        return img
    }
}

enum Gradient {
    static let w = 4096, h = 64
    /// ProPhoto 编码 0→1 中性渐变；dark 版本为 sRGB 编码 0→0.2。
    static func render(maxValue: Double) -> FImage {
        var img = FImage(w: w, h: h, fill: 1)
        for x in 0..<w {
            let v = Float(Double(x) / Double(w - 1) * maxValue)
            for y in 0..<h { img[x, y] = SIMD4(v, v, v, 1) }
        }
        return img
    }
}

// MARK: - 生成

struct FixtureSet {
    let dir: URL
    func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static let iccVariants: [(id: String, space: RGBSpace, cg: CFString)] = [
        ("srgb", Spaces.srgb, CGColorSpace.sRGB),
        ("adobergb", Spaces.adobeRGB, CGColorSpace.adobeRGB1998),
        ("p3", Spaces.displayP3, CGColorSpace.displayP3),
        ("prophoto", Spaces.prophoto, CGColorSpace.rommrgb),
    ]

    func generate() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jpegQ: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        let lzw: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]

        // 1. 同一张色卡分别嵌入四种 ICC：8-bit JPEG Q100 与 16-bit TIFF。
        for v in Self.iccVariants {
            let img = Chart.render(Chart.patches) { v.space.encoded(fromXYZ: $0) }
            let cs = CGColorSpace(name: v.cg)!
            try writeImage(makeCGImage(img, format: .u8, colorSpace: cs, alpha: false), to: url("chart_\(v.id).jpg"), type: .jpeg, properties: jpegQ)
            try writeImage(makeCGImage(img, format: .u16, colorSpace: cs, alpha: false), to: url("chart_\(v.id)_16.tif"), type: .tiff, properties: lzw)
        }

        // 2. 无 ICC：sRGB 数值、以及"P3 数值但丢了 ICC"。
        // 坑：即使 CGImage 用 DeviceRGB，ImageIO 写 PNG/JPEG 时仍会自动嵌入 sRGB ICC，
        // 所以先正常写出，再从文件里剥掉颜色描述块。
        let noProfile = CGColorSpaceCreateDeviceRGB()
        let srgbValues = makeCGImage(Chart.render(Chart.patches) { Spaces.srgb.encoded(fromXYZ: $0) }, format: .u8, colorSpace: noProfile, alpha: false)
        try writeImage(srgbValues, to: url("chart_noicc.png"), type: .png)
        try stripPNGColorChunks(url("chart_noicc.png"))
        try writeImage(srgbValues, to: url("chart_noicc.jpg"), type: .jpeg, properties: jpegQ)
        try stripJPEGICC(url("chart_noicc.jpg"))
        try writeImage(makeCGImage(Chart.render(Chart.patches) { Spaces.displayP3.encoded(fromXYZ: $0) }, format: .u8, colorSpace: noProfile, alpha: false),
                       to: url("chart_p3values_noicc.png"), type: .png)
        try stripPNGColorChunks(url("chart_p3values_noicc.png"))

        // 3. 广色域：ProPhoto 与 P3 16-bit TIFF。
        try writeImage(makeCGImage(Chart.render(WideChart.patches(in: Spaces.prophoto)) { Spaces.prophoto.encoded(fromXYZ: $0) },
                                   format: .u16, colorSpace: CGColorSpace(name: CGColorSpace.rommrgb)!, alpha: false),
                       to: url("wide_prophoto_16.tif"), type: .tiff, properties: lzw)
        try writeImage(makeCGImage(Chart.render(WideChart.patches(in: Spaces.displayP3)) { Spaces.displayP3.encoded(fromXYZ: $0) },
                                   format: .u16, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, alpha: false),
                       to: url("wide_p3_16.tif"), type: .tiff, properties: lzw)

        // 4. 16-bit 渐变。
        try writeImage(makeCGImage(Gradient.render(maxValue: 1), format: .u16, colorSpace: CGColorSpace(name: CGColorSpace.rommrgb)!, alpha: false),
                       to: url("gradient_prophoto_16.tif"), type: .tiff, properties: lzw)
        try writeImage(makeCGImage(Gradient.render(maxValue: 0.2), format: .u16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: false),
                       to: url("gradient_dark_srgb_16.tif"), type: .tiff, properties: lzw)

        // 5. 透明水印 PNG（直通 alpha，透明处 RGB=0）。
        try writeImage(makeCGImage(Watermark.render(), format: .u8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: true),
                       to: url("watermark_alpha.png"), type: .png)

        // 6. EXIF 方向。
        for o in [1, 3, 6, 8] {
            try writeImage(makeCGImage(Orientation.stored(o), format: .u8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: false),
                           to: url("orientation_\(o).jpg"), type: .jpeg,
                           properties: [kCGImageDestinationLossyCompressionQuality: 1.0, kCGImagePropertyOrientation: o])
        }

        // 7. HDR 样本。
        // 7a. float TIFF：extended linear Rec.2020，32-bit float。
        let lin2020 = HDRScene.render { Spaces.linear2020.fromXYZ * $0 }
        try writeImage(makeCGImage(lin2020, format: .float32, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!, alpha: false),
                       to: url("hdr_float_linear2020.tif"), type: .tiff, properties: lzw)
        // 7b. PQ PNG：Rec.2020 原色 + PQ，SDR 参考白 = 203 nits（ITU-R BT.2408）。
        let pq = HDRScene.render { xyz in
            let l = Spaces.linear2020.fromXYZ * xyz
            return V3(PQ.encode(nits: l.x * 203), PQ.encode(nits: l.y * 203), PQ.encode(nits: l.z * 203))
        }
        try writeImage(makeCGImage(pq, format: .u16, colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!, alpha: false),
                       to: url("hdr_pq2020_203nit.png"), type: .png)
        // 7c. gain map JPEG：由 ImageIO 从 extended linear P3 half-float 图编码为 ISO 21496-1 gain map。
        // 坑：CGImage 必须带 content headroom，否则 ImageIO 把它当 SDR，高光被静默截断（见 P10）。
        let linP3 = HDRScene.render { Spaces.linearP3.fromXYZ * $0 }
        let linP3CG = makeCGImage(linP3, format: .half, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!, alpha: false)
        try writeImage(CGImageCreateCopyWithContentHeadroom(Float(HDRScene.peak), linP3CG)!,
                       to: url("hdr_gainmap.jpg"), type: .jpeg,
                       properties: [kCGImageDestinationLossyCompressionQuality: 1.0,
                                    kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap])
    }
}

// MARK: - 剥离颜色描述

/// 删除 PNG 的 iCCP / sRGB / gAMA / cHRM / cICP 块。
func stripPNGColorChunks(_ url: URL) throws {
    let d = try Data(contentsOf: url)
    var out = Data(d.prefix(8))
    var i = 8
    while i + 8 <= d.count {
        let len = d[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
        let type = String(bytes: d[i + 4..<i + 8], encoding: .ascii) ?? ""
        let end = i + 12 + len
        if !["iCCP", "sRGB", "gAMA", "cHRM", "cICP"].contains(type) { out.append(d[i..<end]) }
        i = end
    }
    try out.write(to: url)
}

/// 删除 JPEG 中带 ICC_PROFILE 的 APP2 段，以及 EXIF(APP1) 和 Photoshop IRB(APP13)：
/// ImageIO 写 sRGB JPEG 时会在 EXIF 里写 ColorSpace=1，读回时 profileName 仍显示 sRGB。
func stripJPEGICC(_ url: URL) throws {
    let d = try Data(contentsOf: url)
    var out = Data(d.prefix(2))
    var i = 2
    while i + 4 <= d.count {
        let marker = d[i + 1]
        if marker == 0xDA { out.append(d[i...]); break }   // SOS 之后是熵编码数据，原样保留
        let len = Int(d[i + 2]) << 8 | Int(d[i + 3])
        let seg = d[i..<i + 2 + len]
        let isICC = marker == 0xE2 && String(bytes: d[i + 4..<min(i + 15, d.count)], encoding: .ascii) == "ICC_PROFILE"
        if !isICC && marker != 0xE1 && marker != 0xED { out.append(seg) }
        i += 2 + len
    }
    try out.write(to: url)
}
