import PhotoFrameCore

/// 应用层错误：稳定的机器可读 `code` + 给人看的 `message` + 可选的修复提示（§10.1）。
///
/// 任务失败原因、服务接口的错误都用这个类型；可序列化，CLI / MCP 可以直接输出。
public struct ApplicationError: Error, Hashable, Sendable, Codable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var hint: String?

    public init(code: String, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }

    public var description: String { "\(code): \(message)" }
}

/// 不阻止输出、但需要让用户看到的提示。
public struct ApplicationWarning: Hashable, Sendable, Codable, CustomStringConvertible {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }
}

/// 其他模块的错误可以实现这个协议，告诉队列怎样把它记进任务（例如渲染模块的解码错误）。
/// 没有实现时记为 `render.failed`。
public protocol ApplicationErrorConvertible: Error {
    var applicationError: ApplicationError { get }
}

extension ApplicationError {
    // MARK: 服务

    static func sourceNotFound(_ path: String) -> Self {
        Self(code: "source.not_found", message: "找不到源文件：\(path)")
    }
    static func sourceNotRegularFile(_ path: String) -> Self {
        Self(code: "source.not_regular_file", message: "源路径不是普通文件：\(path)")
    }
    static func sourceUnsupportedFormat(_ ext: String) -> Self {
        Self(code: "source.unsupported_format", message: "不支持的源文件格式：\(ext.isEmpty ? "（无扩展名）" : ext)",
             hint: "V1 支持 JPEG、PNG、TIFF（D-02）")
    }
    static func unknownSource(_ id: SourceID) -> Self {
        Self(code: "source.unknown", message: "没有这张源图：\(id)")
    }
    static func unknownJob(_ id: JobID) -> Self {
        Self(code: "job.unknown", message: "没有这个任务：\(id)")
    }
    static func emptyRequest() -> Self {
        Self(code: "request.empty", message: "导出请求至少需要一张源图和一个预设")
    }
    static func notRetryable(_ id: JobID, _ status: JobStatus) -> Self {
        Self(code: "job.not_retryable", message: "任务 \(id) 当前为 \(status.rawValue)，只有失败或已取消的任务可以重试")
    }
    static func notCancelable(_ id: JobID, _ status: JobStatus) -> Self {
        Self(code: "job.not_cancelable", message: "任务 \(id) 已经是 \(status.rawValue)，不能取消")
    }

    static func presetNotFound(_ reference: String) -> Self {
        Self(code: "preset.not_found", message: "找不到预设：\(reference)",
             hint: "用 `photoframe preset list` 查看可用的预设，或给出 .photoframe 文件路径")
    }
    static func presetAmbiguous(_ reference: String, _ ids: [String]) -> Self {
        Self(code: "preset.ambiguous", message: "名称 \(reference) 对应多个预设：\(ids.joined(separator: ", "))",
             hint: "改用 presetId 指定")
    }
    static func presetFileNotFound(_ path: String) -> Self {
        Self(code: "preset.file_not_found", message: "找不到预设文件：\(path)")
    }
    static func analyzerUnavailable() -> Self {
        Self(code: "service.unavailable", message: "这个服务实例没有配置图像分析（检查源图、预估输出、预览）")
    }
    static func duplicateOutput(_ path: String) -> Self {
        Self(code: "request.duplicate_output", message: "同一请求中有多个任务会覆盖同一个作品目录：\(path)",
             hint: "覆盖模式下每个作品目录只能对应一个任务；去掉 --overwrite 或分开导出同名源图")
    }

    // MARK: 校验（validating）

    static func sourceUnreadable(_ path: String) -> Self {
        Self(code: "job.source_unreadable", message: "源文件不存在或不可读：\(path)", hint: "确认文件没有被移动或删除，然后重试")
    }
    static func invalidPreset(_ issues: [String]) -> Self {
        Self(code: "job.invalid_preset", message: "预设有错误：\(issues.joined(separator: "；"))")
    }
    static func destinationUnavailable(_ path: String, _ reason: String) -> Self {
        Self(code: "job.destination_unavailable", message: "输出目录不可用：\(path)（\(reason)）",
             hint: "选择一个可写的输出目录")
    }
    static func destinationInsideStaging(_ path: String) -> Self {
        Self(code: "job.destination_invalid", message: "输出目录不能位于临时目录中：\(path)")
    }

    // MARK: 渲染与发布

    static func renderFailed(_ detail: String) -> Self {
        Self(code: "render.failed", message: "渲染失败：\(detail)", hint: "可以重试；反复失败请附上日志报告问题")
    }
    static func noOutputs() -> Self {
        Self(code: "export.no_outputs", message: "渲染器没有返回任何输出文件")
    }
    static func duplicateRole(_ role: JobOutputRole) -> Self {
        Self(code: "export.duplicate_output", message: "渲染器重复返回了 \(role)")
    }
    static func invalidRole(_ role: JobOutputRole) -> Self {
        Self(code: "export.invalid_output_role", message: "无效的输出位置：\(role)")
    }
    static func invalidPixelSize(_ role: JobOutputRole, _ size: PixelSize) -> Self {
        Self(code: "export.invalid_pixel_size", message: "\(role) 的像素尺寸无效：\(size)")
    }
    static func outputOutsideStaging(_ path: String) -> Self {
        Self(code: "export.output_outside_staging", message: "输出文件不在本任务的临时目录中：\(path)")
    }
    static func outputMissing(_ path: String) -> Self {
        Self(code: "export.output_missing", message: "输出文件不存在：\(path)")
    }
    static func outputNotRegularFile(_ path: String) -> Self {
        Self(code: "export.output_not_regular_file", message: "输出不是普通文件（符号链接、目录或硬链接都不接受）：\(path)")
    }
    static func outputEmpty(_ path: String) -> Self {
        Self(code: "export.output_empty", message: "输出文件为空：\(path)")
    }
    static func outputFormatMismatch(_ path: String, expected: String) -> Self {
        Self(code: "export.output_format_mismatch", message: "输出文件内容不是 \(expected)：\(path)")
    }
    static func stagingFailed(_ detail: String) -> Self {
        Self(code: "export.staging_failed", message: "无法准备临时目录：\(detail)", hint: "检查磁盘空间和输出目录权限")
    }
    static func publishFailed(_ detail: String) -> Self {
        Self(code: "export.publish_failed", message: "发布输出失败：\(detail)", hint: "检查磁盘空间和输出目录权限，然后重试")
    }
    static func overwriteRefused(_ path: String, _ reason: String) -> Self {
        Self(code: "export.overwrite_refused", message: "拒绝覆盖 \(path)：\(reason)",
             hint: "改用默认的加版本后缀，或手动处理这个目录")
    }
    static func overwriteContainsSource(_ path: String, _ source: String) -> Self {
        Self(code: "export.overwrite_contains_source", message: "拒绝覆盖 \(path)：其中含有源文件 \(source)",
             hint: "源图不能放在输出目录里；把它移到别处再导出")
    }
    static func versionsExhausted(_ name: String) -> Self {
        Self(code: "export.versions_exhausted", message: "\(name) 的版本号已用尽", hint: "清理输出目录中的旧版本")
    }
}
