import CoreGraphics
import Foundation
import PhotoFrameCore
import Testing
@testable import PhotoFrameRendering

/// 预览模式（§6.3「预览 ≈ 导出」、§11.2 `renderPreview`、D-18）：同一条管线、降采样，结果与导出按比例一致。
@Suite("预览")
struct PreviewTests {
    struct Scenario: CustomTestStringConvertible, Sendable {
        var name: String
        var sourceSize: PixelSize
        var preset: ExportPreset
        var testDescription: String { name }
    }

    static let watermark = RenderAsset(fileURL: Fixtures.url("watermark_alpha.png"), format: .png)

    static let layers = [
        OverlayLayer(layerId: "sig", type: .text, anchor: .bottomRight, offset: OverlayOffset(x: 0, y: 16),
                     text: TextStyle(content: "AnotherPhotoFrame", fontSizePx: 24, color: PresetColor(hex: "#3A3A38"))),
        OverlayLayer(layerId: "wm", type: .asset, anchor: .topLeft, offset: OverlayOffset(x: 0, y: 12),
                     maxBoundsPx: PixelSize(width: 180, height: 60), opacity: 0.8, slotId: "wm"),
    ]

    static let scenarios: [Scenario] = [
        Scenario(name: "Fit + 文字 + PNG 水印", sourceSize: PixelSize(width: 1300, height: 480),
                 preset: makePreset(layers: layers, slots: [AssetSlot(slotId: "wm")])),
        Scenario(name: "比例裁切 1:1", sourceSize: PixelSize(width: 800, height: 500),
                 preset: makePreset(width: 600, height: 600, margin: 50, mode: .crop,
                                    crop: CropSettings(aspectRatio: Pair(1, 1)), layers: [layers[0]])),
        Scenario(name: "65:24 全景 + 切片页码", sourceSize: PixelSize(width: 6500, height: 2400),
                 preset: makePreset(panorama: PanoramaSettings(enabled: true), layers: [
                     layers[0],
                     OverlayLayer(layerId: "page", type: .text, visibility: .allSlides, anchor: .bottomRight,
                                  reference: .photo(.inside), offset: OverlayOffset(x: 20, y: 20),
                                  text: TextStyle(content: "1/4", fontSizePx: 40, color: PresetColor(hex: "#FFFFFF"))),
                 ])),
    ]

    static func source(_ size: PixelSize) throws -> URL {
        let url = try makeTempDirectory().appendingPathComponent("photo.png")
        try writeGradientPhoto(width: size.width, height: size.height, to: url)
        return url
    }

    static func preview(_ source: URL, _ preset: ExportPreset, _ size: PreviewSize, assets: [String: RenderAsset] = [:],
                        pages: Set<Int>? = nil, color: PreviewColorMode = .sRGB) async throws -> PreviewResult {
        try await PhotoFrameRenderer().renderPreview(
            PreviewRequest(sourceURL: source, preset: preset, size: size, assets: assets, pages: pages, color: color))
    }

