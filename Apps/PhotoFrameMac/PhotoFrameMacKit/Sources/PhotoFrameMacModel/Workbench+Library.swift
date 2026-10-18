import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameStorage

// 左栏：预设、位置、素材（UI 设计文档第 7 节）。

extension Workbench {
    public func refreshLibrary() async {
        await perform("读取本地库失败") {
            let list = try await service.listPresets()
            presets = list.presets
            libraryWarnings = list.warnings
        }
        let assetList = await service.listAssets(category: nil)
        let bindingList = await service.listBindings()
        setLibrary(assets: assetList.assets, bindings: bindingList.bindings)
        libraryWarnings += assetList.warnings + bindingList.warnings
        if let id = selectedPresetId, !presets.contains(where: { $0.presetId == id }) { selectedPresetId = nil }
    }

    /// 换上读到的素材和绑定。素材 ID 或绑定真的变了时，预设本地 / 默认绑定的解析结果可能跟着变：
    /// 预览按新的内容渲染（不用缓存里的旧结果），全部任务重新校验。
    func setLibrary(assets newAssets: [AssetInfo]? = nil, bindings newBindings: [PersistedBinding]) {
        let assetsChanged = newAssets.map { Set($0.map(\.assetId)) != Set(assets.map(\.assetId)) } ?? false
        let bindingsChanged = Set(newBindings) != Set(bindings)
        if let newAssets { assets = newAssets }
        bindings = newBindings
        guard assetsChanged || bindingsChanged else { return }
        libraryRevision += 1
        scheduleValidation(allJobs.map(\.id))
        refreshPreview()
    }

    // MARK: 预设

    /// 某个分组的预设，已按 D-82 排好序。
    public func presets(in group: CatalogPresetOrigin) -> [CatalogPresetSummary] {
        presets.filter { $0.origin.kind == group.kind }
    }

    public func preset(_ id: UUID) -> CatalogPresetSummary? { presets.first { $0.presetId == id } }

    func reference(_ id: UUID) -> PresetReference { .library(id.uuidString) }

    /// 读取左栏选中的预设，在右栏编辑。`saved`：刚存储的草稿；存储期间又改过（草稿已经和它不同）时保留草稿，显示为未存储。
    func loadPresetEditor(saved: ExportPreset? = nil) {
        guard let id = selectedPresetId else {
            presetEditor = nil
            refreshPreview()
            return
        }
        background("presetEditor") { [self] in
            var loaded = false
            await perform("读取预设失败") {
                let entry = try await service.resolvePreset(reference(id))
                guard selectedPresetId == id else { return }
                var draft = entry.preset
                if let saved, let current = presetEditor?.draft, current.presetId == id, current != saved { draft = current }
                presetEditor = PresetEditor(entry: entry, draft: draft)
                loaded = true
            }
            // 读不到新选中的预设：不能留着上一个预设的编辑器，否则右栏显示的、「存储」写入的都是上一个预设。
            if !loaded, selectedPresetId == id, presetEditor?.entry.preset.presetId != id { presetEditor = nil }
            refreshPreview()
        }
    }

    /// 新建：以选中的预设（没有时用第一个内置预设）为底。
    public func newPreset(name: String = "新预设") async {
        guard let template = selectedPresetId ?? presets.first?.presetId else { return }
        await perform {
            let content = try await service.resolvePreset(reference(template)).preset
            let saved = try await service.savePreset(content, name: uniquePresetName(name))
            await refreshLibrary()
            selectedPresetId = saved.presetId
        }
    }

    public func duplicatePreset(_ id: UUID) async {
        await perform {
            let copy = try await service.duplicatePreset(reference(id), name: nil)
            await refreshLibrary()
            selectedPresetId = copy.presetId
        }
    }

    public func renamePreset(_ id: UUID, to name: String) async {
        await perform("无法重命名") {
            let renamed = try await service.renamePreset(reference(id), to: name)
            await refreshLibrary()
            // 右栏正在编辑这个预设：只改名字，不重新读取（重新读取会丢掉还没存储的修改）。
            if var editor = presetEditor, editor.entry.preset.presetId == id {
                editor.entry.preset.name = renamed.name
                editor.draft.name = renamed.name
                presetEditor = editor
                refreshPreview()
            }
        }
    }

    public func deletePreset(_ id: UUID) async {
        await perform("无法删除") {
            try await service.deletePreset(reference(id))
            if selectedPresetId == id { selectedPresetId = nil }
            await refreshLibrary()
        }
    }

    /// 在「用户保存」和「导入」之间移动（D-81、D-94）。
    public func movePreset(_ id: UUID, to group: PresetOrigin) async {
        await perform("无法移动") {
            _ = try await service.movePreset(reference(id), to: group)
            await refreshLibrary()
        }
    }

