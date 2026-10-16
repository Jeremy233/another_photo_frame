import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PhotoFrameCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoFrameRendering

// 测试只用代码合成的图片，或 Experiments/ColorPoC/fixtures 里已有的合成 fixture。不使用任何真实照片。

enum Fixtures {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Experiments/ColorPoC/fixtures")

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
}

/// 每个测试自己的临时目录。
func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhotoFrameRenderingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - 合成图片

/// 8-bit RGB 图像，像素由闭包给出（sRGB 编码值 0…255）。
func makeImage8(width: Int, height: Int, space: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB),
                _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            let i = (y * width + x) * 4
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: space ?? CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// 16-bit RGB 图像，像素值 0…65535。
func makeImage16(width: Int, height: Int, space: CGColorSpace, _ pixel: (Int, Int) -> (UInt16, UInt16, UInt16)) -> CGImage {
    var px = [UInt16](repeating: 0, count: width * height * 3)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            let i = (y * width + x) * 3
            px[i] = r; px[i + 1] = g; px[i + 2] = b
        }
    }
    let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
    return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
                   space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageByteOrderInfo.order16Little.rawValue),
                   provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

func writeImage(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw TestError("无法创建 \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw TestError("写出失败 \(url.lastPathComponent)") }
}

/// 横向渐变的「照片」：左右两端颜色不同，容易看出裁切和方向。
func writeGradientPhoto(width: Int, height: Int, to url: URL, type: UTType = .png) throws {
    let img = makeImage8(width: width, height: height) { x, y in
        (UInt8(40 + 160 * x / max(1, width - 1)), UInt8(60 + 120 * y / max(1, height - 1)), 90)
    }
    try writeImage(img, to: url, type: type, properties: type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 1.0] : [:])
}

struct TestError: Error, CustomStringConvertible {
    var description: String
    init(_ s: String) { description = s }
}

// MARK: - 读回

/// 输出文件的 sRGB 8-bit 像素（文件本身是 sRGB，画进同一空间不做转换）。
struct RGBA8Image {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    subscript(x: Int, y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
}

/// 8-bit 码值在容差内相等（半精度工作格式 + Lanczos 会带来 ±1 的误差）。
func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int = 1) -> Bool {
    abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
}

func readSRGB8(_ url: URL) throws -> RGBA8Image {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw TestError("无法读取 \(url.lastPathComponent)") }
    return draw8(img)
}

func draw8(_ img: CGImage) -> RGBA8Image {
    let w = img.width, h = img.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return RGBA8Image(width: w, height: h, bytes: bytes)
}

// MARK: - 预设

func makePreset(
    width: Int = 1080, height: Int = 1440, margin: Int = 60,
    background: String = "#FAFAF8",
    mode: CanvasSettings.Mode = .fit, crop: CropSettings? = nil,
    panorama: PanoramaSettings = .disabled,
    layers: [OverlayLayer] = [], slots: [AssetSlot] = [],
    output: OutputSettings = OutputSettings(format: .png)
) -> ExportPreset {
    ExportPreset(
        name: "Test",
        canvas: CanvasSettings(width: width, height: height, background: PresetColor(hex: background),
                               minMarginPx: margin, mode: mode, crop: crop),
        panorama: panorama, layers: layers, assetSlots: slots, output: output)
}

func render(_ source: URL, _ preset: ExportPreset, assets: [String: RenderAsset] = [:],
            override: SourceColorOverride? = nil, overrides: [String: String] = [:]) async throws -> RenderResult {
    let dir = try makeTempDirectory()
    let job = RenderJob(sourceURL: source, preset: preset, assets: assets, outputDirectory: dir,
                        sourceColorOverride: override, metadataOverrides: overrides)
    return try await PhotoFrameRenderer().render(job: job)
}

// MARK: - 颜色数学（独立于被测框架）

