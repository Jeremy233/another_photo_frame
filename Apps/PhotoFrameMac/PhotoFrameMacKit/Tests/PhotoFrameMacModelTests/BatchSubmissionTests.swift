import Foundation
import PhotoFrameApplication
import PhotoFrameCore
@testable import PhotoFrameMacModel
import Testing

/// 开始批处理、任务列表在等待后端期间被改动时的行为。
@MainActor @Suite struct BatchSubmissionTests {
    @Test func startBatchRunsOnceAtATime() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let a = try await f.addJob("A.jpg")
        let b = try await f.addJob("B.jpg")
        let wb = f.workbench
        // 连按两次「开始批处理」：第二次在第一次还在校验时到达。每个任务只提交一次。
        async let first: Void = wb.startBatch()
        async let second: Void = wb.startBatch()
        _ = await (first, second)
        await f.waitForRun()
        #expect(wb.jobs.count == 2)
        #expect(wb.job(a) == nil && wb.job(b) == nil && wb.sources.isEmpty)
    }

    @Test func draftEditedDuringValidationStaysInCurrent() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let a = try await f.addJob("A.jpg")
        let b = try await f.addJob("B.jpg")
        let wb = f.workbench
        let other = f.root.appending(path: "Other", directoryHint: .isDirectory)
        // 后端还在校验第一个任务时，用户改了第二个任务的位置。
        f.hooks.set { $0.beforeValidate = { @MainActor in wb.setDestination(other, for: [.job(b)]) } }
        await wb.startBatch()
        await f.waitForRun()
        // 改过的任务不提交改动前的内容：它留在「当前」，改动还在。
        #expect(wb.job(a) == nil)
        #expect(wb.job(b)?.destination == other)
        #expect(wb.jobs.map(\.spec.source.fileURL.lastPathComponent) == ["A.jpg"])
    }

    @Test func reviewShowsTheJobEvenWhenAPresetIsInTheInspector() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let wb = f.workbench
        // 3:2 的照片做全景：带警告。
        let jobId = try await f.addJob(preset: "Instagram Panorama")
        #expect(wb.selection == [.job(jobId)])
        // 任务还是选中的，但右栏在看左栏的预设。
        let presetId = f.presetId("Instagram Standard")
        wb.selectedPresetId = presetId
        await wb.settle()
        #expect(wb.inspectorSubject == .preset(presetId))

        await wb.startBatch()
        #expect(wb.warningPrompt != nil)
        await wb.resolveWarnings(.review)
        #expect(wb.inspectorSubject == .jobs([jobId]))
        #expect(wb.preview.subject?.preset?.name == "Instagram Panorama")
    }

    @Test func reexportSkipsUnfinishedJobs() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let ids = try await queuedJob(f)
        await wb.refreshJobs()
        #expect(wb.record(ids[0])?.status == .queued)
        // 「活跃」和「已完成」共用一个选择：还没做完的任务不能再导出一份。
        await wb.reexport(Set(ids))
        #expect(await f.service.jobs().count == 1)
        _ = await f.service.waitUntilFinished(ids)
    }

    @Test func refreshKeepsRecordsThatEventsUpdatedMeanwhile() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let ids = try await queuedJob(f)
        await wb.refreshJobs()
        #expect(wb.record(ids[0])?.status == .queued)
        // 读到任务列表的快照之后、返回之前，任务被取消，事件先一步更新了界面：刷新不能用旧快照盖掉它。
        let service = f.service
        f.hooks.set {
            $0.afterJobsSnapshot = { @MainActor in
                try? await service.cancel(ids[0])
                if let record = try? await service.status(ids[0]) { await wb.apply(.attemptFinished(record)) }
            }
        }
        await wb.refreshJobs()
        #expect(wb.record(ids[0])?.status == .canceled)
    }

    @Test func staleEventsDoNotOverwriteNewerRecords() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let ids = try await queuedJob(f)
        let queued = try await f.service.status(ids[0])
        try await f.service.cancel(ids[0])
        await wb.refreshJobs()
        // 刷新之后才处理到的「已加入」事件带的是旧记录。
        await wb.apply(.jobAdded(queued))
        #expect(wb.record(ids[0])?.status == .canceled)
    }

    @Test func progressEventsPatchTheLocalRecord() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let ids = try await queuedJob(f)
        await wb.refreshJobs()
        let attempt = try #require(wb.record(ids[0])?.currentAttempt.attemptId)
        let calls = f.hooks.statusCalls
        let progress = JobProgress(stage: .rendering, completedOutputs: 1, plannedOutputs: 3)
        await wb.apply(.progress(jobId: ids[0], attemptId: attempt, progress: progress))
        // 每写出一页一次的进度事件直接改本地记录，不再整条重新读取。
        #expect(wb.record(ids[0])?.progress == progress)
        #expect(f.hooks.statusCalls == calls)
        // 比本地旧的进度不覆盖新的。
        await wb.apply(.progress(jobId: ids[0], attemptId: attempt, progress: JobProgress(stage: .decoding)))
        #expect(wb.record(ids[0])?.progress == progress)
        // 本地没有这次执行：重新读取。
        await wb.apply(.progress(jobId: ids[0], attemptId: AttemptID(), progress: progress))
        #expect(f.hooks.statusCalls == calls + 1)
    }

    @Test func finishedBackgroundWorkIsRemoved() async throws {
        let f = try Fixture()
        let wb = f.workbench
        let ids = await wb.addSources([try f.photo("W.jpg")])
        let id = try #require(ids.first)
        // 不调用 settle：后台检查做完后自己从工作表里移除。
        for _ in 0..<500 where wb.sourceItem(id)?.inspection == nil && wb.sourceItem(id)?.inspectionError == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(wb.sourceItem(id)?.inspection != nil)
        #expect(wb.work.isEmpty)
    }

    /// 直接通过服务提交一个任务。队列是暂停的，任务停在 queued。
    private func queuedJob(_ f: Fixture) async throws -> [JobID] {
        let source = try await f.service.addSource(try f.photo("Q.jpg"))
        let preset = try await f.service.resolvePreset(.library("Instagram Standard")).preset
        return try await f.service.submit(ExportRequest(
            sourceIds: [source.sourceId], presets: [preset], destination: ExportDestination(rootDirectory: f.exports)))
    }
}
