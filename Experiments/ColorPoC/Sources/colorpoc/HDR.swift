import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd

// MARK: - 6. HDR：保留、SDR tone map、gain map 输出与读回

/// 某张图（左上原点）里各 HDR 中性色块的平均 Y（在工作空间线性值下）。
func neutralY(_ img: FImage, ws: WorkingSpace, placement: Placement?) -> [Double] {
    HDRScene.patches.prefix(HDRScene.neutralLevels.count).map { p in
        let r = (placement?.map(p.rect) ?? p.rect).inset(placement == nil ? 4 : 8).pixelRange
        var sum = 0.0, n = 0
        for y in r.ys { for x in r.xs { sum += (ws.math.toXYZ * img.rgb(x, y)).y; n += 1 } }
        return sum / Double(n)
    }
}

/// 8-bit 输出中中性色块中心的码值（G 通道）。
func neutralCodes(_ img: FImage, placement: Placement) -> [Int] {
    HDRScene.patches.prefix(HDRScene.neutralLevels.count).map { p in
        let r = placement.map(p.rect)
        return code8(img[Int(r.midX), Int(r.midY)].y)
    }
}

/// SDR 色卡（第 2–3 行，24 块）在 8-bit sRGB 输出里的 ΔE。
func sdrChartDeltaE(_ img: FImage, placement: Placement) -> Stats {
    let pts = Array(HDRScene.patches[24..<48])
    return Stats(chartDeltaE(img, patches: pts, placement: placement, inset: 8, stride: 3))
}

/// 两张 8-bit sRGB 图在照片区域内的 ΔE。
func imageDeltaE(_ a: FImage, _ b: FImage, rect: CGRect, stride: Int = 3) -> Stats {
    var v: [Double] = []
    let r = rect.inset(3).pixelRange
    for y in Swift.stride(from: r.ys.lowerBound, to: r.ys.upperBound, by: stride) {
        for x in Swift.stride(from: r.xs.lowerBound, to: r.xs.upperBound, by: stride) { v.append(deltaE(srgb: a.rgb(x, y), srgb: b.rgb(x, y))) }
    }
    return Stats(v)
}

struct HDRReadback {
    var info: FileInfo
    var sdrBgMismatch: Int
    var sdrBgMaxDev: Int
    var sdrNeutral: [Int]
    var sdrChart: Stats
    var sdrVsOurSDR: Stats
    var hdrHeadroom: Float
    var hdrRatios: [Double]   // 读回 HDR 的中性色块 Y / 写出前合成图的 Y
    var hdrBgLinear: Double
    var hiChroma: Stats       // 高光（Y>1）像素读回 vs 写出前的 Δu'v'
    var gainMapSize: String
}

func uvPrime(_ xyz: V3) -> SIMD2<Double> {
    let d = xyz.x + 15 * xyz.y + 3 * xyz.z
    return d <= 0 ? SIMD2(0, 0) : SIMD2(4 * xyz.x / d, 9 * xyz.y / d)
}

/// 高光像素（写出前 Y>1）在读回后色度偏移 Δu'v' 的统计。
func highlightChroma(_ back: FImage, _ composed: FImage, ws: WorkingSpace, rect: CGRect) -> Stats {
    var v: [Double] = []
    let r = rect.inset(3).pixelRange
    for y in Swift.stride(from: r.ys.lowerBound, to: r.ys.upperBound, by: 2) {
        for x in Swift.stride(from: r.xs.lowerBound, to: r.xs.upperBound, by: 2) {
            let a = ws.math.toXYZ * composed.rgb(x, y)
            guard a.y > 1 else { continue }
            v.append(simd_length(uvPrime(ws.math.toXYZ * back.rgb(x, y)) - uvPrime(a)))
        }
    }
    return Stats(v)
}

func gainMapSize(_ url: URL) -> String {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
          let d = CGImageSourceCopyAuxiliaryDataInfoAtIndex(s, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any],
          let desc = d[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any] else { return "–" }
    let fmt = (desc["PixelFormat"] as? UInt32).map { f in String(bytes: [24, 16, 8, 0].map { UInt8((f >> $0) & 0xff) }, encoding: .ascii) ?? "?" } ?? "?"
    return "\(desc["Width"] ?? "?")×\(desc["Height"] ?? "?") \(fmt)"
}