enum ColorMath {
    static func srgbToLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    /// sRGB 编码值（0…1）→ D65 XYZ → Lab（D65 白点）。
    static func lab(srgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let r = srgbToLinear(srgb.0), g = srgbToLinear(srgb.1), b = srgbToLinear(srgb.2)
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func deltaE2000(_ l1: (Double, Double, Double), _ l2: (Double, Double, Double)) -> Double {
        let (L1, a1, b1) = l1, (L2, a2, b2) = l2
        let C1 = hypot(a1, b1), C2 = hypot(a2, b2), Cm = (C1 + C2) / 2
        let G = 0.5 * (1 - sqrt(pow(Cm, 7) / (pow(Cm, 7) + pow(25, 7))))
        let a1p = (1 + G) * a1, a2p = (1 + G) * a2
        let C1p = hypot(a1p, b1), C2p = hypot(a2p, b2)
        func hue(_ b: Double, _ a: Double) -> Double { (b == 0 && a == 0) ? 0 : (atan2(b, a) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }
        let h1 = hue(b1, a1p), h2 = hue(b2, a2p)
        let dL = L2 - L1, dC = C2p - C1p
        var dh = 0.0
        if C1p * C2p != 0 { dh = h2 - h1; if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 } }
        let dH = 2 * sqrt(C1p * C2p) * sin(dh / 2 * .pi / 180)
        let Lm = (L1 + L2) / 2, Cmp = (C1p + C2p) / 2
        var hm = h1 + h2
        if C1p * C2p != 0 {
            if abs(h1 - h2) > 180 { hm = h1 + h2 < 360 ? (h1 + h2 + 360) / 2 : (h1 + h2 - 360) / 2 } else { hm = (h1 + h2) / 2 }
        }
        let T = 1 - 0.17 * cos((hm - 30) * .pi / 180) + 0.24 * cos(2 * hm * .pi / 180)
            + 0.32 * cos((3 * hm + 6) * .pi / 180) - 0.20 * cos((4 * hm - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hm - 275) / 25, 2))
        let Rc = 2 * sqrt(pow(Cmp, 7) / (pow(Cmp, 7) + pow(25, 7)))
        let Sl = 1 + 0.015 * pow(Lm - 50, 2) / sqrt(20 + pow(Lm - 50, 2))
        let Sc = 1 + 0.045 * Cmp, Sh = 1 + 0.015 * Cmp * T
        let Rt = -sin(2 * dTheta * .pi / 180) * Rc
        return sqrt(pow(dL / Sl, 2) + pow(dC / Sc, 2) + pow(dH / Sh, 2) + Rt * (dC / Sc) * (dH / Sh))
    }

    static func deltaE(_ a: (Int, Int, Int), _ b: (Double, Double, Double)) -> Double {
        deltaE2000(lab(srgb: (Double(a.0) / 255, Double(a.1) / 255, Double(a.2) / 255)), lab(srgb: b))
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        let s = v.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }
}

/// ColorPoC 的 96 色色卡（与 Experiments/ColorPoC/Sources/colorpoc/Fixtures.swift 相同的生成规则）。
enum Chart {
    static let cell = 80, cols = 12, rows = 8

    static let colors: [(Double, Double, Double)] = {
        let checker: [(Int, Int, Int)] = [
            (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
            (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
            (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
            (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
        ]
        var c = checker.map { (Double($0.0) / 255, Double($0.1) / 255, Double($0.2) / 255) }
        for g in [0.0, 0.02, 0.05, 0.1, 0.2, 0.3, 0.45, 0.6, 0.75, 0.9, 0.98, 1.0] { c.append((g, g, g)) }
        for s in [1.0, 0.6] { c += [(s, 0, 0), (0, s, 0), (0, 0, s), (0, s, s), (s, 0, s), (s, s, 0)] }
        var seed: UInt64 = 0x5EED
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        while c.count < cols * rows { c.append((rnd(), rnd(), rnd())) }
        return c
    }()

    /// 输出（与色卡同尺寸、无缩放）中每个色块内部像素对真值的 ΔE2000。
    static func deltaEs(_ img: RGBA8Image, originX: Int = 0, originY: Int = 0) -> [Double] {
        var out: [Double] = []
        for (i, truth) in colors.enumerated() {
            let x0 = originX + (i % cols) * cell, y0 = originY + (i / cols) * cell
            for y in stride(from: y0 + 8, to: y0 + cell - 8, by: 4) {
                for x in stride(from: x0 + 8, to: x0 + cell - 8, by: 4) {
                    out.append(ColorMath.deltaE(img[x, y], truth))
                }
            }
        }
        return out
    }
}
