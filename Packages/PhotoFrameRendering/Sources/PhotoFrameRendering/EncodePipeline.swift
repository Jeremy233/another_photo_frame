import CoreGraphics
import Foundation
import PhotoFrameCore

/// 导出 SDR 页面的编码流水线：CI 渲染仍由任务线程逐页做，ImageIO 编码与写文件交给后台线程，
/// 渲染下一页时前几页还在编码。结果按页序取回，所以进度、警告、出错和取消时的清理都与逐页顺序执行相同；
/// 编码的是同一张位图，写出的字节也相同。
///
/// `submit`、`next` 只能由同一个线程（渲染任务）调用。
final class EncodePipeline: @unchecked Sendable {
    /// 一页要编码的内容。
    struct Page: @unchecked Sendable {
        var image: CGImage
        var settings: OutputSettings
        var metadata: [CFString: Any]
        var url: URL
    }

    /// 同时编码的页数上限。
    let depth: Int
    /// 每个在途页一条串行队列。串行队列由 GCD 的 overcommit 线程执行：调用方阻塞在 `next` 里等结果时，
    /// 即使协作线程池全被渲染任务占满（并发任务数 ≥ 核数），编码也一定有线程可用。
    /// 全局并发队列不保证这一点（实测会死锁）。
    private let queues: [DispatchQueue]
    private let condition = NSCondition()
    /// 后台写入、调用线程取走，受 `condition` 保护。
    private var finished: [Int: Result<OutputEncoder.Written, RenderError>] = [:]
    private var submitted = 0
    private var collected = 0

    /// - Parameters:
    ///   - pageBytes: 一页 sRGB 8-bit 位图的字节数。在途的位图合计不超过 `byteBudget`（至少 1 页、最多 `maxDepth` 页），
    ///     画布很大时退回逐页编码，任务的内存与原来相同（D-18）。
    ///   - priority: 后台线程的优先级跟随渲染任务。
    init(pageBytes: Int, maxDepth: Int = 4, byteBudget: Int = 64 << 20, priority: TaskPriority = Task.currentPriority) {
        let depth = max(1, min(maxDepth, byteBudget / max(pageBytes, 1)))
        let qos = DispatchQoS.QoSClass(priority)
        self.depth = depth
        queues = (0..<depth).map {
            DispatchQueue(label: "PhotoFrameRendering.encode.\($0)", qos: DispatchQoS(qosClass: qos, relativePriority: 0))
        }
    }

    /// 还没取回的页数。
    var inFlight: Int { submitted - collected }

    /// 把下一页交给后台编码。
    func submit(_ page: Page) {
        let index = submitted
        submitted += 1
        // 在途页不超过 depth，所以第 index 页提交时，同一条队列上的前一页（index − depth）已经取回。
        queues[index % depth].async { [self] in
            let result = Result { () throws(RenderError) in
                try OutputEncoder.encodeSDR(page.image, settings: page.settings, metadata: page.metadata, to: page.url)
            }
            condition.lock()
            finished[index] = result
            condition.broadcast()
            condition.unlock()
        }
    }

    /// 按页序取回下一页的结果。下一页还没编码完时，`wait` 为 true 就等它，否则返回 nil；没有在途的页时返回 nil。
    func next(wait: Bool) -> (page: Int, result: Result<OutputEncoder.Written, RenderError>)? {
        guard collected < submitted else { return nil }
        condition.lock()
        defer { condition.unlock() }
        while finished[collected] == nil {
            guard wait else { return nil }
            condition.wait()
        }
        let page = collected
        collected += 1
        return (page, finished.removeValue(forKey: page)!)
    }
}

/// 第 `page` 页编码失败（按页序取回时发现）。
struct PageEncodeFailure: Error {
    var page: Int
    var error: RenderError
}
