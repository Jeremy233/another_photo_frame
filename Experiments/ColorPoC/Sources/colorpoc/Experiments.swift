import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd

/// 收集结果：markdown 片段 + 机器可读 JSON。
final class Results {
    var md: [String] = []
    var json: [String: Any] = [:]
    func line(_ s: String = "") { md.append(s); print(s) }
    func table(_ header: [String], _ rows: [[String]]) {
        line("| " + header.joined(separator: " | ") + " |")
        line("|" + header.map { _ in "---" }.joined(separator: "|") + "|")
        for r in rows { line("| " + r.joined(separator: " | ") + " |") }
        line()
    }
    func set(_ path: String, _ v: Any) { json[path] = v }
}

func f2(_ v: Double) -> String { v.isNaN ? "–" : String(format: "%.2f", v) }
func f3(_ v: Double) -> String { v.isNaN ? "–" : String(format: "%.3f", v) }
func f4(_ v: Double) -> String { v.isNaN ? "–" : String(format: "%.4f", v) }

extension CGRect {
    func inset(_ d: Double) -> CGRect { insetBy(dx: d, dy: d) }
    var pixelRange: (xs: Range<Int>, ys: Range<Int>) {
        (Int(minX.rounded(.up))..<Int(maxX.rounded(.down)), Int(minY.rounded(.up))..<Int(maxY.rounded(.down)))
    }
}

func code8(_ v: Float) -> Int { Int((v * 255).rounded()) }

struct Env {
    let fixtures: FixtureSet
    let out: URL
    func outURL(_ ws: String, _ name: String) -> URL { out.appendingPathComponent(ws).appendingPathComponent(name) }
}

let canvasIG = CGSize(width: 1080, height: 1350)
let bgSRGB8 = (250, 250, 248)

/// 主流程：照片 + 背景 + 水印（右下角留白区）。
func composeMain(_ p: Pipeline, photo: CIImage, env: Env, clampEdges: Bool = true,
                 photoTransform: ((CIImage) -> CIImage)? = nil) -> (CIImage, Placement, CGRect) {
    let (placed, pl) = p.fit(photo, canvas: canvasIG, margin: 90, clampEdges: clampEdges)
    let photoLayer = photoTransform.map { $0(placed) } ?? placed
    let wm = p.scaled(p.load(env.fixtures.url("watermark_alpha.png")), by: 0.6)
    let wmTopLeft = CGPoint(x: canvasIG.width - 90 - wm.extent.width.rounded(.up), y: 1220)
    let wmRect = CGRect(origin: wmTopLeft, size: CGSize(width: wm.extent.width.rounded(.up), height: wm.extent.height.rounded(.up)))
    let comp = p.place(wm, topLeft: wmTopLeft, canvas: canvasIG)
        .composited(over: photoLayer.composited(over: p.background(canvasIG, srgb8: bgSRGB8)))
        .cropped(to: CGRect(origin: .zero, size: canvasIG))
    return (comp, pl, wmRect)
}

/// 背景区域（排除照片外扩 4px 与水印外扩 4px）中不等于 (250,250,248) 的像素。
func backgroundCheck(_ img: FImage, photo: CGRect, wm: CGRect) -> (mismatch: Int, total: Int, maxDev: Int) {
    let ph = photo.insetBy(dx: -4, dy: -4), wr = wm.insetBy(dx: -4, dy: -4)
    var mismatch = 0, total = 0, maxDev = 0
    for y in 0..<img.h {
        for x in 0..<img.w {
            let pt = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
            if ph.contains(pt) || wr.contains(pt) { continue }
            total += 1
            let p = img[x, y]
            let d = max(abs(code8(p.x) - bgSRGB8.0), abs(code8(p.y) - bgSRGB8.1), abs(code8(p.z) - bgSRGB8.2))
            if d != 0 { mismatch += 1 }
            maxDev = max(maxDev, d)
        }
    }
    return (mismatch, total, maxDev)
}

