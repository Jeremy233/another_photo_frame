import Foundation
import PhotoFrameCore

/// 本机的预设库 + 素材库 + 绑定，给 PhotoFrameService、CLI、GUI 共用的入口。
///
/// 三个部分也可以单独使用；这里只放需要同时动到两部分的操作（复制预设连同绑定、删除预设清理绑定、
/// 绑定前检查素材与 slot、解析素材槽）。
public struct LocalLibrary: Sendable {
    public let root: URL
    public let presets: PresetLibrary
    public let assets: AssetLibrary
    public let bindings: AssetBindingStore

    /// `root` 默认是 App Group 共享容器里的库目录（``LibraryLocation/defaultRoot(appGroupIdentifier:)``，D-78）；
    /// GUI 传 ``LibraryLocation/groupContainerRoot(appGroupIdentifier:)``，测试传临时目录。
    public init(root: URL = LibraryLocation.defaultRoot(), platforms: PlatformCatalog, assetLimits: AssetImportLimits = .default) {
        self.root = root
        presets = PresetLibrary(root: root, platforms: platforms)
        assets = AssetLibrary(root: root, limits: assetLimits)
        bindings = AssetBindingStore(root: root)
    }

    public init(root: URL, presets: PresetLibrary, assets: AssetLibrary, bindings: AssetBindingStore) {
        self.root = root
        self.presets = presets
        self.assets = assets
        self.bindings = bindings
    }

    // MARK: 预设

    /// 复制预设；`copyBindings` 为 true 时把原预设的本地绑定也复制给副本，副本看起来和原来一样。
    @discardableResult
    public func duplicatePreset(_ id: UUID, name: String? = nil, copyBindings: Bool = true) throws(LibraryError) -> PresetEntry {
        let copy = try presets.duplicate(id, name: name)
        if copyBindings { try bindings.copyPresetBindings(from: id, to: copy.presetId) }
        return copy
    }

    /// 删除预设，并删除它的本地绑定。
    public func deletePreset(_ id: UUID) throws(LibraryError) {
        try presets.delete(id)
        try bindings.removePresetBindings(presetId: id)
    }

    // MARK: 素材

    /// 删除素材。指向它的绑定**保留**，解析时按 D-28 警告并回退到下一级；返回这些绑定，供界面提示用户重新绑定。
    @discardableResult
    public func deleteAsset(_ id: UUID) throws(LibraryError) -> [PersistedBinding] {
        try assets.delete(id)
        return bindings.bindings(referencing: id)
    }

    // MARK: 绑定

    /// 「保存到此预设的本地绑定」。检查 slot 在预设里存在、素材存在且格式被 slot 接受。`assetId == nil` 清除绑定。
    public func bindForPreset(_ presetId: UUID, slotId: String, assetId: UUID?) throws(LibraryError) {
        let preset = try presets.entry(presetId).preset
        guard let slot = preset.assetSlots.first(where: { $0.slotId == slotId }) else { throw .unknownSlot(slotId) }
        if let assetId { try checkAsset(assetId, fits: slot) }
        try bindings.setPresetBinding(presetId: presetId, slotId: slotId, assetId: assetId)
    }

    /// 「设为本用户默认绑定」。默认绑定跨预设生效，只检查素材存在。`assetId == nil` 清除绑定。
    public func bindByDefault(slotId: String, assetId: UUID?) throws(LibraryError) {
        guard ExportPreset.isValidIdentifier(slotId) else { throw .unknownSlot(slotId) }
        if let assetId { _ = try assets.info(assetId) }
        try bindings.setDefaultBinding(slotId: slotId, assetId: assetId)
    }

    // MARK: 解析

    /// 用当前素材库和持久绑定构造 ``SlotResolver``（快照：之后的修改不会反映进去）。
    public func makeSlotResolver() -> (resolver: SlotResolver, warnings: [LibraryWarning]) {
        let loaded = bindings.load()
        let listing = assets.list()
        return (SlotResolver(library: InMemoryAssetLibrary(listing.assets.map(\.record)), bindings: loaded.table),
                loaded.warnings + listing.warnings)
    }

    /// 按 D-14 解析预设的素材槽，并给出每个 slot 的内容文件，渲染可以直接使用。
    ///
    /// 必需素材缺失时抛出 ``SlotResolutionError``（`slot.missing_required`）；
    /// 失效绑定（素材已删除、格式不被接受）按 D-28 警告并回退，警告在 `resolution.warnings` 里。
    public func resolveSlots(for preset: ExportPreset, jobBindings: [String: UUID] = [:]) throws(SlotResolutionError) -> ResolvedSlots {
        let (resolver, warnings) = makeSlotResolver()
        let resolution = try resolver.resolve(preset, jobBindings: jobBindings)
        var files: [String: ResolvedSlots.File] = [:]
        for (slotId, slot) in resolution.resolved {
            if let url = assets.contentURL(for: slot.asset.assetId) {
                files[slotId] = .init(url: url, format: slot.asset.format)
            }
        }
        return ResolvedSlots(resolution: resolution, files: files, libraryWarnings: warnings)
    }

    // MARK: - 内部

    private func checkAsset(_ id: UUID, fits slot: AssetSlot) throws(LibraryError) {
        let info = try assets.info(id)
        guard slot.acceptedFormats.contains(info.format) else {
            throw .incompatibleAsset(slotId: slot.slotId, format: info.format)
        }
    }
}

/// ``LocalLibrary/resolveSlots(for:jobBindings:)`` 的结果。
public struct ResolvedSlots: Hashable, Sendable {
    public struct File: Hashable, Sendable {
        public var url: URL
        public var format: AssetSlot.Format
    }

    /// 与 ``SlotResolver`` 的结果相同（不含路径，可以序列化给 CLI / MCP）。
    public var resolution: SlotResolution
    /// slotId → 内容文件。只给渲染器用，不要原样返回给 MCP。
    public var files: [String: File]
    /// 读库时的提示（跳过的损坏素材、损坏的绑定文件等）。
    public var libraryWarnings: [LibraryWarning]

    public var skippedLayerIds: [String] { resolution.skippedLayerIds }
}
