import Foundation
import ImageIO
import Observation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameRendering

/// 预览什么：一张源图 × 一份预设（任务的副本或左栏的预设草稿）。
public struct PreviewSubject: Equatable, Sendable {
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

public enum PreviewZoom: Hashable, Sendable {
    case fit
    /// 100%：一个成品像素对应一个屏幕像素。
    case actualSize
    case scale(Double)
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
        isRendering = true
        let page = page
        let range: OutputSettings.DynamicRange = self.range == .hdr ? .hdr : .sdr
        task = Task { [service, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let options: PreviewOptions = switch page {
            case .page(let n): PreviewOptions(maxLongEdge: Self.pageLongEdge, pages: [n], dynamicRange: range)
            case .strip: PreviewOptions(maxLongEdge: Self.stripLongEdge, dynamicRange: range)
            }
            let request = ExportPreviewRequest(
                source: .id(subject.sourceId), preset: preset, options: options,
                assetBindings: subject.assetBindings, sourceColorOverride: subject.colorOverride)
            let result: Result<ExportPreview, ApplicationError>
            do throws(ApplicationError) { result = .success(try await service.renderPreview(request)) } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
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
}
