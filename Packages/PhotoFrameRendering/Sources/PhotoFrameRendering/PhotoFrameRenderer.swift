import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PhotoFrameCore

/// 从源图文件到成品文件的完整渲染（规范 §5、§6、§7）。任务队列（PhotoFrameApplication）调用这里；
/// GUI 预览调用同一条管线的 `renderPreview(_:)`。
///
/// 只负责把成品写进 `RenderJob.outputDirectory`；原子发布、命名、冲突处理由调用方负责（§9.2）。
/// 一个实例可以被多个任务并发使用：`CIContext` 是线程安全的；唯一的可变状态是预览的解码缓存，自带锁。
public final class PhotoFrameRenderer: @unchecked Sendable {
    let context: CIContext
    /// 预览用的解码缓存（§12.1「预览使用降采样解码与缩略图缓存」）：GUI 改颜色、文字、图层等不影响照片尺寸的参数，
    /// 或翻到同一预设的另一页时，不再重新解码源图。导出不用它，每个任务的内存仍只取决于当前任务（D-18）。
    let previewSources = DecodedSourceCache()

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

    /// 预览（§6.3「预览 ≈ 导出」、§11.2 `renderPreview`、D-18）：与导出走同一条管线（PageLayout、SourceDecoder、
    /// OverlayPlanner、PageComposer），只是按预览尺寸降采样解码与合成，返回内存中的位图，不写文件。
    ///
    /// - 版式在导出分辨率上由 PhotoFrameCore 算出，再按预览缩放映射到预览像素（矩形按像素边取整，误差 ≤ 0.5 px）；
    ///   照片与图层直接画进映射后的矩形，不先画大图再缩小。
    /// - `.sRGB` 的像素与 SDR 导出编码前相同（缩放系数为 1 时与 PNG 导出逐像素一致）。
    /// - 支持取消：在阶段之间、每一页之前检查 `Task.isCancelled`，抛出 `CancellationError`。
    public func renderPreview(_ request: PreviewRequest) async throws -> PreviewResult {
        try previewPages(request)
    }

    // MARK: - 主流程

