import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd

// MARK: - 1. 四种 ICC 的色卡 → sRGB 输出的 ΔE2000

func runChart(_ env: Env, _ R: Results) throws {
    R.line("## 1. 色卡：四种 ICC 输入 → sRGB 输出的 ΔE2000")
    R.line()
    R.line("画布 1080×1350，留白 90，色卡 960×640 Lanczos 缩放到 0.9375，背景 #FAFAF8，叠加水印。ΔE 为 96 个色块内部像素对真值（色块定义的 sRGB 值）。")
    R.line()
    let inputs = ["chart_srgb.jpg", "chart_adobergb.jpg", "chart_p3.jpg", "chart_prophoto.jpg",
                  "chart_srgb_16.tif", "chart_adobergb_16.tif", "chart_p3_16.tif", "chart_prophoto_16.tif",
                  "chart_noicc.png", "chart_noicc.jpg", "chart_p3values_noicc.png"]
    var rows: [[String]] = []
    var all: [String: [String: Double]] = [:]
    for ws in WorkingSpace.all {
        let p = Pipeline(ws)
        for name in inputs {
            let photo = p.load(env.fixtures.url(name))
            let (comp, pl, wmRect) = composeMain(p, photo: photo, env: env)
            let base = (name as NSString).deletingPathExtension
            let pngURL = env.outURL(ws.id, "chart/\(base).png"), jpgURL = env.outURL(ws.id, "chart/\(base).jpg")
            try p.writePNG(comp, to: pngURL)
            try p.writeJPEG(comp, to: jpgURL)
            let (_, png, pngInfo) = decodeRaw(pngURL)!
            let (_, jpg, _) = decodeRaw(jpgURL)!
            let dePNG = Stats(chartDeltaE(png, patches: Chart.patches, placement: pl))
            let deJPG = Stats(chartDeltaE(jpg, patches: Chart.patches, placement: pl))
            let photoRect = CGRect(origin: pl.origin, size: pl.size)
            let bgPNG = backgroundCheck(png, photo: photoRect, wm: wmRect)
            let bgJPG = backgroundCheck(jpg, photo: photoRect, wm: wmRect)
            // 编码器是否又做了一次转换：CI 直接渲染的 RGBA8 与 PNG 文件里的字节逐一比较。
            let direct = p.renderRGBA8(comp, rect: CGRect(origin: .zero, size: canvasIG))
            var encDiff = 0
            for i in 0..<direct.px.count where i % 4 != 3 { encDiff = max(encDiff, abs(code8(direct.px[i]) - code8(png.px[i]))) }
            let srcProfile = fileInfo(env.fixtures.url(name))?.profileName ?? "无"
            rows.append([ws.id, name, srcProfile, csName(photo.colorSpace),
                         f2(dePNG.median), f2(dePNG.p95), f2(dePNG.max), f2(deJPG.median), f2(deJPG.p95),
                         "\(bgPNG.mismatch)/\(bgPNG.total)", "\(bgJPG.maxDev)", "\(encDiff)", pngInfo.colorSpace])
            all["\(ws.id)/\(name)"] = ["pngMedian": dePNG.median, "pngP95": dePNG.p95, "pngMax": dePNG.max,
                                       "jpgMedian": deJPG.median, "jpgP95": deJPG.p95, "jpgMax": deJPG.max,
                                       "bgMismatchPNG": Double(bgPNG.mismatch), "bgMaxDevJPG": Double(bgJPG.maxDev),
                                       "encoderMaxDiff": Double(encDiff)]
        }
    }
    R.table(["工作空间", "输入", "文件 ICC（ImageIO）", "CIImage.colorSpace", "PNG ΔE 中位", "PNG ΔE P95", "PNG ΔE max",
             "JPEG ΔE 中位", "JPEG ΔE P95", "PNG 背景≠(250,250,248)", "JPEG 背景最大偏差", "CI 直出 vs PNG 文件最大差", "输出标签"], rows)
    R.set("chart", all)

    R.line("### 1.1 照片与背景交界：缩放前是否 clampedToExtent")
    R.line()
    R.line("外沿 = 照片外 3px 背景带相对 (250,250,248) 的最大码值偏差；内沿 = 照片内 3px 相对向内 8px 处像素的最大码值偏差（色卡边缘色块为纯色，理想为 0）。")
    R.line()
    var edgeRows: [[String]] = []
    for ws in WorkingSpace.all {
        let p = Pipeline(ws)
        for clamp in [false, true] {
            let photo = p.load(env.fixtures.url("chart_srgb_16.tif"))
            let (comp, pl, _) = composeMain(p, photo: photo, env: env, clampEdges: clamp)
            let url = env.outURL(ws.id, "chart/edge_\(clamp ? "clamp" : "transparent").png")
            try p.writePNG(comp, to: url)
            let img = decodeRaw(url)!.1
            edgeRows.append([ws.id, clamp ? "clampedToExtent → Lanczos → 裁到整数尺寸" : "直接 Lanczos（边外为透明）",
                             "\(Int(pl.size.width))×\(Int(pl.size.height))", { let e = edgeBandDeviation(img, photo: CGRect(origin: pl.origin, size: pl.size)); return "\(e.outer) / \(e.inner)" }()])
        }
    }
    R.table(["工作空间", "缩放写法", "照片尺寸", "外沿 / 内沿 最大偏差"], edgeRows)
}

