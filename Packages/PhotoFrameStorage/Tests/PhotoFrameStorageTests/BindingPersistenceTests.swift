import Foundation
import Testing
import PhotoFrameCore
@testable import PhotoFrameStorage

private func code(_ body: () throws(LibraryError) -> Void) -> String? {
    do {
        try body()
        return nil
    } catch {
        return error.code
    }
}

@Suite("素材绑定持久化与解析（D-14、D-28、D-29）")
struct BindingPersistenceTests {
    let root = TempRoot()
    let library: LocalLibrary
    let preset: PresetEntry
    let pngA: AssetInfo
    let pngB: AssetInfo
    let svgC: AssetInfo

    init() throws {
        library = root.library()
        preset = try library.presets.add(samplePreset())
        pngA = try library.assets.importAsset(makePNG(red: 0.1), format: .png, category: .signature, displayName: "A").asset
        pngB = try library.assets.importAsset(makePNG(red: 0.5), format: .png, category: .signature, displayName: "B").asset
        svgC = try library.assets.importAsset(svg(), format: .svg, category: .cameraBadge, displayName: "C").asset
    }

    @Test("预设本地绑定和用户默认绑定写盘，新实例读回")
    func persisted() throws {
        try library.bindForPreset(preset.presetId, slotId: "signature", assetId: pngA.assetId)
        try library.bindByDefault(slotId: "signature", assetId: pngB.assetId)
        try library.bindByDefault(slotId: "camera.badge", assetId: svgC.assetId)

        let table = root.library().bindings.load().table
        #expect(table.presetBinding(preset.presetId, slotId: "signature") == pngA.assetId)
        #expect(table.userGlobal == ["signature": pngB.assetId, "camera.badge": svgC.assetId])

        try library.bindForPreset(preset.presetId, slotId: "signature", assetId: nil)
        try library.bindByDefault(slotId: "camera.badge", assetId: nil)
        let cleared = root.library().bindings.load().table
        #expect(cleared.presetLocal.isEmpty)
        #expect(cleared.userGlobal == ["signature": pngB.assetId])
        // bindings.json 不含路径。
        let raw = try String(contentsOf: library.bindings.fileURL, encoding: .utf8)
        #expect(!raw.contains("/"))
    }

    @Test("单任务 > 预设本地 > 用户默认，解析结果带内容文件")
    func priority() throws {
        try library.bindForPreset(preset.presetId, slotId: "signature", assetId: pngA.assetId)
        try library.bindByDefault(slotId: "signature", assetId: pngB.assetId)
        try library.bindByDefault(slotId: "camera.badge", assetId: svgC.assetId)

        let r1 = try library.resolveSlots(for: preset.preset)
        #expect(r1.resolution.resolved["signature"]?.asset.assetId == pngA.assetId)
        #expect(r1.resolution.resolved["signature"]?.scope == .presetLocal)
        #expect(r1.resolution.resolved["camera.badge"]?.scope == .userGlobal)
        #expect(r1.files["signature"]?.url == library.assets.contentURL(for: pngA.assetId))
        #expect(r1.files["camera.badge"]?.format == .svg)
        #expect(r1.resolution.warnings.isEmpty && r1.libraryWarnings.isEmpty)

        let r2 = try library.resolveSlots(for: preset.preset, jobBindings: ["signature": pngB.assetId])
        #expect(r2.resolution.resolved["signature"]?.scope == .job)
        #expect(r2.resolution.resolved["signature"]?.asset.assetId == pngB.assetId)
    }