    /// 导出与预览共用的前半段：校验 → 版式 → 解码 → 图层规划 → HDR 决策（§6.1 第 3 条「预览 ≈ 导出」）。
    /// 两者只在解码采样尺度（`decodeScale`）和最后的输出方式上不同。
    private func prepare(
        _ inputs: RenderInputs, decodeScale: Double = 1, cachesDecode: Bool = false, progress: (RenderProgress) -> Void
    ) throws -> PreparedRender {
        let output = inputs.preset.output
        try Self.validate(output)
        try Task.checkCancellation()
        progress(RenderProgress(stage: .decoding, completedOutputs: 0, totalOutputs: nil))

        // 1. 版式（几何全部来自 PhotoFrameCore）
        let probe = try Self.probe(inputs.sourceURL)
        var warnings: [RenderWarning] = []
        var layout = try PageLayout.make(preset: inputs.preset, source: probe, maxCarouselItems: inputs.maxCarouselItems,
                                         warnings: &warnings)

        // 2. 解码（按输出所需尺寸降采样，D-18；预览再乘以预览缩放）
        let needed = layout.neededPhotoSize
        let neededSize = decodeScale < 1
            ? PixelSize(width: max(1, Int((Double(needed.width) * decodeScale).rounded(.up))),
                        height: max(1, Int((Double(needed.height) * decodeScale).rounded(.up))))
            : needed
        let decoder = SourceDecoder(context: context)
        let source = try cachesDecode
            ? previewSources.source(inputs.sourceURL, neededSize: neededSize, override: inputs.sourceColorOverride, decoder: decoder)
            : decoder.decode(inputs.sourceURL, neededSize: neededSize, override: inputs.sourceColorOverride)
        warnings += source.warnings
        guard source.displaySize == probe.displaySize else {
            throw RenderError(code: "render.decode_failed", message: "解码尺寸与文件属性不符")
        }
        try Task.checkCancellation()

        // 3. 图层内容与位置
        progress(RenderProgress(stage: .rendering, completedOutputs: 0, totalOutputs: layout.pages.count))
        var steps = source.transformSteps
        let overlays = try OverlayPlanner.plan(inputs: inputs, layout: &layout, properties: source.properties,
                                               warnings: &warnings)

        // 4. 照片：SDR 版本与（需要时）HDR 版本
        // auto（D-125）跟随源图：不是 HDR、没有余量或输出 PNG 时安静地按 SDR；强制 HDR 时才警告。
        let wantsHDR = output.dynamicRange == .hdr || (output.dynamicRange == .auto && output.format == .jpeg)
        let hasHeadroom = (source.headroom ?? 1) > SourceDecoder.sdrWhiteTolerance
        let writesHDR = wantsHDR && source.hdr != nil && hasHeadroom
        if output.dynamicRange != .hdr {
            // auto：不警告
        } else if source.hdr == nil {
            warnings.append(RenderWarning(code: "output.hdr_source_not_hdr", message: "源图不是 HDR，按 SDR 输出"))
        } else if !writesHDR {
            warnings.append(RenderWarning(code: "output.hdr_no_headroom",
                                          message: "源图标为 HDR，但画面没有超过 SDR 白的内容（余量 = 1），按 SDR 输出"))
        }
        let sdrMethod: SDRRenditionMethod
        switch source.hdrKind {
        case .none: sdrMethod = .none
        case .gainMap, .gainMapTIFF: sdrMethod = .sourceRendition
        case .transferFunction, .floatLinear:
            // 标为 HDR 但 headroom = 1 时解码器已把它本身作为 SDR 版本，不做 tone map。
            sdrMethod = source.sdr != nil ? .none
                : .toneMapHeadroom(sourceHeadroom: source.headroom ?? 1, targetHeadroom: 1)
        }
        switch sdrMethod {
        case .none: break
        case .sourceRendition: steps.append("SDR 输出：使用源文件自带的 SDR 版本（§6.7 第 1 条）")
        case .toneMapHeadroom(let s, let t):
            steps.append("SDR 输出：CIToneMapHeadroom sourceHeadroom \(fmt(s)) → targetHeadroom \(fmt(t))，只作用于照片（§6.7 第 2、3 条）")
        }
        steps.append("合成：工作空间 \(WorkingColor.spaceName) / \(WorkingColor.formatName)，背景 sRGB hex 经 CI 转入（§6.5）")

        return PreparedRender(layout: layout, source: source, overlays: overlays,
                              photos: PhotoCache(source: source, sdrMethod: sdrMethod),
                              writesHDR: writesHDR, sdrMethod: sdrMethod, warnings: warnings, steps: steps)
    }

