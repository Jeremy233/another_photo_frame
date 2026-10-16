import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd

// MARK: - 7. 真实照片（本地目录，不入库）

/// 文件名形如 `<名字>_srgb.jpg`、`<名字>_adobergb.tif`、`<名字>_p3.jpg`、`<名字>_prophoto.tif` 时视为同一张照片的不同 ICC 版本。
func iccGroupKey(_ url: URL) -> (stem: String, variant: String)? {
    let name = url.deletingPathExtension().lastPathComponent.lowercased()
    for v in ["srgb", "adobergb", "adobe", "displayp3", "p3", "prophoto"] {
        for sep in ["_", "-", " "] where name.hasSuffix(sep + v) {
            return (String(name.dropLast(v.count + 1)) + "." + url.pathExtension.lowercased(), v == "adobe" ? "adobergb" : v == "displayp3" ? "p3" : v)
        }
    }
    return nil
}

func runReal(_ env: Env, _ R: Results, dir: URL) throws {
    let exts = Set(["jpg", "jpeg", "tif", "tiff", "png"])
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
        .filter { exts.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    R.line("## 7. 真实照片（\(files.count) 个文件，目录不入库）")
    R.line()
    guard !files.isEmpty else { R.line("目录里没有 JPEG/PNG/TIFF。"); return }
    let realOut = env.out.appendingPathComponent("real")
    var infoRows: [[String]] = [], wsRows: [[String]] = [], hdrRows: [[String]] = []
    var sdrOutputs: [String: [String: (FImage, Placement)]] = [:]   // 文件 → 工作空间 → 输出

    for url in files {
        let name = url.lastPathComponent
        guard let info = fileInfo(url) else { continue }
        let probe = CIImage(contentsOf: url, options: [.expandToHDR: true, .applyOrientationProperty: true])!
        let isHDR = probe.contentHeadroom > 1 || info.hasISOGainMap || info.hasAppleGainMap || info.isFloat == true
            || (probe.colorSpace.map { $0.isHDR() } ?? false)
        infoRows.append([name, "\(info.width)×\(info.height)", "\(info.depth ?? 0)\(info.isFloat == true ? " float" : "")",
                         info.profileName ?? "（无）", colorTag(url), csName(probe.colorSpace),
                         info.hasISOGainMap ? "ISO" : info.hasAppleGainMap ? "Apple" : "–", f2(Double(probe.contentHeadroom)),
                         "\(info.orientation ?? 1)", isHDR ? "HDR" : "SDR"])
        var perWS: [String: (FImage, Placement)] = [:]
        var ref2020: FImage?
        for ws in WorkingSpace.all.reversed() {   // 先跑 2020，作为其它空间的对照
            let p = Pipeline(ws)
            let img = p.load(url)
            // headroom 未知（如 float TIFF）时由内容计算
            let headroom = img.contentHeadroom > 1 ? img.contentHeadroom
                : (isHDR ? max(p.ctx.calculateHDRStats(for: img)?.contentHeadroom ?? 1, 1) : 1)
            let (comp, pl, wmRect) = composeMain(p, photo: img, env: env)
            let photoRect = CGRect(origin: pl.origin, size: pl.size)
            // 工作空间内：需要 extended 的像素比例（<0 或 >1）
            let f = p.renderFloat(comp, rect: CGRect(origin: .zero, size: canvasIG))
            var neg = 0, over = 0, n = 0
            let r = photoRect.inset(1).pixelRange
            for y in Swift.stride(from: r.ys.lowerBound, to: r.ys.upperBound, by: 2) {
                for x in Swift.stride(from: r.xs.lowerBound, to: r.xs.upperBound, by: 2) {
                    let v = f.rgb(x, y); n += 1
                    if v.min() < -1e-4 { neg += 1 }
                    if v.max() > 1 + 1e-4 { over += 1 }
                }
            }
            // 与 2020 结果换算到同一 XYZ 后比较（检测某个空间是否截断）
            var maxXYZDiff = 0.0
            if let ref = ref2020 {
                for y in Swift.stride(from: r.ys.lowerBound, to: r.ys.upperBound, by: 4) {
                    for x in Swift.stride(from: r.xs.lowerBound, to: r.xs.upperBound, by: 4) {
                        let a = ws.math.toXYZ * f.rgb(x, y), b = Spaces.linear2020.toXYZ * ref.rgb(x, y)
                        maxXYZDiff = max(maxXYZDiff, simd_reduce_max(simd_abs(a - b)))
                    }
                }
            } else { ref2020 = f }

            // SDR 输出：SDR 源直接输出；HDR 源有 gain map 用原底图，否则 CIToneMapHeadroom
            let base = url.deletingPathExtension().lastPathComponent
            let sdrComp: CIImage
            var sdrMethod = "直接"
            if isHDR {
                if info.hasISOGainMap || info.hasAppleGainMap {
                    sdrComp = composeMain(p, photo: p.load(url, expandHDR: false), env: env).0; sdrMethod = "gain map 底图"
                } else {
                    sdrComp = composeMain(p, photo: img, env: env, photoTransform: { p.toneMapToSDR($0, sourceHeadroom: headroom) }).0
                    sdrMethod = "CIToneMapHeadroom(\(f2(Double(headroom))))"
                }
            } else { sdrComp = comp }
            let pngURL = realOut.appendingPathComponent("\(ws.id)/\(base)_sdr.png")
            try p.writePNG(sdrComp, to: pngURL)
            try p.writeJPEG(sdrComp, to: realOut.appendingPathComponent("\(ws.id)/\(base)_sdr.jpg"))
            let sdr = decodeRaw(pngURL)!.1
            perWS[ws.id] = (sdr, pl)
            let bg = backgroundCheck(sdr, photo: photoRect, wm: wmRect)
            wsRows.append([name, ws.id, String(format: "%.2f%%", 100 * Double(neg) / Double(max(n, 1))),
                           String(format: "%.2f%%", 100 * Double(over) / Double(max(n, 1))),
                           ref2020 == nil || ws.id == "extLinear2020" ? "（基准）" : String(format: "%.5f", maxXYZDiff), sdrMethod, "\(bg.mismatch)"])

            // HDR 输出与读回
            if isHDR {
                let hdrURL = realOut.appendingPathComponent("\(ws.id)/\(base)_hdr.jpg")
                try p.writeJPEG(sdrComp, to: hdrURL, colorSpace: sRGB, hdr: comp)
                let back = p.load(hdrURL)
                let bf = p.renderFloat(back, rect: CGRect(origin: .zero, size: canvasIG))
                var relAll: [Double] = [], relHi: [Double] = []
                for y in Swift.stride(from: r.ys.lowerBound, to: r.ys.upperBound, by: 3) {
                    for x in Swift.stride(from: r.xs.lowerBound, to: r.xs.upperBound, by: 3) {
                        let yo = (ws.math.toXYZ * f.rgb(x, y)).y, yb = (ws.math.toXYZ * bf.rgb(x, y)).y
                        guard yo > 0.01 else { continue }
                        let e = abs(yb / yo - 1)
                        relAll.append(e)
                        if yo > 1 { relHi.append(e) }
                    }
                }
                let sdrBack = p.renderRGBA8(p.load(hdrURL, expandHDR: false), rect: CGRect(origin: .zero, size: canvasIG))
                let bgBack = backgroundCheck(sdrBack, photo: photoRect, wm: wmRect)
                let fi = fileInfo(hdrURL)!
                let chroma = highlightChroma(bf, f, ws: ws, rect: photoRect)
                let sa = Stats(relAll), sh = Stats(relHi)
                hdrRows.append([name, ws.id, fi.hasISOGainMap ? "ISO ✅" : "❌", fi.profileName ?? "–", f2(Double(headroom)),
                                f2(Double(back.contentHeadroom)), "\(f3(sa.median)) / \(f3(sa.p95))",
                                relHi.isEmpty ? "无 >1 像素" : "\(f3(sh.median)) / \(f3(sh.p95))（\(relHi.count) 点）",
                                "\(f4(chroma.median)) / \(f4(chroma.p95))", "\(bgBack.maxDev)",
                                "\(f2(imageDeltaE(sdrBack, sdr, rect: photoRect).median)) / \(f2(imageDeltaE(sdrBack, sdr, rect: photoRect).p95))"])
            }
        }
        sdrOutputs[name] = perWS
    }

    R.line("### 7.1 文件识别")
    R.line()
    R.table(["文件", "尺寸", "位深", "ImageIO ProfileName", "文件内颜色描述", "CIImage.colorSpace", "gain map", "contentHeadroom", "EXIF 方向", "判定"], infoRows)
    R.line("### 7.2 各工作空间：需要 extended 的像素比例与一致性")
    R.line()
    R.line("“与 2020 的 XYZ 最大差”：同一合成图在该空间渲染为 RGBAf 后换算到 XYZ，与 extLinear2020 结果的最大差（若某空间截断，这里会明显变大）。")
    R.line()
    R.table(["文件", "工作空间", "分量 <0 的像素", "分量 >1 的像素", "与 2020 的 XYZ 最大差", "SDR 输出方法", "SDR 背景≠#FAFAF8"], wsRows)

    // 各空间 SDR 输出两两 ΔE
    var crossRows: [[String]] = []
    for (name, m) in sdrOutputs.sorted(by: { $0.key < $1.key }) {
        guard let a = m["extLinear2020"] else { continue }
        for id in ["extLinearSRGB", "extLinearP3"] {
            guard let b = m[id] else { continue }
            let s = imageDeltaE(a.0, b.0, rect: CGRect(origin: a.1.origin, size: a.1.size))
            crossRows.append([name, "\(id) vs extLinear2020", f2(s.median), f2(s.p95), f2(s.max)])
        }
    }
    R.line("### 7.3 SDR 输出随工作空间的差异（ΔE2000）")
    R.line()
    R.table(["文件", "比较", "中位", "P95", "max"], crossRows)

    if !hdrRows.isEmpty {
        R.line("### 7.4 HDR 输出（CI，gain map JPEG）写出 → 读回")
        R.line()
        R.line("相对误差 = |读回 Y / 写出前合成 Y − 1|。SDR 底图 ΔE = 读回底图 vs 我们的 SDR 渲染。")
        R.line()
        R.table(["文件", "工作空间", "gain map", "底图 ICC", "源 headroom", "读回 headroom", "全部像素相对误差 中位/P95",
                 ">1 高光相对误差 中位/P95", "高光 Δu′v′ 中位/P95", "SDR 底图背景最大偏差", "SDR 底图 ΔE 中位/P95"], hdrRows)
    }

    // 同一张照片的多个 ICC 版本：D-19 阈值
    var groups: [String: [String: URL]] = [:]
    for u in files { if let k = iccGroupKey(u) { groups[k.stem, default: [:]][k.variant] = u } }
    var d19Rows: [[String]] = []
    for (stem, variants) in groups.sorted(by: { $0.key < $1.key }) where variants.count >= 2 {
        guard let refURL = variants["srgb"] ?? variants["p3"] else { continue }
        let widest = variants["prophoto"] ?? variants["adobergb"] ?? variants["p3"]
        for ws in WorkingSpace.all {
            guard let ref = sdrOutputs[refURL.lastPathComponent]?[ws.id] else { continue }
            // 源图超出 sRGB 的像素（按最宽版本在 extLinearSRGB 下判断）做掩膜
            var mask = [Bool](repeating: false, count: ref.0.w * ref.0.h)
            if let wURL = widest {
                let p = Pipeline(WorkingSpace.all[0])
                let (comp, _, _) = composeMain(p, photo: p.load(wURL), env: env)
                let f = p.renderFloat(comp, rect: CGRect(origin: .zero, size: canvasIG))
                for i in 0..<mask.count { let v = f.rgb(i % f.w, i / f.w); mask[i] = v.min() < -0.002 || v.max() > 1.002 }
            }
            for (variant, u) in variants.sorted(by: { $0.key < $1.key }) where u != refURL {
                guard let o = sdrOutputs[u.lastPathComponent]?[ws.id] else { continue }
                var all: [Double] = [], inG: [Double] = []
                let r = CGRect(origin: ref.1.origin, size: ref.1.size).inset(3).pixelRange
                for y in Swift.stride(from: r.ys.lowerBound, to: r.ys.upperBound, by: 2) {
                    for x in Swift.stride(from: r.xs.lowerBound, to: r.xs.upperBound, by: 2) {
                        let de = deltaE(srgb: o.0.rgb(x, y), srgb: ref.0.rgb(x, y))
                        all.append(de)
                        if !mask[y * ref.0.w + x] { inG.append(de) }
                    }
                }
                let sa = Stats(all), si = Stats(inG)
                let pass = si.median <= 1 && si.p95 <= 2
                d19Rows.append([stem, ws.id, "\(variant) vs \(refURL.lastPathComponent)", "\(f2(sa.median)) / \(f2(sa.p95))",
                                "\(f2(si.median)) / \(f2(si.p95))", String(format: "%.1f%%", 100 * Double(all.count - inG.count) / Double(max(all.count, 1))),
                                pass ? "✅" : "❌"])
            }
        }
    }
    if !d19Rows.isEmpty {
        R.line("### 7.5 同一照片不同 ICC 版本 → sRGB 输出的 ΔE2000（D-19）")
        R.line()
        R.line("基准为 sRGB 版本的输出。“sRGB 域内”剔除了源图超出 sRGB 的像素（这些像素由 Lightroom 与本管线各自做色域映射，不可比）。")
        R.line()
        R.table(["照片", "工作空间", "比较", "全部像素 中位/P95", "sRGB 域内 中位/P95", "域外像素占比", "D-19（中位≤1, P95≤2）"], d19Rows)
    }
}
