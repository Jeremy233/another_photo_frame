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
        var found: [PhotoSource] = []
        var failures: [String] = []
        for url in urls {
            do throws(ApplicationError) {
                found.append(try await service.addSource(url))
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.displayText)")
            }
        }
        // 一次加进批次：一步撤销。已经在批次里的跳过。
        var added: [SourceID] = []
        undoable("添加图片") {
            for source in found where sourceItem(source.sourceId) == nil {
                sources.append(SourceItem(source: source, jobs: []))
                added.append(source.sourceId)
            }
        }
        for id in added { inspect(id) }
        // 右栏在编辑左栏的预设、批次原来是空的时，预览要用刚加入的源图。
        if !added.isEmpty { refreshPreview() }
        if !failures.isEmpty { alert = WorkbenchAlert(title: "有图片没有添加", message: WorkbenchAlert.paragraph(failures)) }
        return added
    }

    func inspect(_ id: SourceID) {
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
        undoable("更改色彩空间") { sources[i].colorOverride = value }
        scheduleValidation(sources[i].jobs.map(\.id))
        refreshPreview()
    }

    // MARK: 任务草稿

    /// 为这些源图各创建一个任务（把预设拖到源图上，或按钮）。
    public func addJobs(preset presetId: UUID, to sourceIds: [SourceID]) async {
        guard !sourceIds.isEmpty else { return }
        guard let destination = locations.defaultLocation?.url else {
            alert = WorkbenchAlert(title: "无法添加任务", message: "没有输出位置：请先在左栏「位置」里添加一个。")
            return
        }
        await perform("无法添加任务") {
            let preset = try await presetContent(presetId)
            var created: [UUID] = []
            undoable("添加任务") {
                for id in sourceIds {
                    guard let i = sources.firstIndex(where: { $0.id == id }) else { continue }
                    let job = DraftJob(sourceId: id, preset: preset, destination: destination)
                    sources[i].jobs.append(job)
                    created.append(job.id)
                }
            }
            scheduleValidation(created)
            if let last = created.last { selection = [.job(last)] }
        }
    }

    /// 把预设应用到这些行（拖到行上、任务列表有选择时点左栏的预设）：源图各建一个用这个预设的任务；
    /// 任务换成这个预设（位置、命名不变）。源图和它下面的任务都在里面时只给源图建任务，不再改它的任务。
    /// 做完后选中这些任务，右栏和预览显示它们（预览显示第一个），之后的修改作用于全部。
    public func applyPreset(_ presetId: UUID, to items: Set<BatchItemID>) async {
        let sourceIds = sources.map(\.id).filter { items.contains(.source($0)) }
        let replaced = Set(sources.flatMap { item in
            items.contains(.source(item.id)) ? [] : item.jobs.filter { items.contains(.job($0.id)) }.map(\.id)
        })
        guard !sourceIds.isEmpty || !replaced.isEmpty else { return }
        let destination = locations.defaultLocation?.url
        if !sourceIds.isEmpty, destination == nil {
            alert = WorkbenchAlert(title: "无法添加任务", message: "没有输出位置：请先在左栏「位置」里添加一个。")
            return
        }
        await perform("无法应用预设") {
            let preset = try await presetContent(presetId)
            var created: [UUID] = []
            undoable("应用预设") {
                for id in sourceIds {
                    guard let i = sources.firstIndex(where: { $0.id == id }), let destination else { continue }
                    let job = DraftJob(sourceId: id, preset: preset, destination: destination)
                    sources[i].jobs.append(job)
                    created.append(job.id)
                }
                modifyJobs(replaced) { job in
                    job.basePreset = preset
                    job.preset = preset
                    // 新预设没有的素材槽不再留单任务绑定。
                    let slots = Set(preset.assetSlots.map(\.slotId))
                    job.assetBindings = job.assetBindings.filter { slots.contains($0.key) }
                }
            }
            // 读预设期间移除了的任务不再选中。
            let affected = Set(created).union(replaced.filter { job($0) != nil })
            scheduleValidation(Array(affected))
            showInInspector(Set(affected.map(BatchItemID.job)))
            refreshPreview()
        }
    }

    /// 任务列表有选中的行、右栏正显示它们时，点左栏的预设直接应用到选中的行，不用再拖（左栏的选择不变）。
    /// 要编辑左栏的预设本身，先取消任务列表的选择。
    public var appliesPresetOnClick: Bool { mode == .current && focus == .batch && !selection.isEmpty }

    /// 点了左栏「预设」里的一行（包括仍然选中的那一个）。
    public func clickPreset(_ id: UUID) async {
        if appliesPresetOnClick {
            await applyPreset(id, to: selection)
        } else {
            focusPreset()
        }
    }

    /// 左栏预设列表的选择变了（点按、方向键）。应用到任务列表时由 ``clickPreset(_:)`` 处理，左栏的选择不变。
    public func choosePreset(_ id: UUID?) {
        guard !appliesPresetOnClick else { return }
        selectedPresetId = id
    }

    /// 任务列表从上到下看得到的行：每张源图，后面是它的任务（折起来的源图不含任务）。
    public var visibleItems: [BatchItemID] {
        sources.flatMap { item in
            [BatchItemID.source(item.id)] + (isCollapsed(item.id) ? [] : item.jobs.map { .job($0.id) })
        }
    }

    /// ⌘A：选中任务列表里看得到的全部行（全部源图和它们的任务）。
    public func selectAll() {
        guard mode == .current, !sources.isEmpty else { return }
        showInInspector(Set(visibleItems))
    }

    /// 选中的源图（选中任务时取它所属的源图）；工具栏「应用预设」用。
    public var targetSourceIds: [SourceID] {
        let selection = self.selection
        return sources.compactMap { item in
            selection.contains(.source(item.id)) || item.jobs.contains { selection.contains(.job($0.id)) } ? item.id : nil
        }
    }

    /// 从批次里移除这些源图（连同它们的任务）和任务（右键菜单作用于右键点到的行，⌫ 作用于选择）。不删文件。
    public func remove(_ items: Set<BatchItemID>) {
        guard !items.isEmpty else { return }
        let sourceCount = sources.count
        undoable("移除") {
            sources.removeAll { items.contains(.source($0.id)) }
            for i in sources.indices where sources[i].jobs.contains(where: { items.contains(.job($0.id)) }) {
                sources[i].jobs.removeAll { items.contains(.job($0.id)) }
            }
        }
        // 没被移除的仍然选中。
        selection = selection.filter { item in
            switch item {
            case .source(let id): sourceItem(id) != nil
            case .job(let id): job(id) != nil
            }
        }
        if sources.count != sourceCount { sourcesDidLeave() }
    }

    /// 移除选中的源图和任务（⌫）。
    public func removeSelection() {
        remove(selection)
    }

    /// 这些行涉及的任务，按列表顺序：选中的任务，加上选中的源图下面的全部任务。
    public func jobIds(in items: Set<BatchItemID>) -> [UUID] {
        sources.flatMap { item in
            item.jobs.filter { items.contains(.source(item.id)) || items.contains(.job($0.id)) }.map(\.id)
        }
    }

    /// 复制这些任务（第 10 节），选中复制出来的任务。
    public func duplicateJobs(_ ids: Set<UUID>) {
        var created: [UUID] = []
        undoable("复制任务") {
            for s in sources.indices {
                for job in sources[s].jobs where ids.contains(job.id) {
                    var copy = job
                    copy.id = UUID()
                    sources[s].jobs.append(copy)
                    created.append(copy.id)
                }
            }
        }
        guard !created.isEmpty else { return }
        scheduleValidation(created)
        selection = Set(created.map(BatchItemID.job))
    }

    /// 复制选中的任务（⌘D）。
    public func duplicateSelectedJobs() {
        duplicateJobs(Set(selectedJobIds))
    }

    /// 改这些行的输出位置：任务本身，以及源图下面的全部任务（右键菜单「位置」、把位置拖到行上）。
    public func setDestination(_ url: URL, for items: Set<BatchItemID>) {
        undoable("更改位置") { updateJobs(jobIds(in: items)) { $0.destination = url } }
    }

    /// 拖放或菜单作用于哪些行：落在选中的行上时是全部选中的行（§4.2：拖到多选中的一项等于拖到全部），否则只是这一行。
    public func targets(for item: BatchItemID) -> Set<BatchItemID> {
        selection.contains(item) ? selection : [item]
    }

    /// 用预设给源图创建任务（把预设拖到源图上，或源图头部的「添加」菜单）：
    /// 这张源图是选中的源图之一时，给全部选中的源图各建一个（与拖放一致）。
    public func addJobs(preset presetId: UUID, onto sourceId: SourceID) async {
        let targets = targetSourceIds.contains(sourceId) ? targetSourceIds : [sourceId]
        await addJobs(preset: presetId, to: targets)
    }

    /// 右栏「输出」改选中任务的位置。
    public func setDestinationForSelection(_ url: URL) {
        undoable("更改位置") { updateJobs(selectedJobIds) { $0.destination = url } }
    }

    /// 右栏「输出」改选中任务的作品目录命名模板（§9.2）。
    public func setNamingTemplate(_ template: String) {
        undoable("更改作品目录命名") { updateJobs(selectedJobIds) { $0.naming.workNameTemplate = template } }
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
            switch item {
            case .source(let s): guard sourceItem(s) != nil else { return false }
            case .job(let j): guard job(j) != nil else { return false }
            }
            // 拖到选中的行之一时，对全部选中的行生效（§4.2）。
            await applyPreset(id, to: targets(for: item))
            return true
        case .location(let id):
            guard let location = location(id) else { return false }
            setDestination(location.url, for: targets(for: item))
            return true
        case .asset:
            return false
        }
    }

    /// 从 Finder 拖入文件；拖到某张源图上的图片同样作为新源图加入。不支持的文件（例如 HEIC）与「添加图片」一样汇总提示。
    /// 返回是否有可以加入的图片。
    public func dropFiles(_ urls: [URL]) async -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        await addSources(files)
        return files.contains { PhotoSource.supportedExtensions.contains($0.pathExtension.lowercased()) }
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
            undoable("绑定素材") { updateJobs(ids) { $0.assetBindings[slotId] = assetId } }
        case .preset(let id):
            // 预设本地绑定存在库里、只认已存储的素材槽：新加的图层要先存储预设。
            if let editor = presetEditor, !editor.entry.preset.assetSlots.contains(where: { $0.slotId == slotId }) {
                alert = WorkbenchAlert(title: "无法绑定素材", message: "这个图层还没有存储：先点「存储」存储预设，再给新图层绑定素材。")
                return
            }
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
        guard let id = selectedJobIds.first else { return }
        await saveJobAsPreset(id, name: name)
    }

    /// 把这个任务改过的参数存成新的用户预设（右键菜单作用于右键点到的任务）。
    public func saveJobAsPreset(_ id: UUID, name: String) async {
        guard let job = job(id) else { return }
        let content = job.preset
        await perform("无法存储为预设") {
            let saved = try await service.savePreset(content, name: name)
            let stored = try await service.resolvePreset(reference(saved.presetId)).preset
            // 不复制本地绑定的话任务的成品会变（例如签名不见了）。
            await copyPresetBindings(from: content.presetId, to: saved.presetId)
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
                problems += item.errors.map { "\(item.sourceURL.lastPathComponent) · \(item.presetName)：\($0.displayText)" }
            } catch {
                problems.append(error.displayText)
            }
        }
        guard problems.isEmpty, items.count == batch.count else {
            alert = WorkbenchAlert(title: "无法开始批处理", message: WorkbenchAlert.paragraph(problems))
            return nil
        }
        return items
    }

    private func submit(_ batch: [BatchEntry], overwriting: Set<UUID>) async {
        let statuses = Dictionary(jobs.map { ($0.jobId, $0.status) }, uniquingKeysWith: { first, _ in first })
        if runJobIds.allSatisfy({ statuses[$0]?.isTerminal ?? true }) { runJobIds = [] }
        var submitted: [UUID: ExportRequest] = [:]
        await perform("无法提交任务") {
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
        // 已提交的任务不能再被撤销回「当前」。
        if !submitted.isEmpty { clearUndoHistory() }
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
