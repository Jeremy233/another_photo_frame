import Foundation
import PhotoFrameApplication
import PhotoFrameCore
@testable import PhotoFrameMacModel
import PhotoFrameStorage

/// 把调用转发给真正的服务；测试可以在某个调用中间插入动作（模拟用户在等后端时又操作了界面），或让调用失败。
final class HookedService: Workbench.Service, @unchecked Sendable {
    typealias Hook = @Sendable () async -> Void

    struct Hooks {
        /// 下一次校验之前执行一次。
        var beforeValidate: Hook?
        /// 下一次读预设之前执行一次。
        var beforeResolvePreset: Hook?
        /// 下一次替换预设（存储预设的修改）之后执行一次。
        var afterReplacePreset: Hook?
        /// 下一次「存储为预设」之后执行一次。
        var afterSavePreset: Hook?
        /// 下一次读任务列表、拿到快照之后执行一次（返回的仍是之前拿到的快照）。
        var afterJobsSnapshot: Hook?
        /// 读这些预设时失败。
        var failingPresets: Set<PresetReference> = []
        /// 按 ID 读任务记录的次数。
        var statusCalls = 0
    }

    let inner: LocalPhotoFrameService
    private let lock = NSLock()
    private var hooks = Hooks()

    init(_ inner: LocalPhotoFrameService) { self.inner = inner }

    func set(_ body: (inout Hooks) -> Void) { lock.withLock { body(&hooks) } }
    var statusCalls: Int { lock.withLock { hooks.statusCalls } }

    private func take(_ path: WritableKeyPath<Hooks, Hook?>) -> Hook? {
        lock.withLock {
            let hook = hooks[keyPath: path]
            hooks[keyPath: path] = nil
            return hook
        }
    }

    // MARK: 预设

    func listPresets() async throws(ApplicationError) -> CatalogPresetList { try await inner.listPresets() }

    func resolvePreset(_ reference: PresetReference) async throws(ApplicationError) -> CatalogPreset {
        if let hook = take(\.beforeResolvePreset) { await hook() }
        if lock.withLock({ hooks.failingPresets.contains(reference) }) {
            throw ApplicationError(code: "test.unreadable", message: "读不到这个预设")
        }
        return try await inner.resolvePreset(reference)
    }

    func importPreset(from fileURL: URL, replace: Bool) async throws(ApplicationError) -> CatalogPresetImport {
        try await inner.importPreset(from: fileURL, replace: replace)
    }

    func exportPreset(_ reference: PresetReference, to fileURL: URL, overwrite: Bool) async throws(ApplicationError) {
        try await inner.exportPreset(reference, to: fileURL, overwrite: overwrite)
    }

    func duplicatePreset(_ reference: PresetReference, name: String?) async throws(ApplicationError) -> CatalogPresetSummary {
        try await inner.duplicatePreset(reference, name: name)
    }

    func renamePreset(_ reference: PresetReference, to name: String) async throws(ApplicationError) -> CatalogPresetSummary {
        try await inner.renamePreset(reference, to: name)
    }

    func deletePreset(_ reference: PresetReference) async throws(ApplicationError) { try await inner.deletePreset(reference) }

    func movePreset(_ reference: PresetReference, to group: PresetOrigin) async throws(ApplicationError) -> CatalogPresetSummary {
        try await inner.movePreset(reference, to: group)
    }

    func updatePreset(_ reference: PresetReference, edits: [PresetEdit]) async throws(ApplicationError) -> CatalogPresetUpdate {
        try await inner.updatePreset(reference, edits: edits)
    }

    func savePreset(_ content: ExportPreset, name: String) async throws(ApplicationError) -> CatalogPresetSummary {
        let saved = try await inner.savePreset(content, name: name)
        if let hook = take(\.afterSavePreset) { await hook() }
        return saved
    }

    func replacePreset(_ content: ExportPreset) async throws(ApplicationError) -> CatalogPresetSummary {
        let replaced = try await inner.replacePreset(content)
        if let hook = take(\.afterReplacePreset) { await hook() }
        return replaced
    }

    // MARK: 素材与绑定

    func listAssets(category: AssetCategory?) async -> CatalogAssetList { await inner.listAssets(category: category) }
    func resolveAsset(_ reference: String) async throws(ApplicationError) -> AssetInfo { try await inner.resolveAsset(reference) }

    func importAsset(from fileURL: URL, category: AssetCategory, name: String?) async throws(ApplicationError) -> CatalogAssetImport {
        try await inner.importAsset(from: fileURL, category: category, name: name)
    }

    func renameAsset(_ id: UUID, to name: String) async throws(ApplicationError) -> AssetInfo { try await inner.renameAsset(id, to: name) }

    func setAssetCategory(_ id: UUID, to category: AssetCategory) async throws(ApplicationError) -> AssetInfo {
        try await inner.setAssetCategory(id, to: category)
    }

    func deleteAsset(_ id: UUID) async throws(ApplicationError) -> [PersistedBinding] { try await inner.deleteAsset(id) }

    func bindAsset(_ assetId: UUID?, slotId: String, preset: PresetReference?) async throws(ApplicationError) {
        try await inner.bindAsset(assetId, slotId: slotId, preset: preset)
    }

    func listBindings() async -> CatalogBindingList { await inner.listBindings() }
    func assetContentURL(_ id: UUID) async -> URL? { await inner.assetContentURL(id) }

    // MARK: 源图、校验、预览

    func inspectSource(_ source: SourceReference) async throws(ApplicationError) -> SourceInspection { try await inner.inspectSource(source) }

    func validate(_ request: ExportRequest) async throws(ApplicationError) -> ValidationResult {
        if let hook = take(\.beforeValidate) { await hook() }
        return try await inner.validate(request)
    }

    func renderPreview(_ request: ExportPreviewRequest) async throws(ApplicationError) -> ExportPreview { try await inner.renderPreview(request) }
    func addSource(_ fileURL: URL) async throws(ApplicationError) -> PhotoSource { try await inner.addSource(fileURL) }
    func sources() async -> [PhotoSource] { await inner.sources() }

    // MARK: 任务

    func submit(_ request: ExportRequest) async throws(ApplicationError) -> [JobID] { try await inner.submit(request) }
    func start() async { await inner.start() }
    func pause() async { await inner.pause() }
    func cancel(_ job: JobID) async throws(ApplicationError) { try await inner.cancel(job) }
    func retry(_ job: JobID) async throws(ApplicationError) -> AttemptID { try await inner.retry(job) }

    func status(_ job: JobID) async throws(ApplicationError) -> JobSnapshot {
        lock.withLock { hooks.statusCalls += 1 }
        return try await inner.status(job)
    }

    func jobs() async -> [JobSnapshot] {
        let snapshot = await inner.jobs()
        if let hook = take(\.afterJobsSnapshot) { await hook() }
        return snapshot
    }

    func manifest(_ job: JobID) async throws(ApplicationError) -> OutputManifest? { try await inner.manifest(job) }
    func setMaxConcurrentJobs(_ count: Int) async { await inner.setMaxConcurrentJobs(count) }
    func setMemoryBudget(_ bytes: Int64?) async { await inner.setMemoryBudget(bytes) }
    func removeStaleStaging(in destinationRoot: URL) async -> [URL] { await inner.removeStaleStaging(in: destinationRoot) }
    func events() async -> AsyncStream<JobEvent> { await inner.events() }
    func waitUntilFinished(_ jobs: [JobID]) async -> [JobSnapshot] { await inner.waitUntilFinished(jobs) }
}
