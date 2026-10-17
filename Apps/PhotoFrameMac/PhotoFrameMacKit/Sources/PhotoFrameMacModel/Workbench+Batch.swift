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
        }
    }

    /// 没有 ICC 的源图按什么色彩空间解释（D-04）。
    public func setColorOverride(_ value: SourceColorOverride?, for id: SourceID) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
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
        sources.map(\.id).filter { id in
            selection.contains(.source(id)) || sourceItem(id)?.jobs.contains { selection.contains(.job($0.id)) } == true
        }
    }

    /// 删除选中的源图（连同它的任务）和任务。
    public func removeSelection() {
        sources.removeAll { selection.contains(.source($0.id)) }
        for i in sources.indices { sources[i].jobs.removeAll { selection.contains(.job($0.id)) } }
        selection = []
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
        let values = selectedJobIds.compactMap(job).map { $0[keyPath: path] }
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
        switch inspectorSubject {
        case .jobs(let ids):
            let jobs = ids.compactMap(job)
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
                bindings = await service.listBindings().bindings
                refreshPreview()
            }
        case .source, .location, .none:
            break
        }
    }

    // MARK: 存储为预设

    /// 把选中任务改过的参数存成新的用户预设（§4.2 `Save as Preset`）。任务改为基于新预设。
    public func saveSelectedJobAsPreset(name: String) async {
        guard let id = selectedJobIds.first, let job = job(id) else { return }
        await perform("无法存储为预设") {
            let saved = try await service.savePreset(job.preset, name: name)
            let stored = try await service.resolvePreset(reference(saved.presetId)).preset
            updateJobs([id]) {
                $0.basePreset = stored
                $0.preset = stored
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
        for s in sources.indices {
            if let j = sources[s].jobs.firstIndex(where: { $0.id == id }) { body(&sources[s].jobs[j]) }
        }
    }

    // MARK: 开始批处理

    /// 底栏「开始批处理」：校验全部任务 → 目标目录已存在时请用户确认（D-49）→ 提交 → 开始派发。
    /// 没有新任务时只是继续暂停的队列。
    public func startBatch() async {
        let drafts = allJobs
        guard !drafts.isEmpty else {
            await resumeQueue()
            return
        }
        guard let items = await validateForSubmit(drafts, policy: .versionSuffix) else { return }
        let warned = zip(drafts, items).filter { !$0.1.warnings.isEmpty }
        if !warned.isEmpty, settings.reviewsWarningsBeforeStart {
            warningPrompt = WarningPrompt(jobIds: warned.map(\.0.id), warningCount: warned.map(\.1.warnings.count).reduce(0, +))
            return
        }
        await confirmOverwritesAndSubmit(drafts, items: items)
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
            if let first = prompt.jobIds.first { selection = [.job(first)] }
        case .proceed:
            let drafts = allJobs
            guard let items = await validateForSubmit(drafts, policy: .versionSuffix) else { return }
            await confirmOverwritesAndSubmit(drafts, items: items)
        }
    }

    /// 作品目录已存在时先确认（D-49），否则直接提交。
    private func confirmOverwritesAndSubmit(_ drafts: [DraftJob], items: [ValidationItem]) async {
        let conflicts: [OverwritePrompt.Conflict] = zip(drafts, items).compactMap { job, item in
            guard let source = sourceItem(job.sourceId)?.source else { return nil }
            let name = job.naming.workName(source: source, preset: job.preset)
            guard item.directory.lastPathComponent != name else { return nil }
            return .init(jobId: job.id, directory: item.directory.deletingLastPathComponent().appending(path: name))
        }
        if conflicts.isEmpty {
            await submit(drafts, overwriting: [])
        } else {
            overwritePrompt = OverwritePrompt(conflicts: conflicts)
        }
    }

    /// 用户对覆盖确认框的回答。
    public func resolveOverwrite(_ choice: OverwriteChoice) async {
        guard let prompt = overwritePrompt else { return }
        overwritePrompt = nil
        let drafts = allJobs
        switch choice {
        case .cancel:
            return
        case .keepBoth:
            await submit(drafts, overwriting: [])
        case .overwrite:
            let ids = Set(prompt.conflicts.map(\.jobId))
            let targets = drafts.filter { ids.contains($0.id) }
            guard let items = await validateForSubmit(targets, policy: .overwrite) else { return }
            let directories = items.map(\.directory.path)
            guard Set(directories).count == directories.count else {
                alert = WorkbenchAlert(title: "无法覆盖", message: "有两个任务要覆盖同一个作品目录，请修改其中一个的位置或命名。")
                return
            }
            await submit(drafts, overwriting: ids)
        }
    }

    /// 逐个校验；有错误时弹出提示并返回 nil。
    private func validateForSubmit(_ drafts: [DraftJob], policy: ConflictPolicy) async -> [ValidationItem]? {
        var items: [ValidationItem] = []
        var problems: [String] = []
        for job in drafts {
            do throws(ApplicationError) {
                guard let item = try await service.validate(request(for: job, policy: policy)).items.first else { continue }
                items.append(item)
                updateJobsQuietly(job.id) { $0.validation = item }
                problems += item.errors.map { "\(item.sourceURL.lastPathComponent) · \(item.presetName)：\($0.message)" }
            } catch {
                problems.append(error.message)
            }
        }
        guard problems.isEmpty, items.count == drafts.count else {
            alert = WorkbenchAlert(title: "无法开始批处理", message: problems.joined(separator: "\n"))
            return nil
        }
        return items
    }

    private func submit(_ drafts: [DraftJob], overwriting: Set<UUID>) async {
        if runJobIds.allSatisfy({ id in jobs.first { $0.jobId == id }?.status.isTerminal ?? true }) { runJobIds = [] }
        var submitted: Set<UUID> = []
        await perform("提交任务失败") {
            for job in drafts {
                let ids = try await service.submit(request(for: job, policy: overwriting.contains(job.id) ? .overwrite : .versionSuffix))
                runJobIds += ids
                submitted.insert(job.id)
            }
        }
        // 已提交的任务离开「当前」；任务都提交了的源图也一起移走（与 Compressor 提交批处理后清空一致）。
        let emptied = Set(drafts.filter { submitted.contains($0.id) }.map(\.sourceId))
        for i in sources.indices { sources[i].jobs.removeAll { submitted.contains($0.id) } }
        sources.removeAll { $0.jobs.isEmpty && emptied.contains($0.id) }
        selection = selection.filter { item in
            if case .job(let id) = item { return !submitted.contains(id) }
            if case .source(let id) = item { return sourceItem(id) != nil }
            return true
        }
        await refreshJobs()
        await resumeQueue()
        // 与 Compressor 一致：提交后切到「活跃」看进度（D-108，设置里可关，D-114）。
        if !submitted.isEmpty, settings.switchesToActiveAfterStart { mode = .active }
    }
}
