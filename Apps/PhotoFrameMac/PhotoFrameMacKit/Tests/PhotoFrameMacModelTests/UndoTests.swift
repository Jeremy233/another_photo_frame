import Foundation
import PhotoFrameApplication
import PhotoFrameCore
@testable import PhotoFrameMacModel
import Testing

/// ⌘Z / ⇧⌘Z：改参数、应用预设、添加图片都能撤销和重做；拖动滑块合成一步。
@MainActor @Suite struct UndoTests {
    /// 测试里没有事件循环：UndoManager 不按事件自动分组，每个操作自己是一组。
    private func undoManager(for wb: Workbench) -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        wb.undoManager = manager
        return manager
    }

    @Test func parameterChangeUndoesAndRedoes() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let a = try await f.addJob("A.jpg")
        let b = try await f.addJob("B.jpg")
        let wb = f.workbench
        let undo = undoManager(for: wb)
        wb.selection = [.job(a), .job(b)]
        wb.setField(\.canvas.minMarginPx, 90)
        #expect(undo.canUndo && undo.undoActionName == "修改参数")

        // 撤销前右栏换到了别处：撤销后回到当时改的任务。
        wb.selection = [.source(try #require(wb.job(a)?.sourceId))]
        undo.undo()
        #expect(wb.job(a)?.preset.canvas.minMarginPx == 60 && wb.job(b)?.preset.canvas.minMarginPx == 60)
        #expect(wb.job(a)?.isModified == false)
        #expect(wb.selection == [.job(a), .job(b)])
        #expect(undo.canRedo && undo.redoActionName == "修改参数")

        undo.redo()
        #expect(wb.job(a)?.preset.canvas.minMarginPx == 90 && wb.job(b)?.preset.canvas.minMarginPx == 90)
        undo.undo()
        #expect(wb.job(a)?.preset.canvas.minMarginPx == 60)
        // 撤销后重新校验，校验结果还在。
        await wb.settle()
        #expect(wb.job(a)?.validation != nil)
    }

    @Test func sliderDragIsOneUndoStep() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let a = try await f.addJob()
        let wb = f.workbench
        let undo = undoManager(for: wb)
        let before = try #require(wb.job(a)?.preset.output.quality)
        wb.beginContinuousEdit()
        for quality in [70, 71, 72, 75, 80] { wb.setField(\.output.quality, quality) }
        #expect(!undo.canUndo)
        wb.endContinuousEdit()
        #expect(wb.job(a)?.preset.output.quality == 80)
        undo.undo()
        #expect(wb.job(a)?.preset.output.quality == before)
        #expect(!undo.canUndo)
    }

    @Test func rapidChangesToOneFieldCoalesce() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let a = try await f.addJob()
        let wb = f.workbench
        let undo = undoManager(for: wb)
        // 同一个字段连续改（例如拖颜色面板）是一步；换了字段是新的一步。
        wb.setField(\.canvas.minMarginPx, 61)
        wb.setField(\.canvas.minMarginPx, 62)
        wb.setField(\.canvas.minMarginPx, 63)
        wb.setField(\.output.quality, 50)
        undo.undo()
        #expect(wb.job(a)?.preset.canvas.minMarginPx == 63 && wb.job(a)?.preset.output.quality != 50)
        undo.undo()
        #expect(wb.job(a)?.preset.canvas.minMarginPx == 60)
        #expect(!undo.canUndo)
    }

    @Test func presetDraftEditUndoes() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let undo = undoManager(for: wb)
        let id = f.presetId("Instagram Standard")
        wb.selectedPresetId = id
        await wb.settle()
        wb.addLayer(.signature)
        #expect(undo.undoActionName == "添加图层")
        #expect(wb.hasUnsavedBuiltInEdits)
        undo.undo()
        #expect(wb.presetEditor?.draft.layers.contains { $0.layerId == "signature" } == false)
        #expect(!wb.hasUnsavedBuiltInEdits && wb.presetDrafts.isEmpty)
        undo.redo()
        #expect(wb.presetEditor?.draft.layers.contains { $0.layerId == "signature" } == true)
        #expect(wb.hasUnsavedEdits(id))
    }

    @Test func applyingPresetUndoesAndRedoes() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let a = try await f.addJob("A.jpg")
        let wb = f.workbench
        let ids = await wb.addSources([try f.photo("B.jpg")])
        let undo = undoManager(for: wb)
        let xhs = f.presetId("XHS Standard")
        // 任务 A 换成 XHS，源图 B 新建一个任务。
        wb.selection = [.job(a), .source(try #require(ids.first))]
        await wb.clickPreset(xhs)
        await wb.settle()
        #expect(undo.undoActionName == "应用预设")
        #expect(wb.allJobs.count == 2 && wb.job(a)?.basePreset.presetId == xhs)

        undo.undo()
        #expect(wb.allJobs.map(\.id) == [a])
        #expect(wb.job(a)?.basePreset.presetId == f.presetId("Instagram Standard"))
        undo.redo()
        #expect(wb.allJobs.count == 2 && wb.job(a)?.basePreset.presetId == xhs)
        #expect(wb.sourceItem(try #require(ids.first))?.jobs.first?.basePreset.presetId == xhs)
    }

    @Test func addingImagesUndoesAndRedoes() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let undo = undoManager(for: wb)
        let ids = await wb.addSources([try f.photo("A.jpg"), try f.photo("B.jpg")])
        await wb.settle()
        #expect(ids.count == 2 && undo.undoActionName == "添加图片")
        undo.undo()
        #expect(wb.sources.isEmpty)
        undo.redo()
        #expect(wb.sources.map(\.id) == ids)
        // 重做后源图的检查结果还在。
        await wb.settle()
        #expect(wb.sources.allSatisfy { $0.inspection != nil })

        // 撤销添加图片之前，撤销记录按顺序一步步回去。
        await wb.addJobs(preset: f.presetId("XHS Standard"), to: ids)
        #expect(undo.undoActionName == "添加任务")
        undo.undo()
        #expect(wb.allJobs.isEmpty && wb.sources.count == 2)
        undo.undo()
        #expect(wb.sources.isEmpty && !undo.canUndo)
    }

    @Test func removeAndDuplicateUndo() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let a = try await f.addJob()
        let wb = f.workbench
        let undo = undoManager(for: wb)
        wb.selection = [.job(a)]
        wb.duplicateSelectedJobs()
        #expect(wb.allJobs.count == 2 && undo.undoActionName == "复制任务")
        wb.remove([.source(try #require(wb.job(a)?.sourceId))])
        #expect(wb.sources.isEmpty && undo.undoActionName == "移除")
        undo.undo()
        #expect(wb.allJobs.count == 2)
        undo.undo()
        #expect(wb.allJobs.map(\.id) == [a])
    }

    @Test func startingBatchClearsUndoHistory() async throws {
        let f = try Fixture()
        await f.workbench.load()
        _ = try await f.addJob()
        let wb = f.workbench
        let undo = undoManager(for: wb)
        wb.setField(\.canvas.minMarginPx, 80)
        #expect(undo.canUndo)
        await wb.startBatch()
        await f.waitForRun()
        // 已提交的任务不会被撤销回「当前」。
        #expect(wb.sources.isEmpty && !undo.canUndo)
    }
}
