import Foundation
import PhotoFrameApplication

// 退出前的确认（⌘Q）。决定问不问、问什么在这里，弹窗本身在应用的 delegate 里（`applicationShouldTerminate`）。

/// 退出时要不要先问。
public enum QuitPrompt: Equatable, Sendable {
    /// 直接退出。
    case none
    /// 有还没开始的任务（「当前」里没提交的、「活跃」里排队的）：确认一次，可以勾选不再显示（设置里能改回来）。
    case unstartedJobs(count: Int)
    /// 有正在处理的任务：不管设置总要问（停止并退出 / 完成后退出 / 取消）。
    case processingJobs(count: Int)
}

/// 用户对退出确认的回答。
public enum QuitChoice: Sendable {
    /// 退出（没开始的任务丢掉）。
    case quit
    /// 取消全部活跃的任务再退出。
    case stopAndQuit
    /// 不退出，等活跃的任务做完后自动退出。
    case quitWhenFinished
    case cancel
}

extension Workbench {
    /// 正在处理（已经开始、还没结束）的任务数。
    public var processingJobCount: Int {
        jobs.count { !$0.status.isTerminal && $0.status != .queued }
    }

    /// 还没开始的任务数：「当前」里没提交的任务，加上「活跃」里排队的。
    public var unstartedJobCount: Int {
        allJobs.count + jobs.count { $0.status == .queued }
    }

    /// 选了「完成后退出」之后，活跃的任务都做完了：正在处理的结束，排队的也做完（队列暂停时排队的不会再开始，不等它们）。
    public var hasFinishedForQuit: Bool {
        processingJobCount == 0 && (isQueuePaused || !jobs.contains { $0.status == .queued })
    }

    /// 按 ⌘Q 时问什么。选了「完成后退出」、任务都做完时自动退出，不再问没开始的任务。
    public var quitPrompt: QuitPrompt {
        if isWaitingToQuit, hasFinishedForQuit { return .none }
        let processing = processingJobCount
        if processing > 0 { return .processingJobs(count: processing) }
        let unstarted = unstartedJobCount
        if unstarted > 0, settings.confirmsQuitWithUnstartedJobs { return .unstartedJobs(count: unstarted) }
        return .none
    }

    /// 执行用户的回答，返回现在是否退出。
    /// - Parameter dontAskAgain: 「不再显示」：以后有没开始的任务时不再问（正在处理时仍然总要问）。
    public func resolveQuit(_ choice: QuitChoice, dontAskAgain: Bool = false) async -> Bool {
        if dontAskAgain, choice != .cancel { settings.confirmsQuitWithUnstartedJobs = false }
        switch choice {
        case .quit:
            return true
        case .stopAndQuit:
            isWaitingToQuit = false
            let ids = activeJobs.map(\.jobId)
            await cancel(Set(ids))
            // 等取消真正生效（清理临时目录），最多几秒，不让退出卡住。
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [service] in _ = await service.waitUntilFinished(ids) }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
            return true
        case .quitWhenFinished:
            isWaitingToQuit = true
            return hasFinishedForQuit
        case .cancel:
            isWaitingToQuit = false
            return false
        }
    }

    /// 任务有变化时调用：选了「完成后退出」、活跃的任务都做完了，就通知应用退出。
    func checkQuitWhenFinished() {
        guard isWaitingToQuit, hasFinishedForQuit else { return }
        onReadyToQuit?()
    }
}
