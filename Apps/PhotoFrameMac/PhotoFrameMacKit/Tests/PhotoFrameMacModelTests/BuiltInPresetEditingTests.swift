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
        #expect(try await f.service.resolvePreset(.library(id.uuidString)).preset.canvas.minMarginPx == 60)
        // 内置预设不能存回去。
        await wb.savePresetEdits()
        #expect(try await f.service.resolvePreset(.library(id.uuidString)).preset.canvas.minMarginPx == 60)

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
        #expect(wb.presetEditor?.draft.canvas.minMarginPx == 60)
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
        #expect(relaunched.presetEditor?.draft.canvas.minMarginPx == 60)
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
        #expect(try await f.service.resolvePreset(.library(id.uuidString)).preset.canvas.minMarginPx == 60)
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
}
