import Foundation
import PhotoFrameCore
import PhotoFrameRendering

/// 作品目录已存在时怎么办（D-49）。
public enum ConflictPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    /// 默认：加版本后缀 `_v2`、`_v3`…，不动已有目录。
    case versionSuffix
    /// 显式选择（GUI 确认后、CLI `--overwrite`）：替换本软件之前发布的同名作品目录。
    /// 目录不是本软件发布的、含有其他文件、或含有任何任务的源文件时拒绝。
    case overwrite
}

/// 输出到哪里、怎么命名（§9.2）。
public struct ExportDestination: Hashable, Sendable, Codable {
    /// 例如 `~/Pictures/Social Exports`。不存在时在校验阶段创建。
    public var rootDirectory: URL
    public var naming: OutputNaming
    public var conflictPolicy: ConflictPolicy
    /// 是否为每个输出文件计算 SHA-256 写入清单（§9.1「可选 hash」，D-54 默认不算）。
    public var computeHashes: Bool

    public init(
        rootDirectory: URL, naming: OutputNaming = OutputNaming(),
        conflictPolicy: ConflictPolicy = .versionSuffix, computeHashes: Bool = false
    ) {
        self.rootDirectory = rootDirectory
        self.naming = naming
        self.conflictPolicy = conflictPolicy
        self.computeHashes = computeHashes
    }

    enum CodingKeys: String, CodingKey { case rootDirectory, naming, conflictPolicy, computeHashes }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootDirectory = try c.decode(URL.self, forKey: .rootDirectory)
        naming = try c.decodeIfPresent(OutputNaming.self, forKey: .naming) ?? OutputNaming()
        conflictPolicy = try c.decodeIfPresent(ConflictPolicy.self, forKey: .conflictPolicy) ?? .versionSuffix
        computeHashes = try c.decodeIfPresent(Bool.self, forKey: .computeHashes) ?? false
    }
}

/// 一个任务的全部输入。创建任务时就固定下来（§8.3 快照语义）：之后修改预设不影响已排队的任务，重试也用同一份。
public struct JobSpec: Hashable, Sendable, Codable {
    public var source: PhotoSource
    /// 预设快照。
    public var preset: ExportPreset
    public var destination: ExportDestination
    /// 单任务素材绑定 slotId → assetId（D-14 最高优先级）。
    public var assetBindings: [String: UUID]
    /// 源图没有 ICC 时按什么色彩空间解释（D-04）；nil 按 sRGB 并警告。源图自带 ICC 时忽略（渲染时警告）。
    public var sourceColorOverride: SourceColorOverride?

    public init(
        source: PhotoSource, preset: ExportPreset, destination: ExportDestination, assetBindings: [String: UUID] = [:],
        sourceColorOverride: SourceColorOverride? = nil
    ) {
        self.source = source
        self.preset = preset
        self.destination = destination
        self.assetBindings = assetBindings
        self.sourceColorOverride = sourceColorOverride
    }
}

/// 真实进度指标（§9.1）：当前阶段、已完成 / 计划的输出项、已发布字节数。不提供估算百分比。
public struct JobProgress: Hashable, Sendable, Codable {
    public var stage: JobStatus
    /// 渲染器已经编码完成的输出项数量。
    public var completedOutputs: Int
    /// 计划输出几项（封面 + 切片）。渲染器解码并完成布局后才知道，此前为 nil。
    public var plannedOutputs: Int?
    /// 已发布到目的地的字节数；发布完成前为 0。
    public var bytesWritten: Int64

    public init(stage: JobStatus = .queued, completedOutputs: Int = 0, plannedOutputs: Int? = nil, bytesWritten: Int64 = 0) {
        self.stage = stage
        self.completedOutputs = completedOutputs
        self.plannedOutputs = plannedOutputs
        self.bytesWritten = bytesWritten
    }
}

/// 状态变化历史中的一条。
public struct StatusChange: Hashable, Sendable, Codable {
    public var status: JobStatus
    public var at: Date

    public init(status: JobStatus, at: Date) {
        self.status = status
        self.at = at
    }
}

/// 任务的一次执行（§9.1 Attempt）。
public struct AttemptRecord: Hashable, Sendable, Codable, Identifiable {
    public var attemptId: AttemptID
    /// 第几次执行，从 1 开始。
    public var number: Int
    public var status: JobStatus
    public var history: [StatusChange]
    public var progress: JobProgress
    public var error: ApplicationError?
    public var warnings: [ApplicationWarning]
    /// 成功时的输出清单。
    public var manifest: OutputManifest?
    public var createdAt: Date
    /// 离开 `queued`、开始执行的时间。
    public var startedAt: Date?
    public var finishedAt: Date?

    public var id: AttemptID { attemptId }

    public init(attemptId: AttemptID = AttemptID(), number: Int, createdAt: Date = Date()) {
        self.attemptId = attemptId
        self.number = number
        self.status = .queued
        self.history = [StatusChange(status: .queued, at: createdAt)]
        self.progress = JobProgress()
        self.error = nil
        self.warnings = []
        self.manifest = nil
        self.createdAt = createdAt
        self.startedAt = nil
        self.finishedAt = nil
    }
}

/// 任务记录（§11.1 `JobRecord`）。可序列化，不依赖界面或进程（D-13），
/// 以后做「CLI 操控运行中的 GUI」或共享后台服务时可以原样跨进程传递。
public struct JobRecord: Hashable, Sendable, Codable, Identifiable {
    public var jobId: JobID
    public var spec: JobSpec
    public var createdAt: Date
    /// 全部执行记录，按时间顺序；最后一个是当前执行。至少有一个。
    public var attempts: [AttemptRecord]

    public var id: JobID { jobId }

    public init(jobId: JobID = JobID(), spec: JobSpec, createdAt: Date = Date()) {
        self.jobId = jobId
        self.spec = spec
        self.createdAt = createdAt
        self.attempts = [AttemptRecord(number: 1, createdAt: createdAt)]
    }

    public var currentAttempt: AttemptRecord {
        get { attempts[attempts.count - 1] }
        set { attempts[attempts.count - 1] = newValue }
    }

    /// 任务状态 = 当前执行的状态。
    public var status: JobStatus { currentAttempt.status }
    public var progress: JobProgress { currentAttempt.progress }
    public var error: ApplicationError? { currentAttempt.error }
    /// 最近一次成功执行的清单。
    public var manifest: OutputManifest? { attempts.last { $0.status == .completed }?.manifest }

    public var sourceId: SourceID { spec.source.sourceId }
    public var presetId: UUID { spec.preset.presetId }
}

/// §11.2 `status(_:)` 返回的快照。
public typealias JobSnapshot = JobRecord
