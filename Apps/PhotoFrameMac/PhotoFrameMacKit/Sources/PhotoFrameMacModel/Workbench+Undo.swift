import Foundation
import PhotoFrameApplication
import PhotoFrameCore

// 撤销 / 重做（⌘Z / ⇧⌘Z）：「当前」里的改动——改参数、应用预设、添加图片、添加 / 复制 / 移除任务、改位置。
// 用窗口的 UndoManager（与输入框的撤销在同一个栈里）。库里的操作（存储、删除预设，素材）和开始批处理不能撤销，
// 开始批处理后清空撤销记录：已提交的任务不会被撤销回「当前」。

extension Workbench {
    /// 一次操作前后的状态：「当前」的源图和任务、左栏预设的草稿，以及当时右栏在看什么（撤销后回到那里）。
    struct UndoState: Sendable {
        var sources: [SourceItem]
        var presetDrafts: [UUID: ExportPreset]
        var selection: Set<BatchItemID>
        var selectedPresetId: UUID?
        var focus: Focus

        /// 用户改的内容一样：不看源图检查、任务校验的结果（它们在后台陆续到达，不是用户的改动），也不看选择。
        func hasSameContent(as other: UndoState) -> Bool {
            presetDrafts == other.presetDrafts && Self.content(sources) == Self.content(other.sources)
        }

        static func content(_ sources: [SourceItem]) -> [SourceItem] {
            sources.map { item in
                var item = item
                item.inspection = nil
                item.inspectionError = nil
                for j in item.jobs.indices { item.jobs[j].validation = nil }
                return item
            }
        }
    }

    func undoState() -> UndoState {
        UndoState(sources: sources, presetDrafts: presetDrafts, selection: selection, selectedPresetId: selectedPresetId, focus: focus)
    }

    /// 执行一个可以撤销的操作，Edit 菜单里显示为「撤销 + `name`」。
    /// - Parameter key: 连续的同一种修改（同一个字段，间隔不到 1 秒，例如拖颜色面板）合成一步。
    func undoable(_ name: String, coalescing key: AnyHashable? = nil, _ body: () -> Void) {
        // 嵌套的操作（例如「应用预设」里改任务）、拖动滑块的过程中：算在外面那一步里。
        guard undoNesting == 0, continuousEditStart == nil else {
            body()
            return
        }
        let before = undoState()
        undoNesting += 1
        body()
        undoNesting -= 1
        registerUndo(name, before: before, key: key)
    }

    /// 开始拖动滑块：直到 ``endContinuousEdit(_:)`` 的全部修改合成一步撤销。
    public func beginContinuousEdit() {
        guard continuousEditStart == nil else { return }
        continuousEditStart = undoState()
    }

    public func endContinuousEdit(_ name: String = "修改参数") {
        guard let before = continuousEditStart else { return }
        continuousEditStart = nil
        registerUndo(name, before: before, key: nil)
    }

    /// 已提交的任务、源图离开了「当前」：之前的撤销记录不再适用。
    func clearUndoHistory() {
        undoManager?.removeAllActions(withTarget: self)
        lastUndo = nil
    }

    private func registerUndo(_ name: String, before: UndoState, key: AnyHashable?) {
        guard let undoManager, !undoManager.isUndoing, !undoManager.isRedoing, !before.hasSameContent(as: undoState()) else { return }
        let now = ContinuousClock.now
        if let key, let last = lastUndo, last.key == key, now - last.time < .seconds(1),
           undoManager.canUndo, undoManager.undoActionName == name {
            // 上一步撤销回到这一串修改之前的状态，不用再记一步。
            lastUndo?.time = now
            return
        }
        // 测试里 UndoManager 不按事件自动分组：自己开一组。
        let explicit = !undoManager.groupsByEvent
        if explicit { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { workbench in
            MainActor.assumeIsolated { workbench.restore(before, name: name) }
        }
        undoManager.setActionName(name)
        if explicit { undoManager.endUndoGrouping() }
        lastUndo = key.map { (key: $0, time: now) }
    }

    /// 撤销或重做：回到 `state`，并登记反方向的一步。
    private func restore(_ state: UndoState, name: String) {
        let current = undoState()
        apply(state)
        undoManager?.registerUndo(withTarget: self) { workbench in
            MainActor.assumeIsolated { workbench.restore(current, name: name) }
        }
        undoManager?.setActionName(name)
        lastUndo = nil
    }

    /// 换上撤销记录里的状态。源图检查、任务校验的结果用现在的（记录里的可能还没到或已经过时），
    /// 内容变了的任务重新校验，还没检查过的源图重新检查。
    private func apply(_ state: UndoState) {
        let liveSources = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveJobs = Dictionary(allJobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var restored = state.sources
        var revalidate: [UUID] = []
        var reinspect: [SourceID] = []
        for s in restored.indices {
            let live = liveSources[restored[s].id]
            if let live {
                restored[s].inspection = live.inspection
                restored[s].inspectionError = live.inspectionError
            } else if restored[s].inspection == nil, restored[s].inspectionError == nil {
                reinspect.append(restored[s].id)
            }
            for j in restored[s].jobs.indices {
                var job = restored[s].jobs[j]
                if let old = liveJobs[job.id], live?.colorOverride == restored[s].colorOverride {
                    job.validation = old.validation
                    var unvalidated = old
                    unvalidated.validation = nil
                    var mine = job
                    mine.validation = nil
                    if unvalidated != mine { revalidate.append(job.id) }
                } else {
                    revalidate.append(job.id)
                }
                restored[s].jobs[j] = job
            }
        }
        let left = !Set(liveSources.keys).isSubset(of: restored.map(\.id))
        sources = restored

        let known = Set(presets.map(\.presetId))
        presetDrafts = state.presetDrafts.filter { known.contains($0.key) }
        if let editor = presetEditor {
            presetEditor?.draft = presetDrafts[editor.entry.preset.presetId] ?? editor.entry.preset
        }
        // 右栏回到操作时看的东西。
        selection = state.selection.filter { item in
            switch item {
            case .source(let id): sourceItem(id) != nil
            case .job(let id): job(id) != nil
            }
        }
        if let id = state.selectedPresetId, known.contains(id) { selectedPresetId = id }
        switch state.focus {
        case .batch: if !selection.isEmpty { focus = .batch }
        case .preset: if selectedPresetId != nil { focus = .preset }
        case .location: if selectedLocationId != nil { focus = .location }
        }

        for id in reinspect { inspect(id) }
        scheduleValidation(revalidate)
        if left { sourcesDidLeave() }
        refreshPreview()
    }
}
