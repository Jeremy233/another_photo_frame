import PhotoFrameApplication

/// 任务校验得到的一条错误或警告，给任务行的弹出框和 Inspector 顶部的「警告」用（参照 Compressor 的错误窗口）。
public struct JobIssue: Hashable, Sendable, Identifiable {
    public var isError: Bool
    public var code: String
    public var message: String
    /// 一句话的修改建议；没有就是 nil。
    public var hint: String?

    public var id: String { "\(isError) \(code) \(message)" }

    /// 常见警告的修改建议（错误优先用服务给的 hint）。控件用「」写出界面上的确切名称。
    static func hint(for code: String) -> String? {
        switch code {
        case "panorama.not_landscape": "全景切片适合横向长图；不需要时在「全景」里取消「全景分割」"
        case "panorama.not_wide_enough": "按实际需要的张数导出；想要更多张可以在「全景」里把「张数」改为手动"
        case "panorama.exceeds_carousel_limit": "在「全景」里减少切片张数，或取消「封面」"
        case "panorama.increased_slide_count": "把「全景」的「张数」改回自动，长卷两端就不会补背景色"
        case "overlay.exceeds_canvas", "overlay.insufficient_margin":
            "在「装饰」里调小「水平偏移」「垂直偏移」，或在「画布」里加大「边框宽度」"
        case "overlay.overlaps_photo": "把装饰的「参照」改为照片外侧，或在「画布」里加大「边框宽度」"
        case "overlay.missing_pages": "在「装饰」里把「显示在」改成实际存在的页"
        case "overlay.font_missing": "在「装饰」里清空「字体」改用系统字体，或先安装这个字体"
        case "overlay.metadata_missing": "源图没有这些 EXIF 字段，对应部分会留空；可以在「装饰」里改「模板」"
        case "overlay.asset_missing", "overlay.empty_text", "overlay.missing_text":
            "在「装饰」里给这个装饰绑定「素材」或填写「文字」，不需要就取消「启用」"
        case "platform.hdr_unverified": "上传后的 HDR 效果尚未实测；不确定时把「输出」的「动态范围」改为 SDR"
        case "output.hdr_source_not_hdr", "output.hdr_no_headroom": "把「输出」的「动态范围」改为「跟随源图」，就不会再提示"
        case "output.metadata_dropped": "保留 HDR 时不能写入这些元数据；需要元数据时把「动态范围」改为 SDR"
        case "source.profile_missing": "颜色不对时选中源图，在右栏「色彩」里的「按此解释」选择色彩空间"
        case "source.override_ignored": "「按此解释」只用于没有 ICC 的源图，这张源图按自带的 ICC 解释"
        case "render.crop_ignored_for_panorama": "全景切片不裁切；需要裁切时在「全景」里取消「全景分割」"
        case "slot.optional_missing": "把左栏「素材」里的素材拖到「装饰」的「素材」行上，或取消这个装饰的「启用」"
        case "slot.stale_binding": "在「装饰」的「素材」里重新选择素材"
        case "slot.missing_required": "把左栏「素材」里的素材拖到「装饰」的「素材」行上"
        default: nil
        }
    }
}

extension DraftJob {
    /// 最近一次校验的错误和警告，错误在前。消息里的图层、素材槽用界面上的名字。
    public var issues: [JobIssue] {
        guard let validation else { return [] }
        let titles = preset.layerTitles
        return (validation.errors.map(JobIssue.init) + validation.warnings.map(JobIssue.init)).map { $0.naming(titles) }
    }
}

extension JobIssue {
    /// 只是说明、不算问题（例如 HDR 预览里成品为什么是 SDR）：显示成灰色的信息，不计入警告数。
    public var isInfo: Bool { code.hasPrefix("preview.") }
}

extension JobIssue {
    init(_ warning: ApplicationWarning) {
        self.init(isError: false, code: warning.code, message: warning.message, hint: JobIssue.hint(for: warning.code))
    }

    /// 错误：服务给了修改建议就用它的，否则用常见问题的建议。
    public init(_ error: ApplicationError) {
        self.init(isError: true, code: error.code, message: error.message, hint: error.hint ?? JobIssue.hint(for: error.code))
    }
}

extension JobRecord {
    /// 「已完成」详情里的错误和警告，与任务行、右栏同一种列表。
    public var issues: [JobIssue] {
        let titles = spec.preset.layerTitles
        return ((error.map { [JobIssue($0)] } ?? []) + displayWarnings.map(JobIssue.init)).map { $0.naming(titles) }
    }
}

extension Workbench {
    /// 右栏「警告」里的内容：选中一个任务时它的校验结果，选中源图时源图检查的提示，再加上当前预览渲染时的提示。
    /// 同一种（同一代码）的只列一次。预览区不显示这些提示，选中预设或源图时它们也只在这里。
    public var inspectorIssues: [JobIssue] {
        var issues: [JobIssue] = []
        let (subject, jobs) = inspected()
        switch subject {
        case .jobs:
            guard jobs.count == 1, let job = jobs.first else { return [] }
            issues = job.issues
        case .source(let id):
            if let item = sourceItem(id) {
                if let error = item.inspectionError { issues.append(JobIssue(error)) }
                issues += item.inspection?.warnings.map(JobIssue.init) ?? []
            }
        case .preset, .location, .none:
            break
        }
        guard preview.subject == previewSubject else { return issues }
        var codes = Set(issues.map(\.code))
        var extra: [JobIssue] = []
        let titles = preview.subject?.preset?.layerTitles ?? [:]
        for warning in preview.warnings where codes.insert(warning.code).inserted { extra.append(JobIssue(warning).naming(titles)) }
        return issues + extra.filter { !$0.isInfo } + extra.filter(\.isInfo)
    }
}
