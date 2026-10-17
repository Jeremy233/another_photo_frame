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
    var settingsTask: Task<Void, Never>?

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

    // MARK: 当前批次

    public internal(set) var sources: [SourceItem] = []
    /// 任务列表的选择（可多选）。非空时右栏显示源图 / 任务。
    public var selection: Set<BatchItemID> = [] {
        didSet {
            guard selection != oldValue else { return }
            if !selection.isEmpty { focus = .batch }
            refreshPreview()
        }
    }
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
    var focus: Focus = .batch

    enum Focus { case batch, preset, location }

    // MARK: 任务队列

    public internal(set) var jobs: [JobRecord] = []
    public internal(set) var isQueuePaused: Bool
    public var jobSelection: Set<JobID> = []
    /// 最近一次批处理包含的任务，底栏进度按它计算。
    var runJobIds: [JobID] = []

    // MARK: 提示

    public var alert: WorkbenchAlert?
    public var overwritePrompt: OverwritePrompt?
    public var warningPrompt: WarningPrompt?

    public let preview: PreviewModel

    var work: [String: Task<Void, Never>] = [:]
    var validationDelay: Duration

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
    public var inspectorSubject: InspectorSubject {
        if focus == .preset, let id = selectedPresetId { return .preset(id) }
        if focus == .location, let id = selectedLocationId, location(id) != nil { return .location(id) }
        let jobIds = selectedJobIds
        if !jobIds.isEmpty { return .jobs(jobIds) }
        if selection.count == 1, case .source(let id) = selection.first { return .source(id) }
        return .none
    }

    /// 选中的任务，按列表顺序。选中源图时不包含它下面的任务。
    public var selectedJobIds: [UUID] {
        allJobs.map(\.id).filter { selection.contains(.job($0)) }
    }

    /// 右栏正在编辑的预设内容：选中的任务或预设。
    public var editedPresets: [ExportPreset] {
        switch inspectorSubject {
        case .jobs(let ids): ids.compactMap { job($0)?.preset }
        case .preset: presetEditor.map { [$0.draft] } ?? []
        case .source, .location, .none: []
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
            updateJobs(ids) { body(&$0.preset) }
        case .preset:
            if var draft = presetEditor?.draft {
                body(&draft)
                presetEditor?.draft = draft
                refreshPreview()
            }
        case .source, .location, .none:
            break
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

    /// 修改这些任务，然后重新校验、刷新预览。
    func updateJobs(_ ids: [UUID], _ body: (inout DraftJob) -> Void) {
        let set = Set(ids)
        for s in sources.indices {
            for j in sources[s].jobs.indices where set.contains(sources[s].jobs[j].id) {
                body(&sources[s].jobs[j])
            }
        }
        scheduleValidation(ids)
        refreshPreview()
    }

    /// 在后台执行；同一个 key 的旧任务先取消（防抖）。
    func background(_ key: String, _ body: @escaping @MainActor () async -> Void) {
        work[key]?.cancel()
        work[key] = Task { await body() }
    }

    /// 等所有后台工作完成（测试用）。
    public func settle() async {
        while let (key, task) = work.first {
            await task.value
            if work[key] == task { work[key] = nil }
        }
        await settingsTask?.value
        await preview.settle()
    }

    /// 执行服务调用，失败时弹出提示。
    func perform(_ title: String = "操作失败", _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch let error as ApplicationError {
            alert = WorkbenchAlert(error, title: title)
        } catch is CancellationError {
        } catch {
            alert = WorkbenchAlert(title: title, message: "\(error)")
        }
    }
}

/// 左栏选中的预设正在右栏编辑。
public struct PresetEditor: Equatable, Sendable {
    public var entry: CatalogPreset
    public var draft: ExportPreset

    /// 内置预设只读，要先复制（D-81）。
    public var isReadOnly: Bool {
        switch entry.origin {
        case .builtIn, .file: true
        case .user, .imported: false
        }
    }

    public var isDirty: Bool { draft != entry.preset }
}
