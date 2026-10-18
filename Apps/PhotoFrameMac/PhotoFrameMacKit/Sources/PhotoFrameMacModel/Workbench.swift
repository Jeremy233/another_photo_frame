import Foundation
import Observation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameStorage

/// 主窗口的全部状态（UI 设计文档第 1–12 节）。
///
/// 只保存界面状态，所有业务操作都交给 ``PhotoFrameService``（D-13）：预设与素材库、源图检查、校验、预览、任务队列。
/// 「当前」界面里的任务是还没提交的草稿（``DraftJob``），点「开始批处理」才提交给服务。
@MainActor @Observable
public final class Workbench {
    public typealias Service = PhotoFrameService & PresetContentService

    let service: any Service
    let locationStore: any LocationStore
    let settingsStore: any SettingsStore

    /// ⌘, 设置（D-114）。修改即保存；调度参数立即交给任务队列。
    public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsStore.save(settings)
            if settings.effectiveMaxConcurrentJobs != oldValue.effectiveMaxConcurrentJobs
                || settings.effectiveMemoryBudgetBytes != oldValue.effectiveMemoryBudgetBytes {
                let previous = settingsTask
                settingsTask = Task { await previous?.value; await applySchedulingSettings() }
            }
        }
    }
    @ObservationIgnored var settingsTask: Task<Void, Never>?

    // MARK: 布局

    public var mode: WorkbenchMode = .current
    /// 左栏开关（⌃⌘S）。「活跃」「已完成」时左栏总是收起（与 Compressor 一致）。
    public var showsSidebar = true
    public var showsInspector = true
    public var sidebarTab: SidebarTab = .presets
    public var assetDisplay: AssetDisplayMode = .text
    public var inspectorTab: InspectorTab = .canvas
    /// 打开「添加图片」面板（底栏按钮、⌘O）。
    public var isAddingImages = false

    // MARK: 库

    public internal(set) var presets: [CatalogPresetSummary] = []
    public internal(set) var assets: [AssetInfo] = []
    public internal(set) var bindings: [PersistedBinding] = []
    /// 读库时跳过的损坏文件等（D-91）。
    public internal(set) var libraryWarnings: [ApplicationWarning] = []
    public internal(set) var locations = LocationList()
    /// 素材绑定或素材列表每变一次加一。预设本地绑定和默认绑定在渲染、校验时才解析，不在任务和预设的内容里，
    /// 预览内容带上它，变了就重新渲染（不用缓存里的旧结果），任务也重新校验。
    var libraryRevision = 0

    // MARK: 当前批次

    public internal(set) var sources: [SourceItem] = [] {
        didSet {
            // 源图离开批次或任务全部删掉后，不再记着它折起来（再加任务时是展开的）。
            if !collapsedSources.isEmpty {
                let kept = collapsedSources.filter { id in sources.contains { $0.id == id && !$0.jobs.isEmpty } }
                if kept != collapsedSources { collapsedSources = kept }
            }
        }
    }
    /// 任务列表的选择（可多选）。非空时右栏显示源图 / 任务。
    public var selection: Set<BatchItemID> = [] {
        didSet {
            guard selection != oldValue else { return }
            if !selection.isEmpty { focus = .batch }
            expandSelectedJobs()
            refreshPreview()
        }
    }
    /// 批次列表里折起来的源图：只显示头部，不显示它的任务。
    public internal(set) var collapsedSources: Set<SourceID> = []
    /// 左栏选中的预设。选中时右栏编辑预设本身。
    public var selectedPresetId: UUID? {
        didSet {
            guard selectedPresetId != oldValue else { return }
            if selectedPresetId != nil { focus = .preset }
            loadPresetEditor()
        }
    }
    /// 左栏选中的位置。选中时右栏显示位置属性。
    public var selectedLocationId: UUID? {
        didSet {
            guard selectedLocationId != oldValue, selectedLocationId != nil else { return }
            focus = .location
        }
    }
    public internal(set) var presetEditor: PresetEditor?
    /// 左栏预设还没存储的修改，按预设 ID。只在内存里：换选别的预设再回来时还在，退出 App 后丢掉，
    /// 内置预设下次启动就是出厂的定义（不写盘，也不改库里的预设）。
    public internal(set) var presetDrafts: [UUID: ExportPreset] = [:]
    var focus: Focus = .batch

    enum Focus { case batch, preset, location }

    /// 源图离开批次（移除、提交）之后调用，参数是还在批次里的源图文件。界面用它丢掉其他原图的解码缓存。
    @ObservationIgnored public var onSourcesRemoved: (@MainActor (Set<URL>) -> Void)?

    // MARK: 任务队列

    public internal(set) var jobs: [JobRecord] = []
    public internal(set) var isQueuePaused: Bool
    /// 「活跃」表格的选择。
    public var jobSelection: Set<JobID> = []
    /// 「已完成」表格的选择，与「活跃」分开：切换界面后顶栏按钮和详情只看这里选中的已结束任务。
    public var historySelection: Set<JobID> = []
    /// 最近一次批处理包含的任务，底栏进度按它计算。
    var runJobIds: [JobID] = []
    /// 已经应用的任务事件数。读任务列表期间有事件改过记录时，读到的快照可能比这些记录旧（见 `refreshJobs`）。
    @ObservationIgnored var appliedJobEvents = 0
    /// 「开始批处理」正在校验或提交：这期间再点一次（或连按 ⌘↩）不重复提交。
    @ObservationIgnored var isStartingBatch = false

    // MARK: 提示

    public var alert: WorkbenchAlert?
    public var overwritePrompt: OverwritePrompt?
    public var warningPrompt: WarningPrompt?

    public let preview: PreviewModel

    @ObservationIgnored var work: [String: BackgroundWork] = [:]
    @ObservationIgnored private var workCount = 0
    @ObservationIgnored var validationDelay: Duration

    /// - Parameters:
    ///   - queueStartsPaused: 服务创建时队列是否暂停（GUI 用 `startsPaused: true`，点「开始批处理」才派发）。
    ///   - debounce: 改参数后多久重新校验和预览；测试传 `.zero`。
    public init(
        service: any Service, locationStore: any LocationStore = UserDefaultsLocationStore(),
        settingsStore: any SettingsStore = UserDefaultsSettingsStore(),
        queueStartsPaused: Bool = true, debounce: Duration = .milliseconds(150)
    ) {
        self.service = service
        self.locationStore = locationStore
        self.settingsStore = settingsStore
        settings = settingsStore.load() ?? AppSettings()
        isQueuePaused = queueStartsPaused
        validationDelay = debounce
        preview = PreviewModel(service: service, debounce: debounce)
        locations = locationStore.load() ?? LocationList.initial()
    }

    /// 窗口出现时调用：读库和已有任务。
    public func load() async {
        await applySchedulingSettings()
        await refreshLibrary()
        await refreshJobs()
    }

    // MARK: - 右栏

    /// 右栏显示什么：最近一次点的是左栏预设还是任务列表（第 6 节）。
    public var inspectorSubject: InspectorSubject { inspected().subject }

    /// 右栏显示什么；显示任务时连同这些任务（按列表顺序）。右栏的每个控件都会读它，
    /// 所以只遍历一遍任务列表，不复制全部任务、也不逐个按 ID 查找。
    func inspected() -> (subject: InspectorSubject, jobs: [DraftJob]) {
        if focus == .preset, let id = selectedPresetId { return (.preset(id), []) }
        if focus == .location, let id = selectedLocationId, location(id) != nil { return (.location(id), []) }
        let jobs = selectedJobs()
        if !jobs.isEmpty { return (.jobs(jobs.map(\.id)), jobs) }
        if selection.count == 1, case .source(let id) = selection.first { return (.source(id), []) }
        return (.none, [])
    }

    /// 选中的任务，按列表顺序。选中源图时不包含它下面的任务。
    public var selectedJobIds: [UUID] { selectedJobs().map(\.id) }

    /// 选中的任务，按列表顺序（遍历一遍）。
    func selectedJobs() -> [DraftJob] {
        let sources = self.sources
        let selection = self.selection
        guard !selection.isEmpty else { return [] }
        var jobs: [DraftJob] = []
        for source in sources {
            for job in source.jobs where selection.contains(.job(job.id)) { jobs.append(job) }
        }
        return jobs
    }

    /// 右栏正在编辑的预设内容：选中的任务或预设。
    public var editedPresets: [ExportPreset] {
        let (subject, jobs) = inspected()
        switch subject {
        case .jobs: return jobs.map(\.preset)
        case .preset: return presetEditor.map { [$0.draft] } ?? []
        case .source, .location, .none: return []
        }
    }

    /// 只编辑一份预设时可以改图层；多选时只改共同字段（第 6 节）。
    public var editedPreset: ExportPreset? {
        let presets = editedPresets
        return presets.count == 1 ? presets[0] : nil
    }

    public var isInspectorEditable: Bool {
        switch inspectorSubject {
        case .jobs: true
        case .preset: presetEditor?.isReadOnly == false
        case .source, .location, .none: false
        }
    }

    /// 某个字段在右栏的值：多选且不同时为「多个值」。
    public func field<Value: Equatable>(_ path: KeyPath<ExportPreset, Value>) -> FieldValue<Value> {
        let values = editedPresets.map { $0[keyPath: path] }
        guard let first = values.first else { return .none }
        return values.allSatisfy { $0 == first } ? .single(first) : .mixed
    }

    public func setField<Value>(_ path: WritableKeyPath<ExportPreset, Value>, _ value: Value) {
        edit { $0[keyPath: path] = value }
    }

    /// 修改右栏正在编辑的全部预设（任务的副本，或左栏预设的草稿）。不自动写回库里的预设（§4.2）。
    public func edit(_ body: (inout ExportPreset) -> Void) {
        guard isInspectorEditable else { return }
        switch inspectorSubject {
        case .jobs(let ids):
            updateJobs(ids) { job in
                let slots = Set(job.preset.assetSlots.map(\.slotId))
                body(&job.preset)
                // 改动删掉的素材槽（删除图层、相机规则时）不再留单任务绑定，否则会一直警告绑定的槽没有被预设使用。
                for slotId in slots.subtracting(job.preset.assetSlots.map(\.slotId)) { job.assetBindings[slotId] = nil }
            }
        case .preset:
            guard var draft = presetEditor?.draft else { return }
            body(&draft)
            guard draft != presetEditor?.draft else { return }
            setPresetDraft(draft)
        case .source, .location, .none:
            break
        }
    }

    /// 选中任务列表里的这些项，并让右栏显示它们：选择没变、右栏却在显示左栏的预设或位置时，也切回任务列表。
    func showInInspector(_ items: Set<BatchItemID>) {
        selection = items
        focusBatch()
    }

    /// 点了任务列表里的行（包括仍然高亮的行）：右栏切回任务列表。选择没变时 `selection` 不会通知，所以由行的点击调用。
    public func focusBatch() {
        guard !selection.isEmpty, focus != .batch else { return }
        focus = .batch
        refreshPreview()
    }

    /// 点了左栏「预设」里的行（包括仍然选中的那一个）：右栏切到这个预设。
    public func focusPreset() {
        guard selectedPresetId != nil, focus != .preset else { return }
        focus = .preset
        refreshPreview()
    }

    /// 点了左栏「位置」里的行：右栏切到这个位置。
    public func focusLocation() {
        guard selectedLocationId != nil, focus != .location else { return }
        focus = .location
        refreshPreview()
    }

    // MARK: - 批次列表的折叠

    public func isCollapsed(_ id: SourceID) -> Bool { collapsedSources.contains(id) }

    /// 折起或展开一张源图的任务。没有任务的源图不折叠。
    public func setCollapsed(_ id: SourceID, _ collapsed: Bool) {
        if collapsed {
            guard let item = sourceItem(id), !item.jobs.isEmpty else { return }
            // 折起来之后选中的任务就看不见了：不再选中它们（⌫ 不会删掉看不见的东西）。
            let hidden = Set(item.jobs.map { BatchItemID.job($0.id) })
            collapsedSources.insert(id)
            if !selection.isDisjoint(with: hidden) { selection.subtract(hidden) }
        } else {
            collapsedSources.remove(id)
        }
    }

    /// 选中的任务所在的源图自动展开（例如新任务加到折起来的源图上）。
    private func expandSelectedJobs() {
        guard !collapsedSources.isEmpty else { return }
        let jobs = Set(selection.compactMap { if case .job(let id) = $0 { id } else { nil } })
        guard !jobs.isEmpty else { return }
        for source in sources where collapsedSources.contains(source.id) && source.jobs.contains(where: { jobs.contains($0.id) }) {
            collapsedSources.remove(source.id)
        }
    }

    // MARK: - 菜单命令的可用状态（与对应按钮相同）

    /// 底栏「开始批处理」和 ⌘↩：「当前」里有任务，或队列暂停着、还有没做完的任务。
    public var canStartBatch: Bool {
        sources.contains { !$0.jobs.isEmpty } || (isQueuePaused && activeCount > 0)
    }

    /// 预览只在「当前」里看得到：缩放命令、左栏开关只在这里可用（「活跃」「已完成」时左栏总是收起）。
    public var isPreviewVisible: Bool { mode == .current }
    public var canToggleSidebar: Bool { mode == .current }

    /// ⌘D「复制」：任务列表里选中的任务，或左栏选中的预设。
    public var canDuplicate: Bool {
        guard mode == .current else { return false }
        switch focus {
        case .batch: return !selectedJobIds.isEmpty
        case .preset: return selectedPresetId != nil
        case .location: return false
        }
    }

    public func duplicateFocused() async {
        guard canDuplicate else { return }
        switch focus {
        case .batch: duplicateSelectedJobs()
        case .preset: if let id = selectedPresetId { await duplicatePreset(id) }
        case .location: break
        }
    }

    // MARK: - 内部工具

    var allJobs: [DraftJob] { sources.flatMap(\.jobs) }

    public func job(_ id: UUID) -> DraftJob? {
        for source in sources {
            if let job = source.jobs.first(where: { $0.id == id }) { return job }
        }
        return nil
    }

    public func sourceItem(_ id: SourceID) -> SourceItem? { sources.first { $0.id == id } }

    /// 修改这些任务，然后重新校验改了的任务、刷新预览。
    func updateJobs(_ ids: [UUID], _ body: (inout DraftJob) -> Void) {
        scheduleValidation(modifyJobs(Set(ids), body))
        refreshPreview()
    }

    /// 修改这些任务，只写回真的变了的（原地修改总会通知所有观察者，值没变也一样），返回变了的任务。
    @discardableResult
    func modifyJobs(_ ids: Set<UUID>, _ body: (inout DraftJob) -> Void) -> [UUID] {
        var changes: [(source: Int, index: Int, job: DraftJob)] = []
        for (s, item) in sources.enumerated() {
            for (j, old) in item.jobs.enumerated() where ids.contains(old.id) {
                var job = old
                body(&job)
                if job != old { changes.append((s, j, job)) }
            }
        }
        for change in changes { sources[change.source].jobs[change.index] = change.job }
        return changes.map(\.job.id)
    }

    /// 有源图离开批次（移除、提交）之后，丢掉只与它们有关的缓存：预览的渲染结果、界面的原图解码。
    func sourcesDidLeave() {
        preview.retainRenders(for: Set(sources.map(\.id)))
        onSourcesRemoved?(Set(sources.map(\.source.fileURL)))
    }

    /// 后台工作。同一个 key 只留最新的一个（防抖）。
    struct BackgroundWork {
        var id: Int
        var task: Task<Void, Never>
    }

    /// 在后台执行；同一个 key 的旧任务先取消（防抖）。做完后从 `work` 里移除，字典不会越积越多。
    func background(_ key: String, _ body: @escaping @MainActor () async -> Void) {
        work[key]?.task.cancel()
        workCount += 1
        let id = workCount
        let task = Task { [self] in
            await body()
            // 已经被同一个 key 的新任务替换时，由新任务负责。
            if work[key]?.id == id { work[key] = nil }
        }
        work[key] = BackgroundWork(id: id, task: task)
    }

    /// 等所有后台工作完成（测试用）。
    public func settle() async {
        while let (key, entry) = work.first {
            await entry.task.value
            if work[key]?.id == entry.id { work[key] = nil }
        }
        await settingsTask?.value
        await preview.settle()
    }

    /// 执行服务调用，失败时弹出提示。标题统一写「无法 + 动作」，与按钮上的动词一致。
    func perform(_ title: String, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch let error as ApplicationError {
            alert = WorkbenchAlert(error, title: title)
        } catch is CancellationError {
        } catch {
            alert = WorkbenchAlert(title: title, message: "\(error)")
        }
    }

    /// 执行服务调用，失败时不弹窗、返回错误（批量操作收集起来一次提示）。
    func attempt(_ body: () async throws -> Void) async -> ApplicationError? {
        do {
            try await body()
            return nil
        } catch let error as ApplicationError {
            return error
        } catch is CancellationError {
            return nil
        } catch {
            return ApplicationError(code: "unknown", message: "\(error)")
        }
    }
}

/// 左栏选中的预设正在右栏编辑。
public struct PresetEditor: Equatable, Sendable {
    public var entry: CatalogPreset
    public var draft: ExportPreset

    /// 只有直接打开的预设文件只读。内置预设也可以改，但改动只留在内存里，要存储就另存为用户预设（不改出厂的定义）。
    public var isReadOnly: Bool {
        if case .file = entry.origin { true } else { false }
    }

    public var isBuiltIn: Bool { entry.origin == .builtIn }

    public var isDirty: Bool { draft != entry.preset }
}
