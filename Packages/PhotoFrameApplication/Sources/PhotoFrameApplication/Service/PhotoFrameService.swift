import Foundation
import PhotoFrameCore
import PhotoFrameStorage

/// 导出请求（§11.1 `ExportRequest`）：多张源图 × 多个预设快照，每个组合生成一个任务（§3.1）。
public struct ExportRequest: Hashable, Sendable, Codable {
    public var sourceIds: [SourceID]
    /// 预设快照：请求创建时的内容，之后修改预设不影响这些任务（§8.3）。
    public var presets: [ExportPreset]
    public var destination: ExportDestination
    /// 单任务素材绑定，作用于本请求生成的每个任务（D-14）。
    public var assetBindings: [String: UUID]

    public init(sourceIds: [SourceID], presets: [ExportPreset], destination: ExportDestination, assetBindings: [String: UUID] = [:]) {
        self.sourceIds = sourceIds
        self.presets = presets
        self.destination = destination
        self.assetBindings = assetBindings
    }
}

/// GUI、CLI、MCP 共用的后端入口（§10.1、§11.2、D-13）。
///
/// 所有类型都可序列化、与界面无关，以后可以在进程间适配器后面提供同一个接口。
public protocol PhotoFrameService: Sendable {
    /// 可用的预设：内置 + 本服务读过的 `.photoframe` 文件（以后加上用户预设库）。
    func listPresets() async throws(ApplicationError) -> [PresetListing]
    /// 按 ID、名称或文件找到预设。文件只读取、不安装。
    func resolvePreset(_ reference: PresetReference) async throws(ApplicationError) -> PresetEntry
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

/// 进程内实现：源图登记 + 预设来源 + ``JobQueue`` + 图像分析。GUI、CLI、MCP 各自在自己的进程里创建一个（D-13）。
///
/// 渲染与图像分析由调用方注入（PhotoFrameEngine 用 PhotoFrameRendering 实现），应用层不依赖渲染模块。
public actor LocalPhotoFrameService: PhotoFrameService {
    public let queue: JobQueue
    private let analyzer: (any ImageAnalyzer)?
    private let presetProvider: any PresetProvider
    private let configuration: QueueConfiguration
    private var sourcesById: [SourceID: PhotoSource] = [:]
    private var sourceOrder: [SourceID] = []
    /// 通过文件路径读过的预设，之后也出现在 `listPresets` 里。
    private var filePresets: [PresetEntry] = []

    public init(
        queue: JobQueue, configuration: QueueConfiguration = QueueConfiguration(),
        analyzer: (any ImageAnalyzer)? = nil, presets: (any PresetProvider)? = nil
    ) {
        self.queue = queue
        self.configuration = configuration
        self.analyzer = analyzer
        self.presetProvider = presets ?? Self.defaultPresets(configuration.platformCatalog)
    }

    /// - Parameters:
    ///   - renderer: 任务队列使用的渲染器。
    ///   - analyzer: 检查源图、预估输出、预览；nil 时这些接口报 `service.unavailable`，`validate` 不预估输出。
    ///   - presets: 预设来源；nil 时用平台配置生成内置预设（没有平台配置时用应用附带的配置）。
    ///   - configuration: 队列设置；素材来源放在 `configuration.assets`。
    public init(
        renderer: any JobRenderer, analyzer: (any ImageAnalyzer)? = nil, presets: (any PresetProvider)? = nil,
        configuration: QueueConfiguration = QueueConfiguration()
    ) {
        self.init(queue: JobQueue(renderer: renderer, configuration: configuration), configuration: configuration,
                  analyzer: analyzer, presets: presets)
    }

    private static func defaultPresets(_ catalog: PlatformCatalog?) -> any PresetProvider {
        guard let catalog = catalog ?? (try? PlatformCatalogStore.builtIn()) else { return CompositePresetProvider([]) }
        return BuiltInPresetProvider(catalog: catalog)
    }

    private var catalog: PlatformCatalog? { configuration.platformCatalog ?? (try? PlatformCatalogStore.builtIn()) }

    // MARK: - 预设

    public func listPresets() async throws(ApplicationError) -> [PresetListing] {
        let catalog = self.catalog
        return try await allPresets().map { PresetListing($0, catalog: catalog) }
    }

    private func allPresets() async throws(ApplicationError) -> [PresetEntry] {
        let provided = try await presetProvider.presets()
        let ids = Set(provided.map(\.preset.presetId))
        return provided + filePresets.filter { !ids.contains($0.preset.presetId) }
    }

    public func resolvePreset(_ reference: PresetReference) async throws(ApplicationError) -> PresetEntry {
        if case .file(let url) = reference {
            let entry = try PresetFileLoader.load(url, platforms: catalog)
            filePresets.removeAll { $0.origin == entry.origin }
            filePresets.append(entry)
            return entry
        }
        return try reference.match(in: try await allPresets())
    }

    // MARK: - 源图

    public func addSource(_ fileURL: URL) throws(ApplicationError) -> PhotoSource {
        let url = fileURL.standardizedFileURL
        if let existing = sourcesById.values.first(where: { $0.fileURL.standardizedFileURL == url }) {
            return existing
        }
        try Self.checkSourceFile(url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        let source = PhotoSource(fileURL: url, fileSizeBytes: size)
        sourcesById[source.sourceId] = source
        sourceOrder.append(source.sourceId)
        return source
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
        // 覆盖检查要保护的源文件：本请求的全部源图，以及队列中已有任务的源图。
        let protectedSources = sources.map(\.fileURL) + (await queue.allRecords()).map(\.spec.source.fileURL)
        let resolver = configuration.currentSlotResolver()
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
                    try ExportChecks.resolveSlots(resolver, preset: preset, bindings: request.assetBindings)
                }
                warnings += slots?.1 ?? []

                // 预估输出：只在前面的检查都通过时做，避免对读不了的文件报重复错误。
                var outputs: [ValidationItem.PlannedFile] = []
                if errors.isEmpty, let analyzer {
                    let job = JobRenderRequest(jobId: JobID(), attemptId: AttemptID(), source: source, preset: preset,
                                               platform: platform, slots: slots?.0)
                    do {
                        let plan = try await analyzer.plan(job)
                        warnings += plan.warnings
                        outputs = plan.outputs.map {
                            ValidationItem.PlannedFile(
                                role: $0.role,
                                fileName: OutputNaming.fileName(for: $0.role, format: preset.output.format, outputCount: plan.outputs.count),
                                pixelSize: $0.pixelSize)
                        }
                    } catch {
                        errors.append(JobQueue.applicationError(error))
                    }
                }

                let directory = predictDirectory(
                    source: source, preset: preset, destination: destination, claimed: &claimed,
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
    private func predictDirectory(
        source: PhotoSource, preset: ExportPreset, destination: ExportDestination, claimed: inout Set<String>,
        protectedSources: [URL], errors: inout [ApplicationError]
    ) -> URL {
        let workName = destination.naming.workName(source: source, preset: preset)
        let platformDir = destination.rootDirectory.standardizedFileURL.appending(
            path: OutputNaming.platformFolderName(for: preset.platform), directoryHint: .isDirectory)
        let fm = FileManager.default
        switch destination.conflictPolicy {
        case .versionSuffix:
            for version in 1...OutputNaming.maxVersion {
                let target = platformDir.appending(path: OutputNaming.versioned(workName, version: version), directoryHint: .isDirectory)
                if !fm.fileExists(atPath: target.path), claimed.insert(target.path).inserted { return target }
            }
            errors.append(.versionsExhausted(workName))
            return platformDir.appending(path: workName, directoryHint: .isDirectory)
        case .overwrite:
            let target = platformDir.appending(path: workName, directoryHint: .isDirectory)
            if !claimed.insert(target.path).inserted {
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
        let (slots, slotWarnings) = try ExportChecks.resolveSlots(
            configuration.currentSlotResolver(), preset: request.preset, bindings: request.assetBindings)
        let job = JobRenderRequest(jobId: JobID(), attemptId: AttemptID(), source: source, preset: request.preset,
                                   platform: platform, slots: slots)
        do {
            var preview = try await analyzer.preview(job, options: request.options)
            preview.warnings = presetWarnings + slotWarnings + preview.warnings
            return preview
        } catch {
            throw JobQueue.applicationError(error)
        }
    }

    // MARK: - 任务

    public func submit(_ request: ExportRequest) async throws(ApplicationError) -> [JobID] {
        guard !request.sourceIds.isEmpty, !request.presets.isEmpty else { throw .emptyRequest() }
        var specs: [JobSpec] = []
        for sourceId in request.sourceIds {
            guard let source = sourcesById[sourceId] else { throw .unknownSource(sourceId) }
            for preset in request.presets {
                specs.append(JobSpec(source: source, preset: preset, destination: request.destination, assetBindings: request.assetBindings))
            }
        }
        return await queue.submit(specs).map(\.jobId)
    }

    public func start() async { await queue.resume() }
    public func pause() async { await queue.pause() }

    public func cancel(_ job: JobID) async throws(ApplicationError) {
        try await queue.cancel(job)
    }

    public func retry(_ job: JobID) async throws(ApplicationError) -> AttemptID {
        try await queue.retry(job)
    }

    public func status(_ job: JobID) async throws(ApplicationError) -> JobSnapshot {
        guard let record = await queue.record(for: job) else { throw .unknownJob(job) }
        return record
    }

    public func jobs() async -> [JobSnapshot] { await queue.allRecords() }

    public func manifest(_ job: JobID) async throws(ApplicationError) -> OutputManifest? {
        try await status(job).manifest
    }

    public func setMaxConcurrentJobs(_ count: Int) async { await queue.setMaxConcurrentJobs(count) }
    public func setMemoryBudget(_ bytes: Int64?) async { await queue.setMemoryBudget(bytes) }

    public func removeStaleStaging(in destinationRoot: URL) async -> [URL] {
        await queue.removeStaleStaging(in: destinationRoot)
    }

    public func events() async -> AsyncStream<JobEvent> { await queue.events() }

    public func waitUntilFinished(_ jobs: [JobID]) async -> [JobSnapshot] {
        await queue.waitUntilFinished(jobs)
    }
}
