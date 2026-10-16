import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameStorage
import Testing

@Suite("任务队列")
struct JobQueueTests {
    @Test("正常完成：按流水线经过每个状态，进度来自真实指标")
    func happyPath() async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer([.succeed(slides: 3)])
        let queue = JobQueue(renderer: renderer)
        let log = EventLog(await queue.events())

        let job = await queue.submit(box.spec(try box.makeSource()))
        let record = try #require(await queue.waitUntilFinished([job.jobId]).first)

        #expect(record.status == .completed)
        #expect(record.currentAttempt.history.map(\.status) == JobStatus.pipeline)
        await eventually { log.statuses(of: job.jobId).last == .completed }
        #expect(log.statuses(of: job.jobId) == Array(JobStatus.pipeline.dropFirst()))

        let progress = log.progress(of: job.jobId)
        #expect(progress.first?.plannedOutputs == 4)
        // 每写完一个文件加一；最后一条是发布后的字节数。
        #expect(progress.map(\.completedOutputs) == [0, 1, 2, 3, 4, 4])
        #expect(progress.dropLast().allSatisfy { $0.bytesWritten == 0 })
        #expect(record.progress.completedOutputs == 4)
        #expect(record.progress.plannedOutputs == 4)
        #expect(record.progress.bytesWritten == record.manifest?.totalBytes)
        #expect((record.progress.bytesWritten) > 0)