func readBackHDR(_ url: URL, p: Pipeline, placement: Placement, wmRect: CGRect, ourSDR: FImage, composedY: [Double], composed: FImage) -> HDRReadback {
    let info = fileInfo(url)!
    // SDR 回退：默认解码（不展开 gain map），按文件自带 ICC 转到 sRGB 8-bit 再比较
    let sdrCI = CIImage(contentsOf: url, options: [.expandToHDR: false])!
    let sdr = p.renderRGBA8(sdrCI, rect: CGRect(origin: .zero, size: canvasIG))
    let photoRect = CGRect(origin: placement.origin, size: placement.size)
    let bg = backgroundCheck(sdr, photo: photoRect, wm: wmRect)
    // HDR：展开 gain map
    let hdrCI = p.load(url, expandHDR: true)
    let hdr = p.renderFloat(hdrCI, rect: CGRect(origin: .zero, size: canvasIG))
    let y = neutralY(hdr, ws: p.ws, placement: placement)
    let bgLin = (p.ws.math.toXYZ * hdr.rgb(10, 10)).y
    return HDRReadback(info: info, sdrBgMismatch: bg.mismatch, sdrBgMaxDev: bg.maxDev, sdrNeutral: neutralCodes(sdr, placement: placement),
                       sdrChart: sdrChartDeltaE(sdr, placement: placement), sdrVsOurSDR: imageDeltaE(sdr, ourSDR, rect: photoRect),
                       hdrHeadroom: hdrCI.contentHeadroom, hdrRatios: zip(y, composedY).map { $0 / $1 }, hdrBgLinear: bgLin,
                        hiChroma: highlightChroma(hdr, composed, ws: p.ws, rect: photoRect), gainMapSize: gainMapSize(url))
}

