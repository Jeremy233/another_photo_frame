import CoreGraphics
import Foundation
import ImageIO
import PhotoFrameCore
import PhotoFrameStorage
import Testing
import UniformTypeIdentifiers
@testable import PhotoFrameRendering

/// D-131–D-135：内置品牌 logo、胶卷装饰与手填的元数据。
@Suite("内置品牌 logo 与胶卷装饰")
struct BuiltInOverlayTests {
    @Test("每个内置 SVG 都按受信任模式完整解析（不跳过任何元素）；用户素材的规则不变")
    func builtInSVGsParse() throws {
        let svgs = BuiltInWatermarks.filePaths.filter { $0.hasSuffix(".svg") }
        #expect(svgs.count > 60)
        for path in svgs {
            let svg = try RestrictedSVG.parse(try #require(BuiltInWatermarks.fileData(path)), trusted: true)
            #expect(svg.warnings.isEmpty, "\(path): \(svg.warnings)")
            #expect(!svg.commands.isEmpty, "\(path)")
        }
        // 用户导入的 SVG 仍不允许 url( 引用（渐变）。
        let nikon = try #require(BuiltInWatermarks.fileData("cameras/nikon/nikon-emblem.svg"))
        #expect(throws: RenderError.self) { try RestrictedSVG.parse(nikon) }
        let gradients = try RestrictedSVG.parse(nikon, trusted: true).commands.filter {
            if case .gradientFill = $0 { true } else { false }
        }
        #expect(gradients.count == 10, "Nikon 标志的 10 道光束是渐变")
    }

    @Test("设了 PF_DUMP_BUILTINS 时把每个内置 SVG 画成 PNG（人工比对用）",
          .enabled(if: ProcessInfo.processInfo.environment["PF_DUMP_BUILTINS"] != nil))
    func dumpBuiltIns() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PF_DUMP_BUILTINS"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for path in BuiltInWatermarks.filePaths where path.hasSuffix(".svg") {
            let svg = try RestrictedSVG.parse(try #require(BuiltInWatermarks.fileData(path)), trusted: true)
            let h = 256.0, w = (h * svg.viewBox.width / svg.viewBox.height).rounded(.up)
            let ctx = try #require(CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            svg.draw(in: ctx, box: CGRect(x: 0, y: 0, width: w, height: h))
            try writeImage(try #require(ctx.makeImage()), to: dir.appendingPathComponent(path.replacingOccurrences(of: "/", with: "__") + ".png"), type: .png)
        }
    }

    @Test("元数据：手填品牌型号组成 {camera} 并认品牌；数字补单位；尼康 Z 系列去空格；{brand} 按 logo 大小写")
    func metadata() {
        let nikon: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "NIKON CORPORATION",
                                                                      kCGImagePropertyTIFFModel: "NIKON Z 6_2"]]
        let a = MetadataText.resolve(from: nikon, overrides: [:])
        #expect(a.values["camera"] == "NIKON Z6II" && a.values["model"] == "NIKON Z6II" && a.values["make"] == "NIKON CORPORATION")
        #expect(a.values["brand"] == "Nikon" && a.brand?.id == "nikon")

