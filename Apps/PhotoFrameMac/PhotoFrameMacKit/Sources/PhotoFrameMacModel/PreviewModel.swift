import CoreGraphics
import Foundation
import ImageIO
import Observation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameRendering

/// 预览什么：一张源图 × 一份预设（任务的副本或左栏的预设草稿）。
public struct PreviewSubject: Hashable, Sendable {
    public var sourceId: SourceID
    public var sourceURL: URL
    /// nil：只有源图，没有任务可预览（只能看原图）。
    public var preset: ExportPreset?
    public var assetBindings: [String: UUID]
    public var colorOverride: SourceColorOverride?
    /// 素材库的版本：预设本地绑定和默认绑定在渲染时才解析，绑定或素材变了就是新的内容。
    public var libraryRevision: Int
}

/// 预览区显示哪一页（UI 设计文档第 9 节）。
public enum PreviewPage: Hashable, Sendable {
    /// 轮播位置：0 = 封面，k = 第 k 张切片（D-27）。
    case page(Int)
    /// 全景长卷：所有切片并排，标出接缝。
    case strip
}

public enum PreviewRange: String, CaseIterable, Identifiable, Sendable {
    case sdr, hdr
    public var id: Self { self }
}

/// 中间栏上方的预览。图像由后端渲染（`renderPreview`，与导出同一条管线，§4.2），这里只管请求和显示状态。
@MainActor @Observable
public final class PreviewModel {
    private let service: any PhotoFrameService
    private let debounce: Duration

    public private(set) var subject: PreviewSubject?
    public var page: PreviewPage = .page(0) {
        didSet { if page != oldValue { render() } }
    }
    public var zoom: PreviewZoom = .fit
    /// 「适合窗口」时的实际比例，由预览视图按当前画面和区域大小报告；放大缩小从这里起步，菜单标题也显示它。
    public var fitScale: Double = 1
    /// 原图 / 成品对比。
    public var showsOriginal = false
    /// 成品按 SDR / HDR 预览（D-106）：HDR 时导出写 HDR 的页来自 gain map JPEG，以 EDR 显示。
    public var range: PreviewRange = .sdr {
        didSet { if range != oldValue { render() } }
    }
    /// 在全景长卷上标出接缝（右栏「全景」的「显示接缝位置」，只影响预览）。
    public var showsSeams = true

    /// 当前页，成品尺寸（预览从不大于导出尺寸）。
    public private(set) var pageImage: PreviewImage?
    /// 当前页解码好的位图。每次渲染在后台解码一次，画面、放大窗口和导航小窗都用它，视图里不再解码。
    public private(set) var pageDisplayImage: CGImage?
    /// 全景长卷：全部页的缩小版。
    public private(set) var strip: [PreviewImage] = []
    /// 全景长卷各页解码好的位图，与 `strip` 一一对应（解码失败的页是 nil）。
    public private(set) var stripImages: [CGImage?] = []
    /// 全景长卷的导航小窗缩略图（高 120 px，封面、间隔、切片依次排开）。
    public private(set) var stripThumbnail: CGImage?
    /// 导出会写出的全部页。
    public private(set) var roles: [JobOutputRole] = []
    public private(set) var warnings: [ApplicationWarning] = []
    public private(set) var error: ApplicationError?
    public private(set) var isRendering = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var memoryWatch: MemoryPressureWatch?

    /// 当前页的长边上限：大于导出尺寸时后端按导出尺寸渲染，所以这就是成品大小。
    static let pageLongEdge = 8192
    static let stripLongEdge = 640
    /// 全景长卷里封面与切片之间的间隔（像素，按 100% 计）：长卷的排版和导航小窗共用。
    public nonisolated static let stripGapPixels = 48.0

    init(service: any PhotoFrameService, debounce: Duration) {
        self.service = service
        self.debounce = debounce
        // 系统内存紧张时丢掉渲染缓存（都可以重新渲染）。
        memoryWatch = MemoryPressureWatch { [weak self] in self?.removeAllRenders() }
    }

    /// 有切片时才有全景长卷。
    public var hasStrip: Bool { roles.count > 1 }

    func update(_ subject: PreviewSubject?) {
        guard subject != self.subject else { return }
        let sameSource = subject?.sourceId == self.subject?.sourceId
        self.subject = subject
        if !sameSource { page = .page(0) }
        render()
    }

    /// 渲染结果缓存：同一源图、同一份预设、同一页和动态范围再次显示时（切回看过的任务或页）立即显示，不再请求后端。
    /// 键里带源文件的修改时间，文件改了会重新渲染。按最近使用淘汰，编码数据和解码后的位图一共不超过 `cacheByteLimit`。
    struct RenderKey: Hashable {
        var subject: PreviewSubject
        var sourceModified: Date?
        var page: PreviewPage
        var range: PreviewRange
    }