/// 色卡 ΔE：输出（sRGB 编码）每个色块内部像素对真值。
func chartDeltaE(_ img: FImage, patches: [Patch], placement: Placement, inset: Double = 6, stride: Int = 2) -> [Double] {
    var des: [Double] = []
    for p in patches {
        let ref = Spaces.srgb.encoded(fromXYZ: p.xyz)
        let r = placement.map(p.rect).inset(inset).pixelRange
        for y in Swift.stride(from: r.ys.lowerBound, to: r.ys.upperBound, by: stride) {
            for x in Swift.stride(from: r.xs.lowerBound, to: r.xs.upperBound, by: stride) {
                des.append(deltaE(srgb: img.rgb(x, y), srgb: ref))
            }
        }
    }
    return des
}

func isInGamut(_ v: V3, eps: Double = 1e-4) -> Bool { v.min() >= -eps && v.max() <= 1 + eps }

struct ClipCount {
    var expectedOutOfRange = 0
    var clipped = 0
    var pixels = 0
    var maxErrInRange = 0.0
}

/// 比较工作空间浮点渲染与真值：统计"真值超出 [0,1] 但观测值被压回 [0,1]"的像素。
func clipCount(_ img: FImage, expected: (Int, Int) -> V3?, region: (xs: Range<Int>, ys: Range<Int>), scale k: Double = 1) -> ClipCount {
    var c = ClipCount()
    for y in region.ys {
        for x in region.xs {
            guard let e0 = expected(x, y) else { continue }
            let e = e0 * k
            let o = img.rgb(x, y)
            c.pixels += 1
            let err = simd_reduce_max(simd_abs(o - e))
            let tol = 0.01 + 0.03 * simd_reduce_max(simd_abs(e))
            if !isInGamut(e, eps: 0.002) {
                c.expectedOutOfRange += 1
                if err > tol && isInGamut(o, eps: 0.002) { c.clipped += 1 }
            } else {
                c.maxErrInRange = max(c.maxErrInRange, err)
            }
        }
    }
    return c
}

func expectedPatchValue(_ patches: [Patch], ws: WorkingSpace, placement: Placement?, inset: Double) -> (Int, Int) -> V3? {
    let rects = patches.map { (placement?.map($0.rect) ?? $0.rect).inset(inset) }
    let vals = patches.map { ws.math.fromXYZ * $0.xyz }
    return { x, y in
        let pt = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
        for (i, r) in rects.enumerated() where r.contains(pt) { return vals[i] }
        return nil
    }
}

/// CG 探针：把 ImageIO 解码的 CGImage 画进工作空间的 half-float CGContext，看 CG 会不会截断。
func cgDraw(_ img: CGImage, into space: CGColorSpace, half: Bool = true) -> FImage {
    let info = half
        ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGImageByteOrderInfo.order16Little.rawValue
        : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: half ? 16 : 8, bytesPerRow: 0,
                        space: space, bitmapInfo: info)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return readRaw(ctx.makeImage()!).0
}

/// 照片边缘：外沿 3px 背景带相对 #FAFAF8 的最大偏差，以及内沿 3px 相对向内 8px 处像素的最大偏差
/// （Lanczos 把透明区卷进滤波核时，振铃会出现在内沿）。
func edgeBandDeviation(_ img: FImage, photo: CGRect) -> (outer: Int, inner: Int) {
    var outer = 0, inner = 0
    let o = photo.insetBy(dx: -3, dy: -3)
    for y in Int(o.minY)..<Int(o.maxY) {
        for x in Int(o.minX)..<Int(o.maxX) where !photo.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
            let p = img[x, y]
            outer = max(outer, abs(code8(p.x) - bgSRGB8.0), abs(code8(p.y) - bgSRGB8.1), abs(code8(p.z) - bgSRGB8.2))
        }
    }
    func diff(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Int { max(abs(code8(a.x) - code8(b.x)), abs(code8(a.y) - code8(b.y)), abs(code8(a.z) - code8(b.z))) }
    let x0 = Int(photo.minX), x1 = Int(photo.maxX) - 1, y0 = Int(photo.minY), y1 = Int(photo.maxY) - 1
    for y in (y0 + 10)..<(y1 - 10) {
        for i in 0..<3 {
            inner = max(inner, diff(img[x0 + i, y], img[x0 + 8, y]), diff(img[x1 - i, y], img[x1 - 8, y]))
        }
    }
    for x in (x0 + 10)..<(x1 - 10) {
        for i in 0..<3 {
            inner = max(inner, diff(img[x, y0 + i], img[x, y0 + 8]), diff(img[x, y1 - i], img[x, y1 - 8]))
        }
    }
    return (outer, inner)
}
