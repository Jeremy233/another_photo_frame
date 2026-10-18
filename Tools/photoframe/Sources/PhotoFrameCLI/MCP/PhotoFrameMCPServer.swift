import Foundation
import MCP
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameRendering
import PhotoFrameStorage

/// 本地 stdio MCP 服务器（§11.4）：把 ``PhotoFrameService`` 的能力以 MCP 工具和只读资源提供给 AI 客户端。
///
/// - 所有操作都经过 `PhotoFrameService`（与 GUI、CLI 同一个后端，D-13、D-70）。
/// - 所有文件路径都经过 ``MCPAccessPolicy``；结果里的字符串在返回前去掉白名单以外的路径。
/// - 导出任务异步执行：`create_export_job` 立即返回 jobId；进程退出前 ``shutdown()`` 取消本服务器创建的未完成任务（§10.3）。
public actor PhotoFrameMCPServer {
    let service: any PhotoFrameService
    let policy: MCPAccessPolicy
    /// 本服务器创建的任务，按创建顺序。只能查看、取消这些任务。
    private var ownedJobs: [JobID] = []
    /// 已通过未结束任务数检查、还在提交中的任务数（`create_export_job` 在 `submit` 返回前占着名额）。
    private var reservedJobs = 0
    /// `shutdown()` 开始后不再创建任务。
    private var isShuttingDown = false
    /// 等正在提交的任务登记完的 `shutdown()`。
    private var submissionWaiters: [CheckedContinuation<Void, Never>] = []
    /// 本次会话写出的预览文件字节数（导出成品从任务清单里算）。
    private var previewBytes: Int64 = 0

    public init(service: any PhotoFrameService, policy: MCPAccessPolicy) {
        self.service = service
        self.policy = policy
    }

    /// 创建 MCP `Server` 并注册工具与资源。调用方负责 `start(transport:)`。
    public func makeServer() async -> Server {
        let server = Server(
            name: "photoframe", version: PhotoFrameCLI.version, title: "AnotherPhotoFrame",
            instructions: instructions,
            capabilities: Server.Capabilities(
                resources: Server.Capabilities.Resources(subscribe: false, listChanged: false),
                tools: Server.Capabilities.Tools(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MCPToolName.allCases.map(\.tool))
        }
        await server.withMethodHandler(CallTool.self) { [self] params in
            guard let name = MCPToolName(rawValue: params.name) else {
                throw MCPError.invalidParams("Unknown tool: \(params.name)")
            }
            return await call(name, params.arguments)
        }
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: MCPResources.list)
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(templates: MCPResources.templates)
        }
        await server.withMethodHandler(ReadResource.self) { [self] params in
            try await readResource(params.uri)
        }
        return server
    }

    /// 取消本服务器创建的、尚未结束的任务，并等它们停下（队列会删除它们的临时目录）。
    public func shutdown() async {
        isShuttingDown = true
        // 先等正在提交的 create_export_job 把任务登记好（之后不会再有新任务），再全部取消。
        if reservedJobs > 0 {
            await withCheckedContinuation { submissionWaiters.append($0) }
        }
        let ids = ownedJobs
        for id in ids {
            if let s = try? await service.status(id), !s.status.isTerminal { try? await service.cancel(id) }
        }
        _ = await service.waitUntilFinished(ids)
    }

    var instructions: String {
        func list(_ dirs: [String]) -> String { dirs.isEmpty ? "（未配置，拒绝）" : dirs.joined(separator: "、") }
        return """
            AnotherPhotoFrame：按社交平台预设给照片加白边、切全景轮播图、叠加水印 / 签名 / EXIF 文字，色彩管理正确。
            允许读取的目录：\(list(policy.readDirectories))。允许写入的目录：\(list(policy.writeDirectories))。
            路径一律用绝对路径。典型流程：list_presets → inspect_image → validate_export → preview_export → create_export_job → get_job_status。
            默认不覆盖：已存在的作品目录自动加 _v2、_v3；只有显式传 overwrite: true 才替换本软件之前导出的目录（D-49）。
            预设字段说明和逐项修改的路径写法见资源 photoframe://docs/preset-schema。
            """
    }

    // MARK: - 工具

    func call(_ name: MCPToolName, _ arguments: [String: Value]?) async -> CallTool.Result {
        do {
            switch name {
            case .listPresets: return try await listPresets(arguments)
            case .getPreset: return try await getPreset(arguments)
            case .updatePreset: return try await updatePreset(arguments)
            case .inspectImage: return try await inspectImage(arguments)
            case .listAssets: return try await listAssets(arguments)
            case .validateExport: return try await validateExport(arguments)
            case .previewExport: return try await previewExport(arguments)
            case .createExportJob: return try await createExportJob(arguments)
            case .getJobStatus: return try await jobStatus(arguments)
            case .cancelExportJob: return try await cancelJob(arguments)
            }
        } catch {
            return failure(error)
        }
    }

    private func listPresets(_ arguments: [String: Value]?) async throws(ApplicationError) -> CallTool.Result {
        _ = try MCPArguments(arguments, allowed: [])
        let list = try await service.listPresets()
        return success(PresetListJSON(presets: list.presets.map(PresetJSON.init), warnings: list.warnings.map(WarningJSON.init)))
    }

    private func getPreset(_ arguments: [String: Value]?) async throws(ApplicationError) -> CallTool.Result {
        let args = try MCPArguments(arguments, allowed: ["preset", "path"])
        let entry = try await service.resolvePreset(.library(args.requiredString("preset")))
        let path = try args.string("path")
        let value = try PresetContent.value(entry.preset, at: path)
        let summary = CatalogPresetSummary(entry, catalog: try? PlatformCatalogStore.builtIn())
        return success(PresetGetJSON(preset: PresetJSON(summary), path: path, value: value))
    }

    private func updatePreset(_ arguments: [String: Value]?) async throws(ApplicationError) -> CallTool.Result {
        let args = try MCPArguments(arguments, allowed: ["preset", "edits"])
        let reference = PresetReference.library(try args.requiredString("preset"))
        guard let items = args.values["edits"]?.arrayValue, !items.isEmpty else { throw .invalidArguments("edits 应为非空数组") }
        guard items.count <= PresetEditError.maxEdits else { throw ApplicationError(PresetEditError.tooManyEdits(items.count)) }
        var edits: [PresetEdit] = []
        for item in items {
            let edit = try MCPArguments(item.objectValue, allowed: ["path", "value", "remove"])
            let path = try PresetContent.path(edit.requiredString("path"))
            let remove = try edit.bool("remove")
            switch (edit.values["value"], remove) {
            case (nil, true): edits.append(.remove(path))
            case (let value?, false): edits.append(.set(path, try Self.jsonValue(value)))
            case (_?, true): throw .invalidArguments("\(path) 不能同时有 value 和 remove")
            case (nil, false): throw .invalidArguments("\(path) 需要 value 或 remove: true")
            }
        }
        let result = try await service.updatePreset(reference, edits: edits)
        return success(PresetUpdateJSON(preset: PresetJSON(result.preset), changed: edits.map(\.path.description),
                                        warnings: result.warnings.map(WarningJSON.init)))
    }

    private func inspectImage(_ arguments: [String: Value]?) async throws(ApplicationError) -> CallTool.Result {
        let args = try MCPArguments(arguments, allowed: ["path"])
        let url = try policy.inputFile(args.requiredString("path"), argument: "path")
        return success(InspectJSON(try await service.inspectSource(.file(url))))
    }

    private func listAssets(_ arguments: [String: Value]?) async throws(ApplicationError) -> CallTool.Result {
        let args = try MCPArguments(arguments, allowed: ["category"])
        var category: AssetCategory?
        if let text = try args.string("category") {
            guard let c = AssetCategoryArgument(rawValue: text) else { throw .invalidArguments("category 只能是 signature、watermark、camera-badge") }
            category = c.category
        }
        let list = await service.listAssets(category: category)
        return success(AssetListJSON(assets: list.assets.map(AssetJSON.init), warnings: list.warnings.map(WarningJSON.init)))
    }

    // MARK: 导出

    /// `images`、`presets` 各自最多几项（任务总数另受 `maxActiveJobs` 限制）。
    static let maxListItems = 64

    private static let exportArguments: Set<String> = ["images", "presets", "outputDirectory", "overwrite", "assumeProfile", "bindings"]

    /// 解析导出参数并校验（与 CLI `export` 相同：先校验全部任务，D-72）。推算出的每个作品目录再按白名单检查一次。
    private func validatedRequest(_ arguments: [String: Value]?) async throws(ApplicationError) -> (ExportRequest, ValidationResult) {
        let args = try MCPArguments(arguments, allowed: Self.exportArguments)
        let imagePaths = try args.strings("images", max: Self.maxListItems)
        let presetRefs = try args.strings("presets", max: Self.maxListItems)
        let destination = try policy.outputDirectory(args.requiredString("outputDirectory"), argument: "outputDirectory")
        // 每个任务先写到 <输出目录>/.photoframe-staging/<attemptId>/，清理残留时也会删那里的旧目录：它同样不能经链接指向白名单外。
        try policy.checkWritable(AtomicExporter.stagingRoot(for: destination), argument: "outputDirectory")
        let override = try Self.assumedProfile(args)
        let assetBindings = try await bindings(args)

        var presets: [ExportPreset] = []
        for ref in presetRefs {
            let preset = try await service.resolvePreset(.library(ref)).preset
            if !presets.contains(where: { $0.presetId == preset.presetId }) { presets.append(preset) }
        }
        var sourceIds: [SourceID] = []
        for (i, path) in imagePaths.enumerated() {
            let url = try policy.inputFile(path, argument: "images[\(i)]")
            let source = try await service.addSource(url)
            if !sourceIds.contains(source.sourceId) { sourceIds.append(source.sourceId) }
        }
        let request = ExportRequest(
            sourceIds: sourceIds, presets: presets,
            destination: ExportDestination(rootDirectory: destination, conflictPolicy: try args.bool("overwrite") ? .overwrite : .versionSuffix),
            assetBindings: assetBindings, sourceColorOverride: override)
        var validation = try await service.validate(request)
        for i in validation.items.indices {
            do {
                try policy.checkWritable(validation.items[i].directory, argument: "作品目录")
            } catch {
                validation.items[i].errors.append(error)
            }
        }
        return (request, validation)
    }

    private func validateExport(_ arguments: [String: Value]?) async throws(ApplicationError) -> CallTool.Result {
        let (_, validation) = try await validatedRequest(arguments)
        return success(DryRunResultJSON(valid: validation.isValid, jobs: validation.items.map(DryRunJobJSON.init)))
    }

    private func createExportJob(_ arguments: [String: Value]?) async throws(ApplicationError) -> CallTool.Result {
        try await checkOutputQuota()
        let (request, validation) = try await validatedRequest(arguments)
        guard validation.isValid else {
            let body = DryRunResultJSON(dryRun: false, valid: false, jobs: validation.items.map(DryRunJobJSON.init))
            return failure(validation.errors.first ?? .emptyRequestError, body: body)
        }
        let count = request.sourceIds.count * request.presets.count
        try await reserve(count)
        let ids: [JobID]
        do {
            ids = try await service.submit(request)
        } catch {
            finishSubmission(count, ids: [])
            throw error
        }
        finishSubmission(count, ids: ids)
        var jobs: [ExportJobJSON] = []
        for id in ids { jobs.append(Self.jobJSON(try await service.status(id))) }
        return success(CreatedJobsJSON(valid: true, jobs: jobs))
    }

    private func jobStatus(_ arguments: [String: Value]?) async throws(ApplicationError) -> CallTool.Result {
        let args = try MCPArguments(arguments, allowed: ["jobId"])
        if let text = try args.string("jobId") {
            let id = try ownedJob(text)
            return success(JobResultJSON(job: Self.jobJSON(try await service.status(id))))
        }
        var jobs: [ExportJobJSON] = []
        for id in ownedJobs { jobs.append(Self.jobJSON(try await service.status(id))) }
        return success(JobListJSON(jobs: jobs))
    }

    private func cancelJob(_ arguments: [String: Value]?) async throws(ApplicationError) -> CallTool.Result {
        let args = try MCPArguments(arguments, allowed: ["jobId"])
        let id = try ownedJob(args.requiredString("jobId"))
        try await service.cancel(id)
        _ = await service.waitUntilFinished([id])
        return success(JobResultJSON(job: Self.jobJSON(try await service.status(id))))
    }

    private func ownedJob(_ text: String) throws(ApplicationError) -> JobID {
        // 不属于本服务器的任务与不存在的任务报同样的错。
        guard let id = JobID(text), ownedJobs.contains(id) else {
            throw ApplicationError(code: "job.unknown", message: "本服务器没有这个任务：\(text)")
        }
        return id
    }

    /// 检查未结束任务数上限并预留名额。取快照之后到预留之间没有 await，并发的 create_export_job 不会一起通过检查。
    private func reserve(_ count: Int) async throws(ApplicationError) {
        let snapshot = await service.jobs()
        guard !isShuttingDown else {
            throw ApplicationError(code: "mcp.shutting_down", message: "服务器正在退出，不再创建新任务")
        }
        let statuses = Dictionary(snapshot.map { ($0.jobId, $0.status) }, uniquingKeysWith: { first, _ in first })
        // 快照里还没有的任务（快照之后才提交的）也算未结束。
        let active = ownedJobs.count { statuses[$0].map { !$0.isTerminal } ?? true } + reservedJobs
        guard active + count <= policy.limits.maxActiveJobs else {
            throw ApplicationError(code: "mcp.queue_full",
                                   message: "未结束的任务最多 \(policy.limits.maxActiveJobs) 个（已有 \(active) 个，本次 \(count) 个）",
                                   hint: "等已有任务结束，或在 MCP 客户端配置里调大 --max-active-jobs")
        }
        reservedJobs += count
    }

    /// 结束预留并登记提交的任务（同一段同步代码）；没有正在提交的任务时唤醒等待的 `shutdown()`。
    private func finishSubmission(_ count: Int, ids: [JobID]) {
        reservedJobs -= count
        ownedJobs += ids
        guard reservedJobs == 0 else { return }
        let waiters = submissionWaiters
        submissionWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// 本次会话已写出的字节数：完成的导出任务 + 预览文件。
    private func outputBytes() async -> Int64 {
        var total = previewBytes
        for id in ownedJobs { total += (try? await service.status(id).manifest?.totalBytes) ?? 0 }
        return total
    }

    private func checkOutputQuota() async throws(ApplicationError) {
        let used = await outputBytes()
        guard used < policy.limits.maxOutputBytes else {
            throw ApplicationError(code: "mcp.output_quota_exceeded",
                                   message: "本次会话已写出 \(used / 1_048_576) MiB，达到上限 \(policy.limits.maxOutputBytes / 1_048_576) MiB",
                                   hint: "重启 MCP 服务器，或在客户端配置里调大 --max-output-mb")
        }
    }

    // MARK: 预览

    private func previewExport(_ arguments: [String: Value]?) async throws(ApplicationError) -> CallTool.Result {
        let args = try MCPArguments(arguments, allowed: [
            "image", "preset", "maxEdge", "pages", "dynamicRange", "outputDirectory", "overwrite", "assumeProfile", "bindings",
        ])
        let limits = policy.limits
        // 默认 1200，但不超过 --max-preview-edge（否则不传 maxEdge 的调用全部失败）。
        let maxEdge = try args.int("maxEdge") ?? min(1200, limits.maxPreviewEdge)
        guard maxEdge >= 16, maxEdge <= limits.maxPreviewEdge else {
            throw .limitExceeded("maxEdge 应在 16…\(limits.maxPreviewEdge) 之间", hint: "在 MCP 客户端配置里调大 --max-preview-edge")
        }
        var pages = Set(0..<limits.maxPreviewPages)
        if let given = try args.ints("pages") {
            guard !given.isEmpty, given.allSatisfy({ $0 >= 0 && $0 < 1000 }) else { throw .invalidArguments("pages 应为 0…999 的整数") }
            guard Set(given).count <= limits.maxPreviewPages else {
                throw .limitExceeded("一次最多预览 \(limits.maxPreviewPages) 页", hint: "分几次预览")
            }
            pages = Set(given)
        }
        var range = OutputSettings.DynamicRange.sdr
        if let text = try args.string("dynamicRange") {
            // 预览的颜色模式只有 sdr / hdr；预设的 auto（D-125）不是预览模式。
            guard let value = OutputSettings.DynamicRange(rawValue: text), value != .auto else { throw .invalidArguments("dynamicRange 只能是 sdr、hdr") }
            range = value
        }
        let image = try policy.inputFile(args.requiredString("image"), argument: "image")
        let directory = try args.string("outputDirectory").map { (d) throws(ApplicationError) in
            try policy.outputDirectory(d, argument: "outputDirectory")
        }
        if directory != nil { try await checkOutputQuota() }
        let override = try Self.assumedProfile(args)
        let assetBindings = try await bindings(args)
        let entry = try await service.resolvePreset(.library(args.requiredString("preset")))
        let source = try await service.addSource(image)
        let preview = try await service.renderPreview(ExportPreviewRequest(
            source: .id(source.sourceId), preset: entry.preset, options: PreviewOptions(maxLongEdge: maxEdge, pages: pages, dynamicRange: range),
            assetBindings: assetBindings, sourceColorOverride: override))
        let warnings = (entry.warnings + preview.warnings).map(WarningJSON.init)
        let preset = PresetRefJSON(presetId: entry.preset.presetId.uuidString, name: entry.preset.name)
        let positions = preview.roles.map(\.carouselPosition)

        if let directory {
            let targets = try PreviewFiles.write(preview, source: source, preset: entry.preset, to: directory, overwrite: args.bool("overwrite"))
            previewBytes += preview.pages.reduce(0) { $0 + Int64($1.data.count) }
            let files = zip(preview.pages, targets).map { PreviewFileJSON($0, path: $1.path) }
            return success(PreviewJSON(source: source.fileURL.path, preset: preset, files: files, positions: positions, warnings: warnings))
        }
        let total = preview.pages.reduce(0) { $0 + $1.data.count }
        guard total <= limits.maxInlinePreviewBytes else {
            throw .limitExceeded("预览图共 \(total / 1024) KiB，超过直接返回的上限 \(limits.maxInlinePreviewBytes / 1024) KiB",
                                 hint: "减小 maxEdge、减少 pages，或给 outputDirectory 写成文件")
        }
        let images = preview.pages.map { page in
            Tool.Content.image(data: page.data.base64EncodedString(), mimeType: page.format == .jpeg ? "image/jpeg" : "image/png",
                               annotations: nil, _meta: nil)
        }
        let files = preview.pages.map { PreviewFileJSON($0, path: nil) }
        return success(PreviewJSON(source: source.fileURL.path, preset: preset, files: files, positions: positions, warnings: warnings),
                       extra: images)
    }

    // MARK: 参数

    private static func assumedProfile(_ args: MCPArguments) throws(ApplicationError) -> SourceColorOverride? {
        guard let text = try args.string("assumeProfile") else { return nil }
        guard let profile = AssumedProfile(rawValue: text) else { throw .invalidArguments("assumeProfile 只能是 srgb、display-p3、adobe-rgb") }
        return profile.override
    }

    private func bindings(_ args: MCPArguments) async throws(ApplicationError) -> [String: UUID] {
        var result: [String: UUID] = [:]
        for (slot, asset) in try args.stringMap("bindings") {
            result[slot] = try await service.resolveAsset(asset).assetId
        }
        return result
    }

    static func jobJSON(_ record: JobRecord) -> ExportJobJSON {
        var json = ExportJobJSON(record)
        json.progress = .init(record.progress)
        return json
    }

    /// MCP 的 `Value` → 预设 JSON。
    static func jsonValue(_ value: Value) throws(ApplicationError) -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        } catch {
            throw .invalidArguments("value 不是合法的 JSON")
        }
    }

    // MARK: - 资源

    private func readResource(_ uri: String) async throws -> ReadResource.Result {
        let content: Resource.Content
        switch uri {
        case MCPResources.access:
            content = .text(try encodeText(AccessJSON(policy)), uri: uri, mimeType: "application/json")
        case MCPResources.presetSchema:
            content = .text(MCPResources.presetSchemaText, uri: uri, mimeType: "text/markdown")
        case MCPResources.platforms:
            content = .text(try encodeText(PlatformCatalogStore.builtIn()), uri: uri, mimeType: "application/json")
        case MCPResources.presets:
            let list = try await service.listPresets()
            content = .text(try encodeText(PresetListJSON(presets: list.presets.map(PresetJSON.init), warnings: list.warnings.map(WarningJSON.init))),
                            uri: uri, mimeType: "application/json")
        default:
            guard uri.hasPrefix(MCPResources.presetPrefix) else { throw MCPError.invalidParams("Unknown resource: \(uri)") }
            let ref = String(uri.dropFirst(MCPResources.presetPrefix.count)).removingPercentEncoding ?? ""
            guard !ref.isEmpty else { throw MCPError.invalidParams("Unknown resource: \(uri)") }
            let entry: CatalogPreset
            do {
                entry = try await service.resolvePreset(.library(ref))
            } catch {
                throw MCPError.invalidParams(policy.redact(error.message))
            }
            content = .text(try encodeText(try PresetContent.manifest(entry.preset)), uri: uri, mimeType: "application/json")
        }
        return ReadResource.Result(contents: [content])
    }

    private func encodeText(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return policy.redact(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    // MARK: - 结果

    private func success(_ body: some Encodable, extra: [Tool.Content] = []) -> CallTool.Result {
        result(body, error: nil, extra: extra)
    }

    private func failure(_ error: ApplicationError, body: (some Encodable)? = Optional<NoBody>.none) -> CallTool.Result {
        result(body, error: error, extra: [])
    }

    /// 结构化结果：主体字段 + `ok`（+ `error`）。所有字符串都去掉白名单以外的路径；text 内容是同一份 JSON。
    private func result(_ body: (some Encodable)?, error: ApplicationError?, extra: [Tool.Content]) -> CallTool.Result {
        var object: [String: Value] = [:]
        if let body, let data = try? JSONEncoder().encode(body), let decoded = try? JSONDecoder().decode([String: Value].self, from: data) {
            object = decoded
        }
        object["ok"] = .bool(error == nil)
        if let error {
            var e: [String: Value] = ["code": .string(error.code), "message": .string(error.message)]
            if let hint = error.hint { e["hint"] = .string(Self.mcpHint(hint)) }
            object["error"] = .object(e)
        }
        let value = redact(.object(object))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)] + extra,
                               structuredContent: Value?.some(value), isError: error != nil)
    }

    private func redact(_ value: Value) -> Value {
        switch value {
        case .string(let s): .string(policy.redact(s))
        case .array(let a): .array(a.map(redact))
        case .object(let o): .object(o.mapValues(redact))
        default: value
        }
    }

    /// 服务层的提示是按 CLI 写的（`--overwrite`），换成 MCP 的参数名。
    static func mcpHint(_ hint: String) -> String {
        hint.replacingOccurrences(of: "加 --overwrite", with: "设置 overwrite: true")
            .replacingOccurrences(of: "去掉 --overwrite", with: "不设置 overwrite")
            .replacingOccurrences(of: "--overwrite", with: "overwrite: true")
    }
}

