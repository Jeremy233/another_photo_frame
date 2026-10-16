import Foundation
import PhotoFrameCore

/// 导出请求（§11.1 `ExportRequest`）：多张源图 × 多个预设快照，每个组合生成一个任务（§3.1）。
public struct ExportRequest: Hashable, Sendable, Codable {
    public var sourceIds: [SourceID]
    /// 预设快照：请求创建时的内容，之后修改预设不影响这些任务（§8.3）。
    public var presets: [ExportPreset]
    public var destination: ExportDestination
    /// 单任务素材绑定，作用于本请求生成的每个任务（D-14）。
    public var assetBindings: [String: UUID]

    public init(sourceIds: [SourceID], presets: [ExportPreset], destination: ExportDestination, assetBindings: [String: UUID] = [:]) {
        self.sourceIds = sourceIds
        self.presets = presets
        self.destination = destination
        self.assetBindings = assetBindings
    }
}

/// GUI、CLI、MCP 共用的后端入口（§10.1、§11.2、D-13）。这里只有任务相关的部分；
/// 预设列表、源图检查、预览等接口等渲染与存储接上后再补。
///
/// 所有类型都可序列化、与界面无关，以后可以在进程间适配器后面提供同一个接口。
public protocol PhotoFrameService: Sendable {
    /// 登记一张源图。只检查文件存在且是 V1 支持的格式（D-02），不读取像素；同一路径重复添加返回已有记录。
    func addSource(_ fileURL: URL) async throws(ApplicationError) -> PhotoSource
    func sources() async -> [PhotoSource]

    /// 按请求创建任务（源图 × 预设）。队列未暂停时立即开始排队执行。
    func submit(_ request: ExportRequest) async throws(ApplicationError) -> [JobID]
    /// 开始 / 继续派发任务。
    func start() async
    /// 暂停派发新任务；正在执行的任务继续做完。
    func pause() async
    func cancel(_ job: JobID) async throws(ApplicationError)
    /// 重试失败或已取消的任务，返回新的 AttemptID。
    func retry(_ job: JobID) async throws(ApplicationError) -> AttemptID

    func status(_ job: JobID) async throws(ApplicationError) -> JobSnapshot
    func jobs() async -> [JobSnapshot]
    /// 最近一次成功执行的输出清单；还没有成功过时为 nil。
    func manifest(_ job: JobID) async throws(ApplicationError) -> OutputManifest?

    /// 任务事件流。
    func events() async -> AsyncStream<JobEvent>
    /// 等这些任务结束（CLI 默认阻塞到任务结束，§10.3）。
    func waitUntilFinished(_ jobs: [JobID]) async -> [JobSnapshot]
}

/// 进程内实现：源图登记 + ``JobQueue``。GUI、CLI、MCP 各自在自己的进程里创建一个（D-13）。
public actor LocalPhotoFrameService: PhotoFrameService {
    public let queue: JobQueue
    private var sourcesById: [SourceID: PhotoSource] = [:]
    private var sourceOrder: [SourceID] = []

    public init(queue: JobQueue) {
        self.queue = queue
    }

    public init(renderer: any JobRenderer, configuration: QueueConfiguration = QueueConfiguration()) {
        self.queue = JobQueue(renderer: renderer, configuration: configuration)
    }

    public func addSource(_ fileURL: URL) throws(ApplicationError) -> PhotoSource {
        let url = fileURL.standardizedFileURL
        if let existing = sourcesById.values.first(where: { $0.fileURL.standardizedFileURL == url }) {
            return existing
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw .sourceNotFound(url.path)
        }
        guard !isDirectory.boolValue else { throw .sourceNotRegularFile(url.path) }
        let ext = url.pathExtension.lowercased()
        guard PhotoSource.supportedExtensions.contains(ext) else { throw .sourceUnsupportedFormat(ext) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        let source = PhotoSource(fileURL: url, fileSizeBytes: size)
        sourcesById[source.sourceId] = source
        sourceOrder.append(source.sourceId)
        return source
    }

    public func sources() -> [PhotoSource] {
        sourceOrder.compactMap { sourcesById[$0] }
    }

    public func submit(_ request: ExportRequest) async throws(ApplicationError) -> [JobID] {
        guard !request.sourceIds.isEmpty, !request.presets.isEmpty else { throw .emptyRequest() }
        var specs: [JobSpec] = []
        for sourceId in request.sourceIds {
            guard let source = sourcesById[sourceId] else { throw .unknownSource(sourceId) }
            for preset in request.presets {
                specs.append(JobSpec(source: source, preset: preset, destination: request.destination, assetBindings: request.assetBindings))
            }
        }
        return await queue.submit(specs).map(\.jobId)
    }

    public func start() async { await queue.resume() }
    public func pause() async { await queue.pause() }

    public func cancel(_ job: JobID) async throws(ApplicationError) {
        try await queue.cancel(job)
    }

    public func retry(_ job: JobID) async throws(ApplicationError) -> AttemptID {
        try await queue.retry(job)
    }

    public func status(_ job: JobID) async throws(ApplicationError) -> JobSnapshot {
        guard let record = await queue.record(for: job) else { throw .unknownJob(job) }
        return record
    }

    public func jobs() async -> [JobSnapshot] { await queue.allRecords() }

    public func manifest(_ job: JobID) async throws(ApplicationError) -> OutputManifest? {
        try await status(job).manifest
    }

    public func events() async -> AsyncStream<JobEvent> { await queue.events() }

    public func waitUntilFinished(_ jobs: [JobID]) async -> [JobSnapshot] {
        await queue.waitUntilFinished(jobs)
    }
}
