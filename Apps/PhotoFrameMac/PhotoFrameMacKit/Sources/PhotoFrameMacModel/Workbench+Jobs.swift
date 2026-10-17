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
        let run = runJobIds.compactMap { id in jobs.first { $0.jobId == id } }
        return run.isEmpty ? nil : BatchProgress(run)
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
        switch event {
        case .queuePaused:
            isQueuePaused = true
        case .queueResumed:
            isQueuePaused = false
        case .jobAdded(let record), .attemptFinished(let record):
            upsert(record)
        case .attemptCreated(let id, _, _), .statusChanged(let id, _, _), .progress(let id, _, _):
            if let record = try? await service.status(id) { upsert(record) }
        }
    }

    public func refreshJobs() async {
        jobs = await service.jobs()
    }

    private func upsert(_ record: JobRecord) {
        if let i = jobs.firstIndex(where: { $0.jobId == record.jobId }) {
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

    /// 已完成的任务再导出一次：按原来的快照新建任务（D-52），默认加版本号、不覆盖。
    public func reexport(_ ids: Set<JobID>) async {
        for id in ids {
            guard let spec = record(id)?.spec else { continue }
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