// MARK: - 结果格式（字段与 CLI `--json` 一致）

struct CreatedJobsJSON: Encodable {
    var valid: Bool
    var jobs: [ExportJobJSON]
}

struct JobResultJSON: Encodable {
    var job: ExportJobJSON
}

struct JobListJSON: Encodable {
    var jobs: [ExportJobJSON]
}

/// `photoframe://access`：允许的目录和上限。
struct AccessJSON: Encodable {
    var readDirectories: [String]
    var writeDirectories: [String]
    var limits: Limits

    struct Limits: Encodable {
        var maxInputBytes: Int64
        var maxPreviewEdge: Int
        var maxPreviewPages: Int
        var maxInlinePreviewBytes: Int
        var maxActiveJobs: Int
        var maxOutputBytes: Int64
    }

    init(_ policy: MCPAccessPolicy) {
        readDirectories = policy.readDirectories
        writeDirectories = policy.writeDirectories
        let l = policy.limits
        limits = Limits(maxInputBytes: l.maxInputBytes, maxPreviewEdge: l.maxPreviewEdge, maxPreviewPages: l.maxPreviewPages,
                        maxInlinePreviewBytes: l.maxInlinePreviewBytes, maxActiveJobs: l.maxActiveJobs, maxOutputBytes: l.maxOutputBytes)
    }
}

extension ApplicationError {
    static func limitExceeded(_ message: String, hint: String) -> Self {
        Self(code: "mcp.limit_exceeded", message: message, hint: hint)
    }

    static let emptyRequestError = Self(code: "request.invalid", message: "导出请求无效")
}