    /// 预览矩形的每条边与「导出矩形 × 缩放」相差不超过半个像素。
    static func expectProportional(_ preview: PixelRect?, _ export: PixelRect?, sx: Double, sy: Double,
                                   _ what: String) {
        guard let preview, let export else {
            #expect(preview == nil && export == nil, "\(what)：预览 \(String(describing: preview))，导出 \(String(describing: export))")
            return
        }
        let pairs = [
            (Double(preview.minX), Double(export.minX) * sx), (Double(preview.maxX), Double(export.maxX) * sx),
            (Double(preview.minY), Double(export.minY) * sy), (Double(preview.maxY), Double(export.maxY) * sy),
        ]
        for (p, e) in pairs { #expect(abs(p - e) <= 0.5 + 1e-9, "\(what)：预览 \(preview)，导出 \(export) × \(sx)") }
    }

    static func contains(_ r: PixelRect, _ x: Int, _ y: Int) -> Bool {
        x >= r.minX && x < r.maxX && y >= r.minY && y < r.maxY
    }

    static func intersects(_ a: PixelRect, _ b: PixelRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    // MARK: - 版式

    @Test("缩放到 1/4：画布、照片矩形、图层矩形与导出按比例一致，位图与矩形相符", arguments: scenarios)
    func quarterScaleLayout(_ scenario: Scenario) async throws {
        let src = try Self.source(scenario.sourceSize)
        let assets = ["wm": Self.watermark]
        let export = try await render(src, scenario.preset, assets: assets)
        let preview = try await Self.preview(src, scenario.preset, .scale(0.25), assets: assets)

        let canvas = scenario.preset.canvas.size
        #expect(preview.scaleX == Double(preview.pages[0].pixelSize.width) / Double(canvas.width))
        #expect(abs(preview.scaleX - 0.25) < 1e-9 && abs(preview.scaleY - 0.25) < 1e-9)
        #expect(preview.roles == export.outputs.map(\.role))
        #expect(preview.pages.map(\.role) == export.outputs.map(\.role))
        #expect(preview.warnings == export.warnings)

        for (page, out) in zip(preview.pages, export.outputs) {
            let what = "\(scenario.name) 第 \(page.role.page) 页"
            #expect(page.pixelSize == PixelSize(width: canvas.width / 4, height: canvas.height / 4), "\(what)")
            #expect(page.exportPixelSize == out.pixelSize)
            #expect(page.image.width == page.pixelSize.width && page.image.height == page.pixelSize.height)
            #expect(page.dynamicRange == .sdr && page.hdrHeadroom == nil)

            // 导出坐标与导出结果完全相同；预览坐标按比例。
            #expect(page.exportPhotoRect == out.photoRect, "\(what)")
            Self.expectProportional(page.photoRect, out.photoRect, sx: preview.scaleX, sy: preview.scaleY, "\(what) 照片")
            #expect(page.layers.map(\.layerId) == out.layers.map(\.layerId), "\(what)")
            #expect(page.layers.map(\.exportRect) == out.layers.map(\.rect), "\(what)")
            for (layer, exported) in zip(page.layers, out.layers) {
                Self.expectProportional(layer.rect, exported.rect, sx: preview.scaleX, sy: preview.scaleY,
                                        "\(what) 图层 \(layer.layerId)")
            }

            // 位图：照片矩形内没有背景色，照片与图层之外全是背景色。
            let img = draw8(page.image)
            var outside = 0, inside = 0
            for y in 0..<img.height {
                for x in 0..<img.width {
                    if page.layers.contains(where: { Self.contains($0.rect, x, y) }) { continue }
                    let isPhoto = page.photoRect.map { Self.contains($0, x, y) } ?? false
                    let isBackground = img[x, y] == (250, 250, 248)
                    if isPhoto, isBackground { inside += 1 }
                    if !isPhoto, !isBackground { outside += 1 }
                }
            }
            #expect(outside == 0, "\(what)：照片与图层之外有 \(outside) 个像素不是背景色")
            #expect(inside == 0, "\(what)：照片矩形内有 \(inside) 个背景色像素")
            // 不压在照片上的图层确实画出来了（框内有非背景色像素）。
            for layer in page.layers where !(page.photoRect.map { Self.intersects($0, layer.rect) } ?? false) {
                let r = layer.rect
                let ink = (r.minY..<r.maxY).reduce(0) { n, y in
                    n + (r.minX..<r.maxX).filter { img[$0, y] != (250, 250, 248) }.count
                }
                #expect(ink > 0, "\(what)：图层 \(layer.layerId) 没有画出来")
            }
        }
    }

    @Test("65:24 全景到 IG：左右补边 210 px 在 1/4 预览里按像素边取整（52.5 → 53，217.5 → 218）")
    func panoramaPadding() async throws {
        let src = try Self.source(PixelSize(width: 6500, height: 2400))
        let preview = try await Self.preview(src, makePreset(panorama: PanoramaSettings(enabled: true)), .scale(0.25))
        #expect(preview.pages.count == 5)
        #expect(preview.pages[1].exportPhotoRect == PixelRect(x: 210, y: 0, width: 870, height: 1440))
        #expect(preview.pages[1].photoRect == PixelRect(x: 53, y: 0, width: 217, height: 360))
        #expect(preview.pages[4].exportPhotoRect == PixelRect(x: 0, y: 0, width: 870, height: 1440))
        #expect(preview.pages[4].photoRect == PixelRect(x: 0, y: 0, width: 218, height: 360))
    }

    @Test("按最大长边：长边正好等于给定值，不放大")
    func maxLongEdge() async throws {
        let src = try Self.source(PixelSize(width: 1300, height: 480))
        let small = try await Self.preview(src, makePreset(), .maxLongEdge(720))
        #expect(small.pages[0].pixelSize == PixelSize(width: 540, height: 720))
        #expect(small.scaleX == 0.5 && small.scaleY == 0.5)
        let large = try await Self.preview(src, makePreset(), .maxLongEdge(4000))
        #expect(large.pages[0].pixelSize == PixelSize(width: 1080, height: 1440))
        #expect(large.scaleX == 1 && large.scaleY == 1)
    }

    @Test("缩放系数为 1：与 PNG 导出逐像素相同（同一条管线）")
    func identicalAtFullScale() async throws {
        let src = try Self.source(PixelSize(width: 1300, height: 480))
        let preset = makePreset(layers: Self.layers, slots: [AssetSlot(slotId: "wm")])
        let assets = ["wm": Self.watermark]
        let export = try await render(src, preset, assets: assets)
        let preview = try await Self.preview(src, preset, .scale(1), assets: assets)
        #expect(draw8(preview.pages[0].image).bytes == (try readSRGB8(export.outputs[0].fileURL)).bytes)
        #expect(preview.pages[0].photoRect == export.outputs[0].photoRect)
        #expect(preview.pages[0].layers.map(\.rect) == export.outputs[0].layers.map(\.rect))
    }

    // MARK: - 颜色

    @Test("背景色、全景补边色与导出一致（sRGB 精确，extended 读回 ±1）",
          arguments: ["#FAFAF8", "#1E2A3B", "#D23C1E"])
    func backgroundMatchesExport(_ hex: String) async throws {
        let src = try Self.source(PixelSize(width: 6500, height: 2400))
        let preset = makePreset(background: hex, panorama: PanoramaSettings(enabled: true, padColor: .color(PresetColor(hex: "#C0FFEE"))))
        let export = try await render(src, preset)
        let srgb = try await Self.preview(src, preset, .scale(0.25))
        let extended = try await Self.preview(src, preset, .scale(0.25), color: .extendedRange)

        // 封面角上是画布背景，第 1 张切片左侧是补边色。
        for (page, x) in [(0, 2), (1, 2)] {
            let expected = try readSRGB8(export.outputs[page].fileURL)[x * 4, 8]
            #expect(draw8(srgb.pages[page].image)[x, 2] == expected, "第 \(page) 页 sRGB 预览")
            #expect(close(draw8(extended.pages[page].image)[x, 2], expected), "第 \(page) 页 extended 预览")
        }
        #expect(try readSRGB8(export.outputs[0].fileURL)[2, 2] == WorkingColor.rgb8(PresetColor(hex: hex)))
    }

    @Test("照片颜色与导出一致：预览像素与导出对应位置相差 ≤ 2")
    func photoColorsMatchExport() async throws {
        let src = try Self.source(PixelSize(width: 1300, height: 480))
        let export = try await render(src, makePreset())
        let preview = try await Self.preview(src, makePreset(), .scale(0.25))
        let full = try readSRGB8(export.outputs[0].fileURL)
        let small = draw8(preview.pages[0].image)
        let rect = try #require(preview.pages[0].photoRect)
        for fy in [0.2, 0.5, 0.8] {
            for fx in [0.1, 0.5, 0.9] {
                let x = rect.minX + Int(Double(rect.width) * fx), y = rect.minY + Int(Double(rect.height) * fy)
                let ex = Int((Double(x) + 0.5) / preview.scaleX), ey = Int((Double(y) + 0.5) / preview.scaleY)
                #expect(close(small[x, y], full[ex, ey], tolerance: 2), "(\(x), \(y))：\(small[x, y]) vs \(full[ex, ey])")
            }
        }
    }

    @Test("HDR 输出：extendedRange 给出 HDR 页面（照片 > 1、背景不变亮），sRGB 给出 SDR 底图")
    func hdrExtended() async throws {
        let preset = makePreset(width: 960, height: 720, margin: 0, output: OutputSettings(format: .jpeg, dynamicRange: .hdr))
        let src = Fixtures.url("hdr_pq2020_203nit.png")
        let hdr = try await Self.preview(src, preset, .scale(0.5), color: .extendedRange)
        let page = hdr.pages[0]
        #expect(page.dynamicRange == .hdr)
        let headroom = try #require(page.hdrHeadroom)
        #expect(headroom > 6)
        #expect(page.image.bitsPerComponent == 16)
        #expect(page.image.colorSpace?.name == CGColorSpace.extendedSRGB)
        #expect(page.image.contentHeadroom > 1)

        // 读成 extended 线性 sRGB 浮点：色卡第 0 行最亮的色块远超 SDR 白，上方的背景约 0.955（#FAFAF8 的线性值）。
        let w = page.image.width, h = page.image.height
        var px = [Float](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
            space: WorkingColor.extendedLinearSRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGImageByteOrderInfo.order32Little.rawValue))
        ctx.draw(page.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let brightest = (0..<w).map { px[((20 + 20) * w + $0) * 4 + 1] }.max() ?? 0
        #expect(brightest > 4, "最亮色块 \(brightest)")
        #expect(abs(px[(5 * w + 5) * 4 + 1] - 0.955) < 0.02, "背景 \(px[(5 * w + 5) * 4 + 1])")

        let sdr = try await Self.preview(src, preset, .scale(0.5))
        #expect(sdr.pages[0].dynamicRange == .sdr && sdr.pages[0].hdrHeadroom == nil)
        #expect(sdr.pages[0].image.bitsPerComponent == 8)
        #expect(draw8(sdr.pages[0].image)[5, 5] == (250, 250, 248))

        // SDR 源：extendedRange 也只是 SDR 页面。
        let plain = try await Self.preview(Fixtures.url("chart_srgb.jpg"), preset, .scale(0.5), color: .extendedRange)
        #expect(plain.pages[0].dynamicRange == .sdr)
        #expect(plain.warnings.contains { $0.code == "output.hdr_source_not_hdr" })
    }

    // MARK: - 请求选项

    @Test("只渲染指定页：位图与渲染全部页时相同，roles 仍列出全部页")
    func pageSelection() async throws {
        let src = try Self.source(PixelSize(width: 3000, height: 1000))
        let preset = makePreset(panorama: PanoramaSettings(enabled: true))
        let all = try await Self.preview(src, preset, .scale(0.25))
        let one = try await Self.preview(src, preset, .scale(0.25), pages: [2])
        #expect(one.roles == [.cover, .slide(0), .slide(1), .slide(2), .slide(3)])
        #expect(one.pages.map(\.role) == [.slide(1)])
        #expect(draw8(one.pages[0].image).bytes == draw8(all.pages[2].image).bytes)
    }

    @Test("预览一个导出任务：输入相同，不写输出目录")
    func previewOfJob() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("photo.png")
        try writeGradientPhoto(width: 1300, height: 480, to: src)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let job = RenderJob(sourceURL: src, preset: makePreset(layers: [Self.layers[0]]), outputDirectory: out)
        let preview = try await PhotoFrameRenderer().renderPreview(PreviewRequest(job: job, size: .maxLongEdge(360)))
        #expect(preview.pages[0].layers.map(\.layerId) == ["sig"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test("无效的预览尺寸给出稳定错误码", arguments: [PreviewSize.scale(0), .scale(-1), .scale(.nan), .maxLongEdge(0)])
    func invalidSize(_ size: PreviewSize) async throws {
        let src = try Self.source(PixelSize(width: 300, height: 200))
        do {
            _ = try await Self.preview(src, makePreset(), size)
            Issue.record("应当失败")
        } catch let e as RenderError {
            #expect(e.code == "render.invalid_preview_size")
        }
    }

    // MARK: - 取消

    @Test("取消：任务已取消时抛出 CancellationError，渲染器之后照常可用")
    func cancelledBeforeStart() async throws {
        let src = try Self.source(PixelSize(width: 3000, height: 1000))
        let request = PreviewRequest(sourceURL: src, preset: makePreset(panorama: PanoramaSettings(enabled: true)),
                                     size: .scale(0.25))
        let renderer = PhotoFrameRenderer()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await renderer.renderPreview(request)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await renderer.renderPreview(request).pages.count == 5)
    }

    @Test("取消：渲染进行中取消（参数变化时丢弃旧预览）同样抛出 CancellationError")
    func cancelledWhileRunning() async throws {
        let src = try Self.source(PixelSize(width: 6000, height: 2000))
        let request = PreviewRequest(sourceURL: src, preset: makePreset(panorama: PanoramaSettings(enabled: true)),
                                     size: .scale(0.5))
        let renderer = PhotoFrameRenderer()
        let task = Task { try await renderer.renderPreview(request) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
