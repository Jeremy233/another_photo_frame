import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameRendering

// 「当前」界面：源图、任务草稿、拖放、素材绑定、开始批处理（UI 设计文档第 9–12 节）。

extension Workbench {
    // MARK: 源图

    /// 添加图片（按钮、从 Finder 拖入）。不支持的格式跳过并提示。返回新加入的源图。
    @discardableResult
    public func addSources(_ urls: [URL]) async -> [SourceID] {
        var added: [SourceID] = []
        var failures: [String] = []
        for url in urls {
            do throws(ApplicationError) {
                let source = try await service.addSource(url)
                guard sourceItem(source.sourceId) == nil else { continue }
                sources.append(SourceItem(source: source, jobs: []))
                added.append(source.sourceId)
                inspect(source.sourceId)
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.message)")
            }
        }
        // 右栏在编辑左栏的预设、批次原来是空的时，预览要用刚加入的源图。
        if !added.isEmpty { refreshPreview() }
        if !failures.isEmpty { alert = WorkbenchAlert(title: "有图片没有添加", message: failures.joined(separator: "\n")) }
        return added
    }

    private func inspect(_ id: SourceID) {
        background("inspect-\(id)") { [self] in
            let result: Result<SourceInspection, ApplicationError>
            do throws(ApplicationError) { result = .success(try await service.inspectSource(.id(id))) } catch { result = .failure(error) }
            guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .success(let inspection): sources[i].inspection = inspection
            case .failure(let error): sources[i].inspectionError = error
            }
            // 检查结果不是预览内容的一部分，内容没变时不会重新渲染。
            refreshPreview()
        }
    }

    /// 没有 ICC 的源图按什么色彩空间解释（D-04）。
    public func setColorOverride(_ value: SourceColorOverride?, for id: SourceID) {
        guard let i = sources.firstIndex(where: { $0.id == id }), sources[i].colorOverride != value else { return }
        sources[i].colorOverride = value
        scheduleValidation(sources[i].jobs.map(\.id))
        refreshPreview()
    }

    // MARK: 任务草稿

    /// 为这些源图各创建一个任务（把预设拖到源图上，或按钮）。
    public func addJobs(preset presetId: UUID, to sourceIds: [SourceID]) async {
        guard !sourceIds.isEmpty, let destination = locations.defaultLocation?.url else { return }
        await perform("无法添加任务") {
            let preset = try await service.resolvePreset(reference(presetId)).preset
            var created: [UUID] = []
            for id in sourceIds {
                guard let i = sources.firstIndex(where: { $0.id == id }) else { continue }
                let job = DraftJob(sourceId: id, preset: preset, destination: destination)
                sources[i].jobs.append(job)
                created.append(job.id)
            }
            scheduleValidation(created)
            if let last = created.last { selection = [.job(last)] }
        }
    }

    /// 选中的源图（选中任务时取它所属的源图）；工具栏「应用预设」用。
    public var targetSourceIds: [SourceID] {
        let selection = self.selection
        return sources.compactMap { item in
            selection.contains(.source(item.id)) || item.jobs.contains { selection.contains(.job($0.id)) } ? item.id : nil
        }
    }

    /// 删除选中的源图（连同它的任务）和任务。
    public func removeSelection() {
        let selection = self.selection
        let sourceCount = sources.count
        sources.removeAll { selection.contains(.source($0.id)) }
        for i in sources.indices where sources[i].jobs.contains(where: { selection.contains(.job($0.id)) }) {
            sources[i].jobs.removeAll { selection.contains(.job($0.id)) }
        }
        self.selection = []
        if sources.count != sourceCount { sourcesDidLeave() }
    }

    /// 复制选中的任务（第 10 节）。
    public func duplicateSelectedJobs() {
        var created: [UUID] = []
        for s in sources.indices {
            for job in sources[s].jobs where selection.contains(.job(job.id)) {
                var copy = job
                copy.id = UUID()
                sources[s].jobs.append(copy)
                created.append(copy.id)
            }
        }
        scheduleValidation(created)
        selection = Set(created.map(BatchItemID.job))
    }

    /// 改任务的输出位置（把位置拖到任务上，或右栏「输出」）。拖到源图上时改它的全部任务。
    public func setDestination(_ url: URL, for item: BatchItemID) {
        let ids: [UUID] = switch item {
        case .job(let id): [id]
        case .source(let id): sourceItem(id)?.jobs.map(\.id) ?? []
        }
        updateJobs(ids) { $0.destination = url }
    }

    /// 右栏「输出」改选中任务的位置。
    public func setDestinationForSelection(_ url: URL) {
        updateJobs(selectedJobIds) { $0.destination = url }
    }

    /// 右栏「输出」改选中任务的作品目录命名模板（§9.2）。
    public func setNamingTemplate(_ template: String) {
        updateJobs(selectedJobIds) { $0.naming.workNameTemplate = template }
    }

    /// 选中任务共同的任务级字段（位置、命名），不同时为「多个值」。
    public func jobField<Value: Equatable>(_ path: KeyPath<DraftJob, Value>) -> FieldValue<Value> {
        let values = selectedJobs().map { $0[keyPath: path] }
        guard let first = values.first else { return .none }
        return values.allSatisfy { $0 == first } ? .single(first) : .mixed
    }

    /// 处理拖到任务列表某一行上的内容。返回是否接受。
    @discardableResult
    public func drop(_ payload: DragPayload, on item: BatchItemID) async -> Bool {
        switch payload {
        case .preset(let id):
            let sourceId: SourceID? = switch item {
            case .source(let s): s
            case .job(let j): job(j)?.sourceId
            }
            guard let sourceId else { return false }
            // 拖到选中的多张源图之一时，对全部选中的源图生效（§4.2）。
            let targets = targetSourceIds.contains(sourceId) ? targetSourceIds : [sourceId]
            await addJobs(preset: id, to: targets)
            return true
        case .location(let id):
            guard let location = location(id) else { return false }
            setDestination(location.url, for: item)
            return true
        case .asset:
            return false
        }
    }

    /// 从 Finder 拖入文件；拖到某张源图上的图片同样作为新源图加入。
    public func dropFiles(_ urls: [URL]) async -> Bool {
        let images = urls.filter { PhotoSource.supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { return false }
        await addSources(images)
        return true
    }

    // MARK: 素材绑定

    public enum BindingLevel: Sendable { case job, preset, userDefault }

    /// 图层占位符当前绑定的素材和来源层级（D-14：单任务 > 预设本地 > 用户默认）。只用于显示，真正的解析在服务里。
    public func binding(for slotId: String) -> (assetId: UUID, level: BindingLevel)? {
        let (subject, jobs) = inspected()
        switch subject {
        case .jobs:
            guard jobs.count == 1, let job = jobs.first else { return nil }
            if let asset = job.assetBindings[slotId] { return (asset, .job) }
            return persistedBinding(slotId, presetId: job.basePreset.presetId)
        case .preset(let id):
            return persistedBinding(slotId, presetId: id)
        case .source, .location, .none:
            return nil
        }
    }

    private func persistedBinding(_ slotId: String, presetId: UUID) -> (assetId: UUID, level: BindingLevel)? {
        if let b = bindings.first(where: { $0.slotId == slotId && $0.presetId == presetId }) { return (b.assetId, .preset) }
        if let b = bindings.first(where: { $0.slotId == slotId && $0.presetId == nil }) { return (b.assetId, .userDefault) }
        return nil
    }

    /// 把素材拖到右栏「图层」的占位符上。编辑任务时是单任务绑定；编辑预设时保存为预设本地绑定。`nil` 清除。
    public func bindAsset(_ assetId: UUID?, slotId: String) async {
        switch inspectorSubject {
        case .jobs(let ids):
            updateJobs(ids) { $0.assetBindings[slotId] = assetId }
        case .preset(let id):
            await perform("无法绑定素材") {
                try await service.bindAsset(assetId, slotId: slotId, preset: reference(id))
                setLibrary(bindings: await service.listBindings().bindings)
            }
        case .source, .location, .none:
            break
        }
    }

    // MARK: 存储为预设

    /// 把选中任务改过的参数存成新的用户预设（§4.2 `Save as Preset`）。任务改为基于新预设。
    public func saveSelectedJobAsPreset(name: String) async {
        guard let id = selectedJobIds.first, let job = job(id) else { return }
        let content = job.preset
        await perform("无法存储为预设") {
            let saved = try await service.savePreset(content, name: name)
            let stored = try await service.resolvePreset(reference(saved.presetId)).preset
            // 新预设有新的 presetId，原预设的本地绑定对它不起作用，任务的成品会变（例如签名不见了）：
            // 像「复制」一样（D-84）把新预设也有的素材槽的本地绑定复制过去。复制不了的（素材已删除等）跳过，导出时本来也会回退。
            let slots = Set(stored.assetSlots.map(\.slotId))
            for binding in await service.listBindings().bindings where binding.presetId == content.presetId && slots.contains(binding.slotId) {
                try? await service.bindAsset(binding.assetId, slotId: binding.slotId, preset: reference(saved.presetId))
            }
            // 存储期间又改过的任务保留改动（显示为已修改），只把它的基准换成新预设。
            updateJobs([id]) {
                $0.basePreset = stored
                if $0.preset == content { $0.preset = stored }
            }
            await refreshLibrary()
        }
    }

    // MARK: 校验

    func request(for job: DraftJob, policy: ConflictPolicy = .versionSuffix) -> ExportRequest {
        ExportRequest(
            sourceIds: [job.sourceId], presets: [job.preset],
            destination: ExportDestination(rootDirectory: job.destination, naming: job.naming, conflictPolicy: policy),
            assetBindings: job.assetBindings, sourceColorOverride: sourceItem(job.sourceId)?.colorOverride)
    }

    /// 改动后重新校验（输出尺寸、页数、作品目录、警告），用于任务列表。
    func scheduleValidation(_ ids: [UUID]) {
        for id in ids {
            background("validate-\(id)") { [self] in
                try? await Task.sleep(for: validationDelay)
                guard !Task.isCancelled, let job = job(id) else { return }
                let item = try? await service.validate(request(for: job)).items.first
                guard !Task.isCancelled else { return }
                updateJobsQuietly(id) { $0.validation = item }
            }
        }
    }

    private func updateJobsQuietly(_ id: UUID, _ body: (inout DraftJob) -> Void) {
        modifyJobs([id], body)
    }

    // MARK: 开始批处理

    /// 开始批处理时的一个任务：当时的任务和导出请求（请求里有当时源图的色彩空间设置）。
    /// 校验和提交都用这一份；提交前与列表里现在的任务比较，校验之后改过的不提交旧内容。
    struct BatchEntry {
        var job: DraftJob
        /// 默认策略（加版本号）的请求。
        var request: ExportRequest
    }

    /// 「当前」里全部任务的快照。
    private func batchSnapshot() -> [BatchEntry] {
        allJobs.map { BatchEntry(job: $0, request: request(for: $0)) }
    }

    /// 底栏「开始批处理」：校验全部任务 → 目标目录已存在时请用户确认（D-49）→ 提交 → 开始派发。
    /// 没有新任务时只是继续暂停的队列。
    public func startBatch() async {
        // 校验、提交都要等后端；这期间再点一次（连按 ⌘↩）不重复提交。
        guard !isStartingBatch else { return }
        isStartingBatch = true
        defer { isStartingBatch = false }
        let batch = batchSnapshot()
        guard !batch.isEmpty else {
            await resumeQueue()
            return
        }
        guard let items = await validateForSubmit(batch, policy: .versionSuffix) else { return }
        let warned = zip(batch, items).filter { !$0.1.warnings.isEmpty }
        if !warned.isEmpty, settings.reviewsWarningsBeforeStart {
            warningPrompt = WarningPrompt(jobIds: warned.map(\.0.job.id), warningCount: warned.map(\.1.warnings.count).reduce(0, +))
            return
        }
        await confirmOverwritesAndSubmit(batch, items: items)
    }

    /// 用户对警告询问的回答。`dontAskAgain`：以后不再询问（设置里可以改回来）。
    public func resolveWarnings(_ choice: WarningChoice, dontAskAgain: Bool = false) async {
        guard let prompt = warningPrompt else { return }
        warningPrompt = nil
        if dontAskAgain, choice != .cancel { settings.reviewsWarningsBeforeStart = false }
        switch choice {
        case .cancel:
            return
        case .review:
            mode = .current
            // 右栏可能正在显示左栏的预设：选择没变时也要切回这个任务。
            if let first = prompt.jobIds.first { showInInspector([.job(first)]) }
        case .proceed:
            guard !isStartingBatch else { return }
            isStartingBatch = true
            defer { isStartingBatch = false }
            let batch = batchSnapshot()
            guard let items = await validateForSubmit(batch, policy: .versionSuffix) else { return }
            await confirmOverwritesAndSubmit(batch, items: items)
        }
    }

    /// 作品目录已存在时先确认（D-49），否则直接提交。
    private func confirmOverwritesAndSubmit(_ batch: [BatchEntry], items: [ValidationItem]) async {
        let conflicts: [OverwritePrompt.Conflict] = zip(batch, items).compactMap { entry, item in
            let job = entry.job
            guard let source = sourceItem(job.sourceId)?.source else { return nil }
            let name = job.naming.workName(source: source, preset: job.preset)
            guard item.directory.lastPathComponent != name else { return nil }
            return .init(jobId: job.id, directory: item.directory.deletingLastPathComponent().appending(path: name))
        }
        if conflicts.isEmpty {
            await submit(batch, overwriting: [])
        } else {
            overwritePrompt = OverwritePrompt(conflicts: conflicts)
        }
    }

    /// 用户对覆盖确认框的回答。
    public func resolveOverwrite(_ choice: OverwriteChoice) async {
        guard let prompt = overwritePrompt else { return }
        overwritePrompt = nil
        guard choice != .cancel, !isStartingBatch else { return }
        isStartingBatch = true
        defer { isStartingBatch = false }
        let batch = batchSnapshot()
        switch choice {
        case .cancel:
            return
        case .keepBoth:
            await submit(batch, overwriting: [])
        case .overwrite:
            let ids = Set(prompt.conflicts.map(\.jobId))
            let targets = batch.filter { ids.contains($0.job.id) }
            guard let items = await validateForSubmit(targets, policy: .overwrite) else { return }
            // 每个任务单独校验，同一批里的撞名在这里查。不区分大小写的卷（macOS 默认）上只差大小写的目录是同一个。
            let directories = items.map {
                OutputNaming.collisionKey(for: $0.directory, caseSensitive: OutputNaming.volumeIsCaseSensitive($0.directory))
            }
            guard Set(directories).count == directories.count else {
                alert = WorkbenchAlert(title: "无法覆盖", message: "有两个任务要覆盖同一个作品目录，请修改其中一个的位置或命名。")
                return
            }
            await submit(batch, overwriting: ids)
        }
    }

    /// 逐个校验；有错误时弹出提示并返回 nil。
    private func validateForSubmit(_ batch: [BatchEntry], policy: ConflictPolicy) async -> [ValidationItem]? {
        var items: [ValidationItem] = []
        var problems: [String] = []
        for entry in batch {
            do throws(ApplicationError) {
                guard let item = try await service.validate(entry.request.with(policy)).items.first else { continue }
                items.append(item)
                // 校验期间改过的任务不写这份结果（改动本身会重新校验）。
                if let live = job(entry.job.id), request(for: live) == entry.request {
                    updateJobsQuietly(entry.job.id) { $0.validation = item }
                }
                problems += item.errors.map { "\(item.sourceURL.lastPathComponent) · \(item.presetName)：\($0.message)" }
            } catch {
                problems.append(error.message)
            }
        }
        guard problems.isEmpty, items.count == batch.count else {
            alert = WorkbenchAlert(title: "无法开始批处理", message: problems.joined(separator: "\n"))
            return nil
        }
        return items
    }

    private func submit(_ batch: [BatchEntry], overwriting: Set<UUID>) async {
        let statuses = Dictionary(jobs.map { ($0.jobId, $0.status) }, uniquingKeysWith: { first, _ in first })
        if runJobIds.allSatisfy({ statuses[$0]?.isTerminal ?? true }) { runJobIds = [] }
        var submitted: [UUID: ExportRequest] = [:]
        await perform("提交任务失败") {
            for entry in batch {
                // 按列表里现在的任务提交：校验之后删掉的跳过；改过的（影响导出的内容变了）留在「当前」，不提交改动前的内容。
                guard let live = job(entry.job.id), request(for: live) == entry.request else { continue }
                let policy: ConflictPolicy = overwriting.contains(entry.job.id) ? .overwrite : .versionSuffix
                runJobIds += try await service.submit(entry.request.with(policy))
                submitted[entry.job.id] = entry.request
            }
        }
        // 已提交的任务离开「当前」，提交期间又改过的留下；任务都提交了的源图也一起移走（与 Compressor 提交批处理后清空一致）。
        let removed = Set(submitted.compactMap { id, request in job(id).map { self.request(for: $0) } == request ? id : nil })
        let emptied = Set(batch.filter { removed.contains($0.job.id) }.map(\.job.sourceId))
        for i in sources.indices where sources[i].jobs.contains(where: { removed.contains($0.id) }) {
            sources[i].jobs.removeAll { removed.contains($0.id) }
        }
        let sourceCount = sources.count
        sources.removeAll { $0.jobs.isEmpty && emptied.contains($0.id) }
        selection = selection.filter { item in
            if case .job(let id) = item { return !removed.contains(id) }
            if case .source(let id) = item { return sourceItem(id) != nil }
            return true
        }
        if sources.count != sourceCount { sourcesDidLeave() }
        await refreshJobs()
        await resumeQueue()
        // 与 Compressor 一致：提交后切到「活跃」看进度（D-108，设置里可关，D-114）。
        if !submitted.isEmpty, settings.switchesToActiveAfterStart { mode = .active }
    }
}

private extension ExportRequest {
    /// 同一个请求换一种作品目录冲突策略。
    func with(_ policy: ConflictPolicy) -> ExportRequest {
        var request = self
        request.destination.conflictPolicy = policy
        return request
    }
}