// MARK: - 2. 广色域：中途截断统计

func runWide(_ env: Env, _ R: Results) throws {
    R.line("## 2. 广色域与中途截断")
    R.line()
    R.line("统计色块内部像素：真值在该空间里超出 [0,1]（需要 extended range）的像素数，以及其中被压回 [0,1] 的像素数（= 被截断）。")
    R.line("S1 = 解码后直接渲染到工作空间 RGBAf；S2 = 缩放 + 合成后的画布；CG = ImageIO 解码的 CGImage 画进工作空间 half-float CGContext。")
    R.line()
    var rows: [[String]] = []
    var json: [String: Any] = [:]
    for (file, space) in [("wide_prophoto_16.tif", Spaces.prophoto), ("wide_p3_16.tif", Spaces.displayP3)] {
        let patches = WideChart.patches(in: space)
        for ws in WorkingSpace.all {
            let p = Pipeline(ws)
            let img = p.load(env.fixtures.url(file))
            let s1 = clipCount(p.renderFloat(img, rect: img.extent),
                               expected: expectedPatchValue(patches, ws: ws, placement: nil, inset: 2),
                               region: (0..<Chart.w, 0..<Chart.h))
            let (comp, pl, _) = composeMain(p, photo: img, env: env)
            let canvas = p.renderFloat(comp, rect: CGRect(origin: .zero, size: canvasIG))
            let s2 = clipCount(canvas, expected: expectedPatchValue(patches, ws: ws, placement: pl, inset: 6),
                               region: (0..<Int(canvasIG.width), 0..<Int(canvasIG.height)))
            let cg = decodeRaw(env.fixtures.url(file))!.0
            let cgImg = cgDraw(cg, into: ws.cg)
            let s3 = clipCount(cgImg, expected: expectedPatchValue(patches, ws: ws, placement: nil, inset: 2),
                               region: (0..<Chart.w, 0..<Chart.h))
            // SDR 输出：超出 sRGB 的色块如何映射（逐通道截断 → ΔE）
            let outURL = env.outURL(ws.id, "wide/\((file as NSString).deletingPathExtension).png")
            try p.writePNG(comp, to: outURL)
            let png = decodeRaw(outURL)!.1
            var oog: [Double] = [], inG: [Double] = []
            for patch in patches {
                let lin = Spaces.linearSRGB.fromXYZ * patch.xyz
                let r = pl.map(patch.rect).inset(6).pixelRange
                let obs = png.rgb((r.xs.lowerBound + r.xs.upperBound) / 2, (r.ys.lowerBound + r.ys.upperBound) / 2)
                let de = deltaE2000(lab(fromXYZ: Spaces.srgb.xyz(fromEncoded: obs)), lab(fromXYZ: patch.xyz))
                if isInGamut(lin) { inG.append(de) } else { oog.append(de) }
            }
            let si = Stats(inG), so = Stats(oog)
            rows.append([file, ws.id, "\(s1.expectedOutOfRange)", "\(s1.clipped)", "\(s2.expectedOutOfRange)", "\(s2.clipped)",
                         "\(s3.clipped)", f4(s1.maxErrInRange),
                         "\(inG.count): \(f2(si.median)) / \(f2(si.max))", "\(oog.count): \(f2(so.median)) / \(f2(so.max))"])
            json["\(file)/\(ws.id)"] = ["s1Expected": s1.expectedOutOfRange, "s1Clipped": s1.clipped,
                                        "s2Expected": s2.expectedOutOfRange, "s2Clipped": s2.clipped, "cgClipped": s3.clipped,
                                        "s1MaxErrInRange": s1.maxErrInRange]
        }
    }
    R.table(["输入", "工作空间", "S1 需 extended 像素", "S1 被截断", "S2 需 extended 像素", "S2 被截断", "CG 被截断",
             "S1 域内最大误差", "sRGB 输出·域内色块数: ΔE 中位/max", "sRGB 输出·域外色块数: ΔE 中位/max"], rows)
    R.set("wide", json)
}

