import Foundation
import PhotoFrameApplication

/// ⌘, 设置窗口里的选项（D-114）。只属于 GUI，存在应用的 UserDefaults；CLI / MCP 各自用默认调度。
public struct AppSettings: Hashable, Sendable, Codable {
    /// 点「开始批处理」后切到「活跃」（D-108 默认切到，与 Compressor 一致）。
    public var switchesToActiveAfterStart = true
    /// 同时执行的任务数；nil 为自动（性能核数的一半，1…4，D-53）。最多 8，且不超过本机核数（D-128）。
    public var maxConcurrentJobs: Int?
    /// 内存预算（GiB）；nil 为自动（物理内存的一半，D-53）。
    public var memoryBudgetGiB: Int?
    /// 开始批处理前，有任务带警告时先询问（参照 Compressor「The batch has warnings」）。
    public var reviewsWarningsBeforeStart = true
    /// 退出时有还没开始的任务先确认（确认框里可以勾「不再显示」）。有正在处理的任务时不管这一项总要确认。
    public var confirmsQuitWithUnstartedJobs = true

    public init(
        switchesToActiveAfterStart: Bool = true, maxConcurrentJobs: Int? = nil, memoryBudgetGiB: Int? = nil,
        reviewsWarningsBeforeStart: Bool = true, confirmsQuitWithUnstartedJobs: Bool = true
    ) {
        self.switchesToActiveAfterStart = switchesToActiveAfterStart
        self.maxConcurrentJobs = maxConcurrentJobs.map(QueueConfiguration.clampedMaxConcurrentJobs)
        self.memoryBudgetGiB = memoryBudgetGiB
        self.reviewsWarningsBeforeStart = reviewsWarningsBeforeStart
        self.confirmsQuitWithUnstartedJobs = confirmsQuitWithUnstartedJobs
    }

    public var effectiveMaxConcurrentJobs: Int {
        maxConcurrentJobs.map(QueueConfiguration.clampedMaxConcurrentJobs) ?? QueueConfiguration.defaultMaxConcurrentJobs
    }
    public var effectiveMemoryBudgetBytes: Int64 { memoryBudgetGiB.map { Int64($0) << 30 } ?? QueueConfiguration.defaultMemoryBudgetBytes }

    /// 设置窗口里可选的并发数：1 到 8，且不超过本机核数（D-128）。
    public static var concurrencyChoices: [Int] { Array(1...QueueConfiguration.maxConcurrentJobsLimit) }

    /// 可选的内存预算：2 的幂，不超过物理内存。
    public static var memoryChoicesGiB: [Int] {
        let physical = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        return [2, 4, 8, 16, 32, 64, 128, 256, 512].filter { $0 <= max(physical, 2) }
    }

    /// 读取时容忍缺字段（以后加新选项时旧设置仍能读）。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switchesToActiveAfterStart = try c.decodeIfPresent(Bool.self, forKey: .switchesToActiveAfterStart) ?? true
        // 以前存下的值可能超过本机的上限（D-128 之前可以选到 8）：读的时候截断，设置窗口里显示的就是实际用的值。
        maxConcurrentJobs = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentJobs).map(QueueConfiguration.clampedMaxConcurrentJobs)
        memoryBudgetGiB = try c.decodeIfPresent(Int.self, forKey: .memoryBudgetGiB)
        reviewsWarningsBeforeStart = try c.decodeIfPresent(Bool.self, forKey: .reviewsWarningsBeforeStart) ?? true
        confirmsQuitWithUnstartedJobs = try c.decodeIfPresent(Bool.self, forKey: .confirmsQuitWithUnstartedJobs) ?? true
    }
}

/// 设置存在哪里。
public protocol SettingsStore: Sendable {
    func load() -> AppSettings?
    func save(_ settings: AppSettings)
}

public struct UserDefaultsSettingsStore: SettingsStore {
    private let key: String

    public init(key: String = "appSettings") { self.key = key }

    public func load() -> AppSettings? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
    }

    public func save(_ settings: AppSettings) {
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: key)
    }
}

/// 只在内存里（测试、预览用）。
public final class MemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AppSettings?

    public init(_ settings: AppSettings? = nil) { self.settings = settings }

    public func load() -> AppSettings? { lock.withLock { settings } }
    public func save(_ settings: AppSettings) { lock.withLock { self.settings = settings } }
}

extension Workbench {
    /// 把并发数和内存预算交给任务队列，运行中修改立即生效（D-53）。
    func applySchedulingSettings() async {
        await service.setMaxConcurrentJobs(settings.effectiveMaxConcurrentJobs)
        await service.setMemoryBudget(settings.effectiveMemoryBudgetBytes)
    }
}
