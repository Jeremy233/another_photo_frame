import Foundation
import PhotoFrameApplication
import PhotoFrameCore
@testable import PhotoFrameMacModel
import Testing

/// 内置预设可以直接改：改动只在这次运行的内存里，另存为用户预设时输入名称；不另存的话下次启动恢复出厂定义。
@MainActor @Suite struct BuiltInPresetEditingTests {
    @Test func builtInPresetCanBeEditedInMemory() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let id = f.presetId("Instagram Standard")
        wb.selectedPresetId = id
        await wb.settle()
        #expect(wb.isInspectorEditable)
        #expect(!wb.hasUnsavedBuiltInEdits)

        wb.setField(\.canvas.minMarginPx, 10)
        #expect(wb.presetEditor?.draft.canvas.minMarginPx == 10)
        #expect(wb.hasUnsavedBuiltInEdits && wb.hasUnsavedEdits(id))
        // 出厂的定义（服务里的预设）不变。
        #expect(try await f.service.resolvePreset(.library(id.uuidString)).preset.canvas.minMarginPx == 20)
        // 内置预设不能存回去。
        await wb.savePresetEdits()
        #expect(try await f.service.resolvePreset(.library(id.uuidString)).preset.canvas.minMarginPx == 20)

        // 换选别的预设再回来，修改还在。
        wb.selectedPresetId = f.presetId("XHS Standard")
        await wb.settle()
        #expect(!wb.hasUnsavedBuiltInEdits)
        wb.selectedPresetId = id
        await wb.settle()
        #expect(wb.presetEditor?.draft.canvas.minMarginPx == 10 && wb.hasUnsavedBuiltInEdits)

        // 用这个预设建任务时用改过的内容。
        let sourceIds = await wb.addSources([try f.photo("A.jpg")])
        await wb.addJobs(preset: id, to: sourceIds)
        let job = try #require(wb.sources.first?.jobs.first)
        #expect(job.preset.canvas.minMarginPx == 10 && !job.isModified)

