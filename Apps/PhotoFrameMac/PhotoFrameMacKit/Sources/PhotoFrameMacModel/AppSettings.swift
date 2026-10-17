import Foundation
import PhotoFrameApplication

/// ⌘, 设置窗口里的选项（D-114）。只属于 GUI，存在应用的 UserDefaults；CLI / MCP 各自用默认调度。
public struct AppSettings: Hashable, Sendable, Codable {
    /// 点「开始批处理」后切到「活跃」（D-108 默认切到，与 Compressor 一致）。
    public var switchesToActiveAfterStart = true
    /// 同时执行的任务数；nil 为自动（性能核数的一半，1…4，D-53）。
    public var maxConcurrentJobs: Int?
    /// 内存预算（GiB）；nil 为自动（物理内存的一半，D-53）。
    public var memoryBudgetGiB: Int?

    public init(switchesToActiveAfterStart: Bool = true, maxConcurrentJobs: Int? = nil, memoryBudgetGiB: Int? = nil) {
        self.switchesToActiveAfterStart = switchesToActiveAfterStart
        self.maxConcurrentJobs = maxConcurrentJobs
        self.memoryBudgetGiB = memoryBudgetGiB
    }

    public var effectiveMaxConcurrentJobs: Int { maxConcurrentJobs ?? QueueConfiguration.defaultMaxConcurrentJobs }
    public var effectiveMemoryBudgetBytes: Int64 { memoryBudgetGiB.map { Int64($0) << 30 } ?? QueueConfiguration.defaultMemoryBudgetBytes }

    /// 设置窗口里可选的并发数。
    public static let concurrencyChoices = Array(1...8)

    /// 可选的内存预算：2 的幂，不超过物理内存。
    public static var memoryChoicesGiB: [Int] {
        let physical = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        return [2, 4, 8, 16, 32, 64, 128, 256, 512].filter { $0 <= max(physical, 2) }
    }

    /// 读取时容忍缺字段（以后加新选项时旧设置仍能读）。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switchesToActiveAfterStart = try c.decodeIfPresent(Bool.self, forKey: .switchesToActiveAfterStart) ?? true
        maxConcurrentJobs = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentJobs)
        memoryBudgetGiB = try c.decodeIfPresent(Int.self, forKey: .memoryBudgetGiB)
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