func runHDR(_ env: Env, _ R: Results) throws {
    R.line("## 6. HDR")
    R.line()
    R.line("场景：第 0 行中性色块线性亮度 \(HDRScene.neutralLevels.map { f2($0) }.joined(separator: ", "))（相对 SDR 参考白）；第 1 行彩色高光（含 P3 / Rec.2020 原色）；底部 0→8 渐变。")
    R.line("k = 解码后 1.0 色块的实测 Y：Apple 把多少当作 SDR 参考白。")
    R.line()
    let files = ["hdr_gainmap.jpg", "hdr_pq2020_203nit.png", "hdr_float_linear2020.tif"]
    var decodeRows: [[String]] = [], sdrRows: [[String]] = [], outRows: [[String]] = [], crossRows: [[String]] = []
    var json: [String: Any] = [:]
    let bgLinExpected = TRC.srgb.decode(250.0 / 255) * 0.2126 + TRC.srgb.decode(250.0 / 255) * 0.7152 + TRC.srgb.decode(248.0 / 255) * 0.0722
    for file in files {
        var tonemapped: [String: FImage] = [:]
        var placementForCross: Placement?
        for ws in WorkingSpace.all {
            let p = Pipeline(ws)
            let img = p.load(env.fixtures.url(file))
            let headroom = img.contentHeadroom
            // S1：解码进入工作空间
            let s1 = p.renderFloat(img, rect: img.extent)
            let y1 = neutralY(s1, ws: ws, placement: nil)
            let k = y1[4]
            let gt = HDRScene.groundTruth()
            let c1 = clipCount(s1, expected: { x, y in ws.math.fromXYZ * gt[y * HDRScene.w + x] },
                               region: (0..<HDRScene.w, 0..<HDRScene.h), scale: k)
            // S2：合成（照片不 tone map），背景与水印按 SDR 参考白放置
            let (comp, pl, wmRect) = composeMain(p, photo: img, env: env)
            placementForCross = pl
            let canvasF = p.renderFloat(comp, rect: CGRect(origin: .zero, size: canvasIG))
            let y2 = neutralY(canvasF, ws: ws, placement: pl)
            let rects = HDRScene.patches.map { pl.map($0.rect).inset(8) }
            let vals = HDRScene.patches.map { ws.math.fromXYZ * $0.xyz }
            let c2 = clipCount(canvasF, expected: { x, y in
                let pt = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                for (i, r) in rects.enumerated() where r.contains(pt) { return vals[i] }
                return nil
            }, region: (0..<Int(canvasIG.width), 0..<Int(canvasIG.height)), scale: k)
            let bgLin = (ws.math.toXYZ * canvasF.rgb(10, 10)).y
            decodeRows.append([file, ws.id, csName(img.colorSpace), f2(Double(headroom)), f3(k),
                               y1.map { f2($0 / k) }.joined(separator: " "),
                               "\(c1.expectedOutOfRange)/\(c1.clipped)", "\(c2.expectedOutOfRange)/\(c2.clipped)",
                               f4(bgLin) + " (期望 " + f4(bgLinExpected) + ")"])

            // SDR 输出候选：直接截断 / CIToneMapHeadroom（仅作用于照片图层）/ gain map 自带的 SDR 底图
            let base = (file as NSString).deletingPathExtension
            let srcHeadroom = headroom > 1 ? headroom : Float(HDRScene.peak * k)
            let photoRect = CGRect(origin: pl.origin, size: pl.size)
            var sdrCandidates: [(String, CIImage)] = [("直接截断", comp)]
            sdrCandidates.append(("CIToneMapHeadroom", composeMain(p, photo: img, env: env,
                                                                  photoTransform: { p.toneMapToSDR($0, sourceHeadroom: srcHeadroom) }).0))
            let hasGainMap = fileInfo(env.fixtures.url(file))?.hasISOGainMap == true
            if hasGainMap { sdrCandidates.append(("gain map 底图", composeMain(p, photo: p.load(env.fixtures.url(file), expandHDR: false), env: env).0)) }
            var sdrImages: [String: FImage] = [:]
            for (label, sdrComp) in sdrCandidates {
                let url = env.outURL(ws.id, "hdr/\(base)_sdr_\(label == "直接截断" ? "clip" : label == "CIToneMapHeadroom" ? "tonemap" : "base").png")
                try p.writePNG(sdrComp, to: url)
                let img8 = decodeRaw(url)!.1
                sdrImages[label] = img8
                var c255 = 0
                let pr = photoRect.inset(2).pixelRange
                for yy in pr.ys { for xx in pr.xs { let q = img8[xx, yy]; if q.x >= 1 || q.y >= 1 || q.z >= 1 { c255 += 1 } } }
                sdrRows.append([file, ws.id, label, neutralCodes(img8, placement: pl).map(String.init).joined(separator: " "), "\(c255)",
                                f2(sdrChartDeltaE(img8, placement: pl).median), "\(backgroundCheck(img8, photo: photoRect, wm: wmRect).mismatch)"])
            }
            tonemapped[ws.id] = sdrImages["CIToneMapHeadroom"]!

            // HDR 输出：CI（SDR 底图 = tone map 结果，或 gain map 原底图）与 ImageIO 两条路线
            var routes = ["CI·tonemap 底图", "CI·tonemap 底图·RGB gain map", "ImageIO"]
            if hasGainMap { routes.insert("CI·原 gain map 底图", at: 1) }
            for route in routes {
                let tag = route == "CI·tonemap 底图" ? "CI" : route.hasSuffix("RGB gain map") ? "CIrgb" : route.hasPrefix("CI") ? "CIbase" : "ImageIO"
                let url = env.outURL(ws.id, "hdr/\(base)_hdr_gainmap_\(tag).jpg")
                let ourSDR = route == "CI·原 gain map 底图" ? sdrImages["gain map 底图"]! : sdrImages["CIToneMapHeadroom"]!
                do {
                    switch route {
                    case "CI·tonemap 底图": try p.writeJPEG(sdrCandidates[1].1, to: url, colorSpace: sRGB, hdr: comp)
                    case "CI·tonemap 底图·RGB gain map": try p.writeJPEG(sdrCandidates[1].1, to: url, colorSpace: sRGB, hdr: comp, rgbGainMap: true)
                    case "CI·原 gain map 底图": try p.writeJPEG(sdrCandidates[2].1, to: url, colorSpace: sRGB, hdr: comp)
                    default: try p.writeGainMapJPEGViaImageIO(comp, to: url, renderSpace: ws.cg, baseSpace: sRGB, headroom: srcHeadroom)
                    }
                    let rb = readBackHDR(url, p: p, placement: pl, wmRect: wmRect, ourSDR: ourSDR, composedY: y2, composed: canvasF)
                    let within = zip(HDRScene.neutralLevels, rb.hdrRatios).filter { $0.0 * Double(k) <= Double(rb.hdrHeadroom) * 1.0001 }
                    let maxRelErr = within.map { abs($0.1 - 1) }.max() ?? .nan
                    outRows.append([file, ws.id, route, rb.info.hasISOGainMap ? "ISO ✅" : (rb.info.hasAppleGainMap ? "Apple" : "❌"),
                                    rb.info.profileName ?? "–", f2(Double(rb.hdrHeadroom)),
                                    rb.hdrRatios.map { f2($0) }.joined(separator: " "), f3(maxRelErr),
                                    "\(rb.sdrBgMaxDev)", rb.sdrNeutral.map(String.init).joined(separator: " "),
                                    "\(f2(rb.sdrVsOurSDR.median)) / \(f2(rb.sdrVsOurSDR.p95))", f4(rb.hdrBgLinear),
                                    "\(f4(rb.hiChroma.median)) / \(f4(rb.hiChroma.p95))", rb.gainMapSize])
                    json["\(file)/\(ws.id)/\(route)"] = ["headroom": rb.hdrHeadroom, "ratios": rb.hdrRatios, "maxRelErr": maxRelErr,
                                                         "sdrBgMaxDev": rb.sdrBgMaxDev, "sdrVsOurSDRMedian": rb.sdrVsOurSDR.median,
                                                         "sdrVsOurSDRP95": rb.sdrVsOurSDR.p95]
                } catch {
                    outRows.append([file, ws.id, route, "写出失败：\(error)", "", "", "", "", "", "", "", "", "", ""])
                }
            }
        }
        // tone map 结果是否依赖工作空间
        if let pl = placementForCross, let a = tonemapped["extLinearSRGB"] {
            for id in ["extLinearP3", "extLinear2020"] {
                let s = imageDeltaE(a, tonemapped[id]!, rect: CGRect(origin: pl.origin, size: pl.size))
                crossRows.append([file, "extLinearSRGB vs \(id)", f2(s.median), f2(s.p95), f2(s.max)])
            }
        }
    }
    R.line("### 6.1 解码进入工作空间（S1）与合成后（S2）")
    R.line()
    R.table(["输入", "工作空间", "CIImage.colorSpace", "contentHeadroom", "k（1.0 色块实测 Y）", "中性色块 Y/k",
             "S1 需 extended/被截断", "S2 需 extended/被截断", "合成后背景线性 Y"], decodeRows)
    R.line("### 6.2 SDR 输出：直接截断 / CIToneMapHeadroom / gain map 底图")
    R.line()
    R.table(["输入", "工作空间", "SDR 方法", "中性色块码值（0.05 … 8.0）", "照片内 255 像素", "SDR 色卡 ΔE 中位", "背景≠#FAFAF8"], sdrRows)
    R.line("tone map 结果随工作空间的差异（8-bit 输出，照片区域 ΔE2000）：")
    R.line()
    R.table(["输入", "比较", "中位", "P95", "max"], crossRows)
    R.line("### 6.3 HDR 输出（gain map JPEG）写出 → 读回")
    R.line()
    R.line("“HDR 读回比值”= 读回展开后的中性色块 Y ÷ 写出前合成图的 Y；只在 headroom 以内的级别统计最大相对误差。SDR 回退 = 不展开 gain map 的底图。")
    R.line()
    R.table(["输入", "工作空间", "路线", "gain map", "底图 ICC", "读回 headroom", "HDR 读回比值（各级）", "headroom 内最大相对误差",
             "SDR 底图背景最大偏差", "SDR 底图中性色块码值", "SDR 底图 vs 期望 SDR 渲染 ΔE 中位/P95", "HDR 读回背景线性 Y", "高光 Δu′v′ 中位/P95", "gain map 尺寸/格式"], outRows)
    R.set("hdr", json)
}
