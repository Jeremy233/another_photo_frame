import Foundation
import PhotoFrameApplication
import PhotoFrameCore
@testable import PhotoFrameMacModel
import Testing

/// 编辑预设、存储为预设、图层和素材绑定：等后端期间又改了内容、读取失败时的行为。
@MainActor @Suite struct PresetEditingTests {
    @Test func editsMadeWhileSavingAreKept() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        await wb.duplicatePreset(f.presetId("Instagram Standard"))
        await wb.settle()
        wb.setField(\.canvas.minMarginPx, 72)
        // 存储还没完成（后端在写文件）时，用户又改了这个字段。
        f.hooks.set { $0.afterReplacePreset = { @MainActor in wb.setField(\.canvas.minMarginPx, 90) } }
        await wb.savePresetEdits()
        await wb.settle()
        let editor = try #require(wb.presetEditor)
        #expect(editor.entry.preset.canvas.minMarginPx == 72)
        #expect(editor.draft.canvas.minMarginPx == 90 && editor.isDirty)
    }

    @Test func jobEditedWhileSavingAsPresetKeepsItsEdit() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let jobId = try await f.addJob()
        let wb = f.workbench
        wb.setField(\.canvas.minMarginPx, 100)
        f.hooks.set { $0.afterSavePreset = { @MainActor in wb.setField(\.canvas.minMarginPx, 120) } }
        await wb.saveSelectedJobAsPreset(name: "Wide Margin")
        let saved = try #require(wb.presets.first { $0.name == "Wide Margin" })
        #expect(saved.minMarginPx == 100)
        // 任务改为基于新预设，存储期间的改动还在（显示为已修改）。
        let job = try #require(wb.job(jobId))
        #expect(job.basePreset.presetId == saved.presetId)
        #expect(job.preset.canvas.minMarginPx == 120 && job.isModified)
    }

    @Test func savingJobAsPresetKeepsPresetBindings() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        await wb.importAssets([try f.assetPNG("sig.png")], category: .signature)
        let asset = try #require(wb.assets(in: .signature).first)
        // 用户预设：签名图层的素材绑定在预设本地。
        await wb.duplicatePreset(f.presetId("Instagram Standard"))
        await wb.settle()
        let presetId = try #require(wb.selectedPresetId)
        wb.addLayer(.signature)
        await wb.savePresetEdits()
        await wb.settle()
        await wb.bindAsset(asset.assetId, slotId: "signature")

        // 用这个预设建任务，改一下再存储为新预设。
        let sourceIds = await wb.addSources([try f.photo("S.jpg")])
        let sourceId = try #require(sourceIds.first)
        await wb.drop(.preset(presetId), on: .source(sourceId))
        await wb.settle()
        let jobId = try #require(wb.sourceItem(sourceId)?.jobs.first?.id)
        #expect(wb.selection == [.job(jobId)])
        #expect(wb.job(jobId)?.validation?.warnings.contains { $0.code == "slot.optional_missing" } == false)
        wb.setField(\.canvas.minMarginPx, 100)
        await wb.saveSelectedJobAsPreset(name: "Signed")
        await wb.settle()

        // 新预设也有这个绑定（与「复制」一样），任务的成品不变：签名还在。
        let saved = try #require(wb.presets.first { $0.name == "Signed" })
        #expect(wb.bindings.contains { $0.presetId == saved.presetId && $0.slotId == "signature" && $0.assetId == asset.assetId })
        #expect(wb.binding(for: "signature")?.level == .preset)
        #expect(wb.job(jobId)?.validation?.warnings.contains { $0.code == "slot.optional_missing" } == false)
    }

    @Test func removingLayersDropsTheirJobBindings() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        await wb.importAssets([try f.assetPNG("sig.png")], category: .signature)
        let asset = try #require(wb.assets(in: .signature).first)
        let jobId = try await f.addJob()
        wb.addLayer(.signature)
        await wb.bindAsset(asset.assetId, slotId: "signature")
        #expect(wb.job(jobId)?.assetBindings == ["signature": asset.assetId])

        // 删除图层：它的素材槽没了，单任务绑定也不留（否则一直警告绑定的槽没有被使用）。
        wb.removeLayer("signature")
        await wb.settle()
        #expect(wb.job(jobId)?.assetBindings.isEmpty == true)
        #expect(wb.job(jobId)?.validation?.warnings.contains { $0.code == "slot.unused_job_binding" } == false)

        // 删除相机匹配规则也一样。
        wb.addLayer(.cameraBadge)
        wb.addCameraRule("cameraBadge")
        await wb.bindAsset(asset.assetId, slotId: "cameraBadge.camera-1")
        #expect(wb.job(jobId)?.assetBindings["cameraBadge.camera-1"] == asset.assetId)
        wb.removeCameraRule("cameraBadge", at: 0)
        #expect(wb.job(jobId)?.assetBindings["cameraBadge.camera-1"] == nil)
    }

    @Test func renamingThePresetBeingEditedKeepsUnsavedEdits() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        await wb.duplicatePreset(f.presetId("Instagram Standard"))
        await wb.settle()
        let id = try #require(wb.selectedPresetId)
        wb.setField(\.canvas.minMarginPx, 77)
        await wb.renamePreset(id, to: "Renamed")
        await wb.settle()
        let editor = try #require(wb.presetEditor)
        #expect(editor.entry.preset.name == "Renamed" && editor.draft.name == "Renamed")
        #expect(editor.draft.canvas.minMarginPx == 77 && editor.isDirty)

        await wb.savePresetEdits()
        await wb.settle()
        #expect(wb.preset(id)?.name == "Renamed" && wb.preset(id)?.minMarginPx == 77)
        #expect(wb.presetEditor?.isDirty == false)
    }

    @Test func failedPresetLoadDoesNotKeepThePreviousEditor() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let first = f.presetId("Instagram Standard")
        let second = f.presetId("XHS Standard")
        wb.selectedPresetId = first
        await wb.settle()
        #expect(wb.presetEditor?.entry.preset.presetId == first)

        f.hooks.set { $0.failingPresets = [.library(second.uuidString)] }
        wb.selectedPresetId = second
        await wb.settle()
        // 右栏不能还是上一个预设：否则显示的、「存储」写入的都是它。
        #expect(wb.inspectorSubject == .preset(second))
        #expect(wb.presetEditor == nil)
        #expect(wb.alert?.title == "无法读取预设")
    }
}
