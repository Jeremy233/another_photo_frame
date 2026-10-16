import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PhotoFrameCore

/// 从源图文件到成品文件的完整渲染（规范 §5、§6、§7）。任务队列（PhotoFrameApplication）调用这里。
///
/// 只负责把成品写进 `RenderJob.outputDirectory`；原子发布、命名、冲突处理由调用方负责（§9.2）。
/// 一个实例可以被多个任务并发使用：`CIContext` 是线程安全的，渲染器本身没有可变状态。
public final class PhotoFrameRenderer: @unchecked Sendable {
    let context: CIContext

    public init() {
        context = WorkingColor.makeContext()
    }

    /// 渲染一个任务。
    ///
    /// - 支持取消：在阶段之间、每一页之前检查 `Task.isCancelled`；取消或出错时删除本次已写出的文件，
    ///   再抛出 `CancellationError` 或 `RenderError`。
    /// - 进度按真实阶段与已写出文件数报告（§9.1），不伪造百分比。
    /// - 输出文件名固定：单页／封面 `00.<ext>`，切片 k 为 `<k+1 两位数>.<ext>`。
    public func render(
        job: RenderJob,
        progress: @Sendable (RenderProgress) -> Void = { _ in }
    ) async throws -> RenderResult {
        var written: [URL] = []
        do {
            return try renderPages(job: job, progress: progress, written: &written)
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    // MARK: - 主流程

    private func renderPages(
        job: RenderJob, progress: (RenderProgress) -> Void, written: inout [URL]
    ) throws -> RenderResult {
        let preset = job.preset
        let output = preset.output
        try Self.validate(output)
        try Task.checkCancellation()
        progress(RenderProgress(stage: .decoding, completedOutputs: 0, totalOutputs: nil))

        // 1. 版式（几何全部来自 PhotoFrameCore）
        let probe = try Self.probe(job.sourceURL)
        var warnings: [RenderWarning] = []
        var layout = try PageLayout.make(preset: preset, source: probe, maxCarouselItems: job.maxCarouselItems,
                                         warnings: &warnings)

        // 2. 解码（按输出所需尺寸降采样，D-18）
        let decoder = SourceDecoder(context: context)
        let source = try decoder.decode(job.sourceURL, neededSize: layout.neededPhotoSize, override: job.sourceColorOverride)
        warnings += source.warnings
        guard source.displaySize == probe.displaySize else {
            throw RenderError(code: "render.decode_failed", message: "解码尺寸与文件属性不符")
        }
        try Task.checkCancellation()

        // 3. 图层内容与位置
        progress(RenderProgress(stage: .rendering, completedOutputs: 0, totalOutputs: layout.pages.count))
        var steps = source.transformSteps
        let overlays = try OverlayPlanner.plan(job: job, layout: &layout, properties: source.properties, warnings: &warnings)

        // 4. 照片：SDR 版本与（需要时）HDR 版本
        let wantsHDR = output.dynamicRange == .hdr
        let writesHDR = wantsHDR && source.hdr != nil
        if wantsHDR && !writesHDR {
            warnings.append(RenderWarning(code: "output.hdr_source_not_hdr", message: "源图不是 HDR，按 SDR 输出"))
        }
        let sdrMethod: SDRRenditionMethod
        switch source.hdrKind {
        case .none: sdrMethod = .none
        case .gainMap, .gainMapTIFF: sdrMethod = .sourceRendition
        case .transferFunction, .floatLinear:
            sdrMethod = .toneMapHeadroom(sourceHeadroom: source.headroom ?? 1, targetHeadroom: 1)
        }
        switch sdrMethod {
        case .none: break
        case .sourceRendition: steps.append("SDR 输出：使用源文件自带的 SDR 版本（§6.7 第 1 条）")
        case .toneMapHeadroom(let s, let t):
            steps.append("SDR 输出：CIToneMapHeadroom sourceHeadroom \(fmt(s)) → targetHeadroom \(fmt(t))，只作用于照片（§6.7 第 2、3 条）")
        }
        steps.append("合成：工作空间 \(WorkingColor.spaceName) / \(WorkingColor.formatName)，背景 sRGB hex 经 CI 转入（§6.5）")
        steps.append("输出：工作空间 → sRGB 8-bit（CI），嵌入 sRGB ICC"
                     + (writesHDR ? "；HDR：CI gain map（RGB），headroom \(fmt(source.headroom ?? 1))" : ""))

        let photos = PhotoCache(source: source, sdrMethod: sdrMethod)
        let encoder = OutputEncoder(context: context)
        let metadata = OutputMetadata.properties(from: source.properties, policy: output.metadata)
        let ext = output.format == .jpeg ? "jpg" : "png"

        var outputs: [RenderedOutput] = []
        for plan in layout.pages {
            try Task.checkCancellation()
            let background = try WorkingColor.ciColor(plan.background)
            let sdrPage = PageComposer.compose(plan: plan, photo: photos.sdr(for: plan.photo, displaySize: source.displaySize),
                                               overlays: overlays, background: background)
            let url = job.outputDirectory.appendingPathComponent(String(format: "%02d.%@", plan.role.page, ext))
            progress(RenderProgress(stage: .encoding, completedOutputs: outputs.count, totalOutputs: layout.pages.count))
            let result: OutputEncoder.Written
            if writesHDR, output.format == .jpeg {
                let hdrPage = PageComposer.compose(plan: plan, photo: photos.hdr(for: plan.photo, displaySize: source.displaySize),
                                                   overlays: overlays, background: background)
                result = try encoder.writeHDRJPEG(sdr: sdrPage, hdr: hdrPage, headroom: source.headroom ?? 1,
                                                  size: plan.canvas, settings: output, metadata: metadata, to: url)
            } else {
                result = try encoder.writeSDR(sdrPage, size: plan.canvas, settings: output, metadata: metadata, to: url)
            }
            written.append(url)
            warnings += result.warnings.map { RenderWarning(code: "output.metadata_dropped", message: $0, page: plan.role.page) }
            outputs.append(RenderedOutput(
                role: plan.role, fileURL: url, pixelSize: plan.canvas, format: output.format,
                dynamicRange: writesHDR ? .hdr : .sdr, colorProfile: WorkingColor.sRGBProfileName,
                hdrHeadroom: writesHDR ? source.headroom : nil, byteCount: result.byteCount,
                photoRect: plan.photo.pageRect(canvas: plan.canvas),
                layers: plan.overlays.map { RenderedLayer(layerId: $0.layer.layerId, rect: $0.rect) }))
        }
        progress(RenderProgress(stage: .encoding, completedOutputs: outputs.count, totalOutputs: layout.pages.count))

        let diagnostics = RenderDiagnostics(
            sourceFormat: source.format.rawValue, sourcePixelSize: source.storedSize, orientation: source.orientation,
            displaySize: source.displaySize, bitDepth: source.bitDepth, isFloat: source.isFloat, hasAlpha: source.hasAlpha,
            hasEmbeddedProfile: source.hasEmbeddedProfile, sourceProfile: source.sourceProfile,
            sourceProfileOrigin: source.sourceProfileOrigin, hdrKind: source.hdrKind, sourceHeadroom: source.headroom,
            workingSpace: WorkingColor.spaceName, workingFormat: WorkingColor.formatName, sdrMethod: sdrMethod,
            transformSteps: steps)
        return RenderResult(outputs: outputs, diagnostics: diagnostics, warnings: warnings)
    }

    static func validate(_ output: OutputSettings) throws(RenderError) {
        guard output.colorSpace == "sRGB" else {
            throw RenderError(code: "render.unsupported_output_color_space", message: "V1 只输出 sRGB：\(output.colorSpace)")
        }
        if output.dynamicRange == .hdr, output.format != .jpeg {
            throw RenderError(code: "render.hdr_format_unsupported", message: "HDR 输出只支持带 gain map 的 JPEG（D-17）",
                              hint: "把输出格式改为 JPEG，或改为 SDR 输出")
        }
    }

    /// 读文件属性得到布局用的尺寸与方向（不解码像素）。
    static func probe(_ url: URL) throws(RenderError) -> SourceImage {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw .decodeFailed(url, "无法读取文件")
        }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        try? handle.close()
        _ = try SourceFileFormat.sniff(head)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0
        else { throw .decodeFailed(url, "ImageIO 无法读取图像属性") }
        let orientation = ExifOrientation(rawValue: props[kCGImagePropertyOrientation] as? Int ?? 1) ?? .up
        return SourceImage(storedSize: PixelSize(width: w, height: h), orientation: orientation)
    }
}

/// 缩放后的照片缓存：同一张源图在一个任务里只缩放一次（全景的所有切片共用一个全局栅格）。
private final class PhotoCache {
    let source: DecodedSource
    let sdrMethod: SDRRenditionMethod
    private var sdrCache: [String: CIImage] = [:]
    private var hdrCache: [String: CIImage] = [:]

