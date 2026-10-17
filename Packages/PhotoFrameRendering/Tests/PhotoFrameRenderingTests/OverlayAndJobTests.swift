import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PhotoFrameCore
import PhotoFrameStorage
import Testing
import UniformTypeIdentifiers
@testable import PhotoFrameRendering

@Suite("图层")
struct OverlayTests {
    static func photo(_ dir: URL, width: Int = 1200, height: Int = 800) throws -> URL {
        let url = dir.appendingPathComponent("photo.png")
        try writeGradientPhoto(width: width, height: height, to: url)
        return url
    }

    /// 非背景像素的包围盒（排除照片矩形）。
    static func inkBounds(_ img: RGBA8Image, excluding photo: PixelRect) -> PixelRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<img.height {
            for x in 0..<img.width {
                if x >= photo.minX, x < photo.maxX, y >= photo.minY, y < photo.maxY { continue }
                if img[x, y] != (250, 250, 248) {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        return maxX < 0 ? nil : PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @Test("文字图层画在 OverlayPlacement 给出的矩形内（照片右下角下方 16 px）")
    func textPlacement() async throws {
        let dir = try makeTempDirectory()
        let layer = OverlayLayer(
            layerId: "sig", type: .text, anchor: .bottomRight, offset: OverlayOffset(x: 0, y: 16),
            text: TextStyle(content: "AnotherPhotoFrame", fontSizePx: 24, color: PresetColor(hex: "#3A3A38")))
        let preset = makePreset(layers: [layer])
        let result = try await render(try Self.photo(dir), preset)
        let img = try readSRGB8(result.outputs[0].fileURL)

        let fit = try FitLayout(canvas: PixelSize(width: 1080, height: 1440), minimumMargin: 60,
                                source: PixelSize(width: 1200, height: 800))
        let ink = try #require(Self.inkBounds(img, excluding: fit.pixelRect))
        // 文字块右边缘对齐照片右边缘，上边缘在照片下方 16 px 处（字形有内部留白，墨迹在框内）。
        #expect(ink.maxX <= fit.pixelRect.maxX)
        #expect(ink.minY >= fit.pixelRect.maxY + 16)
        #expect(ink.maxY <= fit.pixelRect.maxY + 16 + 30)
        #expect(ink.width > 100)
    }

    @Test("metadataText：EXIF 占位符与手动覆盖")
    func metadataText() async throws {
        #expect(MetadataText.fill("{camera} · {aperture} · {lens}", values: ["camera": "Z 8", "aperture": "f/8"])
            == ("Z 8 · f/8", ["lens"]))
        let values = MetadataText.values(from: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "NIKON CORPORATION", kCGImagePropertyTIFFModel: "NIKON Z 8"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 8.0, kCGImagePropertyExifExposureTime: 0.004,
                                             kCGImagePropertyExifFocalLength: 35.0, kCGImagePropertyExifISOSpeedRatings: [100]],
        ])
        #expect(values["camera"] == "NIKON Z 8")
        #expect(values["aperture"] == "f/8")
        #expect(values["shutter"] == "1/250s")
        #expect(values["focalLength"] == "35mm")
        #expect(values["iso"] == "ISO 100")

        let dir = try makeTempDirectory()
        let layer = OverlayLayer(layerId: "exif", type: .metadataText, anchor: .bottomLeft,
                                 offset: OverlayOffset(x: 0, y: 16), maxBoundsPx: PixelSize(width: 600, height: 48),
                                 text: TextStyle(template: "{camera} · {aperture}", fontSizePx: 18))
        let result = try await render(try Self.photo(dir), makePreset(layers: [layer]), overrides: ["camera": "Film"])
        #expect(result.warnings.contains { $0.code == "overlay.metadata_missing" && $0.layerId == "exif" })
    }

    @Test("EXIF 文字：缺失字段连同多余分隔符一起去掉（D-64）", arguments: [
        ("{focalLength} · {lens} · {shutter}", "35mm · 1/250s"),
        ("{lens} · {focalLength} · {shutter}", "35mm · 1/250s"),
        ("{focalLength} · {shutter} · {lens}", "35mm · 1/250s"),
        ("{lens} | {iso}", ""),
        ("Shot on {camera} ({lens})", "Shot on Z 8"),
        ("({lens})", ""),
        ("© 2026\n{lens} · {iso}\n{focalLength}", "© 2026\n35mm"),
        ("{focalLength}{shutter}", "35mm1/250s"),
    ])
    func metadataSeparators(_ c: (String, String)) {
        let values = ["focalLength": "35mm", "shutter": "1/250s", "camera": "Z 8"]
        #expect(MetadataText.fill(c.0, values: values).text == c.1)
    }

