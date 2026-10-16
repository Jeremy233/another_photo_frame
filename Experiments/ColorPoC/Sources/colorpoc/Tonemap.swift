import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO
import simd

// MARK: - tonemap：HDR→SDR 几种曲线的并排对比（用于目视决策，不进 run）

/// BT.2390 EETF（ITU-R BT.2390 §5.4.1），在 PQ 域把 [0, Lw] 映射到 [0, Lmax]。输入输出为 nits。
func bt2390EETF(_ nits: Double, lw: Double, lmax: Double) -> Double {
    let pqW = PQ.encode(nits: lw)
    let e1 = PQ.encode(nits: nits) / pqW
    let maxLum = PQ.encode(nits: lmax) / pqW
    let ks = 1.5 * maxLum - 0.5
    var e2 = e1
    if e1 > ks {
        let t = (e1 - ks) / (1 - ks)
        let t2 = t * t, t3 = t2 * t
        e2 = (2 * t3 - 3 * t2 + 1) * ks + (t3 - 2 * t2 + t) * (1 - ks) + (-2 * t3 + 3 * t2) * maxLum
    }
    return PQ.decode(min(e2, 1) * pqW)
}

/// 对线性 Rec.2020（1.0 = SDR 白 = 203 nits）的像素做曲线映射；保持色相：按 maxRGB 或亮度的比例缩放 RGB。
enum Curve {
    case eetf2390(headroom: Double)     // 作用于 maxRGB
    case reinhard(headroom: Double)     // 扩展 Reinhard，作用于亮度 Y

    func apply(_ rgb: V3) -> V3 {
        switch self {
        case .eetf2390(let h):
            let m = max(rgb.max(), 0)
            guard m > 1e-6 else { return rgb }
            let out = bt2390EETF(m * 203, lw: max(h, 1.0001) * 203, lmax: 203) / 203
            return rgb * (out / m)
        case .reinhard(let h):
            let y = max((Spaces.linear2020.toXYZ * rgb).y, 0)
            guard y > 1e-6 else { return rgb }
            let out = y * (1 + y / (h * h)) / (1 + y)
            return rgb * (out / y)
        }
    }
}

struct TonePanel { let label: String; let img: FImage }   // img 为 sRGB 8-bit（0…1）

