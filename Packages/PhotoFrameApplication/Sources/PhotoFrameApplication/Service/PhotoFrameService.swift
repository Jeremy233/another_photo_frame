import Foundation
import ImageIO
import PhotoFrameCore
import PhotoFrameRendering
import PhotoFrameStorage

/// 导出请求（§11.1 `ExportRequest`）：多张源图 × 多个预设快照，每个组合生成一个任务（§3.1）。
public struct ExportRequest: Hashable, Sendable, Codable {
    public var sourceIds: [SourceID]
    /// 预设快照：请求创建时的内容，之后修改预设不影响这些任务（§8.3）。
    public var presets: [ExportPreset]
    public var destination: ExportDestination
    /// 单任务素材绑定，作用于本请求生成的每个任务（D-14）。
    public var assetBindings: [String: UUID]
    /// 没有 ICC 的源图按什么色彩空间解释（D-04），作用于本请求的每个任务。
    public var sourceColorOverride: SourceColorOverride?

    public init(
        sourceIds: [SourceID], presets: [ExportPreset], destination: ExportDestination, assetBindings: [String: UUID] = [:],
        sourceColorOverride: SourceColorOverride? = nil
    ) {
        self.sourceIds = sourceIds
        self.presets = presets
        self.destination = destination
        self.assetBindings = assetBindings
        self.sourceColorOverride = sourceColorOverride
    }
}

/// GUI、CLI、MCP 共用的后端入口（§10.1、§11.2、D-13）。
///
/// 所有类型都可序列化、与界面无关，以后可以在进程间适配器后面提供同一个接口。
public protocol PhotoFrameService: Sendable {
    // 预设库（§8、D-76…D-92）

    /// 可用的预设：内置、用户保存、导入（预设库），以及本服务读过的 `.photoframe` 文件。
    func listPresets() async throws(ApplicationError) -> CatalogPresetList
    /// 按 ID、名称、短名或文件找到预设（D-76）。文件只读取、不放进预设库。
    func resolvePreset(_ reference: PresetReference) async throws(ApplicationError) -> CatalogPreset
    /// 把 `.photoframe` 导入预设库。ID 冲突时默认另存为副本（D-39、D-80），`replace` 时替换同 ID 的预设。
    func importPreset(from fileURL: URL, replace: Bool) async throws(ApplicationError) -> CatalogPresetImport
    /// 把预设导出为 `.photoframe`（校验 + 隐私检查，D-37）。目标已存在时只有 `overwrite` 才替换。
    func exportPreset(_ reference: PresetReference, to fileURL: URL, overwrite: Bool) async throws(ApplicationError)
    /// 复制预设（内置预设也可以），默认连同本地绑定（D-79、D-84）。
    func duplicatePreset(_ reference: PresetReference, name: String?) async throws(ApplicationError) -> CatalogPresetSummary
    func renamePreset(_ reference: PresetReference, to name: String) async throws(ApplicationError) -> CatalogPresetSummary
    /// 删除用户预设及其本地绑定；内置预设不能删除。
    func deletePreset(_ reference: PresetReference) async throws(ApplicationError)
    /// 在「用户保存」和「导入」两组之间移动（D-81、D-94）；内容和时间不变。内置预设不能移动（`library.builtin_read_only`）。
    func movePreset(_ reference: PresetReference, to group: PresetOrigin) async throws(ApplicationError) -> CatalogPresetSummary
    /// 逐项修改库里的预设（D-93，字段路径见 `PresetFieldPath`）。改完的预设必须通过与导入相同的检查，原子写入；
    /// 内置预设只读（`library.builtin_read_only`，先复制）。
    func updatePreset(_ reference: PresetReference, edits: [PresetEdit]) async throws(ApplicationError) -> CatalogPresetUpdate

    // 素材库与绑定（§8.2、D-14）

