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
    /// 源图是 HDR（D-62）。
    public var sourceIsHDR: Bool
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
    /// 全景长卷：全部页的缩小版。
    public private(set) var strip: [PreviewImage] = []
    /// 导出会写出的全部页。
    public private(set) var roles: [JobOutputRole] = []
    public private(set) var warnings: [ApplicationWarning] = []
    public private(set) var error: ApplicationError?
    public private(set) var isRendering = false

    private var task: Task<Void, Never>?

    /// 当前页的长边上限：大于导出尺寸时后端按导出尺寸渲染，所以这就是成品大小。
    static let pageLongEdge = 8192
    static let stripLongEdge = 640

    init(service: any PhotoFrameService, debounce: Duration) {
        self.service = service
        self.debounce = debounce
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
    /// 键里带源文件的修改时间，文件改了会重新渲染。按最近使用淘汰，总量不超过 `cacheByteLimit`。
    struct RenderKey: Hashable {
        var subject: PreviewSubject
        var sourceModified: Date?
        var page: PreviewPage
        var range: PreviewRange
    }

    private var cache: [RenderKey: (preview: ExportPreview, bytes: Int)] = [:]
    private var cacheOrder: [RenderKey] = []
    private var cacheBytes = 0
    var cacheByteLimit = 256 << 20
    /// 实际请求后端渲染的次数（测试用）。
    private(set) var renderRequests = 0

    private func renderKey(_ subject: PreviewSubject, page: PreviewPage) -> RenderKey {
        let modified = (try? FileManager.default.attributesOfItem(atPath: subject.sourceURL.path)[.modificationDate]) as? Date
        return RenderKey(subject: subject, sourceModified: modified, page: page, range: range)
    }

    private func cached(_ key: RenderKey) -> ExportPreview? {
        guard let entry = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return entry.preview
    }

    private func store(_ preview: ExportPreview, for key: RenderKey) {
        let bytes = preview.pages.reduce(0) { $0 + $1.data.count }
        if let old = cache.removeValue(forKey: key) { cacheBytes -= old.bytes }
        cacheOrder.removeAll { $0 == key }
        cache[key] = (preview, bytes)
        cacheOrder.append(key)
        cacheBytes += bytes
        while cacheBytes > cacheByteLimit, let oldest = cacheOrder.first, oldest != key {
            cacheOrder.removeFirst()
            if let entry = cache.removeValue(forKey: oldest) { cacheBytes -= entry.bytes }
        }
    }

    private func render() {
        task?.cancel()
        guard let subject, let preset = subject.preset else {
            pageImage = nil
            strip = []
            roles = []
            warnings = []
            error = nil
            isRendering = false
            return
        }
        let page = page
        let key = renderKey(subject, page: page)
        if let preview = cached(key) {
            apply(.success(preview), page: page)
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
            if case .success(let preview) = result { store(preview, for: key) }
            apply(result, page: page)
        }
    }

    private func apply(_ result: Result<ExportPreview, ApplicationError>, page: PreviewPage) {
        isRendering = false
        switch result {
        case .success(let preview):
            error = nil
            roles = preview.roles
            warnings = preview.warnings
            switch page {
            case .page(let n):
                pageImage = preview.pages.first { $0.role.carouselPosition == n }
                // 改参数后页数变少：回到封面。
                if pageImage == nil, n != 0 { self.page = .page(0) }
            case .strip:
                strip = preview.pages
                if !hasStrip { self.page = .page(0) }
            }
        case .failure(let failure):
            error = failure
            pageImage = nil
            strip = []
        }
    }

    func settle() async {
        await task?.value
    }
}

extension PreviewImage {
    /// 解码成显示用的位图。HDR 页（gain map JPEG）按 HDR 解码，带 content headroom，界面允许 EDR 时以 HDR 显示；
    /// 不支持 HDR 的屏幕上系统按 headroom 压回 SDR。
    public func displayImage() -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = dynamicRange == .hdr ? [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] : [:]
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
                colorOverride: item.colorOverride, sourceIsHDR: (item.inspection?.hdr.kind ?? "none") != "none")
        }
        switch inspectorSubject {
        case .jobs(let ids):
            guard ids.count == 1, let job = job(ids[0]), let item = sourceItem(job.sourceId) else { return nil }
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