    @Test("EXIF 文字全部缺失：不画图层，仍给警告")
    func metadataAllMissing() async throws {
        let dir = try makeTempDirectory()
        let layer = OverlayLayer(layerId: "exif", type: .metadataText, anchor: .bottomLeft, offset: OverlayOffset(x: 0, y: 16),
                                 maxBoundsPx: PixelSize(width: 600, height: 48),
                                 text: TextStyle(template: "{lens} · {iso}", fontSizePx: 18))
        let result = try await render(try Self.photo(dir), makePreset(layers: [layer]))
        #expect(result.warnings.contains { $0.code == "overlay.metadata_missing" && $0.layerId == "exif" })
        #expect(result.outputs[0].layers.isEmpty)
        let plain = try await render(try Self.photo(dir), makePreset())
        #expect(try readSRGB8(result.outputs[0].fileURL).bytes == readSRGB8(plain.outputs[0].fileURL).bytes)
    }

    @Test("受限 SVG：路径、圆弧、变换可以渲染")
    func svgRender() async throws {
        let dir = try makeTempDirectory()
        let svg = dir.appendingPathComponent("badge.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50" width="100" height="50">
          <title>badge</title>
          <g transform="translate(10,5)">
            <rect x="0" y="0" width="30" height="40" fill="#C83232"/>
            <path d="M40 0 h20 v40 h-20 z M70 20 a10 10 0 1 0 20 0 a10 10 0 1 0 -20 0" fill="rgb(30,30,200)" fill-rule="evenodd"/>
            <line x1="0" y1="45" x2="80" y2="45" stroke="black" stroke-width="2"/>
          </g>
        </svg>
        """.write(to: svg, atomically: true, encoding: .utf8)
        let layer = OverlayLayer(layerId: "b", type: .cameraBadge, anchor: .topLeft, reference: .canvas,
                                 offset: OverlayOffset(x: 10, y: 10), sizePx: PixelSize(width: 200, height: 100), slotId: "camera.badge")
        let preset = makePreset(width: 600, height: 600, margin: 150, layers: [layer], slots: [AssetSlot(slotId: "camera.badge")])
        let result = try await render(try Self.photo(dir, width: 100, height: 100), preset,
                                      assets: ["camera.badge": RenderAsset(fileURL: svg, format: .svg)])
        let img = try readSRGB8(result.outputs[0].fileURL)
        // viewBox 100×50 放大 2 倍画进 200×100：红色矩形中心 (10 + 2·(10+15), 10 + 2·(5+20))。
        #expect(close(img[60, 60], (200, 50, 50), tolerance: 2), "\(img[60, 60])")
        #expect(close(img[10 + 2 * 60, 10 + 2 * 25], (30, 30, 200), tolerance: 2), "\(img[130, 60])")
        #expect(img[5, 5] == (250, 250, 248))
    }

    @Test("SVG 中的脚本、外部引用、DOCTYPE 被拒绝（D-09）", arguments: [
        #"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="https://example.com/a.png"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1" fill="url(#g)"/></svg>"#,
        #"<!DOCTYPE svg [<!ENTITY x "y">]><svg xmlns="http://www.w3.org/2000/svg"/>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1" onclick="x()"/></svg>"#,
        // 与素材导入共用的规则与上限（D-87：AssetValidator.SVGPolicy、AssetImportLimits.default）
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\">" + String(repeating: "<g>", count: 70)
            + String(repeating: "</g>", count: 70) + "</svg>",
    ])
    func svgRejected(_ source: String) throws {
        #expect(throws: RenderError.self) { _ = try RestrictedSVG.parse(Data(source.utf8)) }
    }

    @Test("动画元素与处理指令：导入时拒绝，渲染时跳过 / 忽略（D-87）")
    func svgRenderingIsLaxerThanImport() throws {
        let animated = #"<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="2" height="2"/><animate attributeName="x" to="2"/></svg>"#
        let parsed = try RestrictedSVG.parse(Data(animated.utf8))
        #expect(parsed.commands.count == 1)
        #expect(parsed.warnings.contains { $0.contains("animate") })
        let instruction = #"<?xml-stylesheet type="text/css" href="x.css"?><svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1"/></svg>"#
        #expect(try RestrictedSVG.parse(Data(instruction.utf8)).commands.count == 1)
        #expect(AssetValidator.SVGPolicy.forbiddenElements.isSuperset(of: AssetValidator.SVGPolicy.animationElements))
        #expect(AssetValidator.SVGPolicy.forbiddenElements.isSuperset(of: AssetValidator.SVGPolicy.renderingForbiddenElements))
    }

    @Test("缺少素材：警告并跳过；跳过列表中的图层不重复警告")
    func missingAsset() async throws {
        let dir = try makeTempDirectory()
        let layers = [
            OverlayLayer(layerId: "a", type: .asset, sizePx: PixelSize(width: 10, height: 10), slotId: "s1"),
            OverlayLayer(layerId: "b", type: .asset, sizePx: PixelSize(width: 10, height: 10), slotId: "s2"),
        ]
        let job = RenderJob(sourceURL: try Self.photo(dir), preset: makePreset(layers: layers), skippedLayerIds: ["b"],
                            outputDirectory: dir)
        let result = try await PhotoFrameRenderer().render(job: job)
        #expect(result.warnings.filter { $0.code == "overlay.asset_missing" }.map(\.layerId) == ["a"])
    }

    @Test("全景：图层默认只在封面；selectedSlides 超出页数只提示（D-44）")
    func panoramaVisibility() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("pano.png")
        try writeGradientPhoto(width: 3000, height: 1000, to: src)
        let cover = OverlayLayer(layerId: "c", type: .text, anchor: .bottom, offset: OverlayOffset(x: 0, y: 16),
                                 text: TextStyle(content: "COVER", fontSizePx: 30))
        let pages = OverlayLayer(layerId: "p", type: .text, visibility: .selectedSlides([2, 9]), anchor: .bottomRight,
                                 reference: .photo(.inside), offset: OverlayOffset(x: 20, y: 20),
                                 text: TextStyle(content: "2", fontSizePx: 40, color: PresetColor(hex: "#FFFFFF")))
        let result = try await render(src, makePreset(panorama: PanoramaSettings(enabled: true), layers: [cover, pages]))
        #expect(result.warnings.contains { $0.code == "overlay.missing_pages" && $0.layerId == "p" })
        let coverImg = try readSRGB8(result.outputs[0].fileURL)
        let fit = try FitLayout(canvas: PixelSize(width: 1080, height: 1440), minimumMargin: 60, source: PixelSize(width: 3000, height: 1000))
        #expect(Self.inkBounds(coverImg, excluding: fit.pixelRect) != nil)
        // 切片 0（第 1 页）没有任何图层：与不带图层的渲染逐像素相同。
        let plain = try await render(src, makePreset(panorama: PanoramaSettings(enabled: true)))
        #expect(try readSRGB8(result.outputs[1].fileURL).bytes == readSRGB8(plain.outputs[1].fileURL).bytes)
        #expect(try readSRGB8(result.outputs[2].fileURL).bytes != readSRGB8(plain.outputs[2].fileURL).bytes)
    }
}

@Suite("元数据（§6.8）")
struct MetadataOutputTests {
    static func sourceWithExif(_ dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("exif.jpg")
        let img = makeImage8(width: 200, height: 100) { x, _ in (UInt8(x), 120, 80) }
        try writeImage(img, to: url, type: .jpeg, properties: [
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestMake", kCGImagePropertyTIFFModel: "TestModel",
                                             kCGImagePropertyTIFFArtist: "Test Author", kCGImagePropertyTIFFCopyright: "© Test"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCByline: ["Test Author"],
                                             kCGImagePropertyIPTCCopyrightNotice: "© Test"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 5.6, kCGImagePropertyExifBodySerialNumber: "SN123",
                                             kCGImagePropertyExifUserComment: "private"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 43.7, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 110.7, kCGImagePropertyGPSLongitudeRef: "W"],
        ])
        return url
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [CFString: Any]
    }

    @Test("默认不写出拍摄参数与 GPS；方向不写或为 1", arguments: [OutputSettings.Format.jpeg, .png])
    func defaultStripped(_ format: OutputSettings.Format) async throws {
        let dir = try makeTempDirectory()
        let result = try await render(try Self.sourceWithExif(dir), makePreset(width: 400, height: 400, output: OutputSettings(format: format)))
        let p = Self.properties(result.outputs[0].fileURL)
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
        #expect((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil)
        #expect((p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifFNumber] == nil)
        #expect((p[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test("「保留拍摄参数」与「保留 GPS」各自独立；序列号与用户注释从不写出")
    func optIn() async throws {
        let dir = try makeTempDirectory()
        let src = try Self.sourceWithExif(dir)
        let shooting = try await render(src, makePreset(width: 400, height: 400, output: OutputSettings(
            format: .jpeg, metadata: .init(keepShootingInfo: true))))
        let p = Self.properties(shooting.outputs[0].fileURL)
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String == "TestMake")
        #expect(exif?[kCGImagePropertyExifFNumber] as? Double == 5.6)
        #expect(exif?[kCGImagePropertyExifBodySerialNumber] == nil)
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(p[kCGImagePropertyGPSDictionary] == nil)

        let gps = try await render(src, makePreset(width: 400, height: 400, output: OutputSettings(
            format: .jpeg, metadata: .init(keepGps: true))))
        let g = Self.properties(gps.outputs[0].fileURL)
        #expect(g[kCGImagePropertyGPSDictionary] != nil)
        #expect((g[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil)
    }
}

extension MetadataOutputTests {
    /// 读回作者与版权。ImageIO 写出时把 TIFF Artist 存成 XMP dc:creator，所以三处一起看。
    static func author(_ url: URL) -> AuthorInfo {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return AuthorInfo(properties: CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any],
                          xmp: CGImageSourceCopyMetadataAtIndex(src, 0, nil))
    }

    @Test("「保留作者和版权」默认关闭，与拍摄参数分开（D-63）", arguments: [OutputSettings.Format.jpeg, .png])
    func authorAndCopyright(_ format: OutputSettings.Format) async throws {
        let dir = try makeTempDirectory()
        let src = try Self.sourceWithExif(dir)
        let off = try await render(src, makePreset(width: 400, height: 400, output: OutputSettings(
            format: format, metadata: .init(keepShootingInfo: true))))
        #expect(Self.author(off.outputs[0].fileURL) == AuthorInfo(properties: [:], xmp: nil))

        let on = try await render(src, makePreset(width: 400, height: 400, output: OutputSettings(
            format: format, metadata: .init(keepAuthorAndCopyright: true))))
        let p = Self.properties(on.outputs[0].fileURL)
        let b = Self.author(on.outputs[0].fileURL)
        #expect(b.author == "Test Author" && b.copyright == "© Test")
        #expect((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil, "拍摄参数仍关闭")
        #expect(p[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test("作者和版权也从 XMP（dc:creator、dc:rights）读取")
    func authorFromXMP() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("xmp.jpg")
        let meta = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(meta, nil, "dc:creator" as CFString, ["XMP Author"] as CFArray))
        #expect(CGImageMetadataSetValueWithPath(meta, nil, "dc:rights" as CFString, "XMP Rights" as CFString))
        let dest = CGImageDestinationCreateWithURL(src as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(dest, makeImage8(width: 100, height: 100) { _, _ in (90, 90, 90) }, meta, nil)
        #expect(CGImageDestinationFinalize(dest))

        let out = try await render(src, makePreset(width: 300, height: 300, output: OutputSettings(
            format: .jpeg, metadata: .init(keepAuthorAndCopyright: true))))
        let a = Self.author(out.outputs[0].fileURL)
        #expect(a.author == "XMP Author")
        #expect(a.copyright == "XMP Rights")
    }
}

@Suite("任务接口")
struct JobInterfaceTests {
    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [RenderProgress] = []
        func append(_ p: RenderProgress) { lock.withLock { items.append(p) } }
        var all: [RenderProgress] { lock.withLock { items } }
    }

    @Test("按阶段报告进度：decoding → rendering → encoding")
    func progress() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("pano.png")
        try writeGradientPhoto(width: 3000, height: 1000, to: src)
        let log = ProgressLog()
        let job = RenderJob(sourceURL: src, preset: makePreset(panorama: PanoramaSettings(enabled: true)), outputDirectory: dir)
        let result = try await PhotoFrameRenderer().render(job: job) { log.append($0) }
        let stages = log.all.map(\.stage)
        #expect(stages.first == .decoding)
        #expect(stages.firstIndex(of: .rendering)! < stages.firstIndex(of: .encoding)!)
        #expect(log.all.last == RenderProgress(stage: .encoding, completedOutputs: 5, totalOutputs: 5))
        #expect(result.outputs.allSatisfy { $0.byteCount > 0 && FileManager.default.fileExists(atPath: $0.fileURL.path) })
    }

    @Test("取消：抛出 CancellationError，并删除本次写出的文件")
    func cancellation() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("pano.png")
        try writeGradientPhoto(width: 3000, height: 1000, to: src)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let job = RenderJob(sourceURL: src, preset: makePreset(panorama: PanoramaSettings(enabled: true)), outputDirectory: out)
        let renderer = PhotoFrameRenderer()
        let task = Task {
            try await renderer.render(job: job) { p in
                // 写出第一张之后取消。
                if p.stage == .encoding, p.completedOutputs == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test("出错时同样清理已写出的文件；目标已存在时不覆盖")
    func noOverwrite() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("photo.png")
        try writeGradientPhoto(width: 300, height: 200, to: src)
        let existing = dir.appendingPathComponent("00.png")
        try Data("keep".utf8).write(to: existing)
        let job = RenderJob(sourceURL: src, preset: makePreset(), outputDirectory: dir)
        await #expect(throws: RenderError.self) { _ = try await PhotoFrameRenderer().render(job: job) }
        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
    }

    @Test("不支持的输入：HEIC 与无法识别的文件给出稳定错误码")
    func unsupportedInput() async throws {
        let dir = try makeTempDirectory()
        let heic = dir.appendingPathComponent("a.heic")
        try Data([0, 0, 0, 24] + Array("ftypheic".utf8) + [UInt8](repeating: 0, count: 16)).write(to: heic)
        do {
            _ = try await render(heic, makePreset())
            Issue.record("应当失败")
        } catch let e as RenderError {
            #expect(e.code == "render.unsupported_format")
        }
    }
}

@Suite("文字样式（D-111）")
struct TextStyleRenderingTests {
    static func traits(_ font: CTFont) -> (weight: Double, italic: Bool) {
        let t = CTFontCopyTraits(font) as NSDictionary
        let weight = (t[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        return (weight, CTFontGetSymbolicTraits(font).contains(.traitItalic))
    }

    @Test("字重、斜体：系统字体与指定字族都取同一字族里最接近的样式", arguments: [nil, "Helvetica Neue"])
    func weightAndItalic(_ family: String?) throws {
        let regular = try TextBlock.make(text: "Z 8 · f/8", style: TextStyle(fontFamily: family, fontSizePx: 40)).0
        let bold = try TextBlock.make(text: "Z 8 · f/8", style: TextStyle(fontFamily: family, fontWeight: .bold, fontSizePx: 40)).0
        let light = try TextBlock.make(text: "Z 8 · f/8", style: TextStyle(fontFamily: family, fontWeight: .light, fontSizePx: 40)).0
        let italic = try TextBlock.make(text: "Z 8 · f/8", style: TextStyle(fontFamily: family, italic: true, fontSizePx: 40))
        #expect(Self.traits(bold.font).weight > Self.traits(regular.font).weight + 0.1)
        #expect(Self.traits(light.font).weight < Self.traits(regular.font).weight - 0.1)
        #expect(Self.traits(italic.0.font).italic && italic.1.isEmpty)
        #expect(CTFontCopyFamilyName(bold.font) as String == CTFontCopyFamilyName(regular.font) as String)
        #expect(CTFontGetSize(bold.font) == 40)
    }

    @Test("字间距：每个字符之后加上间距，文字框变宽")
    func letterSpacing() throws {
        let text = "ABCDEFGHIJ"
        let plain = try TextBlock.make(text: text, style: TextStyle(fontSizePx: 30)).0
        let wide = try TextBlock.make(text: text, style: TextStyle(fontSizePx: 30, letterSpacingPx: 4)).0
        let grown = wide.naturalSize.width - plain.naturalSize.width
        #expect((36...44).contains(grown), "宽度增加 \(grown)")
    }
}
