import Foundation
import Synchronization

/// 在 Swift 并发的协作线程池之外执行同步的渲染代码（D-128）。
///
/// 解码、Core Image 渲染和编码都是同步的长时间工作。直接在 `async` 函数里做会占住一个协作线程直到做完：
/// 同时执行的任务数 ≥ 核数时，协作线程全被渲染占满，预览请求、进度事件、界面上的其他异步工作都要等某个任务结束。
/// 这里每次调用用一条新的串行 `DispatchQueue`：串行队列由 GCD 的 overcommit 线程执行，协作线程池再忙也一定有线程
/// （与 ``EncodePipeline`` 同一个原因，全局并发队列不保证这一点）。调用方的协作线程在等结果时挂起，不被占用。
///
/// 这些线程不在 Task 里，读不到 `Task.isCancelled`：所在 Task 被取消时设置 ``RenderCancellation``，由渲染代码在
/// 阶段之间、每一页之前检查。
public enum RenderThread {
    /// 在专用线程上执行 `body`，等它结束后返回结果或抛出它的错误。线程的优先级跟随调用方的 Task。
    /// 所在 Task 被取消（包括调用之前就已取消）时设置传给 `body` 的取消标志；`body` 不检查就照常做完。
    public static func run<T: Sendable>(_ body: @escaping @Sendable (RenderCancellation) throws -> T) async throws -> T {
        let cancellation = RenderCancellation()
        let queue = DispatchQueue(label: "PhotoFrameRendering.render", qos: DispatchQoS(qosClass: .init(Task.currentPriority), relativePriority: 0))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                queue.async { continuation.resume(with: Result { try body(cancellation) }) }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// 显式的取消标志：渲染代码在协作线程池之外运行，用它代替 `Task.isCancelled`。
public final class RenderCancellation: Sendable {
    private let flag = Atomic(false)

    public init() {}

    public func cancel() { flag.store(true, ordering: .relaxed) }

    public var isCanceled: Bool { flag.load(ordering: .relaxed) }

    /// 已取消时抛出 `CancellationError`（与 `Task.checkCancellation()` 相同）。
    public func checkCancellation() throws {
        if isCanceled { throw CancellationError() }
    }
}

extension DispatchQoS.QoSClass {
    /// 与 Task 优先级对应的 GCD 服务质量：后台线程跟随发起它的 Task。
    init(_ priority: TaskPriority) {
        self = switch priority.rawValue {
        case TaskPriority.high.rawValue...: .userInitiated
        case TaskPriority.medium.rawValue...: .default
        case TaskPriority.low.rawValue...: .utility
        default: .background
        }
    }
}