    private func renderPages(
        job: RenderJob, progress: (RenderProgress) -> Void, written: inout [URL]
    ) throws -> RenderResult {
        let output = job.preset.output
        var prepared = try prepare(job.inputs, progress: progress)
        let (layout, source, writesHDR, photos) = (prepared.layout, prepared.source, prepared.writesHDR, prepared.photos)
        prepared.steps.append("输出：工作空间 → sRGB 8-bit（CI），嵌入 sRGB ICC"
                              + (writesHDR ? "；HDR：CI gain map（RGB），headroom \(fmt(source.headroom ?? 1))" : ""))
        var warnings = prepared.warnings

        // 图层在所有页上尺寸相同，导出时每个图层只画一次。
        var overlays: [String: CIImage] = [:]
        for (layerId, planned) in prepared.overlays {
            overlays[layerId] = try planned.content.render(size: planned.size, alignment: planned.alignment)
        }
        let encoder = OutputEncoder(context: context)
        let metadata = OutputMetadata.properties(from: source.properties, author: source.author, policy: output.metadata)
        let ext = output.format == .jpeg ? "jpg" : "png"

        let pages = layout.pages
        func url(_ plan: PagePlan) -> URL {
            job.outputDirectory.appendingPathComponent(String(format: "%02d.%@", plan.role.page, ext))
        }
        var outputs: [RenderedOutput] = []
        /// 第 `index` 页已写出：按页序记下文件、警告与输出信息。
        func record(_ index: Int, _ result: OutputEncoder.Written) {
            let plan = pages[index]
            written.append(url(plan))
            warnings += result.warnings.map { RenderWarning(code: "output.metadata_dropped", message: $0, page: plan.role.page) }
            outputs.append(RenderedOutput(
                role: plan.role, fileURL: url(plan), pixelSize: plan.canvas, format: output.format,
                dynamicRange: writesHDR ? .hdr : .sdr, colorProfile: WorkingColor.sRGBProfileName,
                hdrHeadroom: writesHDR ? source.headroom : nil, byteCount: result.byteCount,
                photoRect: plan.photo.pageRect(canvas: plan.canvas),
                layers: plan.overlays.map { RenderedLayer(layerId: $0.layer.layerId, rect: $0.rect) }))
        }

        // SDR 页面在本线程逐页渲染，编码与写文件交给后台，同时编码的页数受内存上限约束（EncodePipeline）。
        let pipeline = EncodePipeline(pageBytes: pages.map { $0.canvas.width * $0.canvas.height * 4 }.max() ?? 0)
        /// 按页序取回编码完的页并报告进度；在途页数超过 `limit` 时等最早的一页。
        func collect(keeping limit: Int) throws {
            while let (index, result) = pipeline.next(wait: pipeline.inFlight > limit) {
                switch result {
                case .success(let written): record(index, written)
                case .failure(let error): throw PageEncodeFailure(page: index, error: error)
                }
                progress(RenderProgress(stage: .encoding, completedOutputs: outputs.count, totalOutputs: pages.count))
            }
        }

        var current = 0
        do {
            for (index, plan) in pages.enumerated() {
                current = index
                try Task.checkCancellation()
                let background = try WorkingColor.ciColor(plan.background)
                let sdrPage = PageComposer.compose(plan: plan, photo: photos.sdr(for: plan.photo, displaySize: source.displaySize),
                                                   overlays: overlays, background: background)
                progress(RenderProgress(stage: .encoding, completedOutputs: outputs.count, totalOutputs: pages.count))
                if writesHDR, output.format == .jpeg {
                    try collect(keeping: 0)
                    let hdrPage = PageComposer.compose(plan: plan, photo: photos.hdr(for: plan.photo, displaySize: source.displaySize),
                                                       overlays: overlays, background: background)
                    record(index, try encoder.writeHDRJPEG(sdr: sdrPage, hdr: hdrPage, headroom: source.headroom ?? 1,
                                                           size: plan.canvas, settings: output, metadata: metadata, to: url(plan)))
                } else {
                    let image = try encoder.renderSRGB8(sdrPage, size: plan.canvas)
                    pipeline.submit(EncodePipeline.Page(image: image, settings: output, metadata: metadata, url: url(plan)))
                    try collect(keeping: pipeline.depth - 1)
                }
            }
            try collect(keeping: 0)
        } catch {
            // 交给后台的页先全部结束，写出的文件记进 written，由 render 统一删除。
            // 比出错处更早的页编码失败时报那一页的错误，与逐页执行时先遇到的错误相同。
            let failure = error as? PageEncodeFailure
            var earlier: RenderError?
            while let (index, result) = pipeline.next(wait: true) {
                switch result {
                case .success: written.append(url(pages[index]))
                case .failure(let error): if index < failure?.page ?? current, earlier == nil { earlier = error }
                }
            }
            if let earlier { throw earlier }
            throw failure?.error ?? error
        }
        progress(RenderProgress(stage: .encoding, completedOutputs: outputs.count, totalOutputs: pages.count))
        return RenderResult(outputs: outputs, diagnostics: prepared.diagnostics, warnings: warnings)
    }

    // MARK: - 预览