// MARK: - 3. 16-bit 渐变断层

struct BandingMetrics { var distinctObs: Int; var distinctIdeal: Int; var maxErr: Int; var maxStep: Int; var nonMonotonic: Int }

func banding(_ row: [Int], ideal: [Int]) -> BandingMetrics {
    var maxErr = 0, maxStep = 0, nonMono = 0
    for i in 0..<row.count {
        maxErr = max(maxErr, abs(row[i] - ideal[i]))
        if i > 0 {
            maxStep = max(maxStep, row[i] - row[i - 1])
            if row[i] < row[i - 1] { nonMono += 1 }
        }
    }
    return BandingMetrics(distinctObs: Set(row).count, distinctIdeal: Set(ideal).count, maxErr: maxErr, maxStep: maxStep, nonMonotonic: nonMono)
}

func runGradient(_ env: Env, _ R: Results) throws {
    R.line("## 3. 16-bit 渐变断层")
    R.line()
    R.line("渐变 4096 px 宽，不缩放（scale = 1），取中间一行。理想值由参考数学直接从源值算到 sRGB。")
    R.line("解码并转入工作空间后用 insertingIntermediate() 强制落一次中间缓冲，这样工作格式（RGBAh/RGBAf）才真正参与（否则 CI 会把整条链合成一个 kernel，不落中间缓冲）。")
    R.line("“级数”= 输出中不同码值的个数；8-bit 中间格式会让 16-bit 输出的级数掉到 ≤256。带“反例”的行是故意制造的 8-bit 中间结果，用来证明检测有效。")
    R.line()
    var rows: [[String]] = []
    let cases: [(String, RGBSpace, Double)] = [("gradient_prophoto_16.tif", Spaces.prophoto, 1), ("gradient_dark_srgb_16.tif", Spaces.srgb, 0.2)]
    var variants: [(WorkingSpace, CIFormat, String)] = []
    for ws in WorkingSpace.all { variants.append((ws, .RGBAh, "RGBAh")); variants.append((ws, .RGBAf, "RGBAf")) }
    variants.append((WorkingSpace.all[0], .RGBA8, "RGBA8 线性中间缓冲（反例）"))
    variants.append((WorkingSpace.all[0], .RGBAh, "8-bit sRGB CGImage 中转（反例）"))
    var json: [String: Any] = [:]
    for (file, space, maxV) in cases {
        let src = decodeRaw(env.fixtures.url(file))!.1
        let ideal = (0..<Gradient.w).map { x -> Double in
            let v = Double(src[x, 0].x)
            return Spaces.srgb.encoded(fromXYZ: space.xyz(fromEncoded: V3(v, v, v))).x
        }
        _ = maxV
        for (ws, fmt, label) in variants {
            let p = Pipeline(ws, workingFormat: fmt)
            var img = p.load(env.fixtures.url(file)).insertingIntermediate(cache: false)
            if label.hasPrefix("8-bit sRGB CGImage") {
                img = CIImage(cgImage: p.ctx.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: sRGB)!)
            }
            let canvas = CGSize(width: Gradient.w + 32, height: Gradient.h + 32)
            let (placed, pl) = p.fit(img, canvas: canvas, margin: 16)
            let comp = placed.composited(over: p.background(canvas, srgb8: bgSRGB8)).cropped(to: CGRect(origin: .zero, size: canvas))
            let base = "gradient/\((file as NSString).deletingPathExtension)_\(label.hasPrefix("8-bit") ? "cg8" : fmt == .RGBAh ? "h" : fmt == .RGBAf ? "f" : "8")"
            let u8 = env.outURL(ws.id, base + ".png"), u16 = env.outURL(ws.id, base + "_16.png")
            try p.writePNG(comp, to: u8)
            try p.writePNG(comp, to: u16, sixteen: true)
            let y = Int(pl.origin.y) + Gradient.h / 2, x0 = Int(pl.origin.x)
            let o8 = decodeRaw(u8)!.1, o16 = decodeRaw(u16)!.1
            let r8 = (0..<Gradient.w).map { Int((o8[x0 + $0, y].y * 255).rounded()) }
            let r16 = (0..<Gradient.w).map { Int((o16[x0 + $0, y].y * 65535).rounded()) }
            let b8 = banding(r8, ideal: ideal.map { Int(($0 * 255).rounded()) })
            let b16 = banding(r16, ideal: ideal.map { Int(($0 * 65535).rounded()) })
            rows.append([file, ws.id, label, "\(b8.distinctObs)/\(b8.distinctIdeal)", "\(b8.maxStep)", "\(b8.maxErr)", "\(b8.nonMonotonic)",
                         "\(b16.distinctObs)/\(b16.distinctIdeal)", "\(b16.maxStep)", "\(b16.maxErr)", "\(b16.nonMonotonic)"])
            json["\(file)/\(ws.id)/\(label)"] = ["levels8": b8.distinctObs, "levels8Ideal": b8.distinctIdeal, "maxStep8": b8.maxStep,
                                                 "maxErr8": b8.maxErr, "levels16": b16.distinctObs, "levels16Ideal": b16.distinctIdeal,
                                                 "maxErr16": b16.maxErr, "nonMono16": b16.nonMonotonic]
        }
    }
    R.table(["输入", "工作空间", "中间格式", "8-bit 级数 实/理想", "8-bit 最大台阶", "8-bit 最大误差", "8-bit 回退",
             "16-bit 级数 实/理想", "16-bit 最大台阶", "16-bit 最大误差", "16-bit 回退"], rows)
    R.set("gradient", json)
}