    @Test("素材删除后：警告并回退到下一级；deleteAsset 返回受影响的绑定")
    func deletedAssetFallsBack() throws {
        try library.bindForPreset(preset.presetId, slotId: "signature", assetId: pngA.assetId)
        try library.bindByDefault(slotId: "signature", assetId: pngB.assetId)

        let affected = try library.deleteAsset(pngA.assetId)
        #expect(affected == [PersistedBinding(scope: .presetLocal, presetId: preset.presetId, slotId: "signature", assetId: pngA.assetId)])

        let r = try library.resolveSlots(for: preset.preset)
        #expect(r.resolution.resolved["signature"]?.asset.assetId == pngB.assetId)
        #expect(r.resolution.resolved["signature"]?.scope == .userGlobal)
        #expect(r.resolution.warnings == [
            .optionalSlotMissing(slotId: "camera.badge", layerIds: ["badge"]),
            .staleBinding(slotId: "signature", scope: .presetLocal, assetId: pngA.assetId),
        ])

        // 默认绑定也删掉 → 必需 slot 缺失，阻止输出。
        try library.deleteAsset(pngB.assetId)
        #expect(throws: SlotResolutionError.self) { try library.resolveSlots(for: preset.preset) }
        do {
            _ = try library.resolveSlots(for: preset.preset)
        } catch {
            #expect(error.missingRequiredSlots == ["signature"])
            #expect(error.warnings.map(\.code) == ["slot.optional_missing", "slot.stale_binding", "slot.stale_binding"])
        }
    }

    @Test("内容文件丢失的素材也按失效绑定回退")
    func missingContentFallsBack() throws {
        try library.bindForPreset(preset.presetId, slotId: "signature", assetId: pngA.assetId)
        try library.bindByDefault(slotId: "signature", assetId: pngB.assetId)
        try FileManager.default.removeItem(at: library.assets.contentFile(pngA.assetId, .png))
        let r = try library.resolveSlots(for: preset.preset)
        #expect(r.resolution.resolved["signature"]?.asset.assetId == pngB.assetId)
        #expect(r.libraryWarnings.map(\.code) == ["asset.missing_file"])
    }

    @Test("格式不再被接受（slot 改成只收 PNG）：警告并回退")
    func formatNoLongerAccepted() throws {
        try library.bindForPreset(preset.presetId, slotId: "signature", assetId: svgC.assetId)
        try library.bindByDefault(slotId: "signature", assetId: pngB.assetId)
        var p = preset.preset
        p.assetSlots[1].acceptedFormats = [.png]
        try library.presets.update(p)

        let r = try library.resolveSlots(for: try library.presets.entry(p.presetId).preset)
        #expect(r.resolution.resolved["signature"]?.asset.assetId == pngB.assetId)
        #expect(r.resolution.warnings.last == .incompatibleFormat(slotId: "signature", scope: .presetLocal, assetId: svgC.assetId, format: .svg))
    }

    @Test("可选 slot 缺失跳过图层；没有启用图层用到的必需 slot 不阻止输出（D-29）")
    func optionalAndUnused() throws {
        var p = preset.preset
        p.layers[1].enabled = false
        try library.presets.update(p)
        let r = try library.resolveSlots(for: p)
        #expect(r.resolution.resolved.isEmpty)
        #expect(r.skippedLayerIds == ["badge"])
    }

    @Test("绑定前检查：slot 存在、素材存在、格式被接受")
    func bindChecks() throws {
        var p = samplePreset(slots: [AssetSlot(slotId: "camera.badge", acceptedFormats: [.svg]),
                                     AssetSlot(slotId: "signature", required: true)])
        p = try library.presets.add(p).preset
        #expect(code { () throws(LibraryError) in try library.bindForPreset(p.presetId, slotId: "nope", assetId: pngA.assetId) } == "binding.unknown_slot")
        #expect(code { () throws(LibraryError) in try library.bindForPreset(p.presetId, slotId: "camera.badge", assetId: pngA.assetId) } == "binding.incompatible_format")
        #expect(code { () throws(LibraryError) in try library.bindForPreset(p.presetId, slotId: "signature", assetId: UUID()) } == "asset.not_found")
        #expect(code { () throws(LibraryError) in try library.bindForPreset(UUID(), slotId: "signature", assetId: pngA.assetId) } == "library.preset_not_found")
        #expect(code { () throws(LibraryError) in try library.bindByDefault(slotId: "bad slot", assetId: pngA.assetId) } == "binding.unknown_slot")
        #expect(code { () throws(LibraryError) in try library.bindByDefault(slotId: "signature", assetId: UUID()) } == "asset.not_found")
        // 内置预设也可以有本地绑定（它没有 slot，所以这里只验证会去查 slot）。
        let builtIn = library.presets.list().builtIn[0].presetId
        #expect(code { () throws(LibraryError) in try library.bindForPreset(builtIn, slotId: "signature", assetId: pngA.assetId) } == "binding.unknown_slot")
        #expect(library.bindings.load().table == AssetBindingTable())
    }

    @Test("复制预设连同本地绑定；删除预设清掉它的绑定")
    func duplicateAndDelete() throws {
        try library.bindForPreset(preset.presetId, slotId: "signature", assetId: pngA.assetId)
        let copy = try library.duplicatePreset(preset.presetId)
        let plain = try library.duplicatePreset(preset.presetId, name: "Plain", copyBindings: false)
        var table = library.bindings.load().table
        #expect(table.presetBinding(copy.presetId, slotId: "signature") == pngA.assetId)
        #expect(table.presetLocal[plain.presetId.uuidString] == nil)

        try library.deletePreset(preset.presetId)
        table = library.bindings.load().table
        #expect(table.presetLocal[preset.presetId.uuidString] == nil)
        #expect(table.presetBinding(copy.presetId, slotId: "signature") == pngA.assetId)
    }

    @Test("bindings.json 损坏：读成空表并警告；修改前把坏文件留底")
    func corruptBindingsFile() throws {
        try Data("garbage".utf8).write(to: library.bindings.fileURL)
        let loaded = library.bindings.load()
        #expect(loaded.table == AssetBindingTable())
        #expect(loaded.warnings.map(\.code) == ["binding.unreadable"])
        #expect(try library.resolveSlots(for: samplePreset(slots: [AssetSlot(slotId: "camera.badge"), AssetSlot(slotId: "signature")]))
            .libraryWarnings.map(\.code) == ["binding.unreadable"])

        try library.bindByDefault(slotId: "signature", assetId: pngA.assetId)
        #expect(library.bindings.load().warnings.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.url.path).filter { $0.hasPrefix("bindings.corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: root.url.appending(path: backups[0])) == Data("garbage".utf8))
    }

    @Test("bindings.json 格式版本过新：不使用，也不覆盖")
    func newerBindingsFile() throws {
        let future = Data(#"{"storageFormat": 9, "presetLocal": {}, "userGlobal": {}, "rules": []}"#.utf8)
        try future.write(to: library.bindings.fileURL)
        #expect(library.bindings.load().warnings.map(\.code) == ["library.newer_storage_format"])
        #expect(code { () throws(LibraryError) in try library.bindByDefault(slotId: "signature", assetId: pngA.assetId) } == "library.newer_storage_format")
        #expect(try Data(contentsOf: library.bindings.fileURL) == future)
    }

    @Test("多个线程同时修改绑定不丢更新（文件锁）")
    func concurrentModifications() throws {
        let store = library.bindings
        let asset = pngA.assetId
        DispatchQueue.concurrentPerform(iterations: 32) { i in
            try? store.setDefaultBinding(slotId: "slot-\(i)", assetId: asset)
        }
        #expect(store.load().table.userGlobal.count == 32)
    }

    @Test("makeSlotResolver 可以直接交给任务队列")
    func makeSlotResolver() throws {
        try library.bindByDefault(slotId: "signature", assetId: pngA.assetId)
        let (resolver, warnings) = library.makeSlotResolver()
        #expect(warnings.isEmpty)
        let r = try resolver.resolve(preset.preset)
        #expect(r.resolved["signature"]?.asset == pngA.record)
        #expect(library.assets.contentURL(for: pngA.record) != nil)
    }
}