    init(source: DecodedSource, sdrMethod: SDRRenditionMethod) {
        self.source = source
        self.sdrMethod = sdrMethod
    }

    func sdr(for placement: PhotoPlacement, displaySize: PixelSize) -> CIImage? {
        guard let key = placement.cacheKey else { return nil }
        if let hit = sdrCache[key] { return hit }
        let image: CIImage?
        if let sdr = source.sdr {
            image = scaled(sdr, placement, displaySize)
        } else if let hdr = source.hdr, case .toneMapHeadroom(let headroom, _) = sdrMethod {
            image = scaled(hdr, placement, displaySize).map { PageComposer.toneMapped($0, sourceHeadroom: headroom) }
        } else {
            image = nil
        }
        sdrCache[key] = image
        return image
    }

    func hdr(for placement: PhotoPlacement, displaySize: PixelSize) -> CIImage? {
        guard let key = placement.cacheKey, let hdr = source.hdr else { return nil }
        if let hit = hdrCache[key] { return hit }
        let image = scaled(hdr, placement, displaySize)
        hdrCache[key] = image
        return image
    }

    private func scaled(_ image: CIImage, _ placement: PhotoPlacement, _ displaySize: PixelSize) -> CIImage? {
        switch placement {
        case .region(let region, let rect):
            return PageComposer.scaledPhoto(image, region: region, displaySize: displaySize, target: rect.size)
        case .strip(let strip, _):
            let whole = Rect(x: 0, y: 0, width: Double(displaySize.width), height: Double(displaySize.height))
            return PageComposer.scaledPhoto(image, region: whole, displaySize: displaySize, target: strip.size)
        case .none:
            return nil
        }
    }
}

extension PhotoPlacement {
    /// 照片在页面上的像素矩形。
    func pageRect(canvas: PixelSize) -> PixelRect? {
        switch self {
        case .region(_, let rect): return rect
        case .strip(let s, let x):
            let left = max(s.minX - x, 0), right = min(s.maxX - x, canvas.width)
            return right > left ? PixelRect(x: left, y: s.y, width: right - left, height: s.height) : nil
        case .none: return nil
        }
    }

    /// 相同的缩放结果共用缓存：全景各切片共用同一个长卷栅格。
    var cacheKey: String? {
        switch self {
        case .region(let r, let rect): "region \(r.x) \(r.y) \(r.width) \(r.height) \(rect.width) \(rect.height)"
        case .strip(let s, _): "strip \(s.width) \(s.height)"
        case .none: nil
        }
    }
}
