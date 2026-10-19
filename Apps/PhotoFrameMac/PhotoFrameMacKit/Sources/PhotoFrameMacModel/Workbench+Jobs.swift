import Foundation
import PhotoFrameApplication

// 「活跃」「已完成」界面和底栏进度（UI 设计文档第 2、11 节）。

/// 底栏的批处理总进度：只用真实指标（已结束的任务、已写出的页数），不显示假的匀速进度（第 11 节）。
public struct BatchProgress: Equatable, Sendable {
    public var totalJobs: Int
    public var finishedJobs: Int
    public var failedJobs: Int
    /// 已知计划页数的任务里已经写出的页数。
    public var completedOutputs: Int
    public var plannedOutputs: Int
    /// 0…1：已结束的任务各算 1，执行中的任务按已写出页数 / 计划页数计。
    public var fraction: Double

    public var isRunning: Bool { finishedJobs < totalJobs }

    public init(_ jobs: [JobRecord]) {
        totalJobs = jobs.count
        finishedJobs = jobs.count { $0.status.isTerminal }
        failedJobs = jobs.count { $0.status == .failed }
        var outputs = 0, planned = 0
        var done = 0.0
        for job in jobs {
            if job.status.isTerminal {
                done += 1
            } else if let total = job.progress.plannedOutputs, total > 0 {
                done += Double(job.progress.completedOutputs) / Double(total)
            }
            if let total = job.progress.plannedOutputs {
                planned += total
                outputs += job.progress.completedOutputs
            }
        }
        completedOutputs = outputs
        plannedOutputs = planned
        fraction = jobs.isEmpty ? 0 : done / Double(jobs.count)
    }
}

extension Workbench {
    /// 正在执行和排队中的任务。
    public var activeJobs: [JobRecord] { jobs.filter { !$0.status.isTerminal } }

    /// 「活跃」界面是否显示队列的暂停 / 继续和总进度：只在有活跃任务时显示。GUI 启动时队列本来就是暂停的
    /// （先排队、再开始批处理），没有任务时显示「继续」只会让人困惑（与 Compressor 一样留空）。
    public var showsQueueControls: Bool { activeCount > 0 }

    /// 顶栏「活跃 (N)」里的 N。
    public var activeCount: Int { jobs.count { !$0.status.isTerminal } }

    /// 导出历史，最近结束的在前。
    public var finishedJobs: [JobRecord] {
        jobs.filter(\.status.isTerminal).sorted {
            ($0.currentAttempt.finishedAt ?? $0.createdAt) > ($1.currentAttempt.finishedAt ?? $1.createdAt)
        }
    }

    /// 最近一次批处理的进度；还没开始过时为 nil。
    public var batchProgress: BatchProgress? {
        guard !runJobIds.isEmpty else { return nil }
        let run = Set(runJobIds)
        let records = jobs.filter { run.contains($0.jobId) }
        return records.isEmpty ? nil : BatchProgress(records)
    }

    /// 订阅任务事件，直到窗口关闭（界面 `.task` 里调用）。
    public func observeJobs() async {
        let events = await service.events()
        await refreshJobs()
        for await event in events {
            await apply(event)
        }
    }

    func apply(_ event: JobEvent) async {
        defer { checkQuitWhenFinished() }
        switch event {
        case .queuePaused:
            isQueuePaused = true
            return
        case .queueResumed:
            isQueuePaused = false
            return
        case .jobAdded(let record), .attemptFinished(let record):
            upsert(record)
        case .progress(let id, let attemptId, let progress):
            // 只是进度变了（每写出一页就有一次）：直接改本地记录，不再整条重新读取。
            if !patchProgress(progress, of: id, attempt: attemptId), let record = try? await service.status(id) { upsert(record) }
        case .attemptCreated(let id, _, _), .statusChanged(let id, _, _):
            if let record = try? await service.status(id) { upsert(record) }
        }
        appliedJobEvents += 1
    }

    /// 把进度事件写进本地的记录。本地没有这次执行时返回 false（要重新读取整条记录）。
    private func patchProgress(_ progress: JobProgress, of id: JobID, attempt: AttemptID) -> Bool {
        guard let i = jobs.firstIndex(where: { $0.jobId == id }), jobs[i].currentAttempt.attemptId == attempt else { return false }
        let current = jobs[i].currentAttempt
        // 已结束的执行不再变；比本地旧的进度（重新读取之后才处理到的事件）不覆盖新的。
        if !current.status.isTerminal, progress != current.progress, progress.isNotOlder(than: current.progress) {
            jobs[i].currentAttempt.progress = progress
        }
        return true
    }