func runTonemap(_ urls: [URL], env: Env) throws {
    let ws = WorkingSpace.all[2]
    let p = Pipeline(ws)
    let outDir = env.out.appendingPathComponent("tonemap")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var summary: [String] = ["# HDR→SDR tone map 对比", "",
        "参照 = Lightroom 自带的 SDR 底图（同名 gain map JPEG，不展开）。ΔE 和 ΔL* 都是相对参照；ΔL* 为正表示更亮。", ""]

    for url in urls {
        let name = url.deletingPathExtension().lastPathComponent
        let hdrSrc = p.load(url)
        let e = hdrSrc.extent
        let s = min(1200 / e.width, 1200 / e.height)
        let w = Int((e.width * s).rounded()), h = Int((e.height * s).rounded())
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        func shrink(_ img: CIImage) -> CIImage {
            let x = img.extent
            return p.scaled(img.transformed(by: CGAffineTransform(translationX: -x.minX, y: -x.minY)).clampedToExtent(), by: s).cropped(to: rect)
        }
        // HDR 线性值（Rec.2020，1.0 = SDR 白）
        let hdr = p.renderFloat(shrink(hdrSrc), rect: rect)
        // 峰值按 sRGB 线性分量的 maxRGB 估算（P99.95）：SDR 输出时被截断的是单个通道，不只是亮度
        var ys: [Double] = [], maxes: [Double] = []
        let toSRGB = Spaces.linearSRGB.fromXYZ * ws.math.toXYZ
        for y in 0..<h { for x in 0..<w {
            let v = hdr.rgb(x, y)
            ys.append((ws.math.toXYZ * v).y)
            maxes.append((toSRGB * v).max())
        } }
        let peak = max(percentile(maxes.sorted(), 0.9995), 1.0001)

        /// 把 CPU 算好的线性 FImage 变成 sRGB 8-bit（CI 负责转换，越界逐通道截断）
        func toSDR(_ f: FImage) -> FImage {
            let cg = makeCGImage(f, format: .half, colorSpace: ws.cg, alpha: true)
            return p.renderRGBA8(CIImage(cgImage: cg), rect: rect)
        }
        func mapped(_ c: Curve) -> FImage {
            var f = hdr
            for y in 0..<h { for x in 0..<w {
                let v = c.apply(f.rgb(x, y))
                f[x, y] = SIMD4(Float(v.x), Float(v.y), Float(v.z), 1)
            } }
            return toSDR(f)
        }

        var panels: [TonePanel] = []
        let baseURL = url.deletingPathExtension().appendingPathExtension("jpg")
        if FileManager.default.fileExists(atPath: baseURL.path) {
            panels.append(TonePanel(label: "① Lightroom SDR 底图（参照）", img: p.renderRGBA8(shrink(p.load(baseURL, expandHDR: false)), rect: rect)))
        }
        panels.append(TonePanel(label: "② 直接截断", img: toSDR(hdr)))
        let tm = CIFilter.toneMapHeadroom()
        tm.inputImage = CIImage(cgImage: makeCGImage(hdr, format: .half, colorSpace: ws.cg, alpha: true))
        tm.sourceHeadroom = Float(peak); tm.targetHeadroom = 1
        panels.append(TonePanel(label: "③ CIToneMapHeadroom（headroom \(f2(peak))）", img: p.renderRGBA8(tm.outputImage!, rect: rect)))
        let soft = CIImage(contentsOf: url, options: [.toneMapHDRtoSDR: true, .applyOrientationProperty: true])!
        panels.append(TonePanel(label: "④ Apple 软肩（toneMapHDRtoSDR）", img: p.renderRGBA8(shrink(soft), rect: rect)))
        panels.append(TonePanel(label: "⑤ BT.2390 EETF（maxRGB）", img: mapped(.eetf2390(headroom: peak))))
        panels.append(TonePanel(label: "⑥ Reinhard（亮度）", img: mapped(.reinhard(headroom: peak))))

        // 单张输出
        let sub = outDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for (i, panel) in panels.enumerated() {
            try writeImage(makeCGImage(panel.img, format: .u8, colorSpace: sRGB, alpha: false),
                           to: sub.appendingPathComponent("\(i + 1).jpg"), type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.95])
        }
        // 指标（相对 Lightroom 底图）
        summary.append("## \(name)（画面峰值约 \(f2(peak))× SDR 白，亮于 SDR 白的像素 \(String(format: "%.2f%%", 100 * Double(ys.filter { $0 > 1 }.count) / Double(ys.count)))）")
        summary.append("")
        summary.append("| 方法 | ΔE 中位 / P95 | ΔL* 中位（暗部 / 中间调 / 高光） | 有通道 = 255 的像素 |")
        summary.append("|---|---|---|---|")
        let ref = panels.first!.img
        for panel in panels {
            var de: [Double] = [], dl: [[Double]] = [[], [], []]
            var clipped = 0
            for y in Swift.stride(from: 0, to: h, by: 2) {
                for x in Swift.stride(from: 0, to: w, by: 2) {
                    let a = panel.img.rgb(x, y), b = ref.rgb(x, y)
                    let la = lab(fromXYZ: Spaces.srgb.xyz(fromEncoded: a)), lb = lab(fromXYZ: Spaces.srgb.xyz(fromEncoded: b))
                    de.append(deltaE2000(la, lb))
                    dl[lb.x < 25 ? 0 : lb.x < 75 ? 1 : 2].append(la.x - lb.x)
                    if a.max() >= 254.5 / 255 { clipped += 1 }
                }
            }
            let sd = Stats(de)
            summary.append("| \(panel.label) | \(f2(sd.median)) / \(f2(sd.p95)) | \(dl.map { f2(Stats($0).median) }.joined(separator: " / ")) | \(String(format: "%.2f%%", 100 * Double(clipped) / Double(de.count))) |")
        }
        summary.append("")
        // 拼图：3 列 × 2 行，每格上方加标签
        try writeContactSheet(panels, title: "\(name)    峰值约 \(f2(peak))× SDR 白", tileW: w, tileH: h,
                              to: outDir.appendingPathComponent("\(name)_compare.jpg"))
        print("[tonemap] \(name) done")
    }
    try summary.joined(separator: "\n").write(to: outDir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    print(summary.joined(separator: "\n"))
}

func writeContactSheet(_ panels: [TonePanel], title: String, tileW: Int, tileH: Int, to url: URL) throws {
    let cols = 3, rows = (panels.count + cols - 1) / cols
    let gap = 16, label = 56, header = 72
    let W = cols * tileW + (cols + 1) * gap, H = header + rows * (tileH + label + gap) + gap
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    func text(_ s: String, x: Int, yTop: Int, size: CGFloat) {
        let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
        let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                               kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(H - yTop) - size)
        CTLineDraw(line, ctx)
    }
    text(title, x: gap, yTop: 18, size: 34)
    for (i, panel) in panels.enumerated() {
        let c = i % cols, r = i / cols
        let x = gap + c * (tileW + gap)
        let yTop = header + r * (tileH + label + gap)
        text(panel.label, x: x, yTop: yTop + 10, size: 30)
        let img = makeCGImage(panel.img, format: .u8, colorSpace: sRGB, alpha: false)
        ctx.draw(img, in: CGRect(x: x, y: H - (yTop + label + tileH), width: tileW, height: tileH))
    }
    try writeImage(ctx.makeImage()!, to: url, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.92])
}
