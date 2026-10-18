import PhotoFrameApplication

/// 任务校验得到的一条错误或警告，给任务行的弹出框和 Inspector 顶部的「警告」用（参照 Compressor 的错误窗口）。
public struct JobIssue: Hashable, Sendable, Identifiable {
    public var isError: Bool
    public var code: String
    public var message: String
    /// 一句话的修改建议；没有就是 nil。
    public var hint: String?

    public var id: String { "\(isError) \(code) \(message)" }

    /// 常见警告的修改建议（错误优先用服务给的 hint）。
    static func hint(for code: String) -> String? {
        switch code {
        case "panorama.not_landscape": "全景切片适合横向长图；不需要时在「全景」里关闭全景分割"
        case "panorama.not_wide_enough": "按实际需要的张数导出；想要更多张可以在「全景」里改为手动张数"
        case "panorama.exceeds_carousel_limit": "在「全景」里减少切片张数，或关闭封面"
        case "panorama.increased_slide_count": "改回自动张数，长卷两端就不会补底色"
        case "overlay.exceeds_canvas", "overlay.insufficient_margin": "在「图层」里调小图层或偏移，或在「画布」里加大最小边距"
        case "overlay.overlaps_photo": "把图层的参照改为照片外侧，或加大画布边距"
        case "overlay.missing_pages": "到「图层」里把显示页面改成实际存在的页"
        case "overlay.font_missing": "改用系统字体，或先安装这个字体"
        case "overlay.metadata_missing": "源图没有这些 EXIF 字段，对应部分会留空；可以改 EXIF 文字模板"
        case "overlay.asset_missing", "overlay.empty_text", "overlay.missing_text": "在「图层」里给这个图层选素材或填文字，不需要就关闭它"
        case "platform.hdr_unverified": "上传后的 HDR 效果尚未实测；不确定时把「输出」的动态范围改为 SDR"
        case "output.hdr_source_not_hdr", "output.hdr_no_headroom": "把「输出」的动态范围改为「跟随源图」，就不会再提示"
        case "output.metadata_dropped": "保留 HDR 时不能写入这些元数据；需要元数据时改为 SDR 输出"
        case "source.profile_missing": "源图没有 ICC，按 sRGB 处理；颜色不对时在源图的 Inspector 里指定色彩空间"
        case "source.override_ignored": "源图自带 ICC，指定的色彩空间没有使用"
        case "render.crop_ignored_for_panorama": "全景切片不裁切；需要裁切时关闭全景分割"
        default: nil
        }
    }
}

extension DraftJob {
    /// 最近一次校验的错误和警告，错误在前。
    public var issues: [JobIssue] {
        guard let validation else { return [] }
        return validation.errors.map { JobIssue(isError: true, code: $0.code, message: $0.message, hint: $0.hint ?? JobIssue.hint(for: $0.code)) }
            + validation.warnings.map { JobIssue(isError: false, code: $0.code, message: $0.message, hint: JobIssue.hint(for: $0.code)) }
    }
}

extension JobIssue {
    /// 只是说明、不算问题（例如 HDR 预览里成品为什么是 SDR）：显示成灰色的信息，不计入警告数。
    public var isInfo: Bool { code.hasPrefix("preview.") }
}

extension Workbench {
    /// Inspector「警告」里的内容：选中一个任务时它的校验结果，再加上当前预览渲染时的提示（校验里已有的同类不重复）。
    /// 预览区不再显示这些提示，选中预设或源图时它们也只在这里。
    public var inspectorIssues: [JobIssue] {
        var issues: [JobIssue] = []
        let (subject, jobs) = inspected()
        if case .jobs = subject {
            guard jobs.count == 1, let job = jobs.first else { return [] }
            issues = job.issues
        }
        guard preview.subject == previewSubject else { return issues }
        let codes = Set(issues.map(\.code))
        let extra = preview.warnings.filter { !codes.contains($0.code) }
            .map { JobIssue(isError: false, code: $0.code, message: $0.message, hint: JobIssue.hint(for: $0.code)) }
        return issues + extra.filter { !$0.isInfo } + extra.filter(\.isInfo)
    }
}
