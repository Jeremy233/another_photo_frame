import Foundation
import PhotoFrameCore
import PhotoFrameStorage

// 右栏「全景」的切片张数（UI 设计文档第 8.2 节、D-11）。

extension Workbench {
    /// 张数是自动还是手动：多个任务不一样时为「多个值」。
    public var slideCountIsManual: FieldValue<Bool> {
        let values = editedPresets.map { if case .fixed = $0.panorama.tileCount { true } else { false } }
        guard let first = values.first else { return .none }
        return values.allSatisfy { $0 == first } ? .single(first) : .mixed
    }

    /// 切到手动时从自动算出的切片张数开始（只允许手动改多，D-11），每个任务按它自己的源图算；切回自动。
    public func setSlideCountManual(_ manual: Bool) {
        guard isInspectorEditable else { return }
        let (subject, jobs) = inspected()
        switch subject {
        case .jobs:
            for job in jobs {
                let count = manual ? automaticSlideCount(job.preset, source: sourceItem(job.sourceId), validation: job) : nil
                updateJobs([job.id]) { $0.preset.panorama.tileCount = count.map { .fixed($0) } ?? .auto }
            }
        case .preset:
            guard let draft = presetEditor?.draft else { return }
            let count = manual ? automaticSlideCount(draft, source: previewSubject.flatMap { sourceItem($0.sourceId) }, validation: nil) : nil
            setField(\.panorama.tileCount, count.map { .fixed($0) } ?? .auto)
        case .source, .location, .none:
            break
        }
    }

    /// 手动张数的步进范围：自动张数 … 平台轮播上限（有封面时减去封面）。只编辑一份预设时才有。
    public var manualSlideCountRange: ClosedRange<Int>? {
        guard let preset = editedPreset else { return nil }
        let source = previewSubject.flatMap { sourceItem($0.sourceId) }
        let job = inspected().jobs.first
        let lower = automaticSlideCount(preset, source: source, validation: job) ?? 1
        return lower...max(lower, Self.maxSlideCount(preset, catalog: Self.platformCatalog))
    }

    /// 应用附带的平台目录（与服务默认用的是同一份 `platforms.json`），用来查轮播上限。
    static let platformCatalog: PlatformCatalog? = try? PlatformCatalogStore.builtIn()

    /// 这份预设在这张源图上自动算出的切片张数（与渲染同一套版式计算）。没有源图尺寸时用任务最近一次校验或预览的页数估计。
    func automaticSlideCount(_ preset: ExportPreset, source: SourceItem?, validation job: DraftJob?) -> Int? {
        if let size = source?.inspection?.displaySize,
           let layout = try? PanoramaLayout(
               tile: preset.canvas.size, source: size, coverMinimumMargin: preset.canvas.minMarginPx,
               verticalMargin: preset.panorama.verticalMarginPx, includesCover: preset.panorama.cover) {
            return layout.automaticSlideCount
        }
        // 还没检查完源图：张数是自动时，校验或预览出来的切片数就是自动张数。
        guard case .auto = preset.panorama.tileCount else { return nil }
        if let slides = job?.slideCount, slides > 0 { return slides }
        let slides = preview.roles.count { $0 != .cover }
        return slides > 0 ? slides : nil
    }

    /// 平台轮播上限折算成切片张数；没有平台时用内置平台里最大的上限。
    static func maxSlideCount(_ preset: ExportPreset, catalog: PlatformCatalog?) -> Int {
        let limits = catalog?.platforms.map(\.maxCarouselItems) ?? []
        let items = preset.platform.flatMap { catalog?.profile(id: $0)?.maxCarouselItems } ?? limits.max() ?? 35
        return max(items - (preset.panorama.cover ? 1 : 0), 1)
    }
}