    private func previewPages(_ request: PreviewRequest) throws -> PreviewResult {
        let canvas = request.preset.canvas.size
        let scale = try PreviewScale(canvas: canvas, size: request.size)
        var prepared = try prepare(request.inputs, decodeScale: max(scale.x, scale.y), cachesDecode: true, progress: { _ in })
        let (layout, source, photos) = (prepared.layout, prepared.source, prepared.photos)
        let showsHDR = prepared.writesHDR && request.color != .sRGB
        switch request.color {
        case .sRGB:
            prepared.steps.append("预览：\(scale)，工作空间 → sRGB 8-bit（CI，与 SDR 导出相同），不编码")
        case .gainMap:
            prepared.steps.append("预览：\(scale)，工作空间 → sRGB 8-bit（CI，与 SDR 导出相同）"
                                  + (showsHDR ? "；另给 HDR 页面，headroom \(fmt(source.headroom ?? 1))" : ""))
        case .extendedRange:
            prepared.steps.append("预览：\(scale)，工作空间 → extended sRGB RGBAh，不截断"
                                  + (showsHDR ? "；HDR 页面，headroom \(fmt(source.headroom ?? 1))" : ""))
        }
        try Task.checkCancellation()

        // 图层按预览尺寸直接绘制（文字、SVG 按矢量重画）；映射后尺寸相同的图层在各页之间共用。
        var overlayCache: [String: CIImage] = [:]
        var pages: [PreviewPage] = []
        for exportPlan in layout.pages where request.pages?.contains(exportPlan.role.page) ?? true {
            try Task.checkCancellation()
            let plan = scale.map(exportPlan)
            var overlays: [String: CIImage] = [:]
            for ((layer, rect), (_, exportRect)) in zip(plan.overlays, exportPlan.overlays) where rect.size.isPositive {
                guard let planned = prepared.overlays[layer.layerId] else { continue }
                let key = "\(layer.layerId) \(rect.width) \(rect.height)"
                if overlayCache[key] == nil {
                    overlayCache[key] = try planned.content.render(size: exportRect.size, alignment: planned.alignment,
                                                                   pixels: rect.size)
                }
                overlays[layer.layerId] = overlayCache[key]
            }
            let background = try WorkingColor.ciColor(plan.background)
            func compose(hdr: Bool) -> CIImage {
                let photo = hdr
                    ? photos.hdr(for: plan.photo, displaySize: source.displaySize)
                    : photos.sdr(for: plan.photo, displaySize: source.displaySize)
                return PageComposer.compose(plan: plan, photo: photo, overlays: overlays, background: background)
            }
            let image: CGImage
            var hdrImage: CGImage?
            switch request.color {
            case .sRGB:
                image = try OutputEncoder(context: context).renderSRGB8(compose(hdr: false), size: plan.canvas)
            case .gainMap:
                image = try OutputEncoder(context: context).renderSRGB8(compose(hdr: false), size: plan.canvas)
                if showsHDR { hdrImage = try renderExtended(compose(hdr: true), size: plan.canvas, headroom: source.headroom) }
            case .extendedRange:
                image = try renderExtended(compose(hdr: showsHDR), size: plan.canvas, headroom: showsHDR ? source.headroom : nil)
            }
            pages.append(PreviewPage(
                role: plan.role, image: image, hdrImage: hdrImage, pixelSize: plan.canvas, exportPixelSize: exportPlan.canvas,
                photoRect: plan.photo.pageRect(canvas: plan.canvas),
                exportPhotoRect: exportPlan.photo.pageRect(canvas: exportPlan.canvas),
                layers: zip(plan.overlays, exportPlan.overlays).map {
                    PreviewLayer(layerId: $0.0.layer.layerId, rect: $0.0.rect, exportRect: $0.1.rect)
                },
                dynamicRange: showsHDR ? .hdr : .sdr, hdrHeadroom: showsHDR ? source.headroom : nil))
        }
        return PreviewResult(pages: pages, roles: layout.pages.map(\.role), scaleX: scale.x, scaleY: scale.y,
                             diagnostics: prepared.diagnostics, warnings: prepared.warnings)
    }

    /// `.gainMap` 预览的 HDR 页面编码成带 gain map 的 JPEG（与 HDR 导出同一种编码：SDR 底图 + RGB gain map，
    /// 嵌入 sRGB ICC，D-106）。不支持 HDR 的查看器显示的就是 SDR 预览。
    public func gainMapJPEG(sdr: CGImage, hdr: CGImage, headroom: Double, quality: Int) throws(RenderError) -> Data {
        let size = PixelSize(width: sdr.width, height: sdr.height)
        return try OutputEncoder(context: context).hdrJPEGData(
            sdr: CIImage(cgImage: sdr), hdr: CIImage(cgImage: hdr), headroom: headroom, size: size, quality: quality)
    }

