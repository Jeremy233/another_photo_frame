import CoreGraphics
import Foundation
import PhotoFrameCore

// 预览模式的输入输出（规范 §6.3「预览 ≈ 导出」、§6.6、§11.2 `renderPreview`、D-18）。
// 预览与导出共用同一条管线，只是采样分辨率与输出方式不同：结果是内存中的位图，不写文件。

/// 预览尺寸。预览从不大于导出尺寸。
public enum PreviewSize: Hashable, Sendable, Codable {
    /// 页面长边不超过这么多像素。
    case maxLongEdge(Int)
    /// 相对导出尺寸的缩放系数，取值 (0, 1]。
    case scale(Double)
}

/// 预览位图的颜色。
public enum PreviewColorMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// 输出预览（§6.6 默认）：8-bit sRGB，像素与 SDR 导出编码前相同（超出 sRGB 的颜色逐通道截断）。
    /// HDR 输出时是文件里的 SDR 底图。
    case sRGB
    /// 显示用：extended sRGB、RGBAh，不截断。输出实际写 HDR 时是 HDR 版本的页面（照片用 HDR 版本，
    /// 背景与图层在参考白），位图带 content headroom；其余情况与 `.sRGB` 是同一页面，但保留 sRGB 色域外的颜色，
    /// 不能用来软打样 SDR 文件。
    case extendedRange
    /// 写文件用（D-106）：`image` 与 `.sRGB` 相同；输出实际写 HDR 时另给 `hdrImage`（与 `.extendedRange` 相同），
    /// 两者合起来用 `PhotoFrameRenderer.gainMapJPEG` 编码成与 HDR 导出同一种格式的 gain map JPEG。
    case gainMap
}

/// 一次预览：一张源图 × 一个预设，输入与 `RenderJob` 相同，只是不需要输出目录。
public struct PreviewRequest: Sendable {
    public var sourceURL: URL
    public var preset: ExportPreset
    public var size: PreviewSize
    public var assets: [String: RenderAsset]
    public var skippedLayerIds: Set<String>
    public var sourceColorOverride: SourceColorOverride?
    public var maxCarouselItems: Int?
    public var metadataOverrides: [String: String]
    /// 只渲染这些轮播页（0 = 封面／单页，切片 k 为 k + 1）；nil 表示全部。
    public var pages: Set<Int>?
    public var color: PreviewColorMode

    public init(
        sourceURL: URL,
        preset: ExportPreset,
        size: PreviewSize,
        assets: [String: RenderAsset] = [:],
        skippedLayerIds: Set<String> = [],
        sourceColorOverride: SourceColorOverride? = nil,
        maxCarouselItems: Int? = nil,
        metadataOverrides: [String: String] = [:],
        pages: Set<Int>? = nil,
        color: PreviewColorMode = .sRGB
    ) {
        self.sourceURL = sourceURL
        self.preset = preset
        self.size = size
        self.assets = assets
        self.skippedLayerIds = skippedLayerIds
        self.sourceColorOverride = sourceColorOverride
        self.maxCarouselItems = maxCarouselItems
        self.metadataOverrides = metadataOverrides
        self.pages = pages
        self.color = color
    }

    /// 预览一个导出任务：输入完全相同，`outputDirectory` 不用。
    public init(job: RenderJob, size: PreviewSize, pages: Set<Int>? = nil, color: PreviewColorMode = .sRGB) {
        self.init(sourceURL: job.sourceURL, preset: job.preset, size: size, assets: job.assets,
                  skippedLayerIds: job.skippedLayerIds, sourceColorOverride: job.sourceColorOverride,
                  maxCarouselItems: job.maxCarouselItems, metadataOverrides: job.metadataOverrides,
                  pages: pages, color: color)
    }

    var inputs: RenderInputs {
        RenderInputs(sourceURL: sourceURL, preset: preset, assets: assets, skippedLayerIds: skippedLayerIds,
                     sourceColorOverride: sourceColorOverride, maxCarouselItems: maxCarouselItems,
                     metadataOverrides: metadataOverrides)
    }
}

public struct PreviewResult: Sendable {
    /// 请求的页，按轮播顺序。
    public var pages: [PreviewPage]
    /// 导出会写出的全部页（封面在前，切片按序号），供预览区切换 `[Cover] [Slide 1] …`（§4.2）。
    public var roles: [OutputRole]
    /// 预览像素 = 导出像素 × 缩放。两个方向分别让预览画布落在整像素上，相差不到半个像素。
    public var scaleX: Double
    public var scaleY: Double
    public var diagnostics: RenderDiagnostics
    public var warnings: [RenderWarning]
}

