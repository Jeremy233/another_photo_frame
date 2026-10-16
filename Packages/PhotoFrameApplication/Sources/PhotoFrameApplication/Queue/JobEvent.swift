/// 队列发布的事件。GUI、CLI、MCP 订阅 ``JobQueue/events()`` 得到同样的事件流。
///
/// 可序列化（D-13）：以后加进程间适配器时可以原样转发。
public enum JobEvent: Hashable, Sendable, Codable {
    /// 新任务入队。
    case jobAdded(JobRecord)
    /// 重试：新建了一个 Attempt，重新排队。
    case attemptCreated(jobId: JobID, attemptId: AttemptID, number: Int)
    /// 状态变化。
    case statusChanged(jobId: JobID, attemptId: AttemptID, status: JobStatus)
    /// 进度指标变化（计划输出数、已完成输出数、已发布字节数）。
    case progress(jobId: JobID, attemptId: AttemptID, progress: JobProgress)
    /// 本次执行结束（completed / failed / canceled），附最终记录。
    case attemptFinished(JobRecord)
    case queuePaused
    case queueResumed

    public var jobId: JobID? {
        switch self {
        case .jobAdded(let r), .attemptFinished(let r): r.jobId
        case .attemptCreated(let id, _, _), .statusChanged(let id, _, _), .progress(let id, _, _): id
        case .queuePaused, .queueResumed: nil
        }
    }
}
