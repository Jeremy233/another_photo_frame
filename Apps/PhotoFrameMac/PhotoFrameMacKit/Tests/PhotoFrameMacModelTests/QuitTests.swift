import Foundation
import PhotoFrameApplication
import PhotoFrameCore
@testable import PhotoFrameMacModel
import Testing

/// ⌘Q 前的确认：有没开始的任务时问一次（可以不再显示），有正在处理的任务时总要问。
@MainActor @Suite struct QuitTests {
    private func record(_ status: JobStatus) -> JobRecord {
        var r = JobRecord(spec: JobSpec(
            source: PhotoSource(fileURL: URL(filePath: "/tmp/a.jpg")),
            preset: ExportPreset(name: "P", canvas: CanvasSettings(width: 1080, height: 1350)),
            destination: ExportDestination(rootDirectory: URL(filePath: "/tmp"))))
        r.currentAttempt.status = status
        return r
    }

    @Test func nothingToLoseQuitsImmediately() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        _ = await wb.addSources([try f.photo("A.jpg")])
        // 只有源图、没有任务；已经结束的任务也不算。
        wb.jobs = [record(.completed), record(.failed), record(.canceled)]
        #expect(wb.quitPrompt == .none)
    }

    @Test func unstartedJobsAskUnlessTurnedOff() async throws {
        let f = try Fixture()
        await f.workbench.load()
        _ = try await f.addJob("A.jpg")
        _ = try await f.addJob("B.jpg")
        let wb = f.workbench
        wb.jobs = [record(.queued), record(.completed)]
        // 「当前」里的 2 个 + 「活跃」里排队的 1 个。
        #expect(wb.quitPrompt == .unstartedJobs(count: 3))

        // 取消时勾了「不再显示」也不改设置。
        #expect(await wb.resolveQuit(.cancel, dontAskAgain: true) == false)
        #expect(wb.settings.confirmsQuitWithUnstartedJobs)
        // 退出并勾「不再显示」：以后不再问（设置窗口里能改回来）。
        #expect(await wb.resolveQuit(.quit, dontAskAgain: true))
        #expect(!wb.settings.confirmsQuitWithUnstartedJobs)
        #expect(f.settingsStore.load()?.confirmsQuitWithUnstartedJobs == false)
        #expect(wb.quitPrompt == .none)
        wb.settings.confirmsQuitWithUnstartedJobs = true
        #expect(wb.quitPrompt == .unstartedJobs(count: 3))
    }

    @Test func processingJobsAlwaysAsk() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        wb.settings.confirmsQuitWithUnstartedJobs = false
        wb.jobs = [record(.rendering), record(.encoding), record(.queued)]
        #expect(wb.processingJobCount == 2)
        #expect(wb.quitPrompt == .processingJobs(count: 2))
        wb.settings.confirmsQuitWithUnstartedJobs = true
        #expect(wb.quitPrompt == .processingJobs(count: 2))
    }

    @Test func quitWhenFinishedWaitsForActiveJobs() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        var readyCount = 0
        wb.onReadyToQuit = { readyCount += 1 }
        let running = record(.rendering)
        let queued = record(.queued)
        wb.jobs = [running, queued]
        wb.isQueuePaused = false
        #expect(await wb.resolveQuit(.quitWhenFinished) == false)
        #expect(wb.isWaitingToQuit)

        // 正在处理的做完了，但队列还在派发排队的任务：继续等。
        var done = running
        done.currentAttempt.status = .completed
        wb.jobs = [done, queued]
        wb.checkQuitWhenFinished()
        #expect(readyCount == 0)
        #expect(wb.quitPrompt == .unstartedJobs(count: 1))

        // 都做完了：通知应用退出，这时不再询问。
        var doneToo = queued
        doneToo.currentAttempt.status = .completed
        wb.jobs = [done, doneToo]
        wb.checkQuitWhenFinished()
        #expect(readyCount == 1)
        #expect(wb.quitPrompt == .none)

        // 再按 ⌘Q 选「取消」：不再等。
        wb.jobs = [running]
        #expect(await wb.resolveQuit(.cancel) == false)
        #expect(!wb.isWaitingToQuit)
    }

    @Test func pausedQueueDoesNotWaitForQueuedJobs() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        wb.jobs = [record(.queued)]
        #expect(wb.isQueuePaused)
        // 队列暂停着，排队的任务不会再开始：选「完成后退出」立即退出。
        #expect(await wb.resolveQuit(.quitWhenFinished))
    }

    @Test func stopAndQuitCancelsActiveJobs() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let source = try await f.service.addSource(try f.photo("C.jpg"))
        let preset = try await f.service.resolvePreset(.library("XHS Standard")).preset
        let ids = try await f.service.submit(ExportRequest(
            sourceIds: [source.sourceId], presets: [preset], destination: ExportDestination(rootDirectory: f.exports)))
        await wb.refreshJobs()
        #expect(wb.activeCount == 1)
        #expect(await wb.resolveQuit(.stopAndQuit))
        #expect(try await f.service.status(try #require(ids.first)).status == .canceled)
        #expect(wb.activeCount == 0)
    }
}