// MARK: - 4. 透明边缘

struct HaloMetrics { var pixels = 0; var dark = 0; var bright = 0; var maxDark = 0; var maxBright = 0; var white50: Int = -1; var red50: (Int, Int, Int) = (-1, -1, -1) }

func haloCheck(_ img: FImage, bg: (Int, Int, Int), wmOrigin: CGPoint, scale: Double) -> HaloMetrics {
    var m = HaloMetrics()
    let w = Int((Double(Watermark.w) * scale).rounded(.up)), h = Int((Double(Watermark.h) * scale).rounded(.up))
    for y in Int(wmOrigin.y) - 2..<Int(wmOrigin.y) + h + 2 {
        for x in Int(wmOrigin.x) - 2..<Int(wmOrigin.x) + w + 2 {
            let sx = (Double(x) + 0.5 - wmOrigin.x) / scale, sy = (Double(y) + 0.5 - wmOrigin.y) / scale
            // 红色块附近（含缩放核半径）前景色为红，其余为白
            let isRed = sx >= 270 && sx < 390 && sy >= 70 && sy < 150
            let fg = isRed ? (200, 30, 30) : (255, 255, 255)
            let p = img[x, y]
            let o = [code8(p.x), code8(p.y), code8(p.z)]
            let b = [bg.0, bg.1, bg.2], f = [fg.0, fg.1, fg.2]
            m.pixels += 1
            var d = false, br = false
            for c in 0..<3 {
                if o[c] < min(b[c], f[c]) - 1 { d = true; m.maxDark = max(m.maxDark, min(b[c], f[c]) - o[c]) }
                if o[c] > max(b[c], f[c]) + 1 { br = true; m.maxBright = max(m.maxBright, o[c] - max(b[c], f[c])) }
            }
            if d { m.dark += 1 }
            if br { m.bright += 1 }
        }
    }
    let wx = Int(wmOrigin.x + 210 * scale), wy = Int(wmOrigin.y + 110 * scale)
    m.white50 = code8(img[wx, wy].x)
    let rx = Int(wmOrigin.x + 330 * scale)
    let rp = img[rx, wy]
    m.red50 = (code8(rp.x), code8(rp.y), code8(rp.z))
    return m
}