    public func refreshJobs() async {
        defer { checkQuitWhenFinished() }
        let applied = appliedJobEvents
        let snapshot = await service.jobs()
        guard appliedJobEvents != applied else {
            jobs = snapshot
            return
        }
        // 读的期间有事件改过记录，快照可能比它们旧（例如已经结束的任务又变回「处理中」）：每个任务留较新的那份。
        let local = Dictionary(jobs.map { ($0.jobId, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = snapshot.map { record in
            guard let mine = local[record.jobId], !record.isNotOlder(than: mine) else { return record }
            return mine
        }
        let known = Set(snapshot.map(\.jobId))
        merged += jobs.filter { !known.contains($0.jobId) }
        jobs = merged
    }

    private func upsert(_ record: JobRecord) {
        if let i = jobs.firstIndex(where: { $0.jobId == record.jobId }) {
            // 比本地旧的记录（例如刷新之后才处理到的「已加入」事件）不覆盖新的；没变就不写，免得通知所有观察者。
            guard record != jobs[i], record.isNotOlder(than: jobs[i]) else { return }
            jobs[i] = record
        } else {
            jobs.append(record)
        }
    }

    public func record(_ id: JobID) -> JobRecord? { jobs.first { $0.jobId == id } }

    // MARK: 操作

    /// 暂停只停止派发新任务，正在执行的继续做完（D-51）。
    public func toggleQueuePaused() async {
        if isQueuePaused { await resumeQueue() } else { await pauseQueue() }
    }

    public func pauseQueue() async {
        await service.pause()
        isQueuePaused = true
    }

    public func resumeQueue() async {
        await service.start()
        isQueuePaused = false
    }

    public func cancel(_ ids: Set<JobID>) async {
        for id in ids where record(id)?.status.isTerminal == false {
            await perform("无法取消") { try await service.cancel(id) }
        }
        await refreshJobs()
    }

    /// 只有失败或已取消的任务可以重试（D-52）。
    public func canRetry(_ id: JobID) -> Bool {
        guard let status = record(id)?.status else { return false }
        return status == .failed || status == .canceled
    }

    public func retry(_ ids: Set<JobID>) async {
        for id in ids where canRetry(id) {
            await perform("无法重试") {
                _ = try await service.retry(id)
                if !runJobIds.contains(id) { runJobIds.append(id) }
            }
        }
        await refreshJobs()
        await resumeQueue()
    }

    /// 「已完成」里选中的、确实已经结束的任务（重试之后又在执行的不算）。顶栏按钮和详情都用它。
    public var selectedFinishedJobs: Set<JobID> {
        historySelection.filter { record($0)?.status.isTerminal == true }
    }

    /// 只有成功的任务可以重新导出；失败或已取消的用「重试」（D-52）。顶栏、右键菜单、行尾按钮都按它判断。
    public func canReexport(_ id: JobID) -> Bool {
        record(id)?.status == .completed
    }

    /// 已完成的任务再导出一次：按原来的快照新建任务（D-52），默认加版本号、不覆盖。
    /// 不是成功结束的任务跳过（还没结束的不会再排一份一样的，失败的用「重试」）。
    public func reexport(_ ids: Set<JobID>) async {
        for id in ids {
            guard canReexport(id), let finished = record(id) else { continue }
            let spec = finished.spec
            await perform("无法重新导出") {
                let request = ExportRequest(
                    sourceIds: [spec.source.sourceId], presets: [spec.preset],
                    destination: ExportDestination(rootDirectory: spec.destination.rootDirectory, naming: spec.destination.naming),
                    assetBindings: spec.assetBindings, sourceColorOverride: spec.sourceColorOverride)
                runJobIds += try await service.submit(request)
            }
        }
        await refreshJobs()
        await resumeQueue()
    }

    /// 「在 Finder 中显示」的目标：已完成任务的输出文件。
    public func outputURLs(_ ids: Set<JobID>) -> [URL] {
        jobs.filter { ids.contains($0.jobId) }.flatMap { $0.manifest?.items.map(\.fileURL) ?? [] }
    }
}

extension JobRecord {
    /// 同一个任务的两份记录，这份不比 `other` 旧。执行次数、当前执行的状态历史、进度都只增不减，
    /// 任务事件和重新读取的结果先后到达时，用它决定留哪一份。
    func isNotOlder(than other: JobRecord) -> Bool {
        if attempts.count != other.attempts.count { return attempts.count > other.attempts.count }
        let mine = currentAttempt, theirs = other.currentAttempt
        if mine.history.count != theirs.history.count { return mine.history.count > theirs.history.count }
        return mine.progress.isNotOlder(than: theirs.progress)
    }
}

extension JobProgress {
    /// 同一次执行里的进度只增不减：阶段、已写出页数、已发布字节数；计划页数知道了就不会再变回不知道。
    func isNotOlder(than other: JobProgress) -> Bool {
        (stage.pipelineIndex ?? 0) >= (other.stage.pipelineIndex ?? 0)
            && completedOutputs >= other.completedOutputs
            && bytesWritten >= other.bytesWritten
            && (plannedOutputs != nil || other.plannedOutputs == nil)
    }
}