    @ObservationIgnored private var cache: [RenderKey: RenderedPreview] = [:]
    @ObservationIgnored private var cacheOrder: [RenderKey] = []
    @ObservationIgnored private var cacheBytes = 0
    @ObservationIgnored var cacheByteLimit = 256 << 20
    /// 实际请求后端渲染的次数（测试用）。
    @ObservationIgnored private(set) var renderRequests = 0

    private func renderKey(_ subject: PreviewSubject, page: PreviewPage) -> RenderKey {
        let modified = (try? FileManager.default.attributesOfItem(atPath: subject.sourceURL.path)[.modificationDate]) as? Date
        return RenderKey(subject: subject, sourceModified: modified, page: page, range: range)
    }

    private func cached(_ key: RenderKey) -> RenderedPreview? {
        guard let entry = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return entry
    }

    private func store(_ rendered: RenderedPreview, for key: RenderKey) {
        removeRender(key)
        cache[key] = rendered
        cacheOrder.append(key)
        cacheBytes += rendered.bytes
        while cacheBytes > cacheByteLimit, let oldest = cacheOrder.first, oldest != key { removeRender(oldest) }
    }

    private func removeRender(_ key: RenderKey) {
        guard let entry = cache.removeValue(forKey: key) else { return }
        cacheBytes -= entry.bytes
        cacheOrder.removeAll { $0 == key }
    }

    /// 只留下这些源图的渲染结果（其他源图已经移除或提交）。
    func retainRenders(for sourceIds: Set<SourceID>) {
        for key in cacheOrder where !sourceIds.contains(key.subject.sourceId) { removeRender(key) }
    }

    /// 清空渲染缓存。正在显示的页不受影响。
    func removeAllRenders() {
        cache = [:]
        cacheOrder = []
        cacheBytes = 0
    }

    /// 缓存里有渲染结果的源图（测试用）。
    var cachedRenderSources: Set<SourceID> { Set(cache.keys.map(\.subject.sourceId)) }

    private func render() {
        task?.cancel()
        guard let subject, let preset = subject.preset else {
            pageImage = nil
            pageDisplayImage = nil
            strip = []
            stripImages = []
            stripThumbnail = nil
            roles = []
            warnings = []
            error = nil
            isRendering = false
            return
        }
        let page = page
        let key = renderKey(subject, page: page)
        if let rendered = cached(key) {
            apply(.success(rendered), page: page)
            return
        }
        isRendering = true
        let range: OutputSettings.DynamicRange = self.range == .hdr ? .hdr : .sdr
        task = Task { [service, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let options: PreviewOptions = switch page {
            case .page(let n): PreviewOptions(maxLongEdge: Self.pageLongEdge, pages: [n], dynamicRange: range)
            case .strip: PreviewOptions(maxLongEdge: Self.stripLongEdge, dynamicRange: range)
            }
            renderRequests += 1
            let request = ExportPreviewRequest(
                source: .id(subject.sourceId), preset: preset, options: options,
                assetBindings: subject.assetBindings, sourceColorOverride: subject.colorOverride)
            let result: Result<ExportPreview, ApplicationError>
            do throws(ApplicationError) { result = .success(try await service.renderPreview(request)) } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let preview):
                // 在后台解码一次（不占主线程）；画面、放大窗口、导航小窗和缓存都用这一份。
                let rendered = await Task.detached(priority: .userInitiated) { RenderedPreview(preview, page: page) }.value
                guard !Task.isCancelled else { return }
                store(rendered, for: key)
                apply(.success(rendered), page: page)
            case .failure(let failure):
                apply(.failure(failure), page: page)
            }
        }
    }

    private func apply(_ result: Result<RenderedPreview, ApplicationError>, page: PreviewPage) {
        isRendering = false
        switch result {
        case .success(let rendered):
            let preview = rendered.preview
            error = nil
            roles = preview.roles
            warnings = preview.warnings
            switch page {
            case .page(let n):
                let index = preview.pages.firstIndex { $0.role.carouselPosition == n }
                pageImage = index.map { preview.pages[$0] }
                pageDisplayImage = index.flatMap { rendered.images[$0] }
                // 改参数后页数变少：回到封面。
                if pageImage == nil, n != 0 { self.page = .page(0) }
            case .strip:
                strip = preview.pages
                stripImages = rendered.images
                stripThumbnail = rendered.stripThumbnail
                if !hasStrip { self.page = .page(0) }
            }
        case .failure(let failure):
            error = failure
            pageImage = nil
            pageDisplayImage = nil
            strip = []
            stripImages = []
            stripThumbnail = nil
            // 不留上一次渲染的页数和提示。
            roles = []
            warnings = []
        }
    }

    func settle() async {
        await task?.value
    }
}