    func listAssets(category: AssetCategory?) async -> CatalogAssetList
    /// 素材引用：assetId 或显示名称（不区分大小写，必须唯一）。
    func resolveAsset(_ reference: String) async throws(ApplicationError) -> AssetInfo
    func importAsset(from fileURL: URL, category: AssetCategory, name: String?) async throws(ApplicationError) -> CatalogAssetImport
    func renameAsset(_ id: UUID, to name: String) async throws(ApplicationError) -> AssetInfo
    /// 改素材分组（D-89、D-95）：只用于整理，不影响绑定。
    func setAssetCategory(_ id: UUID, to category: AssetCategory) async throws(ApplicationError) -> AssetInfo
    /// 删除素材；指向它的绑定保留（D-83），返回这些绑定。
    func deleteAsset(_ id: UUID) async throws(ApplicationError) -> [PersistedBinding]
    /// 持久绑定：`preset` 为 nil 时是用户默认绑定，否则是该预设的本地绑定。`assetId` 为 nil 时清除。
    func bindAsset(_ assetId: UUID?, slotId: String, preset: PresetReference?) async throws(ApplicationError)
    func listBindings() async -> CatalogBindingList

    /// 检查源图：格式、尺寸、方向、ICC、HDR、EXIF 摘要。不登记源图。
    func inspectSource(_ source: SourceReference) async throws(ApplicationError) -> SourceInspection
    /// 校验导出请求，不渲染、不写文件（`--dry-run`）。请求本身无效（没有源图或预设、源图未登记）时抛出；
    /// 每个任务的问题列在结果里。
    func validate(_ request: ExportRequest) async throws(ApplicationError) -> ValidationResult
    /// 预览一张源图 × 一个预设，与导出走同一条渲染管线。
    func renderPreview(_ request: ExportPreviewRequest) async throws(ApplicationError) -> ExportPreview

    /// 登记一张源图。只检查文件存在且是 V1 支持的格式（D-02），不读取像素；同一路径重复添加返回已有记录。
    func addSource(_ fileURL: URL) async throws(ApplicationError) -> PhotoSource
    func sources() async -> [PhotoSource]

    /// 按请求创建任务（源图 × 预设）。队列未暂停时立即开始排队执行。
    func submit(_ request: ExportRequest) async throws(ApplicationError) -> [JobID]
    /// 开始 / 继续派发任务。
    func start() async
    /// 暂停派发新任务；正在执行的任务继续做完。
    func pause() async
    func cancel(_ job: JobID) async throws(ApplicationError)
    /// 重试失败或已取消的任务，返回新的 AttemptID。
    func retry(_ job: JobID) async throws(ApplicationError) -> AttemptID

    func status(_ job: JobID) async throws(ApplicationError) -> JobSnapshot
    func jobs() async -> [JobSnapshot]
    /// 最近一次成功执行的输出清单；还没有成功过时为 nil。
    func manifest(_ job: JobID) async throws(ApplicationError) -> OutputManifest?

    /// 修改调度设置，立即生效（D-53）。
    func setMaxConcurrentJobs(_ count: Int) async
    func setMemoryBudget(_ bytes: Int64?) async
    /// 清理输出目录中超过 24 小时的残留临时目录（D-55），返回删除的目录。应用启动时对已知的输出目录调用；
    /// 队列第一次使用某个输出目录时也会自动清理。
    func removeStaleStaging(in destinationRoot: URL) async -> [URL]

    /// 任务事件流。
    func events() async -> AsyncStream<JobEvent>
    /// 等这些任务结束（CLI 默认阻塞到任务结束，§10.3）。
    func waitUntilFinished(_ jobs: [JobID]) async -> [JobSnapshot]
}

