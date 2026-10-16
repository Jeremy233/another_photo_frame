import Foundation
import PhotoFrameCore
import PhotoFrameStorage

/// 渲染器：把一个任务渲染成输出文件。队列只依赖这个协议；真正的实现在 PhotoFrameRendering 模块。
///
/// 约定：
/// - **只往 `outputDirectory` 里写文件。** 这是本次执行独占的临时目录，位于输出根目录下的
///   `.photoframe-staging/<attemptId>/render/`，与最终目的地在同一卷上。队列负责创建和删除它，
///   之后校验、改名并原子发布成品；渲染器不要自己往目的地写，也不要改动源文件。
/// - 文件名随意，发布时按 §9.2 改名（可以直接用 ``OutputNaming/fileName(for:format:outputCount:)``）。
/// - **阶段**：调用 `render` 前队列已进入 `decoding`。渲染器依次报告 `.rendering`、`.encoding`；
///   逐张切片交替渲染、编码时只需在第一次进入某阶段时报告，状态只前进不后退，倒退的报告会被忽略。
/// - **进度**：知道要输出几项时报告 `.plannedOutputs`，每写完一个文件报告 `.outputFinished`。
///   不要报告估算的百分比（§9.1）。
/// - **取消**：任务被取消时，所在 Task 会被取消。渲染器应在两张切片之间等合适的位置检查
///   `Task.isCancelled` 并抛出 `CancellationError`。临时目录由队列删除。
/// - **错误**：抛出实现了 ``ApplicationErrorConvertible`` 的错误可以带上稳定的错误码；
///   其他错误记为 `render.failed`。
public protocol JobRenderer: Sendable {
    /// 估算这个任务的峰值内存（字节），队列据此决定能否与其他任务并行（§12.1、D-18）。
    /// 返回 nil 时队列按源图像素数粗略估算。
    func estimatedPeakMemoryBytes(for job: JobRenderRequest) -> Int64?

    func render(_ job: JobRenderRequest, outputDirectory: URL, progress: RenderProgressReporter) async throws -> JobRenderResult
}

extension JobRenderer {
    public func estimatedPeakMemoryBytes(for job: JobRenderRequest) -> Int64? { nil }
}

/// 交给渲染器的输入。
public struct JobRenderRequest: Sendable {
    public var jobId: JobID
    public var attemptId: AttemptID
    public var source: PhotoSource
    /// 预设快照（§8.3）。
    public var preset: ExportPreset
    /// 平台配置，用于轮播上限和 HDR 格式；预设没有平台或配置里找不到时为 nil。
    public var platform: PlatformProfile?
    /// 素材槽解析结果（D-14、D-28、D-29）。队列没有配置素材库时为 nil，由渲染器自行处理。
    public var slots: SlotResolution?

    public init(
        jobId: JobID, attemptId: AttemptID, source: PhotoSource, preset: ExportPreset,
        platform: PlatformProfile? = nil, slots: SlotResolution? = nil
    ) {
        self.jobId = jobId
        self.attemptId = attemptId
        self.source = source
        self.preset = preset
        self.platform = platform
        self.slots = slots
    }
}

/// 渲染器写出的一个文件。
public struct JobRenderedOutput: Hashable, Sendable {
    public var role: JobOutputRole
    /// 必须在 `outputDirectory` 之内，且是普通文件。
    public var fileURL: URL
    public var pixelSize: PixelSize
    /// 实际嵌入的 ICC 描述，例如 `sRGB IEC61966-2.1`。
    public var colorProfile: String?
    public var warnings: [ApplicationWarning]

    public init(role: JobOutputRole, fileURL: URL, pixelSize: PixelSize, colorProfile: String?, warnings: [ApplicationWarning] = []) {
        self.role = role
        self.fileURL = fileURL
        self.pixelSize = pixelSize
        self.colorProfile = colorProfile
        self.warnings = warnings
    }
}

public struct JobRenderResult: Hashable, Sendable {
    public var outputs: [JobRenderedOutput]
    /// 任务级提示（例如 `Source profile missing — assumed sRGB`、HDR 部分未读取、全景超出轮播上限）。
    public var warnings: [ApplicationWarning]

    public init(outputs: [JobRenderedOutput], warnings: [ApplicationWarning] = []) {
        self.outputs = outputs
        self.warnings = warnings
    }
}

/// 渲染器报告的阶段，对应 ``JobStatus`` 的 `decoding` / `rendering` / `encoding`。
public enum JobRenderStage: String, Hashable, Sendable, Codable {
    case decoding, rendering, encoding

    public var status: JobStatus {
        switch self {
        case .decoding: .decoding
        case .rendering: .rendering
        case .encoding: .encoding
        }
    }
}

public enum JobRenderProgress: Hashable, Sendable {
    case stage(JobRenderStage)
    /// 本任务总共要输出几项（封面 + 切片）。
    case plannedOutputs(Int)
    /// 一个输出文件已经写进临时目录。
    case outputFinished(JobOutputRole)
}

/// 渲染器用来报告进度。`await` 返回时事件已经记入任务并发布给订阅者，顺序有保证。
public struct RenderProgressReporter: Sendable {
    private let handler: @Sendable (JobRenderProgress) async -> Void

    public init(_ handler: @escaping @Sendable (JobRenderProgress) async -> Void) {
        self.handler = handler
    }

    public func report(_ update: JobRenderProgress) async {
        await handler(update)
    }

    /// 不记录任何东西，供测试或预览使用。
    public static let ignore = RenderProgressReporter { _ in }
}
