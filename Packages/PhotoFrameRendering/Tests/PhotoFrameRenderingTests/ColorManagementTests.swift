import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PhotoFrameCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoFrameRendering

/// 规范 §6.9 色彩管理验收测试。阈值用 D-19 暂定值（ΔE2000 中位 ≤ 1、P95 ≤ 2）。
@Suite("色彩管理验收（§6.9）")
struct ColorManagementTests {
    /// 色卡画布与色卡同尺寸、边距 0：照片不缩放，只测颜色转换。
    static func chartPreset(format: OutputSettings.Format = .png) -> ExportPreset {
        makePreset(width: 960, height: 640, margin: 0, output: OutputSettings(format: format))
    }

    @Test("同一色卡的 sRGB / Adobe RGB / Display P3 / ProPhoto 版本输出 sRGB 后与真值一致",
          arguments: ["chart_srgb", "chart_adobergb", "chart_p3", "chart_prophoto"])
    func iccChart16(_ name: String) async throws {
        let result = try await render(Fixtures.url("\(name)_16.tif"), Self.chartPreset())
        #expect(result.diagnostics.sourceProfileOrigin == "embedded")
        #expect(!result.warnings.contains { $0.code == "source.profile_missing" })
        let d = Chart.deltaEs(try readSRGB8(result.outputs[0].fileURL))
        #expect(ColorMath.percentile(d, 0.5) <= 1, "\(name) 中位 ΔE")
        #expect(ColorMath.percentile(d, 0.95) <= 2, "\(name) P95 ΔE")
    }

    @Test("8-bit JPEG 四种 ICC → JPEG Q100", arguments: ["chart_srgb", "chart_adobergb", "chart_p3", "chart_prophoto"])
    func iccChartJPEG(_ name: String) async throws {
        let result = try await render(Fixtures.url("\(name).jpg"), Self.chartPreset(format: .jpeg))
        let d = Chart.deltaEs(try readSRGB8(result.outputs[0].fileURL))
        #expect(ColorMath.percentile(d, 0.5) <= 1, "\(name) 中位 ΔE")
        #expect(ColorMath.percentile(d, 0.95) <= 2, "\(name) P95 ΔE")
    }

    @Test("缺 ICC 时警告并按 sRGB 解释；带 ICC 的输入不被当作 sRGB")
    func missingProfile() async throws {
        let png = try await render(Fixtures.url("chart_noicc.png"), Self.chartPreset())
        #expect(png.warnings.contains { $0.code == "source.profile_missing" })
        #expect(png.diagnostics.sourceProfileOrigin == "assumedSRGB")
        #expect(!png.diagnostics.hasEmbeddedProfile)
        let d = Chart.deltaEs(try readSRGB8(png.outputs[0].fileURL))
        #expect(ColorMath.percentile(d, 0.95) <= 1)

        // ImageIO 对无 ICC 的 JPEG 也报 sRGB（PoC 坑 1），必须自己看文件。
        let jpg = try await render(Fixtures.url("chart_noicc.jpg"), Self.chartPreset())
        #expect(jpg.warnings.contains { $0.code == "source.profile_missing" })

        let p3 = try await render(Fixtures.url("chart_p3.jpg"), Self.chartPreset())
        #expect(!p3.warnings.contains { $0.code == "source.profile_missing" })
        #expect(p3.diagnostics.sourceProfile.contains("P3"))
    }

    @Test("缺 ICC 时可覆盖输入色彩空间（D-04）")
    func overrideProfile() async throws {
        // 「P3 数值但丢了 ICC」：按 sRGB 解释偏色，覆盖为 Display P3 后恢复。
        let assumed = try await render(Fixtures.url("chart_p3values_noicc.png"), Self.chartPreset())
        let dAssumed = Chart.deltaEs(try readSRGB8(assumed.outputs[0].fileURL))
        #expect(ColorMath.percentile(dAssumed, 0.5) > 1.5)

        let fixed = try await render(Fixtures.url("chart_p3values_noicc.png"), Self.chartPreset(), override: .displayP3)
        #expect(fixed.diagnostics.sourceProfileOrigin == "override")
        let d = Chart.deltaEs(try readSRGB8(fixed.outputs[0].fileURL))
        #expect(ColorMath.percentile(d, 0.5) <= 1)
        #expect(ColorMath.percentile(d, 0.95) <= 2)
    }