    public func importPresets(_ urls: [URL]) async {
        var notes: [String] = []
        for url in urls {
            await perform("无法导入 \(url.lastPathComponent)") {
                let result = try await service.importPreset(from: url, replace: false)
                if result.conflictResolution != nil { notes.append("「\(result.preset.name)」与已有预设 ID 相同，已另存为副本。") }
                notes += result.warnings.map(\.message)
            }
        }
        await refreshLibrary()
        if !notes.isEmpty, alert == nil { alert = WorkbenchAlert(title: "导入完成", message: notes.joined(separator: "\n")) }
    }

    /// 导出为 `.photoframe`。保存面板已经确认过替换，所以允许覆盖。
    public func exportPreset(_ id: UUID, to url: URL) async {
        await perform("无法导出") { try await service.exportPreset(reference(id), to: url, overwrite: true) }
    }

    /// 保存右栏对预设本身的修改。
    public func savePresetEdits() async {
        guard let editor = presetEditor, editor.isDirty, !editor.isReadOnly else { return }
        let saved = editor.draft
        await perform("无法保存预设") {
            _ = try await service.replacePreset(saved)
            await refreshLibrary()
            // 存储期间又改过的内容不能被重新读到的预设覆盖掉。
            loadPresetEditor(saved: saved)
        }
    }

    public func revertPresetEdits() {
        guard let editor = presetEditor else { return }
        presetEditor?.draft = editor.entry.preset
        refreshPreview()
    }

    func uniquePresetName(_ base: String) -> String {
        let names = Set(presets.map { $0.name.lowercased() })
        guard names.contains(base.lowercased()) else { return base }
        var n = 2
        while names.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: 素材

    public func assets(in category: AssetCategory) -> [AssetInfo] { assets.filter { $0.category == category } }

    public func importAssets(_ urls: [URL], category: AssetCategory) async {
        var notes: [String] = []
        for url in urls {
            await perform("无法导入 \(url.lastPathComponent)") {
                let result = try await service.importAsset(from: url, category: category, name: nil)
                if !result.duplicateOf.isEmpty { notes.append("「\(result.asset.displayName)」与库里已有的素材内容相同（D-88）。") }
                notes += result.warnings.map(\.message)
            }
        }
        await refreshLibrary()
        if !notes.isEmpty, alert == nil { alert = WorkbenchAlert(title: "导入完成", message: notes.joined(separator: "\n")) }
    }

    public func renameAsset(_ id: UUID, to name: String) async {
        await perform("无法重命名") {
            _ = try await service.renameAsset(id, to: name)
            await refreshLibrary()
        }
    }

    public func setAssetCategory(_ id: UUID, to category: AssetCategory) async {
        await perform {
            _ = try await service.setAssetCategory(id, to: category)
            await refreshLibrary()
        }
    }

    /// 删除素材；指向它的绑定保留，提示用户重新绑定（D-83）。
    public func deleteAsset(_ id: UUID) async {
        await perform("无法删除") {
            let affected = try await service.deleteAsset(id)
            await refreshLibrary()
            if !affected.isEmpty {
                alert = WorkbenchAlert(title: "素材已删除", message: "有 \(affected.count) 个绑定指向这个素材，导出时会回退到下一级绑定，请重新绑定。")
            }
        }
    }

    public func assetContentURL(_ id: UUID) async -> URL? { await service.assetContentURL(id) }

    // MARK: 位置

    public func addLocation(_ url: URL, name: String? = nil) {
        let location = ExportLocation(name: name ?? url.lastPathComponent, url: url)
        locations.locations.append(location)
        if locations.defaultId == nil { locations.defaultId = location.id }
        locationStore.save(locations)
    }

    public func renameLocation(_ id: UUID, to name: String) {
        guard let i = locations.locations.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        locations.locations[i].name = name
        locationStore.save(locations)
    }

    /// 删除位置不影响已经用它的任务（任务里存的是目录）。
    public func removeLocation(_ id: UUID) {
        locations.locations.removeAll { $0.id == id }
        if locations.defaultId == id { locations.defaultId = locations.locations.first?.id }
        locationStore.save(locations)
    }

    public func setDefaultLocation(_ id: UUID) {
        guard locations.locations.contains(where: { $0.id == id }) else { return }
        locations.defaultId = id
        locationStore.save(locations)
    }

    public func location(_ id: UUID) -> ExportLocation? { locations.locations.first { $0.id == id } }

    /// 任务目录对应的位置名称；不是任何位置时为 nil。
    public func locationName(for url: URL) -> String? {
        locations.locations.first { $0.url.standardizedFileURL == url.standardizedFileURL }?.name
    }
}
