import Foundation
import PhotoFrameApplication
import PhotoFrameCore
@testable import PhotoFrameMacModel
import Testing

/// 任务列表的多选（⌘A、⌘ 点按、⇧ 点按），以及把预设应用到选中的行（拖放、点左栏的预设）。
@MainActor @Suite struct SelectionTests {
    /// 三张源图，前两张各有一个任务。
    private func batch(_ f: Fixture) async throws -> (sources: [SourceID], jobs: [UUID]) {
        await f.workbench.load()
        let a = try await f.addJob("A.jpg")
        let b = try await f.addJob("B.jpg", preset: "XHS Standard")
        let ids = await f.workbench.addSources([try f.photo("C.jpg")])
        let sources = f.workbench.sources.map(\.id)
        #expect(sources.count == 3 && ids.count == 1)
        return (sources, [a, b])
    }

    @Test func selectAllSelectsEveryVisibleRow() async throws {
        let f = try Fixture()
        let (sources, jobs) = try await batch(f)
        let wb = f.workbench
        wb.selectAll()
        #expect(wb.selection == Set(sources.map(BatchItemID.source) + jobs.map(BatchItemID.job)))
        // 右栏显示全部任务（按列表顺序），预览显示第一个。
        #expect(wb.inspectorSubject == .jobs(jobs))
        #expect(wb.previewSubject?.sourceId == sources[0])

        // 折起来的源图的任务看不见，不选中。
        wb.setCollapsed(sources[1], true)
        wb.selectAll()
        #expect(!wb.selection.contains(.job(jobs[1])) && wb.selection.contains(.source(sources[1])))
        #expect(wb.visibleItems == [.source(sources[0]), .job(jobs[0]), .source(sources[1]), .source(sources[2])])
    }

    @Test func toggleAndRangeSelection() async throws {
        let f = try Fixture()
        let (sources, jobs) = try await batch(f)
        let wb = f.workbench
        // ⌘ 点按：加入、再点一次去掉。
        wb.selection = [.job(jobs[1])]
        wb.selection.insert(.job(jobs[0]))
        #expect(wb.selectedJobIds == jobs)
        #expect(wb.inspectorSubject == .jobs(jobs))
        wb.selection.remove(.job(jobs[1]))
        #expect(wb.inspectorSubject == .jobs([jobs[0]]))

        // ⇧ 点按：从锚点到点到的行之间看得到的行。
        let items = wb.visibleItems
        let range = items[items.firstIndex(of: .job(jobs[0]))!...items.firstIndex(of: .source(sources[2]))!]
        wb.selection = Set(range)
        #expect(wb.selection == [.job(jobs[0]), .source(sources[1]), .job(jobs[1]), .source(sources[2])])
        #expect(wb.targetSourceIds == sources)
    }

    @Test func applyingPresetToSelectedSourcesCreatesOneJobEach() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let ids = await wb.addSources([try f.photo("A.jpg"), try f.photo("B.jpg"), try f.photo("C.jpg")])
        wb.selection = Set(ids.map(BatchItemID.source))
        #expect(wb.appliesPresetOnClick)

        // 点左栏的预设：直接应用，不选中左栏的预设。
        let preset = f.presetId("XHS Standard")
        wb.choosePreset(preset)
        #expect(wb.selectedPresetId == nil)
        await wb.clickPreset(preset)
        await wb.settle()
        #expect(wb.sources.map { $0.jobs.count } == [1, 1, 1])
        let jobs = wb.sources.flatMap(\.jobs).map(\.id)
        #expect(wb.selection == Set(jobs.map(BatchItemID.job)))
        #expect(wb.inspectorSubject == .jobs(jobs))
        #expect(wb.previewSubject?.sourceId == ids[0])
        #expect(wb.sources.flatMap(\.jobs).allSatisfy { $0.basePreset.presetId == preset })

        // 之后在右栏改参数，作用于全部选中的任务。
        wb.setField(\.canvas.minMarginPx, 33)
        #expect(wb.sources.flatMap(\.jobs).allSatisfy { $0.preset.canvas.minMarginPx == 33 && $0.isModified })
    }

    @Test func applyingPresetToSelectedJobsReplacesTheirPreset() async throws {
        let f = try Fixture()
        let (sources, jobs) = try await batch(f)
        let wb = f.workbench
        let destination = f.root.appending(path: "Elsewhere", directoryHint: .isDirectory)
        wb.selection = [.job(jobs[0])]
        wb.setDestinationForSelection(destination)
        wb.selection = Set(jobs.map(BatchItemID.job))
        let preset = f.presetId("Instagram Standard")
        await wb.clickPreset(preset)
        await wb.settle()
        // 不多建任务；位置不变。
        #expect(wb.sources.map { $0.jobs.count } == [1, 1, 0])
        #expect(jobs.allSatisfy { wb.job($0)?.basePreset.presetId == preset && wb.job($0)?.isModified == false })
        #expect(wb.job(jobs[0])?.destination == destination)
        #expect(wb.selection == Set(jobs.map(BatchItemID.job)))
        _ = sources
    }

    @Test func dropOnSelectedRowAppliesToTheWholeSelection() async throws {
        let f = try Fixture()
        let (sources, jobs) = try await batch(f)
        let wb = f.workbench
        let preset = f.presetId("XHS Standard")
        // 源图 A 和它的任务都选中、再加上源图 C：A、C 各建一个任务，A 原来的任务不变。
        wb.selection = [.source(sources[0]), .job(jobs[0]), .source(sources[2])]
        #expect(await wb.drop(.preset(preset), on: .source(sources[2])))
        await wb.settle()
        #expect(wb.sources.map { $0.jobs.count } == [2, 1, 1])
        #expect(wb.job(jobs[0])?.basePreset.presetId == f.presetId("Instagram Standard"))
        #expect(wb.selection.count == 2 && !wb.selection.contains(.job(jobs[0])))

        // 拖到没有选中的行上：只作用于这一行。
        let instagram = f.presetId("Instagram Standard")
        #expect(await wb.drop(.preset(instagram), on: .job(jobs[1])))
        #expect(wb.job(jobs[1])?.basePreset.presetId == instagram)
        #expect(wb.sources.map { $0.jobs.count } == [2, 1, 1])
    }

    @Test func clickingPresetWithoutBatchSelectionEditsThePreset() async throws {
        let f = try Fixture()
        let (_, jobs) = try await batch(f)
        let wb = f.workbench
        wb.selection = []
        #expect(!wb.appliesPresetOnClick)
        let preset = f.presetId("XHS Standard")
        wb.choosePreset(preset)
        await wb.clickPreset(preset)
        await wb.settle()
        #expect(wb.inspectorSubject == .preset(preset))
        #expect(wb.allJobs.map(\.id) == jobs)

        // 右栏在显示预设时，选中任务后再点预设又是应用。
        wb.selection = [.job(jobs[0])]
        #expect(wb.appliesPresetOnClick)
        wb.focusPreset()
        #expect(!wb.appliesPresetOnClick)
    }

    @Test func jobRemovedWhileApplyingIsNotSelected() async throws {
        let f = try Fixture()
        let (_, jobs) = try await batch(f)
        let wb = f.workbench
        wb.selection = Set(jobs.map(BatchItemID.job))
        // 读预设期间移除了其中一个任务：应用完只选中还在的任务。
        f.hooks.set { $0.beforeResolvePreset = { await MainActor.run { wb.remove([.job(jobs[1])]) } } }
        await wb.clickPreset(f.presetId("XHS Standard"))
        #expect(wb.job(jobs[1]) == nil)
        #expect(wb.selection == [.job(jobs[0])])
    }
}
