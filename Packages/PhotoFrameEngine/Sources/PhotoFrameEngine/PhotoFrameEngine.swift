import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameRendering
import PhotoFrameStorage

/// 创建配置好的后端服务。GUI、CLI、MCP 各自在自己的进程里调用一次（D-13）。
public enum PhotoFrameEngine {
    public struct Options: Sendable {
        /// 同时执行的任务数；nil 用默认值（D-53）。
        public var maxConcurrentJobs: Int?
        /// 内存预算；nil 用默认值（物理内存一半，D-53）。
        public var memoryBudgetBytes: Int64?
        /// GUI 先排队再开始时为 true；CLI 为 false。
        public var startsPaused: Bool
        /// 平台配置；nil 用应用附带的 `platforms.json`。
        public var platformCatalog: PlatformCatalog?
        /// 预设来源；nil 只有内置预设。用户预设库做好后从这里接入。
        public var presets: (any PresetProvider)?
        /// 素材来源；nil 表示没有素材库。素材库做好后从这里接入。
        public var assets: (any AssetProvider)?

        public init(
            maxConcurrentJobs: Int? = nil, memoryBudgetBytes: Int64? = nil, startsPaused: Bool = false,
            platformCatalog: PlatformCatalog? = nil, presets: (any PresetProvider)? = nil, assets: (any AssetProvider)? = nil
        ) {
            self.maxConcurrentJobs = maxConcurrentJobs
            self.memoryBudgetBytes = memoryBudgetBytes
            self.startsPaused = startsPaused
            self.platformCatalog = platformCatalog
            self.presets = presets
            self.assets = assets
        }
    }

    public static func makeService(_ options: Options = Options()) throws(ApplicationError) -> LocalPhotoFrameService {
        let catalog: PlatformCatalog
        if let given = options.platformCatalog {
            catalog = given
        } else {
            do {
                catalog = try PlatformCatalogStore.builtIn()
            } catch {
                throw ApplicationError(code: error.code, message: "无法读取平台配置：\(error)")
            }
        }
        let assets = options.assets ?? NoAssetLibrary()
        let backend = RenderingBackend(assets: assets)
        let configuration = QueueConfiguration(
            maxConcurrentJobs: options.maxConcurrentJobs ?? QueueConfiguration.defaultMaxConcurrentJobs,
            memoryBudgetBytes: options.memoryBudgetBytes ?? QueueConfiguration.defaultMemoryBudgetBytes,
            startsPaused: options.startsPaused,
            platformCatalog: catalog,
            assets: assets)
        return LocalPhotoFrameService(
            renderer: backend, analyzer: backend,
            presets: options.presets ?? BuiltInPresetProvider(catalog: catalog),
            configuration: configuration)
    }
}