        let scan = MetadataText.resolve(from: [:], overrides: ["make": "Mamiya", "model": "7", "aperture": "8", "shutter": "1/250",
                                                               "iso": "200", "film": "Kodak Gold 200", "lens": "  "])
        #expect(scan.values["camera"] == "Mamiya 7" && scan.brand?.id == "mamiya" && scan.values["brand"] == "Mamiya")
        #expect(scan.values["aperture"] == "f/8" && scan.values["shutter"] == "1/250s" && scan.values["iso"] == "ISO 200")
        #expect(scan.film == "Kodak Gold 200" && scan.values["lens"] == nil, "空白的手填值不算")
        #expect(MetadataText.resolve(from: [:], overrides: ["iso": "ISO 800", "aperture": "f/2.8", "shutter": "2s"]).values
            == ["iso": "ISO 800", "aperture": "f/2.8", "shutter": "2s"], "已经带单位的照原样")

        let unknown = MetadataText.resolve(from: [:], overrides: ["make": "GoPro Inc.", "model": "HERO12"])
        #expect(unknown.brand == nil && unknown.values["brand"] == "GoPro")
        #expect(MetadataText.tidyModel("NIKON Z f", make: "NIKON CORPORATION") == "NIKON Zf")
        #expect(MetadataText.tidyModel("NIKON D850", make: "NIKON CORPORATION") == "NIKON D850")
        #expect(MetadataText.tidyModel("Z 8", make: "Canon") == "Z 8", "只改尼康")
    }

    // MARK: - 渲染

    static func photo() throws -> URL {
        let url = try makeTempDirectory().appendingPathComponent("photo.png")
        try writeGradientPhoto(width: 1200, height: 800, to: url)
        return url
    }

    /// 画在画布左上角（留白里），返回这一块的像素。
    static func corner(_ layer: OverlayLayer, background: String = "#FAFAF8", overrides: [String: String],
                       slot: BuiltInAsset? = nil)
        async throws -> (pixels: [(Int, Int, Int)], warnings: [RenderWarning])
    {
        var placed = layer
        placed.anchor = .topLeft
        placed.reference = .canvas
        // 素材槽来源（D-139）：图层的槽绑到一个内置素材，渲染器拿到的是它的内容地址。
        let slots = placed.slotId.map { [AssetSlot(slotId: $0)] } ?? []
        let assets = zip(placed.slotId.map { [$0] } ?? [], slot.map { [$0] } ?? []).reduce(into: [String: RenderAsset]()) {
            $0[$1.0] = RenderAsset(fileURL: $1.1.contentURL, format: $1.1.format)
        }
        let result = try await render(try photo(), makePreset(background: background, layers: [placed], slots: slots),
                                      assets: assets, overrides: overrides)
        let img = try readSRGB8(try #require(result.outputs.first).fileURL)
        var pixels: [(Int, Int, Int)] = []
        for y in 0..<56 { for x in 0..<400 { pixels.append(img[x, y]) } }
        return (pixels, result.warnings)
    }

    static func logo(_ style: BrandLogoStyle = BrandLogoStyle(heightPx: 40)) -> OverlayLayer {
        OverlayLayer(layerId: "logo", type: .brandLogo, logo: style)
    }

    @Test("单色 logo：原色在浅色画布上是黑色，在深色画布上是白色")
    func monoLogo() async throws {
        let light = try await Self.corner(Self.logo(), overrides: ["make": "SONY"])
        #expect(light.pixels.contains { $0.0 < 60 && $0.1 < 60 && $0.2 < 60 })
        let dark = try await Self.corner(Self.logo(), background: "#111111", overrides: ["make": "SONY"])
        #expect(dark.pixels.contains { $0.0 > 200 && $0.1 > 200 && $0.2 > 200 })
    }

    @Test("Kodak 在「自动」下也是红黄；自定颜色时换成单色版")
    func kodak() async throws {
        let auto = try await Self.corner(Self.logo(BrandLogoStyle(heightPx: 30, colorMode: .auto)), overrides: ["make": "Kodak"])
        #expect(auto.pixels.contains { $0.0 > 180 && $0.1 < 80 && $0.2 < 80 }, "红")
        #expect(auto.pixels.contains { $0.0 > 200 && $0.1 > 140 && $0.2 < 80 }, "黄")
        let custom = try await Self.corner(Self.logo(BrandLogoStyle(heightPx: 30, colorMode: .custom, color: PresetColor(hex: "#0000FF"))),
                                           overrides: ["make": "Kodak"])
        #expect(!custom.pixels.contains { $0.0 > 180 && $0.1 < 80 && $0.2 < 80 })
        #expect(custom.pixels.contains { $0.2 > 200 && $0.0 < 60 })
    }

    @Test("彩色 logo 用原色时，深色画布上换成白字版（Fujifilm）")
    func darkVersion() async throws {
        let dark = try await Self.corner(Self.logo(), background: "#111111", overrides: ["make": "FUJIFILM"])
        #expect(dark.pixels.contains { $0.0 > 220 && $0.1 > 220 && $0.2 > 220 }, "白字")
        #expect(dark.pixels.contains { $0.0 > 200 && $0.1 < 60 }, "红点不变")
    }

    @Test("认不出品牌时默认不画并警告；改成显示文字时画 {brand}")
    func unknownBrand() async throws {
        let none = try await Self.corner(Self.logo(), overrides: ["make": "GoPro"])
        #expect(none.warnings.contains { $0.code == "overlay.brand_unknown" })
        #expect(!none.pixels.contains { $0.0 < 120 })
        let text = try await Self.corner(Self.logo(BrandLogoStyle(fallback: .text, heightPx: 30)), overrides: ["make": "GoPro"])
        #expect(text.pixels.contains { $0.0 < 80 && $0.1 < 80 && $0.2 < 80 })
    }

    @Test("胶卷装饰：按源图填的胶卷画图标；没填胶卷时不画、不警告")
    func film() async throws {
        let layer = OverlayLayer(layerId: "film", type: .filmIcon, filmIcon: FilmIconStyle(iconSizePx: 48))
        let drawn = try await Self.corner(layer, overrides: ["film": "Kodak Portra 400"])
        // Portra 400 的图标上半部是紫色 #7657A6。
        #expect(drawn.pixels.contains { abs($0.0 - 0x76) < 12 && abs($0.1 - 0x57) < 12 && abs($0.2 - 0xA6) < 12 })
        let empty = try await Self.corner(layer, overrides: [:])
        #expect(empty.warnings.isEmpty && !empty.pixels.contains { $0.0 < 200 })
        // 没有图标的胶卷：用胶卷品牌的 logo 加文字。
        let fallback = try await Self.corner(layer, overrides: ["film": "Kodak Vision3 50D"])
        #expect(fallback.pixels.contains { $0.0 > 180 && $0.1 < 80 && $0.2 < 80 }, "Kodak 红")
    }

    @Test("品牌 logo 用素材槽里的素材：原色照原样画，自定颜色整个换色；内置的渐变 SVG 按受信任模式解析（D-139）")
    func logoFromSlot() async throws {
        let leica = try #require(BuiltInAsset.asset(path: "cameras/leica/leica.svg"))
        func layer(_ style: BrandLogoStyle) -> OverlayLayer {
            OverlayLayer(layerId: "logo", type: .brandLogo, slotId: "logo", logo: style)
        }
        // 认不出的相机也照样画：素材槽不看相机。
        let original = try await Self.corner(layer(BrandLogoStyle(brand: BrandLogoStyle.fromSlot, heightPx: 30)),
                                             overrides: ["make": "GoPro"], slot: leica)
        #expect(original.warnings.isEmpty, "\(original.warnings)")
        #expect(original.pixels.contains { $0.0 > 180 && $0.1 < 60 && $0.2 < 60 }, "Leica 红")
        let blue = try await Self.corner(layer(BrandLogoStyle(brand: BrandLogoStyle.fromSlot, heightPx: 30, colorMode: .custom,
                                                              color: PresetColor(hex: "#0000FF"))), overrides: [:], slot: leica)
        #expect(blue.pixels.contains { $0.2 > 200 && $0.0 < 60 } && !blue.pixels.contains { $0.0 > 180 && $0.1 < 60 && $0.2 < 60 })
        // 槽里没有素材：警告并跳过。
        let missing = try await Self.corner(layer(BrandLogoStyle(brand: BrandLogoStyle.fromSlot)), overrides: [:])
        #expect(missing.warnings.map(\.code) == ["overlay.asset_missing"])
    }

    @Test("胶卷装饰用素材槽里的图标：源图没填胶卷也画图标（D-139）")
    func filmFromSlot() async throws {
        let portra = try #require(BuiltInAsset.all.first { $0.title == "Kodak Portra 400" })
        let layer = OverlayLayer(layerId: "film", type: .filmIcon, slotId: "film",
                                 filmIcon: FilmIconStyle(film: FilmIconStyle.fromSlot, iconSizePx: 48))
        let drawn = try await Self.corner(layer, overrides: [:], slot: portra)
        #expect(drawn.warnings.isEmpty, "\(drawn.warnings)")
        #expect(drawn.pixels.contains { abs($0.0 - 0x76) < 12 && abs($0.1 - 0x57) < 12 && abs($0.2 - 0xA6) < 12 })
    }

    @Test("普通素材装饰绑定内置素材：用了渐变的 Nikon 标志也能画（D-139）")
    func assetLayerWithBuiltIn() async throws {
        let emblem = try #require(BuiltInAsset.asset(path: "cameras/nikon/nikon-emblem.svg"))
        let layer = OverlayLayer(layerId: "badge", type: .asset, maxBoundsPx: PixelSize(width: 56, height: 56), slotId: "badge")
        let drawn = try await Self.corner(layer, overrides: [:], slot: emblem)
        #expect(drawn.warnings.isEmpty, "\(drawn.warnings)")
        #expect(drawn.pixels.contains { $0.0 > 200 && $0.1 > 170 && $0.2 < 90 }, "Nikon 黄")
    }
}