/// 一次渲染的结果和解码好的位图（渲染缓存里存的就是它）。
struct RenderedPreview: Sendable {
    var preview: ExportPreview
    /// 与 `preview.pages` 一一对应；解码失败的页是 nil。
    var images: [CGImage?]
    /// 全景长卷的导航小窗缩略图，只在长卷时有。
    var stripThumbnail: CGImage?
    /// 编码数据加上解码后的位图一共占多少字节，缓存按它计量。
    var bytes: Int

    /// 解码全部页（在后台调用）。
    nonisolated init(_ preview: ExportPreview, page: PreviewPage) {
        self.preview = preview
        images = preview.pages.map { $0.displayImage() }
        stripThumbnail = page == .strip ? Self.stripThumbnail(preview.pages, images: images) : nil
        let decoded = (images + [stripThumbnail]).reduce(0) { total, image in total + (image.map { $0.bytesPerRow * $0.height } ?? 0) }
        bytes = preview.pages.reduce(0) { $0 + $1.data.count } + decoded
    }

    /// 导航小窗用的整条长卷缩略图（高 120 px，封面、间隔、切片依次排开）。
    nonisolated static func stripThumbnail(_ pages: [PreviewImage], images: [CGImage?]) -> CGImage? {
        let height = 120.0
        let gap = PreviewModel.stripGapPixels
        let maxHeight = Double(pages.map(\.pixelSize.height).max() ?? 1)
        let k = height / max(maxHeight, 1)
        let hasCover = pages.contains { $0.role == .cover } && pages.count > 1
        let width = pages.reduce(0.0) { $0 + Double($1.pixelSize.width) * k } + (hasCover ? gap * k : 0)
        guard width >= 1, let ctx = CGContext(data: nil, width: Int(width.rounded(.up)), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        var x = 0.0
        for (page, image) in zip(pages, images) {
            let w = Double(page.pixelSize.width) * k
            let h = Double(page.pixelSize.height) * k
            if let image { ctx.draw(image, in: CGRect(x: x, y: height - h, width: w, height: h)) }
            x += w + (page.role == .cover && hasCover ? gap * k : 0)
        }
        return ctx.makeImage()
    }
}

extension PreviewImage {
    /// 解码成显示用的位图（立即解码，画的时候不再解码）。HDR 页（gain map JPEG）按 HDR 解码，带 content headroom，
    /// 界面允许 EDR 时以 HDR 显示；不支持 HDR 的屏幕上系统按 headroom 压回 SDR。
    public func displayImage() -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        if dynamicRange == .hdr { options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR }
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
}

extension Workbench {
    /// 预览跟着右栏：选中一个任务时预览它；选中源图时预览它的第一个任务（没有任务只看原图）；
    /// 选中左栏预设时用选中的源图（没有则第一张源图）预览预设草稿。
    var previewSubject: PreviewSubject? {
        func subject(_ item: SourceItem, preset: ExportPreset?, bindings: [String: UUID]) -> PreviewSubject {
            PreviewSubject(
                sourceId: item.id, sourceURL: item.source.fileURL, preset: preset, assetBindings: bindings,
                colorOverride: item.colorOverride, libraryRevision: libraryRevision)
        }
        let (inspectorSubject, jobs) = inspected()
        switch inspectorSubject {
        case .jobs:
            guard jobs.count == 1, let job = jobs.first, let item = sourceItem(job.sourceId) else { return nil }
            return subject(item, preset: job.preset, bindings: job.assetBindings)
        case .source(let id):
            guard let item = sourceItem(id) else { return nil }
            let first = item.jobs.first
            return subject(item, preset: first?.preset, bindings: first?.assetBindings ?? [:])
        case .preset:
            guard let draft = presetEditor?.draft,
                  let item = targetSourceIds.first.flatMap(sourceItem) ?? sources.first else { return nil }
            return subject(item, preset: draft, bindings: [:])
        case .location, .none:
            return nil
        }
    }

    func refreshPreview() {
        preview.update(previewSubject)
    }

    /// 动态范围选「跟随源图」（D-125）时，预览的这张源图实际会导出成什么；不是 auto 或没有源图时为 nil。
    public var autoRangeResult: String? {
        guard let output = editedPreset?.output, output.dynamicRange == .auto,
              let id = previewSubject?.sourceId, let hdr = sourceItem(id)?.inspection?.hdr else { return nil }
        let sourceHasHDR = hdr.kind != "none" && (hdr.headroom.map { $0 > 1.01 } ?? true)
        if output.effectiveDynamicRange(sourceHasHDR: sourceHasHDR) == .hdr { return "HDR（源图是 HDR）" }
        return output.format == .jpeg ? "SDR（源图不是 HDR）" : "SDR（PNG 不支持 HDR）"
    }
}

/// 系统内存紧张（warning、critical）时在主线程调用 `handler`，用来清空可以重新生成的缓存。
public final class MemoryPressureWatch: Sendable {
    private let source: any DispatchSourceMemoryPressure

    public init(_ handler: @escaping @MainActor @Sendable () -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.activate()
    }

    deinit { source.cancel() }
}
