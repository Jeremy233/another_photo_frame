import PhotoFrameApplication

/// `photoframe` 的退出码。数值稳定，脚本可以依赖；完整的表见 docs/usage/CLI.md。
public enum PhotoFrameExitCode: Int32, CaseIterable, Sendable, Codable {
    /// 成功（`--dry-run` 时表示校验通过）。
    case success = 0
    /// 内部错误：不应发生的情况，请报告问题。
    case internalError = 1
    /// 用法错误：参数缺失、未知选项、取值格式不对。
    case usage = 2
    /// 找不到输入：源图、预设文件、预设或素材不存在。
    case notFound = 3
    /// 输入无效：格式不支持、无法解码、预设内容有错误、缺少必需素材、校验未通过。
    case invalidInput = 4
    /// 输出不可用：输出目录不可写、拒绝覆盖、目标文件已存在、写本地库失败。
    case outputUnavailable = 5
    /// 导出任务失败：校验通过后至少一个任务在渲染或发布时失败（其余任务照常完成）。
    case jobFailed = 6
    /// 被 Ctrl-C（SIGINT）或 SIGTERM 中断：未完成的任务已取消，临时文件已清理。
    case interrupted = 130

    /// 按错误码分类。未列出的码都算输入无效。
    public init(for error: ApplicationError) {
        switch error.code {
        case "source.not_found", "preset.file_not_found", "library.preset_not_found",
             "asset.not_found", "asset.file_not_found":
            self = .notFound
        case "job.destination_unavailable", "job.destination_invalid",
             "export.overwrite_refused", "export.overwrite_contains_source", "export.versions_exhausted",
             "export.staging_failed", "export.publish_failed",
             "request.duplicate_output", "preview.file_exists", "preview.write_failed",
             "preset.export_exists", "library.io":
            self = .outputUnavailable
        case "service.unavailable", "cli.internal":
            self = .internalError
        default:
            self = .invalidInput
        }
    }
}

/// 命令已经输出完结果，以这个状态结束进程。
struct CLIExit: Error {
    var status: PhotoFrameExitCode
}