        let manifest = try #require(record.manifest)
        #expect(manifest.items.map(\.fileName) == ["00_Cover.jpg", "01_Slide.jpg", "02_Slide.jpg", "03_Slide.jpg"])
        #expect(manifest.warnings.map(\.code) == ["test.note"])
        #expect(record.currentAttempt.warnings.map(\.code).contains("test.note"))
        #expect(record.currentAttempt.startedAt != nil && record.currentAttempt.finishedAt != nil)
        #expect(!box.stagingExists)
        #expect(log.all.contains { if case .attemptFinished(let r) = $0 { r.jobId == job.jobId && r.status == .completed } else { false } })
    }

    @Test("渲染失败：状态 failed，记录错误码，不留任何文件")
    func renderFailure() async throws {
        let box = try Sandbox()
        let queue = JobQueue(renderer: FakeRenderer([.fail(after: 2)]))
        let job = await queue.submit(box.spec(try box.makeSource()))
        let record = try #require(await queue.waitUntilFinished([job.jobId]).first)

        #expect(record.status == .failed)
        #expect(record.error?.code == "render.decode_failed")
        #expect(record.currentAttempt.history.map(\.status) == [.queued, .validating, .decoding, .rendering, .encoding, .failed])
        #expect(record.manifest == nil)
        #expect(box.exportTree().isEmpty, "\(box.exportTree())")
    }

    @Test("输出校验失败：发布阶段失败，目的地没有半成品")
    func publishFailure() async throws {
        let box = try Sandbox()
        let queue = JobQueue(renderer: FakeRenderer([.corruptFile(index: 2)]))
        let job = await queue.submit(box.spec(try box.makeSource()))
        let record = try #require(await queue.waitUntilFinished([job.jobId]).first)

        #expect(record.status == .failed)
        #expect(record.error?.code == "export.output_format_mismatch")
        #expect(record.currentAttempt.history.map(\.status).suffix(2) == [.writing, .failed])
        #expect(box.exportTree().isEmpty, "\(box.exportTree())")
    }

    @Test("渲染器试图把原图当作输出：失败，原图原封不动")
    func neverMovesOriginal() async throws {
        let box = try Sandbox()
        let source = try box.makeSource()
        let before = try Data(contentsOf: source.fileURL)
        let queue = JobQueue(renderer: FakeRenderer([.returnSourceFile, .hardLinkSource]))
        let a = await queue.submit(box.spec(source))
        let b = await queue.submit(box.spec(source))
        let records = await queue.waitUntilFinished([a.jobId, b.jobId])

        #expect(records.map(\.status) == [.failed, .failed])
        #expect(records.map { $0.error?.code } == ["export.output_outside_staging", "export.output_not_regular_file"])
        #expect(try Data(contentsOf: source.fileURL) == before)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.fileURL.path)
        #expect((attributes[.referenceCount] as? NSNumber)?.intValue == 1, "硬链接应随临时目录一起删除")
        #expect(box.exportTree().isEmpty, "\(box.exportTree())")
    }

    @Test("校验阶段：源文件丢失、预设错误、输出目录是文件")
    func validationFailures() async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer()
        let queue = JobQueue(renderer: renderer)

        let missing = PhotoSource(fileURL: box.root.appending(path: "gone.tif"))
        var badPreset = ExportPreset.testPanorama
        badPreset.canvas.minMarginPx = -1
        let source = try box.makeSource()
        let fileAsRoot = box.root.appending(path: "file")
        try Data("x".utf8).write(to: fileAsRoot)

        let jobs = await queue.submit([
            box.spec(missing),
            box.spec(source, preset: badPreset),
            JobSpec(source: source, preset: .testPanorama, destination: ExportDestination(rootDirectory: fileAsRoot)),
        ])
        let records = await queue.waitUntilFinished(jobs.map(\.jobId))
        #expect(records.map(\.status) == [.failed, .failed, .failed])
        #expect(records.map { $0.error?.code } == ["job.source_unreadable", "job.invalid_preset", "job.destination_unavailable"])
        #expect(records.allSatisfy { $0.currentAttempt.history.map(\.status) == [.queued, .validating, .failed] })
        #expect(renderer.calls == 0)
    }

    @Test("缺少必需素材：校验阶段失败（§8.2）")
    func missingRequiredSlot() async throws {
        let box = try Sandbox()
        var preset = ExportPreset.testStandard
        preset.assetSlots = [AssetSlot(slotId: "photographer.signature", kind: .image, required: true)]
        preset.layers = [OverlayLayer(layerId: "sig", type: .asset, slotId: "photographer.signature")]
        let config = QueueConfiguration(slotResolver: SlotResolver(library: InMemoryAssetLibrary(), bindings: AssetBindingTable()))
        let queue = JobQueue(renderer: FakeRenderer(), configuration: config)
        let job = await queue.submit(box.spec(try box.makeSource(), preset: preset))
        let record = try #require(await queue.waitUntilFinished([job.jobId]).first)
        #expect(record.status == .failed)
        #expect(record.error?.code == "slot.missing_required")
    }

    @Test("取消执行中的任务：停止渲染，只删除自己的临时文件")
    func cancelRunning() async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer(holds: true)
        let queue = JobQueue(renderer: renderer)
        let job = await queue.submit(box.spec(try box.makeSource()))

        await eventually { renderer.running == 1 }
        // 另一个进程 / 任务留下的临时文件，不能被删除。
        let foreign = box.stagingRoot.appending(path: "someone-else/keep.bin")
        try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: foreign)
        let ownStaging = try #require(renderer.outputDirectories.first).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: ownStaging.path))

        try await queue.cancel(job.jobId)
        let record = try #require(await queue.waitUntilFinished([job.jobId]).first)

        #expect(record.status == .canceled)
        #expect(record.error == nil)
        #expect(record.currentAttempt.history.last?.status == .canceled)
        #expect(!FileManager.default.fileExists(atPath: ownStaging.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(box.exportTree().allSatisfy { $0.hasPrefix(".photoframe-staging") }, "\(box.exportTree())")
        #expect(renderer.running == 0)

        // 再次取消是空操作。
        try await queue.cancel(job.jobId)
    }

    @Test("取消排队中的任务：不会开始执行")
    func cancelQueued() async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer()
        let queue = JobQueue(renderer: renderer, configuration: QueueConfiguration(startsPaused: true))
        let job = await queue.submit(box.spec(try box.makeSource()))
        try await queue.cancel(job.jobId)
        await queue.resume()
        await queue.waitUntilIdle()

        let record = try #require(await queue.record(for: job.jobId))
        #expect(record.status == .canceled)
        #expect(record.currentAttempt.history.map(\.status) == [.queued, .canceled])
        #expect(renderer.calls == 0)
    }

    @Test("已完成的任务不能取消，未知任务报错")
    func cancelErrors() async throws {
        let box = try Sandbox()
        let queue = JobQueue(renderer: FakeRenderer())
        let job = await queue.submit(box.spec(try box.makeSource()))
        _ = await queue.waitUntilFinished([job.jobId])
        await #expect(throws: ApplicationError.self) { try await queue.cancel(job.jobId) }
        await #expect(throws: ApplicationError.self) { try await queue.cancel(JobID()) }
        await #expect(throws: ApplicationError.self) { try await queue.retry(job.jobId) }
    }

    @Test("重试：新 Attempt ID，保留历史，用同一份预设快照")
    func retry() async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer([.fail(after: 1), .succeed(slides: 1)])
        let queue = JobQueue(renderer: renderer)
        let log = EventLog(await queue.events())
        let job = await queue.submit(box.spec(try box.makeSource()))
        var record = try #require(await queue.waitUntilFinished([job.jobId]).first)
        #expect(record.status == .failed)
        let firstAttempt = record.currentAttempt

        let newAttempt = try await queue.retry(job.jobId)
        record = try #require(await queue.waitUntilFinished([job.jobId]).first)

        #expect(newAttempt != firstAttempt.attemptId)
        #expect(record.attempts.count == 2)
        #expect(record.attempts[0] == firstAttempt, "旧 Attempt 原样保留")
        #expect(record.attempts[1].attemptId == newAttempt)
        #expect(record.attempts[1].number == 2)
        #expect(record.status == .completed)
        #expect(record.manifest?.attemptId == newAttempt)
        #expect(record.manifest?.items.count == 2)
        #expect(renderer.calls == 2)
        let dirs = renderer.outputDirectories.map { $0.deletingLastPathComponent().lastPathComponent }
        #expect(dirs == [firstAttempt.attemptId.description, newAttempt.description], "每个 Attempt 有自己的临时目录")
        await eventually { log.all.contains { if case .attemptCreated(_, let a, 2) = $0 { a == newAttempt } else { false } } }
        #expect(!box.stagingExists)
    }

    @Test("取消后重试")
    func retryAfterCancel() async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer(holds: true)
        let queue = JobQueue(renderer: renderer)
        let job = await queue.submit(box.spec(try box.makeSource()))
        await eventually { renderer.running == 1 }
        try await queue.cancel(job.jobId)
        _ = await queue.waitUntilFinished([job.jobId])

        renderer.release()
        try await queue.retry(job.jobId)
        let record = try #require(await queue.waitUntilFinished([job.jobId]).first)
        #expect(record.attempts.map(\.status) == [.canceled, .completed])
    }

    @Test("暂停只停止派发新任务；继续后接着执行")
    func pauseAndResume() async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer(holds: true)
        let queue = JobQueue(renderer: renderer, configuration: QueueConfiguration(maxConcurrentJobs: 1))
        let source = try box.makeSource()
        let jobs = await queue.submit([box.spec(source), box.spec(source), box.spec(source)])

        await eventually { renderer.running == 1 }
        await queue.pause()
        renderer.release()
        _ = await queue.waitUntilFinished([jobs[0].jobId])
        await queue.waitUntilIdle()

        #expect(await queue.record(for: jobs[0].jobId)?.status == .completed, "执行中的任务继续做完")
        #expect(await queue.record(for: jobs[1].jobId)?.status == .queued)
        #expect(await queue.record(for: jobs[2].jobId)?.status == .queued)
        #expect(renderer.calls == 1)

        await queue.resume()
        let records = await queue.waitUntilFinished(jobs.map(\.jobId))
        #expect(records.map(\.status) == [.completed, .completed, .completed])
        // 同名作品依次加版本后缀。
        #expect(records.compactMap { $0.manifest?.directory.lastPathComponent }
            == ["Badlands_Panorama", "Badlands_Panorama_v2", "Badlands_Panorama_v3"])
    }

    @Test("并发上限", arguments: [1, 2, 3])
    func concurrencyLimit(limit: Int) async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer(holds: true)
        let queue = JobQueue(renderer: renderer, configuration: QueueConfiguration(maxConcurrentJobs: limit, memoryBudgetBytes: nil))
        let source = try box.makeSource()
        let jobs = await queue.submit((0..<6).map { _ in box.spec(source) })

        await eventually { renderer.running == limit }
        try await Task.sleep(for: .milliseconds(30))
        #expect(renderer.running == limit)
        #expect(await queue.runningJobIds.count == limit)

        renderer.release()
        let records = await queue.waitUntilFinished(jobs.map(\.jobId))
        #expect(records.allSatisfy { $0.status == .completed }, "\(records.compactMap(\.error))")
        #expect(renderer.maxRunning == limit)
        // 并行发布的同名作品不会互相覆盖。
        #expect(Set(records.compactMap { $0.manifest?.directory }).count == 6)
        #expect(!box.stagingExists)
    }

    @Test("内存预算限制并行数；超过预算的单个任务仍能执行")
    func memoryBudget() async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer(holds: true, memoryEstimate: 400)
        let queue = JobQueue(renderer: renderer, configuration: QueueConfiguration(maxConcurrentJobs: 4, memoryBudgetBytes: 1000))
        let source = try box.makeSource()
        let jobs = await queue.submit((0..<4).map { _ in box.spec(source) })

        await eventually { renderer.running == 2 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(renderer.running == 2, "400 × 2 ≤ 1000 < 400 × 3")
        renderer.release()
        _ = await queue.waitUntilFinished(jobs.map(\.jobId))
        #expect(renderer.maxRunning == 2)

        let huge = FakeRenderer(memoryEstimate: 5000)
        let queue2 = JobQueue(renderer: huge, configuration: QueueConfiguration(maxConcurrentJobs: 4, memoryBudgetBytes: 1000))
        let more = await queue2.submit((0..<2).map { _ in box.spec(source) })
        let records = await queue2.waitUntilFinished(more.map(\.jobId))
        #expect(records.allSatisfy { $0.status == .completed })
        #expect(huge.maxRunning == 1)
    }

    @Test("没有渲染器估算时按源图像素估算内存")
    func fallbackEstimate() {
        let config = QueueConfiguration(fallbackJobMemoryBytes: 123)
        var source = PhotoSource(fileURL: URL(filePath: "/x.tif"))
        let spec = JobSpec(source: source, preset: .testStandard, destination: ExportDestination(rootDirectory: URL(filePath: "/out")))
        #expect(config.estimatedMemory(for: spec) == 123)
        source.image = SourceImage(storedSize: PixelSize(width: 8000, height: 6000))
        let sized = JobSpec(source: source, preset: .testStandard, destination: spec.destination)
        #expect(config.estimatedMemory(for: sized) == 8000 * 6000 * 8 + 1080 * 1440 * 16)
    }

    @Test("预设快照：提交后修改预设不影响任务")
    func presetSnapshot() async throws {
        let box = try Sandbox()
        var preset = ExportPreset.testPanorama
        let queue = JobQueue(renderer: FakeRenderer(), configuration: QueueConfiguration(startsPaused: true))
        let job = await queue.submit(box.spec(try box.makeSource(), preset: preset))
        preset.name = "Changed"
        #expect(await queue.record(for: job.jobId)?.spec.preset.name == "Instagram Panorama")
    }
}