    /// 工作空间 → extended sRGB 半浮点（显示用，不截断 > 1 与色域外的值）。HDR 页面写入 content headroom。
    private func renderExtended(_ page: CIImage, size: PixelSize, headroom: Double?) throws(RenderError) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        guard let image = context.createCGImage(page, from: rect, format: .RGBAh, colorSpace: WorkingColor.extendedSRGB)
        else { throw RenderError(code: "render.preview_failed", message: "无法构造 extended 预览位图") }
        guard let headroom else { return image }
        return CGImageCreateCopyWithContentHeadroom(Float(max(headroom, 1)), image) ?? image
    }

    static func validate(_ output: OutputSettings) throws(RenderError) {
        guard output.colorSpace == "sRGB" else {
            throw RenderError(code: "render.unsupported_output_color_space", message: "V1 只输出 sRGB：\(output.colorSpace)")
        }
        if output.dynamicRange == .hdr, output.format != .jpeg {
            throw RenderError(code: "render.hdr_format_unsupported", message: "HDR 输出只支持带增益图的 JPEG",
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

/// 预览的解码缓存。`SourceDecoder.decode` 的结果只取决于源文件、解码长边（由所需尺寸决定）和输入色彩空间覆盖，
/// 所以按这几项（文件用路径、大小、修改时间和文件号识别）复用，像素与重新解码完全相同。
/// 按最近使用淘汰，最多 `capacity` 份、总共不超过 `byteLimit`；单份超过上限的不缓存。
final class DecodedSourceCache: @unchecked Sendable {
    struct Key: Hashable {
        var path: String
        var fileSize: Int64?
        var modified: Date?
        var fileNumber: Int?
        var longNeeded: Int
        var override: SourceColorOverride?
    }

    let capacity: Int
    let byteLimit: Int
    private let lock = NSLock()
    /// 最近使用的在后面。
    private var entries: [(key: Key, source: DecodedSource)] = []
    private var bytes = 0
    /// 实际解码次数（测试用）。
    private(set) var decodeCount = 0

    init(capacity: Int = 2, byteLimit: Int = 256 << 20) {
        self.capacity = capacity
        self.byteLimit = byteLimit
    }

    func source(
        _ url: URL, neededSize: PixelSize, override: SourceColorOverride?, decoder: SourceDecoder
    ) throws(RenderError) -> DecodedSource {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = Key(
            path: url.standardizedFileURL.path, fileSize: (attributes?[.size] as? NSNumber)?.int64Value,
            modified: attributes?[.modificationDate] as? Date,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.intValue,
            longNeeded: max(neededSize.width, neededSize.height, 1), override: override)
        if let hit = lookup(key) { return hit }
        let source = try decoder.decode(url, neededSize: neededSize, override: override)
        store(source, for: key)
        return source
    }

    private func lookup(_ key: Key) -> DecodedSource? {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.source
        }
    }

    private func store(_ source: DecodedSource, for key: Key) {
        lock.withLock {
            decodeCount += 1
            if let index = entries.firstIndex(where: { $0.key == key }) {
                bytes -= entries.remove(at: index).source.pixelBytes
            }
            guard source.pixelBytes <= byteLimit else { return }
            entries.append((key, source))
            bytes += source.pixelBytes
            while entries.count > capacity || bytes > byteLimit {
                bytes -= entries.removeFirst().source.pixelBytes
            }
        }
    }

    func removeAll() {
        lock.withLock {
            entries = []
            bytes = 0
        }
    }
}

/// `prepare` 的结果：导出与预览从这里分开。
private struct PreparedRender {
    var layout: PageLayout
    var source: DecodedSource
    var overlays: [String: PlannedOverlay]
    var photos: PhotoCache
    var writesHDR: Bool
    var sdrMethod: SDRRenditionMethod
    var warnings: [RenderWarning]
    var steps: [String]

    var diagnostics: RenderDiagnostics {
        RenderDiagnostics(
            sourceFormat: source.format.rawValue, sourcePixelSize: source.storedSize, orientation: source.orientation,
            displaySize: source.displaySize, bitDepth: source.bitDepth, isFloat: source.isFloat, hasAlpha: source.hasAlpha,
            hasEmbeddedProfile: source.hasEmbeddedProfile, sourceProfile: source.sourceProfile,
            sourceProfileOrigin: source.sourceProfileOrigin, hdrKind: source.hdrKind, sourceHeadroom: source.headroom,
            workingSpace: WorkingColor.spaceName, workingFormat: WorkingColor.formatName, sdrMethod: sdrMethod,
            transformSteps: steps)
    }
}

/// 缩放后的照片缓存：同一张源图在一个任务里只缩放一次（全景的所有切片共用一个全局栅格）。
final class PhotoCache {
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