func idealOver(_ fg: (Int, Int, Int), _ a: Double, _ bg: (Int, Int, Int), linear: Bool) -> (Int, Int, Int) {
    func ch(_ f: Int, _ b: Int) -> Int {
        let fe = Double(f) / 255, be = Double(b) / 255
        let v = linear ? TRC.srgb.encode(a * TRC.srgb.decode(fe) + (1 - a) * TRC.srgb.decode(be)) : a * fe + (1 - a) * be
        return Int((v * 255).rounded())
    }
    return (ch(fg.0, bg.0), ch(fg.1, bg.1), ch(fg.2, bg.2))
}

func runAlpha(_ env: Env, _ R: Results) throws {
    R.line("## 4. 透明边缘（黑边 / 白边）与合成所在的域")
    R.line()
    R.line("水印 PNG 为直通 alpha，透明像素 RGB 故意为黑色（最容易出黑边）。缩放 0.73 后叠到深色 (32,32,32) 与 #FAFAF8 背景。")
    R.line("“黑边/白边像素”= 任一通道超出 [min(背景,前景), max(背景,前景)] ±1 的像素。50% 白块的理想值：线性光合成 vs gamma 空间合成。")
    R.line()
    let scale = 0.73, origin = CGPoint(x: 50, y: 50), canvas = CGSize(width: 400, height: 220)
    var rows: [[String]] = []
    let a = 128.0 / 255
    for bg in [(32, 32, 32), bgSRGB8] {
        let linW = idealOver((255, 255, 255), a, bg, linear: true).0, gamW = idealOver((255, 255, 255), a, bg, linear: false).0
        let linR = idealOver((200, 30, 30), a, bg, linear: true), gamR = idealOver((200, 30, 30), a, bg, linear: false)
        for ws in WorkingSpace.all {
            let p = Pipeline(ws)
            for lanczos in [true, false] {
                let src = p.load(env.fixtures.url("watermark_alpha.png"))
                let wm = lanczos ? p.scaled(src, by: scale)
                                 : src.samplingLinear().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let comp = p.place(wm, topLeft: origin, canvas: canvas).composited(over: p.background(canvas, srgb8: bg))
                    .cropped(to: CGRect(origin: .zero, size: canvas))
                let url = env.outURL(ws.id, "alpha/watermark_on_\(bg.0)_\(lanczos ? "lanczos" : "bilinear").png")
                try p.writePNG(comp, to: url)
                let m = haloCheck(decodeRaw(url)!.1, bg: bg, wmOrigin: origin, scale: scale)
                rows.append(["(\(bg.0),\(bg.1),\(bg.2))", "CI · \(ws.id) · \(lanczos ? "Lanczos" : "双线性")",
                             "\(m.dark) (≤\(m.maxDark))", "\(m.bright) (≤\(m.maxBright))", "\(m.pixels)",
                             "\(m.white50)", "\(m.red50)", "\(linW) / \(gamW)", "\(linR) / \(gamR)"])
            }
        }
        // 对照：Core Graphics 在 8-bit sRGB 上下文里画（常见的"顺手写法"）
        let wmCG = decodeRaw(env.fixtures.url("watermark_alpha.png"))!.0
        for (label, space, half) in [("CG · sRGB 8-bit 上下文", sRGB, false),
                                     ("CG · extLinearSRGB half 上下文", WorkingSpace.all[0].cg, true)] {
            let info = half
                ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGImageByteOrderInfo.order16Little.rawValue
                : CGImageAlphaInfo.premultipliedLast.rawValue
            let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: half ? 16 : 8,
                                bytesPerRow: 0, space: space, bitmapInfo: info)!
            ctx.setFillColor(CGColor(colorSpace: sRGB, components: [CGFloat(bg.0) / 255, CGFloat(bg.1) / 255, CGFloat(bg.2) / 255, 1])!)
            ctx.fill(CGRect(origin: .zero, size: canvas))
            ctx.interpolationQuality = .high
            let dw = Double(Watermark.w) * scale, dh = Double(Watermark.h) * scale
            ctx.draw(wmCG, in: CGRect(x: origin.x, y: canvas.height - origin.y - dh, width: dw, height: dh))
            var outImg = ctx.makeImage()!
            if half {   // 转回 sRGB 8-bit 再测
                let c8 = CGContext(data: nil, width: outImg.width, height: outImg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c8.draw(outImg, in: CGRect(x: 0, y: 0, width: outImg.width, height: outImg.height))
                outImg = c8.makeImage()!
            }
            let url = env.out.appendingPathComponent("cg/alpha_\(half ? "linear" : "srgb8")_on_\(bg.0).png")
            try writeImage(outImg, to: url, type: .png)
            let m = haloCheck(decodeRaw(url)!.1, bg: bg, wmOrigin: origin, scale: scale)
            rows.append(["(\(bg.0),\(bg.1),\(bg.2))", label, "\(m.dark) (≤\(m.maxDark))", "\(m.bright) (≤\(m.maxBright))", "\(m.pixels)",
                         "\(m.white50)", "\(m.red50)", "\(linW) / \(gamW)", "\(linR) / \(gamR)"])
        }
    }
    R.table(["背景", "路径", "偏暗像素（最大码值）", "偏亮像素（最大码值）", "检查像素", "50% 白块实测 R", "50% 红块实测 RGB", "白块理想 线性/gamma", "红块理想 线性/gamma"], rows)
}

