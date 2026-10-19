import Foundation
import PhotoFrameCore
import PhotoFrameStorage

/// 队列的调度参数（§12.1、D-18）。
public struct QueueConfiguration: Sendable {
    /// 同时执行的任务数上限。
    public var maxConcurrentJobs: Int
    /// 同时执行的任务估算内存之和的上限（字节）；nil 表示不按内存限制。
    /// 单个任务超过整个预算时仍会执行，但只在没有别的任务运行时开始，不会永远卡住。
    public var memoryBudgetBytes: Int64?
    /// 渲染器和源图尺寸都给不出估算时，每个任务按多少字节计。
    public var fallbackJobMemoryBytes: Int64
    /// 创建时是否暂停。GUI 先排好任务、再点「开始批处理」时用 true；CLI 用 false。
    public var startsPaused: Bool
    /// 平台配置，传给渲染器查轮播上限与 HDR 格式。
    public var platformCatalog: PlatformCatalog?
    /// 素材槽解析器；nil 时不在校验阶段解析素材，由渲染器处理。设置了 `assets` 时以 `assets` 为准。
    public var slotResolver: SlotResolver?
    /// 素材来源。每次校验任务时取一次当前的解析器，素材库可以在运行中变化。
    public var assets: (any AssetProvider)?

    public init(
        maxConcurrentJobs: Int = QueueConfiguration.defaultMaxConcurrentJobs,
        memoryBudgetBytes: Int64? = QueueConfiguration.defaultMemoryBudgetBytes,
        fallbackJobMemoryBytes: Int64 = 1 << 30,
        startsPaused: Bool = false,
        platformCatalog: PlatformCatalog? = nil,
        slotResolver: SlotResolver? = nil,
        assets: (any AssetProvider)? = nil
    ) {
        self.maxConcurrentJobs = max(1, maxConcurrentJobs)
        self.memoryBudgetBytes = memoryBudgetBytes
        self.fallbackJobMemoryBytes = fallbackJobMemoryBytes
        self.startsPaused = startsPaused
        self.platformCatalog = platformCatalog
        self.slotResolver = slotResolver
        self.assets = assets
    }

    /// 校验任务时使用的素材解析器：`assets` 优先，其次 `slotResolver`。
    public func currentSlotResolver() -> SlotResolver? {
        assets?.slotResolver() ?? slotResolver
    }

    public func platformProfile(for preset: ExportPreset) -> PlatformProfile? {
        guard let id = preset.platform else { return nil }
        return platformCatalog?.profile(id: id)
    }

    /// 默认并发：性能核数的一半，限制在 1…4。单个任务内部（解码、Core Image）本身已经并行。
    public static var defaultMaxConcurrentJobs: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// 并发数设置的上限：最多 8，且不超过本机核数（D-128）。单个任务内部已经并行，更多任务只会互相抢核。
    public static var maxConcurrentJobsLimit: Int {
        min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// 把设置的并发数限制在 1…``maxConcurrentJobsLimit``。GUI 的设置（包括以前存下的更大的值）、CLI 和 MCP 的 `--jobs`
    /// 都经过这里（``LocalPhotoFrameService/makeDefault(_:)``、``LocalPhotoFrameService/setMaxConcurrentJobs(_:)``）。
    public static func clampedMaxConcurrentJobs(_ count: Int) -> Int {
        min(max(1, count), maxConcurrentJobsLimit)
    }

    /// 默认内存预算：物理内存的一半。
    public static var defaultMemoryBudgetBytes: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory / 2)
    }

    /// 没有渲染器估算时的粗略内存估算：源图按 RGBAh（8 字节 / 像素，D-03）完整解码一次，
    /// 加上一张输出画布的工作缓冲与编码缓冲。源图尺寸未知时用 `fallbackJobMemoryBytes`。
    public func estimatedMemory(for spec: JobSpec) -> Int64 {
        guard let image = spec.source.image, image.storedSize.isPositive else { return fallbackJobMemoryBytes }
        let sourcePixels = Int64(image.storedSize.width) * Int64(image.storedSize.height)
        let canvasPixels = Int64(max(spec.preset.canvas.width, 1)) * Int64(max(spec.preset.canvas.height, 1))
        return sourcePixels * 8 + canvasPixels * 8 * 2
    }
}