        // 还原后回到出厂定义。
        wb.selectedPresetId = id
        await wb.settle()
        wb.revertPresetEdits()
        #expect(wb.presetEditor?.draft.canvas.minMarginPx == 20)
        #expect(!wb.hasUnsavedBuiltInEdits && !wb.hasUnsavedEdits(id))
    }

    @Test func unsavedBuiltInEditsAreForgottenOnNextLaunch() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let id = f.presetId("Instagram Standard")
        wb.selectedPresetId = id
        await wb.settle()
        wb.setField(\.canvas.minMarginPx, 10)
        #expect(wb.hasUnsavedBuiltInEdits)

        // 下次启动：同一个本地库、同样的设置，新的工作台。
        let relaunched = Workbench(service: f.hooks, locationStore: f.store, settingsStore: f.settingsStore, debounce: .zero)
        await relaunched.load()
        relaunched.selectedPresetId = id
        await relaunched.settle()
        #expect(relaunched.presetDrafts.isEmpty)
        #expect(relaunched.presetEditor?.draft.canvas.minMarginPx == 20)
        #expect(relaunched.presetEditor?.isDirty == false)
        #expect(!relaunched.hasUnsavedBuiltInEdits)
        // 库里没有多出预设。
        #expect(relaunched.presets(in: .user).isEmpty)
    }

    @Test func savingBuiltInEditsAsUserPresetAsksForAName() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let id = f.presetId("Instagram Standard")
        wb.selectedPresetId = id
        await wb.settle()
        wb.setField(\.canvas.minMarginPx, 10)
        // 建议的名称不与已有预设重名。
        #expect(wb.suggestedSaveAsName == "Instagram Standard 2")

        await wb.saveBuiltInEditsAsPreset(name: "My Instagram")
        await wb.settle()
        let saved = try #require(wb.presets(in: .user).first)
        #expect(saved.name == "My Instagram" && saved.minMarginPx == 10)
        #expect(saved.presetId != id)
        // 左栏改选新预设；内置预设回到出厂定义。
        #expect(wb.selectedPresetId == saved.presetId)
        #expect(wb.presetEditor?.entry.origin == .user && wb.presetEditor?.isDirty == false)
        #expect(!wb.hasUnsavedEdits(id) && !wb.hasUnsavedBuiltInEdits)
        #expect(try await f.service.resolvePreset(.library(id.uuidString)).preset.canvas.minMarginPx == 20)
    }

    @Test func userPresetDraftSurvivesSwitchingPresets() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        await wb.duplicatePreset(f.presetId("Instagram Standard"))
        await wb.settle()
        let copy = try #require(wb.selectedPresetId)
        wb.setField(\.canvas.minMarginPx, 72)
        wb.selectedPresetId = f.presetId("XHS Standard")
        await wb.settle()
        wb.selectedPresetId = copy
        await wb.settle()
        #expect(wb.presetEditor?.draft.canvas.minMarginPx == 72 && wb.presetEditor?.isDirty == true)
        // 用户预设还没存储的修改不提示另存（它有自己的「存储」）。
        #expect(!wb.hasUnsavedBuiltInEdits)
        await wb.savePresetEdits()
        await wb.settle()
        #expect(!wb.hasUnsavedEdits(copy) && wb.presetEditor?.isDirty == false)
    }

    /// 内置预设加了签名图层、绑了素材：绑定只在内存里。返回预设 ID 和素材 ID。
    private func bindSignatureInMemory(_ f: Fixture) async throws -> (preset: UUID, asset: UUID) {
        let wb = f.workbench
        await wb.load()
        await wb.importAssets([try f.assetPNG("sig.png")], category: .signature)
        let asset = try #require(wb.assets(in: .signature).first).assetId
        let id = f.presetId("Instagram Standard")
        wb.selectedPresetId = id
        await wb.settle()
        wb.addLayer(.signature)
        // 新加的图层不用先存储也能绑定（内置预设没有「存储」）。
        await wb.bindAsset(asset, slotId: "signature")
        #expect(wb.alert == nil)
        return (id, asset)
    }

    @Test func builtInAssetBindingStaysInMemory() async throws {
        let f = try Fixture()
        let wb = f.workbench
        let (id, asset) = try await bindSignatureInMemory(f)
        #expect(wb.presetBindingDrafts[id] == ["signature": asset])
        #expect(wb.binding(for: "signature")?.assetId == asset && wb.binding(for: "signature")?.level == .preset)
        #expect(wb.hasUnsavedBuiltInEdits && wb.hasUnsavedEdits(id))
        // 不写进库里的绑定。
        #expect(await f.service.listBindings().bindings.isEmpty)
        #expect(wb.bindings.isEmpty)
        // 预览用这个绑定。
        _ = await wb.addSources([try f.photo("A.jpg")])
        wb.selectedPresetId = nil
        wb.selectedPresetId = id
        await wb.settle()
        #expect(wb.previewSubject?.assetBindings == ["signature": asset])
        // 用这个预设建的任务带上这个绑定（单任务绑定）。
        let sourceId = try #require(wb.sources.first?.id)
        await wb.addJobs(preset: id, to: [sourceId])
        #expect(wb.sources.first?.jobs.first?.assetBindings == ["signature": asset])
        #expect(await f.service.listBindings().bindings.isEmpty)
        // 右栏回到预设，解除绑定：内存里的绑定去掉。
        wb.focusPreset()
        await wb.bindAsset(nil, slotId: "signature")
        #expect(wb.presetBindingDrafts[id] == nil && wb.binding(for: "signature") == nil)
    }

    @Test func builtInAssetBindingIsForgottenOnNextLaunch() async throws {
        let f = try Fixture()
        let (id, _) = try await bindSignatureInMemory(f)
        let relaunched = Workbench(service: f.hooks, locationStore: f.store, settingsStore: f.settingsStore, debounce: .zero)
        await relaunched.load()
        relaunched.selectedPresetId = id
        await relaunched.settle()
        #expect(relaunched.presetBindingDrafts.isEmpty && relaunched.bindings.isEmpty)
        #expect(relaunched.binding(for: "signature") == nil)
        #expect(!relaunched.hasUnsavedEdits(id))
    }

    @Test func revertingBuiltInClearsInMemoryBindings() async throws {
        let f = try Fixture()
        let wb = f.workbench
        let undo = UndoManager()
        undo.groupsByEvent = false
        wb.undoManager = undo
        let (id, asset) = try await bindSignatureInMemory(f)
        wb.revertPresetEdits()
        #expect(wb.presetBindingDrafts.isEmpty && !wb.hasUnsavedEdits(id) && !wb.hasUnsavedBuiltInEdits)
        #expect(wb.presetEditor?.isDirty == false)
        // 撤销「还原」：绑定回来（仍然只在内存里）。
        undo.undo()
        #expect(wb.presetBindingDrafts[id] == ["signature": asset])
        #expect(await f.service.listBindings().bindings.isEmpty)

        // 删除图层：它的素材槽没了，内存里的绑定也不留（与单任务绑定一样）。
        wb.revertPresetEdits()
        undo.undo()
        wb.removeLayer("signature")
        #expect(wb.presetBindingDrafts.isEmpty && !wb.hasUnsavedBuiltInEdits)
        #expect(await f.service.listBindings().bindings.isEmpty)
    }

    @Test func savingBuiltInAsUserPresetStoresInMemoryBindings() async throws {
        let f = try Fixture()
        let wb = f.workbench
        let (id, asset) = try await bindSignatureInMemory(f)
        await wb.saveBuiltInEditsAsPreset(name: "Signed Instagram")
        await wb.settle()
        let saved = try #require(wb.presets(in: .user).first)
        // 新的用户预设有这个本地绑定（写进库里）；内置预设的内存绑定清空。
        let stored = await f.service.listBindings().bindings
        #expect(stored.count == 1)
        #expect(stored.first?.presetId == saved.presetId && stored.first?.slotId == "signature" && stored.first?.assetId == asset)
        #expect(!stored.contains { $0.presetId == id })
        #expect(wb.presetBindingDrafts.isEmpty && !wb.hasUnsavedEdits(id))
        #expect(wb.selectedPresetId == saved.presetId && wb.binding(for: "signature")?.level == .preset)
    }
}