/// 进程内实现：源图登记 + 本地库（预设、素材、绑定）+ ``JobQueue`` + 图像分析。
/// GUI、CLI、MCP 各自在自己的进程里创建一个（D-13）。
///
/// 正常使用 ``makeDefault(_:)``（用 PhotoFrameRendering 渲染、App Group 里的本地库）。渲染、图像分析和本地库都可以注入，
/// 测试用假的渲染器和临时目录里的库。
public actor LocalPhotoFrameService: PhotoFrameService {
    public let queue: JobQueue
    public nonisolated let library: LocalLibrary
    private let analyzer: (any ImageAnalyzer)?
    private let configuration: QueueConfiguration
    private var sourcesById: [SourceID: PhotoSource] = [:]
    private var sourceOrder: [SourceID] = []
    /// 规范化后的文件 URL → 源图，登记时查重用（拖进上千张图时不必逐个比较）。
    private var sourceIdsByURL: [URL: SourceID] = [:]
    /// 通过文件路径读过的预设，之后也出现在 `listPresets` 里。
    private var filePresets: [CatalogPreset] = []

    /// - Parameters:
    ///   - renderer: 任务队列使用的渲染器。
    ///   - analyzer: 检查源图、预估输出、预览；nil 时这些接口报 `service.unavailable`，`validate` 不预估输出。
    ///   - library: 本地库；nil 时用系统临时目录里一个新的空库（只有内置预设，给测试用）。
    ///   - configuration: 队列设置。素材来源没有设置时用 `library`。
    public init(
        renderer: any JobRenderer, analyzer: (any ImageAnalyzer)? = nil, library: LocalLibrary? = nil,
        configuration: QueueConfiguration = QueueConfiguration()
    ) {
        let catalog = configuration.platformCatalog ?? (try? PlatformCatalogStore.builtIn())
            ?? PlatformCatalog(revision: 0, updatedAt: "", platforms: [])
        let library = library ?? LocalLibrary(
            root: FileManager.default.temporaryDirectory.appending(path: "PhotoFrameLibrary-\(UUID().uuidString)", directoryHint: .isDirectory),
            platforms: catalog)
        var configuration = configuration
        if configuration.platformCatalog == nil { configuration.platformCatalog = catalog }
        if configuration.assets == nil, configuration.slotResolver == nil { configuration.assets = library }
        self.library = library
        self.configuration = configuration
        self.analyzer = analyzer
        self.queue = JobQueue(renderer: renderer, configuration: configuration)
    }

    /// ``makeDefault(_:)`` 的设置。
    public struct Options: Sendable {
        /// 同时执行的任务数；nil 用默认值（D-53）。
        public var maxConcurrentJobs: Int?
        /// 内存预算；nil 用默认值（物理内存一半，D-53）。
        public var memoryBudgetBytes: Int64?
        /// GUI 先排队再开始时为 true；CLI 为 false。
        public var startsPaused: Bool
        /// 平台配置；nil 用应用附带的 `platforms.json`。
        public var platformCatalog: PlatformCatalog?
        /// 本地库根目录；nil 按 `LibraryLocation.defaultRoot()` 的规则选（D-78、D-124），GUI、CLI、MCP 都用这条；测试传临时目录。
        public var libraryRoot: URL?

        public init(
            maxConcurrentJobs: Int? = nil, memoryBudgetBytes: Int64? = nil, startsPaused: Bool = false,
            platformCatalog: PlatformCatalog? = nil, libraryRoot: URL? = nil
        ) {
            self.maxConcurrentJobs = maxConcurrentJobs
            self.memoryBudgetBytes = memoryBudgetBytes
            self.startsPaused = startsPaused
            self.platformCatalog = platformCatalog
            self.libraryRoot = libraryRoot
        }
    }

    /// 用 PhotoFrameRendering 渲染、用本地库提供预设与素材的服务。GUI、CLI、MCP 各自在自己的进程里调用一次（D-13）。
    public static func makeDefault(_ options: Options = Options()) throws(ApplicationError) -> LocalPhotoFrameService {
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
        let library = LocalLibrary(root: options.libraryRoot ?? LibraryLocation.defaultRoot(), platforms: catalog)
        let backend = RenderingBackend(assets: library)
        let configuration = QueueConfiguration(
            maxConcurrentJobs: options.maxConcurrentJobs ?? QueueConfiguration.defaultMaxConcurrentJobs,
            memoryBudgetBytes: options.memoryBudgetBytes ?? QueueConfiguration.defaultMemoryBudgetBytes,
            startsPaused: options.startsPaused, platformCatalog: catalog, assets: library)
        return LocalPhotoFrameService(renderer: backend, analyzer: backend, library: library, configuration: configuration)
    }

    private var catalog: PlatformCatalog? { configuration.platformCatalog }

    // MARK: - 预设

    public func listPresets() async throws(ApplicationError) -> CatalogPresetList {
        let listing = library.presets.list()
        let ids = Set(listing.all.map(\.presetId))
        let entries = listing.all.map(CatalogPreset.init) + filePresets.filter { !ids.contains($0.preset.presetId) }
        return CatalogPresetList(
            presets: entries.map { CatalogPresetSummary($0, catalog: catalog) },
            warnings: listing.warnings.map(ApplicationWarning.init))
    }

    public func resolvePreset(_ reference: PresetReference) async throws(ApplicationError) -> CatalogPreset {
        switch reference {
        case .file(let url):
            let entry = try PresetFileLoader.load(url, platforms: catalog)
            filePresets.removeAll { $0.origin == entry.origin }
            filePresets.append(entry)
            return entry
        case .library(let text):
            return CatalogPreset(try libraryEntry(text))
        }
    }

    private func libraryEntry(_ text: String) throws(ApplicationError) -> PresetEntry {
        do {
            return try library.presets.find(text)
        } catch {
            throw ApplicationError(error)
        }
    }

    /// 只在预设库里的预设上做修改；`.file` 引用没有库里的对象。
    private func libraryId(_ reference: PresetReference) throws(ApplicationError) -> UUID {
        switch reference {
        case .library(let text): return try libraryEntry(text).presetId
        case .file(let url): throw .presetNotInLibrary(url.path)
        }
    }

    private func summary(_ entry: PresetEntry) -> CatalogPresetSummary {
        CatalogPresetSummary(CatalogPreset(entry), catalog: catalog)
    }

    public func importPreset(from fileURL: URL, replace: Bool) async throws(ApplicationError) -> CatalogPresetImport {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw .presetFileNotFound(fileURL.path) }
        do {
            let result = try library.presets.importPackage(fileAt: fileURL, onConflict: replace ? .replace : .saveAsCopy)
            return CatalogPresetImport(
                preset: summary(result.entry), conflictResolution: result.conflictResolution?.rawValue,
                warnings: result.warnings.map { ApplicationWarning(code: $0.code, message: "\($0.path)：\($0.message)") })
        } catch {
            throw ApplicationError(error)
        }
    }

    public func exportPreset(_ reference: PresetReference, to fileURL: URL, overwrite: Bool) async throws(ApplicationError) {
        let id = try libraryId(reference)
        if !overwrite, FileManager.default.fileExists(atPath: fileURL.path) { throw .exportFileExists(fileURL.path) }
        do {
            try library.presets.exportPackage(id, to: fileURL)
        } catch {
            throw ApplicationError(error)
        }
    }

    public func duplicatePreset(_ reference: PresetReference, name: String?) async throws(ApplicationError) -> CatalogPresetSummary {
        let id = try libraryId(reference)
        do {
            return summary(try library.duplicatePreset(id, name: name))
        } catch {
            throw ApplicationError(error)
        }
    }

    public func renamePreset(_ reference: PresetReference, to name: String) async throws(ApplicationError) -> CatalogPresetSummary {
        let id = try libraryId(reference)
        do {
            return summary(try library.presets.rename(id, to: name))
        } catch {
            throw ApplicationError(error)
        }
    }

    public func deletePreset(_ reference: PresetReference) async throws(ApplicationError) {
        let id = try libraryId(reference)
        do {
            try library.deletePreset(id)
        } catch {
            throw ApplicationError(error)
        }
    }

    public func movePreset(_ reference: PresetReference, to group: PresetOrigin) async throws(ApplicationError) -> CatalogPresetSummary {
        let id = try libraryId(reference)
        do {
            return summary(try library.presets.move(id, to: group))
        } catch {
            throw ApplicationError(error)
        }
    }

    public func updatePreset(_ reference: PresetReference, edits: [PresetEdit]) async throws(ApplicationError) -> CatalogPresetUpdate {
        let id = try libraryId(reference)
        do {
            let result = try library.presets.edit(id, edits)
            return CatalogPresetUpdate(
                preset: summary(result.entry), content: result.entry.preset,
                warnings: result.warnings.map { ApplicationWarning(code: $0.code, message: "\($0.path)：\($0.message)") })
        } catch {
            throw ApplicationError(error)
        }
    }

    // MARK: - 素材与绑定

    public func listAssets(category: AssetCategory?) async -> CatalogAssetList {
        let listing = library.assets.list(category: category)
        return CatalogAssetList(assets: listing.assets, warnings: listing.warnings.map(ApplicationWarning.init))
    }

    public func resolveAsset(_ reference: String) async throws(ApplicationError) -> AssetInfo {
        let assets = library.assets.list().assets
        if let id = UUID(uuidString: reference) {
            guard let hit = assets.first(where: { $0.assetId == id }) else { throw ApplicationError(LibraryError.assetNotFound(id)) }
            return hit
        }
        let hits = assets.filter { $0.displayName.compare(reference, options: .caseInsensitive) == .orderedSame }
        guard let first = hits.first else { throw .assetReferenceNotFound(reference) }
        guard hits.count == 1 else { throw .assetAmbiguous(reference, hits.map(\.assetId.uuidString)) }
        return first
    }

    public func importAsset(from fileURL: URL, category: AssetCategory, name: String?) async throws(ApplicationError) -> CatalogAssetImport {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw .assetFileNotFound(fileURL.path) }
        do {
            let result = try library.assets.importAsset(fileAt: fileURL, category: category, displayName: name)
            return CatalogAssetImport(
                asset: result.asset, duplicateOf: result.duplicateOf,
                warnings: result.warnings.map { ApplicationWarning(code: "asset.import_note", message: $0) })
        } catch {
            throw ApplicationError(error)
        }
    }

    public func renameAsset(_ id: UUID, to name: String) async throws(ApplicationError) -> AssetInfo {
        do {
            return try library.assets.rename(id, to: name)
        } catch {
            throw ApplicationError(error)
        }
    }

    public func setAssetCategory(_ id: UUID, to category: AssetCategory) async throws(ApplicationError) -> AssetInfo {
        do {
            return try library.assets.setCategory(id, to: category)
        } catch {
            throw ApplicationError(error)
        }
    }

    public func deleteAsset(_ id: UUID) async throws(ApplicationError) -> [PersistedBinding] {
        do {
            return try library.deleteAsset(id)
        } catch {
            throw ApplicationError(error)
        }
    }

    public func bindAsset(_ assetId: UUID?, slotId: String, preset: PresetReference?) async throws(ApplicationError) {
        let presetId = try preset.map { (ref) throws(ApplicationError) in try libraryId(ref) }
        do {
            if let presetId {
                try library.bindForPreset(presetId, slotId: slotId, assetId: assetId)
            } else {
                try library.bindByDefault(slotId: slotId, assetId: assetId)
            }
        } catch {
            throw ApplicationError(error)
        }
    }

    public func listBindings() async -> CatalogBindingList {
        let loaded = library.bindings.load()
        return CatalogBindingList(bindings: loaded.table.persistedBindings, warnings: loaded.warnings.map(ApplicationWarning.init))
    }

    // MARK: - 源图

    public func addSource(_ fileURL: URL) throws(ApplicationError) -> PhotoSource {
        let url = fileURL.standardizedFileURL
        if let id = sourceIdsByURL[url], let existing = sourcesById[id] {
            return existing
        }
        try Self.checkSourceFile(url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        let source = PhotoSource(fileURL: url, fileSizeBytes: size)
        sourcesById[source.sourceId] = source
        sourceOrder.append(source.sourceId)
        sourceIdsByURL[url] = source.sourceId
        return source
    }

    /// 源图的存储尺寸与 EXIF 方向（只读文件头，不解码像素）。读不到时为 nil，队列按默认值估算。
    static func sourceImage(at url: URL) -> SourceImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let orientation = ExifOrientation(rawValue: props[kCGImagePropertyOrientation] as? Int ?? 1) ?? .up
        return SourceImage(storedSize: PixelSize(width: width, height: height), orientation: orientation)
    }

    private static func checkSourceFile(_ url: URL) throws(ApplicationError) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw .sourceNotFound(url.path)
        }
        guard !isDirectory.boolValue else { throw .sourceNotRegularFile(url.path) }
        let ext = url.pathExtension.lowercased()
        guard PhotoSource.supportedExtensions.contains(ext) else { throw .sourceUnsupportedFormat(ext) }
    }

    public func sources() -> [PhotoSource] {
        sourceOrder.compactMap { sourcesById[$0] }
    }

    private func source(for reference: SourceReference) throws(ApplicationError) -> PhotoSource {
        switch reference {
        case .id(let id):
            guard let source = sourcesById[id] else { throw .unknownSource(id) }
            return source
        case .file(let url):
            return try addSource(url)
        }
    }

    public func inspectSource(_ reference: SourceReference) async throws(ApplicationError) -> SourceInspection {
        let url: URL
        switch reference {
        case .id(let id):
            guard let source = sourcesById[id] else { throw .unknownSource(id) }
            url = source.fileURL
        case .file(let file):
            url = file.standardizedFileURL
            try Self.checkSourceFile(url)
        }
        guard let analyzer else { throw .analyzerUnavailable() }
        do {
            return try await analyzer.inspect(url)
        } catch {
            throw JobQueue.applicationError(error)
        }
    }

    // MARK: - 校验与预览

    public func validate(_ request: ExportRequest) async throws(ApplicationError) -> ValidationResult {
        guard !request.sourceIds.isEmpty, !request.presets.isEmpty else { throw .emptyRequest() }
        let sources = try request.sourceIds.map { (id) throws(ApplicationError) -> PhotoSource in
            guard let source = sourcesById[id] else { throw .unknownSource(id) }
            return source
        }
        let destination = request.destination
        var destinationError: ApplicationError?
        do {
            try ExportChecks.checkDestination(destination.rootDirectory, create: false)
        } catch {
            destinationError = error
        }
        // 覆盖检查要保护的源文件：本请求的全部源图，以及队列中已有任务的源图。只有覆盖策略用得到。
        let protectedSources = destination.conflictPolicy == .overwrite
            ? sources.map(\.fileURL) + (await queue.allRecords()).map(\.spec.source.fileURL) : []
        var resolver = LazySlotResolver(configuration)
        let caseSensitive = OutputNaming.volumeIsCaseSensitive(destination.rootDirectory)
        var claimed: Set<String> = []
        var items: [ValidationItem] = []

        for source in sources {
            for preset in request.presets {
                var warnings: [ApplicationWarning] = []
                var errors: [ApplicationError] = []
                func attempt<T>(_ body: () throws(ApplicationError) -> T) -> T? {
                    do { return try body() } catch { errors.append(error); return nil }
                }
                let platform = configuration.platformProfile(for: preset)
                _ = attempt { () throws(ApplicationError) in try ExportChecks.checkSource(source.fileURL) }
                warnings += attempt { () throws(ApplicationError) in try ExportChecks.checkPreset(preset, platform: platform) } ?? []
                if let destinationError { errors.append(destinationError) }
                let slots = attempt { () throws(ApplicationError) in
                    try ExportChecks.resolveSlots(&resolver, preset: preset, bindings: request.assetBindings, source: source.fileURL)
                }
                warnings += slots?.1 ?? []

                // 预估输出：只在前面的检查都通过时做，避免对读不了的文件报重复错误。
                var outputs: [ValidationItem.PlannedFile] = []
                if errors.isEmpty, let analyzer {
                    let job = JobRenderRequest(jobId: JobID(), attemptId: AttemptID(), source: source, preset: preset,
                                               platform: platform, slots: slots?.0, sourceColorOverride: request.sourceColorOverride)
                    do {
                        let plan = try await analyzer.plan(job)
                        warnings += plan.warnings
                        outputs = plan.outputs.map {
                            ValidationItem.PlannedFile(
                                role: $0.role,
                                fileName: OutputNaming.fileName(for: $0.role, format: preset.output.format,
                                                                outputCount: OutputNaming.positionCount(of: plan.outputs.map(\.role))),
                                pixelSize: $0.pixelSize)
                        }
                    } catch {
                        errors.append(JobQueue.applicationError(error))
                    }
                }

                let directory = predictDirectory(
                    source: source, preset: preset, destination: destination, caseSensitive: caseSensitive, claimed: &claimed,
                    protectedSources: protectedSources, errors: &errors)
                items.append(ValidationItem(
                    sourceId: source.sourceId, sourceURL: source.fileURL, presetId: preset.presetId, presetName: preset.name,
                    directory: directory, outputs: outputs, warnings: warnings, errors: errors))
            }
        }
        return ValidationResult(items: items)
    }

    /// 推算作品目录（§9.2、D-46…D-49）。默认策略按磁盘现状和本请求里排在前面的任务推算版本后缀；
    /// 覆盖策略检查旧目录能否被替换，以及本请求里是否有两个任务指向同一目录。
    /// - Parameter caseSensitive: 目标卷是否区分大小写。不区分时只差大小写的作品名是同一个目录（D-73）。
    private func predictDirectory(
        source: PhotoSource, preset: ExportPreset, destination: ExportDestination, caseSensitive: Bool,
        claimed: inout Set<String>, protectedSources: [URL], errors: inout [ApplicationError]
    ) -> URL {
        let workName = destination.naming.workName(source: source, preset: preset)
        let platformDir = destination.rootDirectory.standardizedFileURL.appending(
            path: OutputNaming.platformFolderName(for: preset.platform), directoryHint: .isDirectory)
        let fm = FileManager.default
        func key(_ url: URL) -> String { OutputNaming.collisionKey(for: url, caseSensitive: caseSensitive) }
        switch destination.conflictPolicy {
        case .versionSuffix:
            for version in 1...OutputNaming.maxVersion {
                let target = platformDir.appending(path: OutputNaming.versioned(workName, version: version), directoryHint: .isDirectory)
                // 与发布时的 RENAME_EXCL 一致：悬空的符号链接也算已存在（attributesOfItem 不跟随链接）。
                let exists = (try? fm.attributesOfItem(atPath: target.path)) != nil
                if !exists, claimed.insert(key(target)).inserted { return target }
            }
            errors.append(.versionsExhausted(workName))
            return platformDir.appending(path: workName, directoryHint: .isDirectory)
        case .overwrite:
            let target = platformDir.appending(path: workName, directoryHint: .isDirectory)
            if !claimed.insert(key(target)).inserted {
                errors.append(.duplicateOutput(target.path))
            } else if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                do {
                    try AtomicExporter().checkReplaceable(target, protectedSources: protectedSources)
                } catch {
                    errors.append(error)
                }
            }
            return target
        }
    }

    public func renderPreview(_ request: ExportPreviewRequest) async throws(ApplicationError) -> ExportPreview {
        let source = try source(for: request.source)
        guard let analyzer else { throw .analyzerUnavailable() }
        try ExportChecks.checkSource(source.fileURL)
        let platform = configuration.platformProfile(for: request.preset)
        let presetWarnings = try ExportChecks.checkPreset(request.preset, platform: platform)
        var resolver = LazySlotResolver(configuration)
        let (slots, slotWarnings) = try ExportChecks.resolveSlots(
            &resolver, preset: request.preset, bindings: request.assetBindings, source: source.fileURL)
        let job = JobRenderRequest(jobId: JobID(), attemptId: AttemptID(), source: source, preset: request.preset,
                                   platform: platform, slots: slots, sourceColorOverride: request.sourceColorOverride)
        do {
            var preview = try await analyzer.preview(job, options: request.options)
            var modeWarnings: [ApplicationWarning] = []
            // HDR 预览里没有 HDR 页：说明成品为什么是 SDR（强制 HDR 的原因由渲染器警告）。
            if request.options.dynamicRange != .sdr, !preview.pages.contains(where: { $0.dynamicRange == .hdr }),
               let message = Self.sdrOutputReason(request.preset.output, platform: platform) {
                modeWarnings.append(ApplicationWarning(code: "preview.output_sdr", message: message))
            }
            preview.warnings = presetWarnings + slotWarnings + modeWarnings + preview.warnings
            return preview
        } catch {
            throw JobQueue.applicationError(error)
        }
    }

    static func sdrOutputReason(_ output: OutputSettings, platform: PlatformProfile?) -> String? {
        switch output.dynamicRange {
        case .sdr: "预设输出 SDR，成品没有 HDR 版本"
        case .hdr: nil
        case .auto:
            if output.format != .jpeg { "PNG 不支持 HDR，成品按 SDR 输出" }
            else if platform?.hdr.status == .unsupported { "\(platform!.displayName) 不支持 HDR，成品按 SDR 输出" }
            else { "源图不是 HDR，成品按 SDR 输出" }
        }
    }

    // MARK: - 任务

    public func submit(_ request: ExportRequest) async throws(ApplicationError) -> [JobID] {
        guard !request.sourceIds.isEmpty, !request.presets.isEmpty else { throw .emptyRequest() }
        var specs: [JobSpec] = []
        for sourceId in request.sourceIds {
            guard var source = sourcesById[sourceId] else { throw .unknownSource(sourceId) }
            if source.image == nil, let image = Self.sourceImage(at: source.fileURL) {
                // 只读文件属性（尺寸、方向），给队列按像素数估算内存（§12.1、D-18、D-53）。
                source.image = image
                sourcesById[sourceId] = source
            }
            for preset in request.presets {
                specs.append(JobSpec(source: source, preset: preset, destination: request.destination,
                                     assetBindings: request.assetBindings, sourceColorOverride: request.sourceColorOverride))
            }
        }
        return await queue.submit(specs).map(\.jobId)
    }

    // 下面这些只转交给任务队列（它自己是 actor），不经过服务的 actor：服务在读写本地库时，
    // 任务进度、状态查询和取消不必排在后面等。

    public nonisolated func start() async { await queue.resume() }
    public nonisolated func pause() async { await queue.pause() }

    public nonisolated func cancel(_ job: JobID) async throws(ApplicationError) {
        try await queue.cancel(job)
    }

    public nonisolated func retry(_ job: JobID) async throws(ApplicationError) -> AttemptID {
        try await queue.retry(job)
    }

    public nonisolated func status(_ job: JobID) async throws(ApplicationError) -> JobSnapshot {
        guard let record = await queue.record(for: job) else { throw .unknownJob(job) }
        return record
    }

    public nonisolated func jobs() async -> [JobSnapshot] { await queue.allRecords() }

    public nonisolated func manifest(_ job: JobID) async throws(ApplicationError) -> OutputManifest? {
        try await status(job).manifest
    }

    public nonisolated func setMaxConcurrentJobs(_ count: Int) async { await queue.setMaxConcurrentJobs(count) }
    public nonisolated func setMemoryBudget(_ bytes: Int64?) async { await queue.setMemoryBudget(bytes) }

    public nonisolated func removeStaleStaging(in destinationRoot: URL) async -> [URL] {
        await queue.removeStaleStaging(in: destinationRoot)
    }

    public nonisolated func events() async -> AsyncStream<JobEvent> { await queue.events() }

    public nonisolated func waitUntilFinished(_ jobs: [JobID]) async -> [JobSnapshot] {
        await queue.waitUntilFinished(jobs)
    }
}
