import CoreGraphics
import CoreImage
import Foundation
import PhotoFrameCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoFrameRendering

/// 几何落到像素上的结果（§5、§13.4 AC-01…AC-03）。几何本身由 PhotoFrameCore 计算并测试，这里验证渲染器照做。
@Suite("版式渲染")
struct LayoutRenderingTests {
    static let background = (250, 250, 248)

    /// 页面上照片矩形之外是否全是背景色，照片矩形内是否不是背景色（照片取值远离 #FAFAF8）。
    static func checkPhotoRect(_ img: RGBA8Image, _ rect: PixelRect?) -> (outsideMismatch: Int, insideBackground: Int) {
        var outside = 0, inside = 0
        for y in 0..<img.height {
            for x in 0..<img.width {
                let isInside = rect.map { x >= $0.minX && x < $0.maxX && y >= $0.minY && y < $0.maxY } ?? false
                let isBackground = img[x, y] == background
                if isInside, isBackground { inside += 1 }
                if !isInside, !isBackground { outside += 1 }
            }
        }
        return (outside, inside)
    }

    @Test("单页 Fit：输出尺寸、照片矩形与 FitLayout 一致")
    func fit() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("photo.png")
        try writeGradientPhoto(width: 1300, height: 480, to: src)
        let result = try await render(src, makePreset())
        #expect(result.outputs.count == 1)
        #expect(result.outputs[0].role == .single)
        #expect(result.outputs[0].fileURL.lastPathComponent == "00.png")
        let img = try readSRGB8(result.outputs[0].fileURL)
        #expect(img.width == 1080 && img.height == 1440)
        let fit = try FitLayout(canvas: PixelSize(width: 1080, height: 1440), minimumMargin: 60,
                                source: PixelSize(width: 1300, height: 480))
        let check = Self.checkPhotoRect(img, fit.pixelRect)
        #expect(check.outsideMismatch == 0)
        #expect(check.insideBackground == 0)
    }

    @Test("比例裁切：裁切框之外的内容不出现，照片填满内框")
    func crop() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("photo.png")
        // 左半红、右半蓝；按 1:1 居中裁切 2:1 的图，左右各裁掉 1/4，两种颜色都应保留。
        try writeImage(makeImage8(width: 800, height: 400) { x, _ in x < 400 ? (200, 30, 30) : (30, 30, 200) },
                       to: src, type: .png)
        let preset = makePreset(width: 600, height: 600, margin: 50, mode: .crop,
                                crop: CropSettings(aspectRatio: Pair(1, 1), anchor: Pair(0, 0.5)))
        let result = try await render(src, preset)
        let img = try readSRGB8(result.outputs[0].fileURL)
        // anchor x = 0：裁切框贴住左边，取 [0, 400) → 全是红色。
        #expect(close(img[60, 300], (200, 30, 30)))
        #expect(close(img[540, 300], (200, 30, 30)))
        #expect(img[25, 300] == Self.background)
    }

    @Test("AC-01：3:1 全景到 IG = 封面 + 4 张 1080×1440，无裁切、无单独白边")
    func ac01() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("pano.png")
        try writeGradientPhoto(width: 3000, height: 1000, to: src)
        let result = try await render(src, makePreset(panorama: PanoramaSettings(enabled: true)))
        #expect(result.outputs.map(\.role) == [.cover, .slide(0), .slide(1), .slide(2), .slide(3)])
        #expect(result.outputs.map { $0.fileURL.lastPathComponent } == ["00.png", "01.png", "02.png", "03.png", "04.png"])
        for out in result.outputs.dropFirst() {
            let img = try readSRGB8(out.fileURL)
            #expect(img.width == 1080 && img.height == 1440)
            let check = Self.checkPhotoRect(img, PixelRect(x: 0, y: 0, width: 1080, height: 1440))
            #expect(check.insideBackground == 0, "切片 \(out.role) 内有背景色像素")
        }
    }

    @Test("AC-02 / AC-03：65:24 全景左右补边 210/210（IG）与 157/158（XHS）",
          arguments: [(1440, 4, 210, 210), (1080, 3, 157, 158)])
    func padding(_ args: (Int, Int, Int, Int)) async throws {
        let (height, n, left, right) = args
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("pano.png")
        try writeGradientPhoto(width: 6500, height: 2400, to: src)
        let result = try await render(src, makePreset(height: height, panorama: PanoramaSettings(enabled: true)))
        #expect(result.outputs.count == n + 1)
        let first = try readSRGB8(result.outputs[1].fileURL)
        let last = try readSRGB8(result.outputs[n].fileURL)
        #expect(Self.checkPhotoRect(first, PixelRect(x: left, y: 0, width: 1080 - left, height: height)) == (0, 0))
        #expect(Self.checkPhotoRect(last, PixelRect(x: 0, y: 0, width: 1080 - right, height: height)) == (0, 0))
    }

    @Test("全景切片可以按位重建虚拟长卷（§5.3 关键边界）")
    func seamless() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("pano.png")
        // 高频细节：棋盘 + 渐变，接缝处任何错位都会产生差异。
        try writeImage(makeImage8(width: 2600, height: 960) { x, y in
            ((x / 7 + y / 7) % 2 == 0 ? UInt8(30 + x % 200) : 220, UInt8(y % 256), UInt8((x * 3) % 256))
        }, to: src, type: .png)
        let preset = makePreset(height: 1080, panorama: PanoramaSettings(enabled: true, verticalMarginPx: 40))
        let result = try await render(src, preset)

        // 参照：同一渲染器把整条长卷当作一页渲染。
        let renderer = PhotoFrameRenderer()
        let pano = try PanoramaLayout(tile: PixelSize(width: 1080, height: 1080), source: PixelSize(width: 2600, height: 960),
                                      verticalMargin: 40)
        let source = try SourceDecoder(context: renderer.context).decode(src, neededSize: pano.pixelImageRect.size, override: nil)
        let photo = PageComposer.scaledPhoto(source.sdr!, region: Rect(x: 0, y: 0, width: 2600, height: 960),
                                             displaySize: source.displaySize, target: pano.pixelImageRect.size)
        let plan = PagePlan(role: .single, canvas: pano.stripSize, background: .defaultBackground,
                            photo: .strip(pano.pixelImageRect, sliceOriginX: 0), overlays: [])
        let strip = PageComposer.compose(plan: plan, photo: photo, overlays: [:],
                                         background: try WorkingColor.ciColor(.defaultBackground))
        let stripImage = draw8(try OutputEncoder(context: renderer.context).renderSRGB8(strip, size: pano.stripSize))

        var mismatches = 0
        for (k, out) in result.outputs.dropFirst().enumerated() {
            let img = try readSRGB8(out.fileURL)
            for y in 0..<img.height {
                for x in 0..<img.width where img[x, y] != stripImage[k * 1080 + x, y] { mismatches += 1 }
            }
        }
        #expect(mismatches == 0)
    }

    @Test("手动张数改多：两端补底色并给出警告（D-11）")
    func manualSlideCount() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("pano.png")
        try writeGradientPhoto(width: 3000, height: 1000, to: src)
        let result = try await render(src, makePreset(panorama: PanoramaSettings(enabled: true, tileCount: .fixed(6))))
        #expect(result.outputs.count == 7)
        #expect(result.warnings.contains { $0.code == "panorama.increased_slide_count" })
        let first = try readSRGB8(result.outputs[1].fileURL)
        #expect(Self.checkPhotoRect(first, nil) == (0, 0), "第一张切片应整张是底色")

        await #expect(throws: RenderError.self) {
            _ = try await render(src, makePreset(panorama: PanoramaSettings(enabled: true, tileCount: .fixed(2))))
        }
    }

    @Test("轮播上限：不输出封面时只算切片，提示里也不提封面（§5.3）")
    func carouselLimitWithoutCover() throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("pano.png")
        try writeGradientPhoto(width: 3000, height: 1000, to: src)
        let renderer = PhotoFrameRenderer()
        func limitWarnings(cover: Bool, limit: Int) throws -> [RenderWarning] {
            let preset = makePreset(panorama: PanoramaSettings(enabled: true, cover: cover))
            return try renderer.plan(sourceURL: src, preset: preset, maxCarouselItems: limit).warnings
                .filter { $0.code == "panorama.exceeds_carousel_limit" }
        }
        // 3000×1000 到 1080×1440：4 张切片。
        #expect(try limitWarnings(cover: true, limit: 4).map(\.message) == ["封面 + 切片共 5 页，超过平台轮播上限 4 页"])
        #expect(try limitWarnings(cover: false, limit: 4).isEmpty)
        #expect(try limitWarnings(cover: false, limit: 3).map(\.message) == ["4 张切片，超过平台轮播上限 3 页"])
    }
}
