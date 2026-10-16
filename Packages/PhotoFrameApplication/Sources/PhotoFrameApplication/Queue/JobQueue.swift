import Foundation
import PhotoFrameCore
import PhotoFrameStorage
import Synchronization

/// 本进程内的任务队列（§9、§10.3）。
///
/// - 按提交顺序执行；同时运行的任务数受 ``QueueConfiguration/maxConcurrentJobs`` 和内存预算限制（§12.1）。
/// - **暂停**只停止派发新任务，已经在执行的任务继续做完。
/// - **取消**排队中的任务立即生效；执行中的任务会取消渲染所在的 Task，删除本次执行的临时文件，
///   状态变为 `canceled`。最终改名发布一旦完成就不能再取消。
/// - **重试**只对 `failed` / `canceled` 的任务，新建一个 Attempt，旧 Attempt 保留在历史里。
/// - 每个进程一个队列，不跨进程共享（D-13）；状态都在可序列化的 ``JobRecord`` 里。
/// - 并发数与内存预算可以在运行中修改（D-53），见 ``setMaxConcurrentJobs(_:)``、``setMemoryBudget(_:)``。
/// - 每个输出根目录第一次使用时清理其中超过 24 小时的残留临时目录（D-55）。
public actor JobQueue {
    public private(set) var configuration: QueueConfiguration
    private let renderer: any JobRenderer
    private let exporter: AtomicExporter

    private var records: [JobID: JobRecord] = [:]
    private var order: [JobID] = []
    /// 等待派发的任务，按先后顺序。
    private var pending: [JobID] = []
    private var running: [JobID: Running] = [:]
    public private(set) var isPaused: Bool
    private var subscribers: [UUID: AsyncStream<JobEvent>.Continuation] = [:]
    private var waiters: [Waiter] = []
    /// 已经清理过残留临时目录的输出根目录。
    private var cleanedRoots: Set<String> = []

    private struct Running {
        var attemptId: AttemptID
        var memory: Int64
        var cancelFlag: CancelFlag
        var task: Task<Void, Never>?
    }

    private struct Waiter {
        /// nil = 等队列空闲；否则等这些任务都进入终态。
        var jobs: Set<JobID>?
        var continuation: CheckedContinuation<Void, Never>
    }

    public init(renderer: any JobRenderer, configuration: QueueConfiguration = QueueConfiguration(), exporter: AtomicExporter = AtomicExporter()) {
        self.renderer = renderer
        self.configuration = configuration
        self.exporter = exporter
        self.isPaused = configuration.startsPaused
    }

    // MARK: - 事件

    /// 订阅之后发生的全部事件。流结束（订阅方停止迭代）时自动退订。
    public func events() -> AsyncStream<JobEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: JobEvent.self)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func emit(_ event: JobEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    // MARK: - 查询

    public func record(for id: JobID) -> JobRecord? { records[id] }

    /// 全部任务，按提交顺序。
    public func allRecords() -> [JobRecord] { order.compactMap { records[$0] } }

    public var runningJobIds: Set<JobID> { Set(running.keys) }

    public var pendingJobIds: [JobID] { pending }

    // MARK: - 操作

    @discardableResult
    public func submit(_ spec: JobSpec) -> JobRecord {
        submit([spec])[0]
    }

    @discardableResult
    public func submit(_ specs: [JobSpec]) -> [JobRecord] {
        let added = specs.map { JobRecord(spec: $0) }
        for record in added {
            records[record.jobId] = record
            order.append(record.jobId)
            pending.append(record.jobId)
            emit(.jobAdded(record))
        }
        dispatch()
        return added
    }

    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        emit(.queuePaused)
        resumeWaiters()
    }

    /// 开始或继续派发。
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        emit(.queueResumed)
        dispatch()
    }

    public func cancel(_ id: JobID) throws(ApplicationError) {
        guard let record = records[id] else { throw .unknownJob(id) }
        switch record.status {
        case .canceled:
            return
        case .completed, .failed:
            throw .notCancelable(id, record.status)
        case .queued where running[id] == nil:
            pending.removeAll { $0 == id }
            finish(id, record.currentAttempt.attemptId, .canceled)
            resumeWaiters()
        default:
            guard let job = running[id] else { return }
            job.cancelFlag.set()
            job.task?.cancel()
        }
    }

    /// 重试失败或已取消的任务：新建 Attempt 并重新排队。返回新的 AttemptID。
    @discardableResult
    public func retry(_ id: JobID) throws(ApplicationError) -> AttemptID {
        guard var record = records[id] else { throw .unknownJob(id) }
        guard record.status == .failed || record.status == .canceled else {
            throw .notRetryable(id, record.status)
        }
        let attempt = AttemptRecord(number: record.attempts.count + 1)
        record.attempts.append(attempt)
        records[id] = record
        pending.append(id)
        emit(.attemptCreated(jobId: id, attemptId: attempt.attemptId, number: attempt.number))
        dispatch()
        return attempt.attemptId
    }

    // MARK: - 调度设置（D-53）

    /// 修改并发上限，立即生效。调低时正在执行的任务继续做完，之后按新上限派发。
    public func setMaxConcurrentJobs(_ count: Int) {
        configuration.maxConcurrentJobs = max(1, count)
        dispatch()
    }

    /// 修改内存预算（nil = 不按内存限制），立即生效。
    public func setMemoryBudget(_ bytes: Int64?) {
        configuration.memoryBudgetBytes = bytes
        dispatch()
    }

    // MARK: - 残留临时目录（D-55）

    /// 清理 `destinationRoot` 下超过 `olderThan` 的残留临时目录，跳过本队列正在执行的 Attempt。
    @discardableResult
    public func removeStaleStaging(in destinationRoot: URL, olderThan age: TimeInterval = AtomicExporter.staleStagingAge) -> [URL] {
        cleanedRoots.insert(destinationRoot.standardizedFileURL.path)
        let active = Set(running.values.map(\.attemptId))
        return AtomicExporter.removeStaleStaging(in: destinationRoot, olderThan: age, excluding: active)
    }

    // MARK: - 等待

    /// 等到没有正在执行的任务，并且没有待派发的任务（或队列已暂停）。CLI 用它阻塞到批处理结束。
    public func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { waiters.append(Waiter(jobs: nil, continuation: $0)) }
    }

    /// 等到这些任务都进入终态，返回它们的记录（顺序与参数一致）。未知的 ID 被忽略。
    public func waitUntilFinished(_ ids: [JobID]) async -> [JobRecord] {
        let known = Set(ids.filter { records[$0] != nil })
        if !allFinished(known) {
            await withCheckedContinuation { waiters.append(Waiter(jobs: known, continuation: $0)) }
        }
        return ids.compactMap { records[$0] }
    }

    private var isIdle: Bool { running.isEmpty && (pending.isEmpty || isPaused) }

    private func allFinished(_ ids: Set<JobID>) -> Bool {
        ids.allSatisfy { records[$0]?.status.isTerminal ?? true }
    }

    private func resumeWaiters() {
        var remaining: [Waiter] = []
        for waiter in waiters {
            let done = waiter.jobs.map(allFinished) ?? isIdle
            if done { waiter.continuation.resume() } else { remaining.append(waiter) }
        }
        waiters = remaining
    }

    // MARK: - 调度

    private var runningMemory: Int64 { running.values.reduce(0) { $0 + $1.memory } }

    private func dispatch() {
        defer { resumeWaiters() }
        guard !isPaused else { return }
        while let id = pending.first, running.count < max(1, configuration.maxConcurrentJobs) {
            guard let record = records[id] else { pending.removeFirst(); continue }
            let memory = estimatedMemory(record)
            // 按提交顺序派发，不让后面的小任务插队，避免大任务一直等不到内存。
            if let budget = configuration.memoryBudgetBytes, !running.isEmpty, runningMemory + memory > budget {
                break
            }
            pending.removeFirst()
            let attemptId = record.currentAttempt.attemptId
            let flag = CancelFlag()
            running[id] = Running(attemptId: attemptId, memory: memory, cancelFlag: flag)
            running[id]?.task = Task { await self.execute(id, attemptId, flag) }
        }
    }

    private func estimatedMemory(_ record: JobRecord) -> Int64 {
        let probe = JobRenderRequest(
            jobId: record.jobId, attemptId: record.currentAttempt.attemptId,
            source: record.spec.source, preset: record.spec.preset,
            platform: platformProfile(for: record.spec.preset))
        return renderer.estimatedPeakMemoryBytes(for: probe) ?? configuration.estimatedMemory(for: record.spec)
    }

    private func platformProfile(for preset: ExportPreset) -> PlatformProfile? {
        configuration.platformProfile(for: preset)
    }

    // MARK: - 执行

    private func execute(_ id: JobID, _ attemptId: AttemptID, _ flag: CancelFlag) async {
        guard let spec = records[id]?.spec else { return }
        var staging: StagingArea?
        do {
            if flag.isSet { throw CancellationError() }
            transition(id, attemptId, to: .validating)
            let startedAt = Date()
            let job = try validate(spec, id, attemptId)
            if flag.isSet { throw CancellationError() }

            transition(id, attemptId, to: .decoding)
            let area = try exporter.makeStaging(destinationRoot: spec.destination.rootDirectory, attemptId: attemptId)
            staging = area
            let reporter = RenderProgressReporter { [weak self] update in
                await self?.handleRenderProgress(update, id, attemptId)
            }
            let result = try await renderer.render(job, outputDirectory: area.renderDirectory, progress: reporter)
            if flag.isSet { throw CancellationError() }

            advance(id, attemptId, through: .encoding)
            transition(id, attemptId, to: .writing)
            // 发布在独立的 Task 里做文件操作，不占用队列；它只看取消标志，不响应 Task 取消。
            let exporter = self.exporter
            let protectedSources = records.values.map(\.spec.source.fileURL)
            staging = nil  // publish 无论成败都会清理临时目录
            let manifest = try await Task.detached {
                try exporter.publish(
                    result, spec: spec, jobId: id, staging: area, startedAt: startedAt,
                    protectedSources: protectedSources, isCanceled: { flag.isSet })
            }.value
            complete(id, attemptId, manifest)
        } catch {
            if let staging { exporter.discard(staging) }
            if flag.isSet || error is CancellationError {
                finish(id, attemptId, .canceled)
            } else {
                finish(id, attemptId, .failed, error: Self.applicationError(error))
            }
        }
        running[id] = nil
        dispatch()
    }

    /// `validating` 阶段：源文件可读、预设与平台检查无错误、输出目录可写、素材槽可解析。
    private func validate(_ spec: JobSpec, _ id: JobID, _ attemptId: AttemptID) throws(ApplicationError) -> JobRenderRequest {
        try ExportChecks.checkSource(spec.source.fileURL)
        let platform = platformProfile(for: spec.preset)
        var warnings = try ExportChecks.checkPreset(spec.preset, platform: platform)

        let root = spec.destination.rootDirectory.standardizedFileURL
        try ExportChecks.checkDestination(root, create: true)
        if !cleanedRoots.contains(root.path) {
            removeStaleStaging(in: root)
        }

        let (slots, slotWarnings) = try ExportChecks.resolveSlots(
            configuration.currentSlotResolver(), preset: spec.preset, bindings: spec.assetBindings)
        warnings += slotWarnings
        if !warnings.isEmpty {
            update(id, attemptId) { $0.warnings += warnings }
        }
        return JobRenderRequest(jobId: id, attemptId: attemptId, source: spec.source, preset: spec.preset, platform: platform, slots: slots)
    }

    private func handleRenderProgress(_ update: JobRenderProgress, _ id: JobID, _ attemptId: AttemptID) {
        guard let attempt = currentAttempt(id, attemptId), attempt.status.isProcessing else { return }
        switch update {
        case .stage(let stage):
            advance(id, attemptId, through: stage.status)
        case .plannedOutputs(let count):
            updateProgress(id, attemptId) { $0.plannedOutputs = count }
        case .outputFinished:
            updateProgress(id, attemptId) { $0.completedOutputs += 1 }
        }
    }

    private func complete(_ id: JobID, _ attemptId: AttemptID, _ manifest: OutputManifest) {
        update(id, attemptId) { attempt in
            attempt.manifest = manifest
            attempt.warnings += manifest.warnings.filter { !attempt.warnings.contains($0) }
        }
        updateProgress(id, attemptId) { $0.bytesWritten = manifest.totalBytes }
        finish(id, attemptId, .completed)
    }

    private func finish(_ id: JobID, _ attemptId: AttemptID, _ status: JobStatus, error: ApplicationError? = nil) {
        guard status.isTerminal else { return }
        if let error { update(id, attemptId) { $0.error = error } }
        guard transition(id, attemptId, to: status), let record = records[id] else { return }
        emit(.attemptFinished(record))
    }

    // MARK: - 状态

    private func currentAttempt(_ id: JobID, _ attemptId: AttemptID) -> AttemptRecord? {
        guard let attempt = records[id]?.currentAttempt, attempt.attemptId == attemptId else { return nil }
        return attempt
    }

    private func update(_ id: JobID, _ attemptId: AttemptID, _ body: (inout AttemptRecord) -> Void) {
        guard currentAttempt(id, attemptId) != nil else { return }
        body(&records[id]!.currentAttempt)
    }

    private func updateProgress(_ id: JobID, _ attemptId: AttemptID, _ body: (inout JobProgress) -> Void) {
        guard let before = currentAttempt(id, attemptId)?.progress else { return }
        update(id, attemptId) { body(&$0.progress) }
        if let after = currentAttempt(id, attemptId)?.progress, after != before {
            emit(.progress(jobId: id, attemptId: attemptId, progress: after))
        }
    }

    /// 按状态机转换；不合法的转换被忽略并返回 false。
    @discardableResult
    private func transition(_ id: JobID, _ attemptId: AttemptID, to status: JobStatus) -> Bool {
        guard let attempt = currentAttempt(id, attemptId), attempt.status.canTransition(to: status) else { return false }
        let now = Date()
        update(id, attemptId) { a in
            if a.status == .queued { a.startedAt = now }
            a.status = status
            a.history.append(StatusChange(status: status, at: now))
            a.progress.stage = status
            if status.isTerminal { a.finishedAt = now }
        }
        emit(.statusChanged(jobId: id, attemptId: attemptId, status: status))
        return true
    }

    /// 沿流水线逐步前进到 `target`；已经在它之后则什么都不做（阶段只进不退）。
    private func advance(_ id: JobID, _ attemptId: AttemptID, through target: JobStatus) {
        guard let targetIndex = target.pipelineIndex else { return }
        while let current = currentAttempt(id, attemptId)?.status, let index = current.pipelineIndex,
              index < targetIndex, let next = current.next {
            guard transition(id, attemptId, to: next) else { return }
        }
    }

    static func applicationError(_ error: any Error) -> ApplicationError {
        switch error {
        case let e as ApplicationError: e
        case let e as any ApplicationErrorConvertible: e.applicationError
        default: .renderFailed(String(describing: error))
        }
    }
}

/// 取消标志：队列设置，渲染所在 Task 之外的发布步骤也能读到。
final class CancelFlag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