/// 一页预览。矩形都是左上原点；预览矩形由导出矩形按缩放映射、按像素边取整（每条边误差 ≤ 0.5 px）。
public struct PreviewPage: Sendable {
    public var role: OutputRole
    /// `.sRGB`、`.gainMap`：8-bit sRGB；`.extendedRange`：extended sRGB 半浮点。
    public var image: CGImage
    /// 只有 `.gainMap` 且本页是 HDR 时有：HDR 版本的页面（extended sRGB 半浮点，带 content headroom）。
    public var hdrImage: CGImage?
    public var pixelSize: PixelSize
    /// 同一页导出时的尺寸。
    public var exportPixelSize: PixelSize
    /// 照片在预览页上的像素矩形；整张都是底色的切片为 nil。
    public var photoRect: PixelRect?
    /// 照片在导出页上的像素矩形（与 `RenderedOutput.photoRect` 相同）。
    public var exportPhotoRect: PixelRect?
    /// 本页绘制的图层，按绘制顺序。
    public var layers: [PreviewLayer]
    /// 位图实际的动态范围：只有 `.extendedRange` / `.gainMap` 且输出写 HDR 时为 `.hdr`。
    public var dynamicRange: OutputSettings.DynamicRange
    public var hdrHeadroom: Double?
}

/// 一个图层在某页预览上的位置。
public struct PreviewLayer: Hashable, Sendable, Codable {
    public var layerId: String
    /// 预览页上的像素矩形。
    public var rect: PixelRect
    /// 导出页上的像素矩形（与 `RenderedLayer.rect` 相同）。
    public var exportRect: PixelRect
}

/// 导出页面 → 预览页面的映射。预览画布取整到整像素，每个方向的缩放是有理数 预览边长 / 导出边长，
/// 坐标用整数运算取整：全景切片原点 kW 正好映射到 k × 预览宽度，切片在预览里同样能拼回长卷。
struct PreviewScale: CustomStringConvertible {
    var exportCanvas: PixelSize
    var canvas: PixelSize

    init(canvas exportCanvas: PixelSize, size: PreviewSize) throws(RenderError) {
        let long = Double(max(exportCanvas.width, exportCanvas.height))
        let s: Double
        switch size {
        case .maxLongEdge(let edge):
            guard edge > 0 else { throw .invalidPreviewSize("最大长边应为正数：\(edge)") }
            s = min(1, Double(edge) / long)
        case .scale(let f):
            guard f > 0, f.isFinite else { throw .invalidPreviewSize("缩放系数应在 (0, 1]：\(f)") }
            s = min(1, f)
        }
        self.exportCanvas = exportCanvas
        canvas = PixelSize(width: max(1, Int((Double(exportCanvas.width) * s).rounded())),
                           height: max(1, Int((Double(exportCanvas.height) * s).rounded())))
    }

    var x: Double { Double(canvas.width) / Double(exportCanvas.width) }
    var y: Double { Double(canvas.height) / Double(exportCanvas.height) }

    var description: String {
        "缩放 \(String(format: "%.4f", x)) × \(String(format: "%.4f", y))（\(exportCanvas) → \(canvas)）"
    }

    /// round(v × num / den)，四舍五入（.5 远离负无穷方向向上），整数运算，没有浮点误差。
    private static func scaled(_ v: Int, _ num: Int, _ den: Int) -> Int {
        let n = 2 * v * num + den, d = 2 * den
        return n >= 0 ? n / d : -((-n + d - 1) / d)
    }

    func mapX(_ v: Int) -> Int { Self.scaled(v, canvas.width, exportCanvas.width) }
    func mapY(_ v: Int) -> Int { Self.scaled(v, canvas.height, exportCanvas.height) }

    /// 四条边分别映射：相邻矩形在预览里仍然相邻。
    func map(_ r: PixelRect) -> PixelRect {
        let x0 = mapX(r.minX), x1 = mapX(r.maxX), y0 = mapY(r.minY), y1 = mapY(r.maxY)
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func map(_ plan: PagePlan) -> PagePlan {
        var out = plan
        out.canvas = canvas
        switch plan.photo {
        case .region(let region, let rect):
            let r = map(rect)
            out.photo = r.size.isPositive ? .region(region, rect: r) : .none
        case .strip(let strip, let sliceX):
            let r = map(strip)
            out.photo = r.size.isPositive ? .strip(r, sliceOriginX: mapX(sliceX)) : .none
        case .none:
            break
        }
        out.overlays = plan.overlays.map { ($0.layer, map($0.rect)) }
        return out
    }
}

extension RenderError {
    static func invalidPreviewSize(_ why: String) -> RenderError {
        RenderError(code: "render.invalid_preview_size", message: "预览尺寸无效：\(why)")
    }
}
