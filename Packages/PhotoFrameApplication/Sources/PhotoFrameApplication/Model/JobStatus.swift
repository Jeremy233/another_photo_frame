/// 一次执行（Attempt）的状态（§9.1）。
///
/// ```text
/// queued → validating → decoding → rendering → encoding → writing → completed
/// ```
///
/// 只能沿流水线前进一步；处理中的任意状态（以及 `queued`）都可以转到 `failed` / `canceled`。
/// 三个终态不再变化：重试不改变旧 Attempt，而是新建一个 Attempt 从 `queued` 开始。
public enum JobStatus: String, Hashable, Sendable, Codable, CaseIterable {
    case queued
    /// 检查源文件、预设、素材绑定和输出目录。由队列执行。
    case validating
    /// 以下三个阶段由渲染器（``JobRenderer``）报告。
    case decoding
    case rendering
    case encoding
    /// 校验临时目录中的成品并原子发布到目的地。由队列执行。
    case writing
    case completed
    case failed
    case canceled

    /// 正常完成的流水线顺序。
    public static let pipeline: [JobStatus] = [.queued, .validating, .decoding, .rendering, .encoding, .writing, .completed]

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .canceled: true
        default: false
        }
    }

    /// 已开始执行、尚未结束。
    public var isProcessing: Bool {
        switch self {
        case .validating, .decoding, .rendering, .encoding, .writing: true
        default: false
        }
    }

    /// 在流水线中的位置；`failed` / `canceled` 为 nil。
    public var pipelineIndex: Int? { Self.pipeline.firstIndex(of: self) }

    /// 流水线中的下一个状态。
    public var next: JobStatus? {
        guard let i = pipelineIndex, i + 1 < Self.pipeline.count else { return nil }
        return Self.pipeline[i + 1]
    }

    public func canTransition(to target: JobStatus) -> Bool {
        if isTerminal { return false }
        switch target {
        case .failed: return isProcessing
        case .canceled: return true
        default: return next == target
        }
    }
}