// MARK: - 5. EXIF 方向

func runOrientation(_ env: Env, _ R: Results) throws {
    R.line("## 5. EXIF 方向")
    R.line()
    var rows: [[String]] = []
    for ws in WorkingSpace.all {
        let p = Pipeline(ws)
        for o in [1, 3, 6, 8] {
            let img = p.load(env.fixtures.url("orientation_\(o).jpg"))
            let canvas = CGSize(width: 400, height: 400)
            let (placed, pl) = p.fit(img, canvas: canvas, margin: 20)
            let comp = placed.composited(over: p.background(canvas, srgb8: bgSRGB8)).cropped(to: CGRect(origin: .zero, size: canvas))
            let url = env.outURL(ws.id, "orientation/orientation_\(o).png")
            try p.writePNG(comp, to: url)
            let out = decodeRaw(url)!.1
            var worst = 0.0
            for (qi, q) in Orientation.quadrants.enumerated() {
                let cx = pl.origin.x + (qi % 2 == 0 ? 0.25 : 0.75) * pl.size.width
                let cy = pl.origin.y + (qi < 2 ? 0.25 : 0.75) * pl.size.height
                worst = max(worst, deltaE(srgb: out.rgb(Int(cx), Int(cy)), srgb: V3(Double(q.0), Double(q.1), Double(q.2)) / 255))
            }
            let ok = pl.size.width == 300 && pl.size.height == 200 && worst < 3
            rows.append([ws.id, "\(o)", "\(Int(pl.size.width))×\(Int(pl.size.height))", f2(worst), ok ? "✅" : "❌"])
        }
    }
    // 交叉验证：ImageIO 缩略图（带 transform）对方向的解释
    var thumbRows: [String] = []
    for o in [1, 3, 6, 8] {
        let src = CGImageSourceCreateWithURL(env.fixtures.url("orientation_\(o).jpg") as CFURL, nil)!
        let t = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: 300] as CFDictionary)!
        let f = readRaw(t).0
        let tl = f.rgb(f.w / 4, f.h / 4) * 255
        thumbRows.append("方向 \(o): 缩略图 \(t.width)×\(t.height)，左上象限 ≈ (\(Int(tl.x)),\(Int(tl.y)),\(Int(tl.z)))")
    }
    R.table(["工作空间", "EXIF 方向", "输出照片尺寸", "四象限最大 ΔE", "结果"], rows)
    R.line("ImageIO 缩略图（kCGImageSourceCreateThumbnailWithTransform）交叉验证：" + thumbRows.joined(separator: "；"))
    R.line()
}