    @Test("源图自带 ICC 时忽略覆盖并警告，颜色按文件 ICC（D-04、§6.2）")
    func overrideIgnoredWithEmbeddedProfile() async throws {
        let result = try await render(Fixtures.url("chart_p3.jpg"), Self.chartPreset(), override: .adobeRGB)
        #expect(result.diagnostics.sourceProfileOrigin == "embedded")
        #expect(result.diagnostics.sourceProfile.contains("P3"))
        #expect(result.warnings.contains { $0.code == "source.override_ignored" })
        let d = Chart.deltaEs(try readSRGB8(result.outputs[0].fileURL))
        #expect(ColorMath.percentile(d, 0.5) <= 1)
    }

    @Test("白边 #FAFAF8 的无损输出精确为 (250, 250, 248)（§6.5）")
    func backgroundExact() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("photo.png")
        try writeGradientPhoto(width: 1200, height: 800, to: src)
        let result = try await render(src, makePreset())
        let img = try readSRGB8(result.outputs[0].fileURL)
        let fit = try FitLayout(canvas: PixelSize(width: 1080, height: 1440), minimumMargin: 60,
                                source: PixelSize(width: 1200, height: 800))
        var mismatches = 0, background = 0
        for y in 0..<img.height {
            for x in 0..<img.width {
                let r = fit.pixelRect
                if x >= r.minX, x < r.maxX, y >= r.minY, y < r.maxY { continue }
                background += 1
                if img[x, y] != (250, 250, 248) { mismatches += 1 }
            }
        }
        #expect(background > 0)
        #expect(mismatches == 0)
    }

    @Test("16-bit 渐变：中间运算不是 8-bit")
    func sixteenBitPrecision() async throws {
        // 渲染到浮点，统计不缩放的渐变行里有多少个不同的值：8-bit 中转最多 256 级。
        let url = Fixtures.url("gradient_dark_srgb_16.tif")
        let renderer = PhotoFrameRenderer()
        let source = try SourceDecoder(context: renderer.context)
            .decode(url, neededSize: PixelSize(width: 4096, height: 64), override: nil)
        let image = try #require(source.sdr)
        let w = 4096
        var px = [Float](repeating: 0, count: w * 4)
        px.withUnsafeMutableBytes { buf in
            renderer.context.render(image, toBitmap: buf.baseAddress!, rowBytes: w * 16,
                                    bounds: CGRect(x: 0, y: 32, width: w, height: 1), format: .RGBAf,
                                    colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)
        }
        let levels = Set((0..<w).map { Int((px[$0 * 4 + 1] * 65535).rounded()) })
        #expect(levels.count > 1000, "得到 \(levels.count) 级")
    }

    @Test("PNG 透明素材在暗、亮背景上没有黑边／白边", arguments: ["#202020", "#FAFAF8"])
    func alphaHalo(_ background: String) async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("photo.png")
        try writeImage(makeImage8(width: 100, height: 100) { _, _ in (128, 128, 128) }, to: src, type: .png)
        let layer = OverlayLayer(layerId: "wm", type: .asset, anchor: .center, reference: .canvas,
                                 sizePx: PixelSize(width: 240, height: 96), slotId: "wm")
        let preset = makePreset(width: 600, height: 400, margin: 150, background: background,
                                layers: [layer], slots: [AssetSlot(slotId: "wm")])
        let result = try await render(src, preset, assets: ["wm": RenderAsset(fileURL: Fixtures.url("watermark_alpha.png"), format: .png)])
        let img = try readSRGB8(result.outputs[0].fileURL)
        // 图层框：画布居中 240×96。框内照片之外的区域只有背景与白色/红色水印，
        // 任何像素都不应比背景和水印颜色范围更暗或更亮（±1 码值容差）。
        let bg = try WorkingColor.rgb8(PresetColor(hex: background))
        let photo = try FitLayout(canvas: PixelSize(width: 600, height: 400), minimumMargin: 150,
                                  source: PixelSize(width: 100, height: 100)).pixelRect
        var bad = 0
        for y in 152..<248 {
            for x in 180..<420 {
                if x >= photo.minX - 2, x < photo.maxX + 2, y >= photo.minY - 2, y < photo.maxY + 2 { continue }
                let (r, g, b) = img[x, y]
                // 水印颜色：白 (255,255,255) 与红 (200,30,30)；与背景混合的结果落在各通道的 [min, max] 内。
                let lo = (min(bg.0, 200), min(bg.1, 30), min(bg.2, 30)), hi = (255, 255, 255)
                if r < lo.0 - 1 || g < lo.1 - 1 || b < lo.2 - 1 || r > hi.0 || g > hi.1 || b > hi.2 { bad += 1 }
            }
        }
        #expect(bad == 0)
        // 黑圈检测：深色背景上不应出现比背景更暗的像素；浅色背景上不应出现比背景更暗的灰边。
        var darker = 0
        for y in 152..<248 {
            for x in 180..<420 {
                if x >= photo.minX - 2, x < photo.maxX + 2, y >= photo.minY - 2, y < photo.maxY + 2 { continue }
                let (r, g, b) = img[x, y]
                // 红色块区域本来就比白背景暗，只检查中性像素（R≈G≈B）。
                if abs(r - g) <= 2, abs(g - b) <= 2, r < min(bg.0, bg.1) - 1 { darker += 1 }
            }
        }
        #expect(darker == 0)
    }

    @Test("透明 PNG 缩小到四分之一以下也没有灰边、黑边（先降采样再缩放的路径）", arguments: ["#FAFAF8", "#202020"])
    func alphaHaloWhenShrunk(_ background: String) async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("photo.png")
        try writeImage(makeImage8(width: 100, height: 100) { _, _ in (128, 128, 128) }, to: src, type: .png)
        // watermark_alpha.png 是 400×160，放进 96×38 的框：缩放 0.24，走降采样路径。
        let layer = OverlayLayer(layerId: "wm", type: .asset, anchor: .topLeft, reference: .canvas,
                                 offset: OverlayOffset(x: 20, y: 20), sizePx: PixelSize(width: 96, height: 38), slotId: "wm")
        let preset = makePreset(width: 600, height: 400, margin: 150, background: background,
                                layers: [layer], slots: [AssetSlot(slotId: "wm")])
        let result = try await render(src, preset, assets: ["wm": RenderAsset(fileURL: Fixtures.url("watermark_alpha.png"), format: .png)])
        let img = try readSRGB8(result.outputs[0].fileURL)
        let bg = try WorkingColor.rgb8(PresetColor(hex: background))
        let rect = try #require(result.outputs[0].layers.first?.rect)
        var darker = 0
        for y in rect.minY..<rect.maxY {
            for x in rect.minX..<rect.maxX {
                let (r, g, b) = img[x, y]
                // 只看中性像素（R≈G≈B）：水印的白色与背景的混合只会更亮；比背景暗就是透明像素里的颜色混进了边缘。
                if abs(r - g) <= 2, abs(g - b) <= 2, r < min(bg.0, bg.1) - 1 { darker += 1 }
            }
        }
        #expect(darker == 0)
    }

    @Test("50% 白色在深色背景上按线性光合成（理想 189，gamma 空间为 144）")
    func linearLightOpacity() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("photo.png")
        try writeImage(makeImage8(width: 10, height: 10) { _, _ in (32, 32, 32) }, to: src, type: .png)
        let swatch = dir.appendingPathComponent("white.png")
        try writeImage(makeImage8(width: 50, height: 50) { _, _ in (255, 255, 255) }, to: swatch, type: .png)
        let layer = OverlayLayer(layerId: "w", type: .asset, anchor: .topLeft, reference: .canvas,
                                 offset: OverlayOffset(x: 10, y: 10), sizePx: PixelSize(width: 50, height: 50),
                                 opacity: 0.5, slotId: "w")
        let preset = makePreset(width: 200, height: 200, margin: 80, background: "#202020",
                                layers: [layer], slots: [AssetSlot(slotId: "w")])
        let result = try await render(src, preset, assets: ["w": RenderAsset(fileURL: swatch, format: .png)])
        let img = try readSRGB8(result.outputs[0].fileURL)
        let (r, g, b) = img[35, 35]
        #expect(abs(r - 189) <= 1 && abs(g - 189) <= 1 && abs(b - 189) <= 1, "得到 \(r),\(g),\(b)")
    }

    @Test("EXIF 方向 1、3、6、8：内容方向与尺寸正确，不重复旋转", arguments: [1, 3, 6, 8])
    func orientation(_ o: Int) async throws {
        let preset = makePreset(width: 300, height: 200, margin: 0)
        let result = try await render(Fixtures.url("orientation_\(o).jpg"), preset)
        #expect(result.diagnostics.displaySize == PixelSize(width: 300, height: 200))
        let img = try readSRGB8(result.outputs[0].fileURL)
        let expected = [(220, 40, 40), (40, 180, 60), (40, 60, 200), (230, 200, 40)] // 左上 右上 左下 右下
        for (i, (x, y)) in [(75, 50), (225, 50), (75, 150), (225, 150)].enumerated() {
            let p = img[x, y], e = expected[i]
            #expect(abs(p.0 - e.0) <= 6 && abs(p.1 - e.1) <= 6 && abs(p.2 - e.2) <= 6, "方向 \(o) 象限 \(i)：\(p)")
        }

        // 输出很小时走 ImageIO 降采样解码（缩略图 API 自己应用方向），同样不能重复旋转。
        let small = try await render(Fixtures.url("orientation_\(o).jpg"), makePreset(width: 60, height: 40, margin: 0))
        #expect(small.diagnostics.transformSteps.contains { $0.contains("解码长边 120") })
        let s = try readSRGB8(small.outputs[0].fileURL)
        for (i, (x, y)) in [(15, 10), (45, 10), (15, 30), (45, 30)].enumerated() {
            let p = s[x, y], e = expected[i]
            #expect(abs(p.0 - e.0) <= 8 && abs(p.1 - e.1) <= 8 && abs(p.2 - e.2) <= 8, "降采样 方向 \(o) 象限 \(i)：\(p)")
        }
    }

    @Test("输出 JPEG 嵌入 sRGB ICC；PNG 带标准 sRGB 描述（§6.8）")
    func outputProfiles() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("photo.png")
        try writeGradientPhoto(width: 300, height: 200, to: src)
        let jpeg = try await render(src, makePreset(output: OutputSettings(format: .jpeg)))
        let data = try Data(contentsOf: jpeg.outputs[0].fileURL)
        #expect(JPEGSegments.contains(data, marker: 0xE2, prefix: Data("ICC_PROFILE\0".utf8)))
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyProfileName] as? String == "sRGB IEC61966-2.1")
        #expect(jpeg.outputs[0].colorProfile == "sRGB IEC61966-2.1")

        let png = try await render(src, makePreset(output: OutputSettings(format: .png)))
        let pngData = try Data(contentsOf: png.outputs[0].fileURL)
        #expect(SourceFileFormat.hasEmbeddedColorDescription(pngData, format: .png))
    }

    @Test("BT.709/2020 逆 OETF 参数曲线的 ICC 按曲线本身解码（PoC 坑 20）")
    func parametricRec2020Profile() async throws {
        // Apple 自己的 itur_2020 ICC 的 TRC 就是这种 para type 3（g ≈ 2.222）；ColorSync 直接解码时按 γ2.4。
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("rec2020_16.tif")
        let space = CGColorSpace(iccData: CGColorSpace(name: CGColorSpace.itur_2020)!.copyICCData()!)!
        try writeImage(makeImage16(width: 256, height: 8, space: space) { x, _ in
            let v = UInt16(x * 257); return (v, v, v)
        }, to: src, type: .tiff)
        let renderer = PhotoFrameRenderer()
        let source = try SourceDecoder(context: renderer.context)
            .decode(src, neededSize: PixelSize(width: 256, height: 8), override: nil)
        #expect(source.transformSteps.contains { $0.contains("坑 20") })
        var px = [Float](repeating: 0, count: 256 * 4)
        px.withUnsafeMutableBytes { buf in
            renderer.context.render(source.sdr!, toBitmap: buf.baseAddress!, rowBytes: 256 * 16,
                                    bounds: CGRect(x: 0, y: 0, width: 256, height: 1), format: .RGBAf,
                                    colorSpace: WorkingColor.space)
        }
        let icc = ICCProfile(space.copyICCData()! as Data)!
        let p = try #require(icc.bt709FamilyParametricTRC)
        for x in [32, 64, 128, 192] {
            let expected = ICCProfile.evaluateType3(p, Double(x) / 255)
            #expect(abs(Double(px[x * 4]) / expected - 1) < 0.01, "码值 \(x)：\(px[x * 4]) vs \(expected)")
        }
    }

    @Test("超出 sRGB 的颜色输出时逐通道截断，不出现负值或 NaN 伪影")
    func wideGamutClip() async throws {
        let result = try await render(Fixtures.url("wide_prophoto_16.tif"), Self.chartPreset())
        let img = try readSRGB8(result.outputs[0].fileURL)
        // 第一个色块是 ProPhoto (0,0,0) = 黑；最后一个 {1,1,1} = 白。
        #expect(img[40, 40] == (0, 0, 0))
        let white = img[(63 % 12) * 80 + 40, (63 / 12) * 80 + 40]
        #expect(white.0 >= 254 && white.1 >= 254 && white.2 >= 254)
    }
}
