import Darwin
import Foundation
@testable import PhotoFrameApplication
import PhotoFrameCore
import Synchronization
import Testing

@Suite("覆盖（D-49）")
struct OverwriteTests {
    func spec(_ box: Sandbox, _ source: PhotoSource, policy: ConflictPolicy, workName: String = OutputNaming.defaultWorkNameTemplate) -> JobSpec {
        JobSpec(source: source, preset: .testPanorama,
                destination: ExportDestination(rootDirectory: box.exports, naming: OutputNaming(workNameTemplate: workName), conflictPolicy: policy))
    }

    /// 写出一组输出并发布，返回清单。`marker` 区分各次导出的文件内容。
    @discardableResult
    func export(_ exporter: AtomicExporter, _ spec: JobSpec, slides: Int, marker: UInt8, protected: [URL] = []) throws -> OutputManifest {
        let area = try exporter.makeStaging(destinationRoot: spec.destination.rootDirectory, attemptId: AttemptID())
        let roles: [JobOutputRole] = [.cover] + (0..<slides).map { .slide(position: $0 + 1) }
        let outputs = try roles.enumerated().map { i, role in
            let url = area.renderDirectory.appending(path: "f\(i)")
            try Data([0xFF, 0xD8, 0xFF, marker]).write(to: url)
            return JobRenderedOutput(role: role, fileURL: url, pixelSize: PixelSize(width: 1080, height: 1440), colorProfile: "sRGB")
        }
        return try exporter.publish(JobRenderResult(outputs: outputs), spec: spec, jobId: JobID(), staging: area,
                                    startedAt: Date(), protectedSources: protected)
    }

    func contents(_ dir: URL) throws -> [String: UInt8] {
        var result: [String: UInt8] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            result[name] = try Data(contentsOf: dir.appending(path: name)).last
        }
        return result
    }

    @Test("默认策略仍是加版本后缀")
    func defaultIsVersionSuffix() throws {
        #expect(ExportDestination(rootDirectory: URL(filePath: "/x")).conflictPolicy == .versionSuffix)
        let old = try JSONDecoder().decode(ExportDestination.self, from: Data(#"{"rootDirectory":"file:///x/","computeHashes":false}"#.utf8))
        #expect(old.conflictPolicy == .versionSuffix)
    }

    @Test("替换本软件之前发布的目录：旧文件全部换成新文件，不留多余切片")
    func replacesPrevious() throws {
        let box = try Sandbox()
        let exporter = AtomicExporter()
        let source = try box.makeSource()
        let first = try export(exporter, spec(box, source, policy: .versionSuffix), slides: 3, marker: 1)
        #expect(AtomicExporter.isPublishedByPhotoFrame(first.directory))

        let second = try export(exporter, spec(box, source, policy: .overwrite), slides: 1, marker: 2)
        #expect(second.directory == first.directory)
        #expect(try contents(second.directory) == ["00_Cover.jpg": 2, "01_Slide.jpg": 2])
        #expect(second.warnings.map(\.code) == ["export.replaced_previous"])
        #expect(AtomicExporter.isPublishedByPhotoFrame(second.directory))
        #expect(!box.stagingExists)
        #expect(box.exportTree().filter { !$0.hasPrefix("Instagram/Badlands_Panorama") } == ["Instagram"])
    }

    @Test("目标不存在时 overwrite 就是普通发布")
    func overwriteWithoutExisting() throws {
        let box = try Sandbox()
        let manifest = try export(AtomicExporter(), spec(box, try box.makeSource(), policy: .overwrite), slides: 1, marker: 1)
        #expect(manifest.directory.lastPathComponent == "Badlands_Panorama")
        #expect(manifest.warnings.isEmpty)
    }

    @Test("拒绝覆盖不是本软件发布的目录")
    func refusesForeignDirectory() throws {
        let box = try Sandbox()
        let target = box.exports.appending(path: "Instagram/Badlands_Panorama")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 9]).write(to: target.appending(path: "00_Cover.jpg"))

        #expect(throws: ApplicationError.self) {
            try export(AtomicExporter(), spec(box, try box.makeSource(), policy: .overwrite), slides: 1, marker: 2)
        }
        #expect(try contents(target) == ["00_Cover.jpg": 9])
        #expect(!box.stagingExists)
    }

    @Test("拒绝覆盖含有其他文件的目录（用户自己放进去的东西）")
    func refusesExtraFiles() throws {
        let box = try Sandbox()
        let exporter = AtomicExporter()
        let source = try box.makeSource()
        let first = try export(exporter, spec(box, source, policy: .versionSuffix), slides: 1, marker: 1)
        try Data("notes".utf8).write(to: first.directory.appending(path: "my notes.txt"))
        try Data().write(to: first.directory.appending(path: ".DS_Store"))

        do {
            try export(exporter, spec(box, source, policy: .overwrite), slides: 1, marker: 2)
            Issue.record("应当拒绝覆盖")
        } catch let error as ApplicationError {
            #expect(error.code == "export.overwrite_refused")
        }
        #expect(try contents(first.directory)["00_Cover.jpg"] == 1)
        #expect(FileManager.default.fileExists(atPath: first.directory.appending(path: "my notes.txt").path))
    }

    @Test("目标目录里有源图（本任务、队列中其他任务、硬链接）时拒绝，源图不受影响")
    func refusesWhenContainsSource() throws {
        let box = try Sandbox()
        let exporter = AtomicExporter()
        let outside = try box.makeSource()
        let first = try export(exporter, spec(box, outside, policy: .versionSuffix), slides: 1, marker: 1)

        // 1. 本任务的源图就放在旧作品目录里（文件名恰好像本软件的输出）。
        let inside = first.directory.appending(path: "01_Slide.jpg")
        let insideSource = PhotoSource(fileURL: inside)
        #expect(throws: ApplicationError.overwriteContainsSource(first.directory.path, inside.path)) {
            try export(exporter, spec(box, insideSource, policy: .overwrite, workName: "Badlands_Panorama"), slides: 1, marker: 2)
        }

        // 2. 队列中另一个任务的源图在里面。
        #expect(throws: ApplicationError.overwriteContainsSource(first.directory.path, inside.path)) {
            try export(exporter, spec(box, outside, policy: .overwrite), slides: 1, marker: 2, protected: [inside])
        }

        // 3. 里面的文件是某个源图的硬链接。
        let cover = first.directory.appending(path: "00_Cover.jpg")
        try FileManager.default.removeItem(at: cover)
        try FileManager.default.linkItem(at: outside.fileURL, to: cover)
        do {
            try export(exporter, spec(box, outside, policy: .overwrite), slides: 1, marker: 2)
            Issue.record("应当拒绝覆盖")
        } catch let error as ApplicationError {
            #expect(error.code == "export.overwrite_contains_source")
        }

        #expect(try Data(contentsOf: outside.fileURL) == Data("original-pixels".utf8))
        #expect(FileManager.default.fileExists(atPath: inside.path))
        #expect(!box.stagingExists)
    }

    @Test("拒绝覆盖符号链接")
    func refusesSymlink() throws {
        let box = try Sandbox()
        let exporter = AtomicExporter()
        let source = try box.makeSource()
        let real = try export(exporter, spec(box, source, policy: .versionSuffix), slides: 1, marker: 1)
        let link = box.exports.appending(path: "Instagram/Other_Panorama")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.directory)
        let other = try box.makeSource("Other.tif")
        #expect(throws: ApplicationError.self) {
            try export(exporter, spec(box, other, policy: .overwrite), slides: 1, marker: 2)
        }
        #expect(try contents(real.directory)["00_Cover.jpg"] == 1)
    }

    @Test("新目录就位失败：旧目录恢复原样")
    func restoresOnFailure() throws {
        let box = try Sandbox()
        let source = try box.makeSource()
        let first = try export(AtomicExporter(), spec(box, source, policy: .versionSuffix), slides: 2, marker: 1)
        let before = try contents(first.directory)

        // 改名序列：1 发布到目标（EEXIST）→ 2 挪开旧目录 → 3 新目录就位（模拟失败）→ 4 恢复旧目录。
        let calls = Mutex(0)
        var exporter = AtomicExporter()
        exporter.renameOperation = RenameOperation { from, to in
            let n = calls.withLock { $0 += 1; return $0 }
            return n == 3 ? EIO : RenameOperation.exclusive.rename(from, to)
        }
        do {
            try export(exporter, spec(box, source, policy: .overwrite), slides: 1, marker: 2)
            Issue.record("应当失败")
        } catch let error as ApplicationError {
            #expect(error.code == "export.publish_failed")
            #expect(error.message.contains("已恢复旧目录"))
        }
        #expect(calls.withLock { $0 } == 4)
        #expect(try contents(first.directory) == before)
        #expect(AtomicExporter.isPublishedByPhotoFrame(first.directory))
        #expect(!box.stagingExists)
    }

    @Test("挪开旧目录失败：什么都不变")
    func moveAsideFailure() throws {
        let box = try Sandbox()
        let source = try box.makeSource()
        let first = try export(AtomicExporter(), spec(box, source, policy: .versionSuffix), slides: 1, marker: 1)
        let calls = Mutex(0)
        var exporter = AtomicExporter()
        exporter.renameOperation = RenameOperation { from, to in
            let n = calls.withLock { $0 += 1; return $0 }
            return n == 2 ? EACCES : RenameOperation.exclusive.rename(from, to)
        }
        #expect(throws: ApplicationError.self) {
            try export(exporter, spec(box, source, policy: .overwrite), slides: 1, marker: 2)
        }
        #expect(try contents(first.directory) == ["00_Cover.jpg": 1, "01_Slide.jpg": 1])
        #expect(!box.stagingExists)
    }

    @Test("经由队列覆盖：队列里其他任务的源图受保护")
    func throughQueue() async throws {
        let box = try Sandbox()
        let queue = JobQueue(renderer: FakeRenderer(), configuration: QueueConfiguration(maxConcurrentJobs: 1))
        let source = try box.makeSource()
        let first = await queue.submit(spec(box, source, policy: .versionSuffix))
        let dir = try #require(await queue.waitUntilFinished([first.jobId]).first?.manifest?.directory)

        // 另一个任务的源图放在了作品目录里。
        let trapped = dir.appending(path: "03_Slide.jpg")
        try Data([0xFF, 0xD8, 0xFF, 7]).write(to: trapped)
        let other = await queue.submit(spec(box, PhotoSource(fileURL: trapped), policy: .versionSuffix, workName: "Trapped"))
        _ = await queue.waitUntilFinished([other.jobId])

        let overwrite = await queue.submit(spec(box, source, policy: .overwrite))
        let record = try #require(await queue.waitUntilFinished([overwrite.jobId]).first)
        #expect(record.status == .failed)
        #expect(record.error?.code == "export.overwrite_contains_source")
        #expect(try Data(contentsOf: trapped).last == 7)

        // 源图移走之后（不再存在）就可以覆盖了。
        try FileManager.default.removeItem(at: trapped)
        try await queue.retry(overwrite.jobId)
        let retried = try #require(await queue.waitUntilFinished([overwrite.jobId]).first)
        #expect(retried.status == .completed)
        #expect(retried.manifest?.directory == dir)
    }
}

@Suite("残留临时目录清理（D-55）")
struct StagingCleanupTests {
    func age(_ url: URL, hours: Double) throws {
        let date = Date().addingTimeInterval(-hours * 3600)
        let fm = FileManager.default
        var all = [url]
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
            all += e.compactMap { $0 as? URL }
        }
        // 先改深层，再改上层（改子项会更新父目录时间）。
        for item in all.reversed() {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: item.path)
        }
    }

    @Test("只删除超过 24 小时的 attempt 目录，不碰其他文件")
    func removesOnlyStaleAttempts() throws {
        let box = try Sandbox()
        let staging = box.stagingRoot
        let fm = FileManager.default
        let stale = staging.appending(path: AttemptID().description)
        let fresh = staging.appending(path: AttemptID().description)
        let notAttempt = staging.appending(path: "keep-me")
        let looseFile = staging.appending(path: AttemptID().description + ".txt")
        for dir in [stale, fresh, notAttempt] {
            try fm.createDirectory(at: dir.appending(path: "render"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appending(path: "render/f"))
        }
        try Data("x".utf8).write(to: looseFile)
        try age(stale, hours: 30)
        try age(notAttempt, hours: 30)
        try age(looseFile, hours: 30)
        try age(fresh, hours: 2)

        // 30 小时前的目录里有一个刚写的文件：仍在使用，不删。
        let staleButActive = staging.appending(path: AttemptID().description)
        try fm.createDirectory(at: staleButActive.appending(path: "render"), withIntermediateDirectories: true)
        try age(staleButActive, hours: 30)
        try Data("new".utf8).write(to: staleButActive.appending(path: "render/new"))

        let removed = AtomicExporter.removeStaleStaging(in: box.exports)
        #expect(removed.map(\.lastPathComponent) == [stale.lastPathComponent])
        #expect(!fm.fileExists(atPath: stale.path))
        for kept in [fresh, notAttempt, looseFile, staleButActive] {
            #expect(fm.fileExists(atPath: kept.path), "\(kept.lastPathComponent)")
        }
    }

    @Test("跳过正在执行的 attempt；全部清掉后删除 .photoframe-staging")
    func excludesActiveAndRemovesEmptyRoot() throws {
        let box = try Sandbox()
        let active = AttemptID()
        let dir = box.stagingRoot.appending(path: active.description)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try age(dir, hours: 48)
        #expect(AtomicExporter.removeStaleStaging(in: box.exports, excluding: [active]).isEmpty)
        #expect(box.stagingExists)

        #expect(AtomicExporter.removeStaleStaging(in: box.exports).count == 1)
        #expect(!box.stagingExists)
        #expect(FileManager.default.fileExists(atPath: box.exports.path))
        #expect(AtomicExporter.removeStaleStaging(in: box.root.appending(path: "missing")).isEmpty)
    }

    @Test("队列第一次使用输出目录时自动清理")
    func queueCleansOnFirstUse() async throws {
        let box = try Sandbox()
        let stale = box.stagingRoot.appending(path: AttemptID().description)
        try FileManager.default.createDirectory(at: stale.appending(path: "render"), withIntermediateDirectories: true)
        try age(stale, hours: 25)
        let userFile = box.exports.appending(path: "Instagram/mine.jpg")
        try FileManager.default.createDirectory(at: userFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: userFile)

        let service = LocalPhotoFrameService(renderer: FakeRenderer())
        let source = try await service.addSource(try box.makeSource().fileURL)
        let ids = try await service.submit(ExportRequest(sourceIds: [source.sourceId], presets: [.testPanorama], destination: ExportDestination(rootDirectory: box.exports)))
        #expect(await service.waitUntilFinished(ids).first?.status == .completed)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!box.stagingExists)
        #expect(try Data(contentsOf: userFile) == Data("mine".utf8))
        #expect(await service.removeStaleStaging(in: box.exports).isEmpty)
    }
}

@Suite("运行中修改调度设置（D-53）")
struct SchedulingSettingsTests {
    @Test("调高并发数立即派发更多任务，调低后按新上限")
    func changeConcurrency() async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer(holds: true)
        let queue = JobQueue(renderer: renderer, configuration: QueueConfiguration(maxConcurrentJobs: 1, memoryBudgetBytes: nil))
        let source = try box.makeSource()
        let jobs = await queue.submit((0..<6).map { _ in box.spec(source) })

        await eventually { renderer.running == 1 }
        await queue.setMaxConcurrentJobs(3)
        await eventually { renderer.running == 3 }
        #expect(await queue.configuration.maxConcurrentJobs == 3)

        await queue.setMaxConcurrentJobs(1)
        #expect(renderer.running == 3, "调低不会中断正在执行的任务")
        renderer.release()
        let records = await queue.waitUntilFinished(jobs.map(\.jobId))
        #expect(records.allSatisfy { $0.status == .completed })
        #expect(renderer.maxRunning == 3)

        await queue.setMaxConcurrentJobs(0)
        #expect(await queue.configuration.maxConcurrentJobs == 1)
    }

    @Test("放宽内存预算立即生效")
    func changeMemoryBudget() async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer(holds: true, memoryEstimate: 400)
        let service = LocalPhotoFrameService(renderer: renderer, configuration: QueueConfiguration(maxConcurrentJobs: 4, memoryBudgetBytes: 500))
        let source = try await service.addSource(try box.makeSource().fileURL)
        let ids = try await service.submit(ExportRequest(
            sourceIds: [source.sourceId], presets: [.testPanorama, .testStandard, .testPanorama],
            destination: ExportDestination(rootDirectory: box.exports)))

        await eventually { renderer.running == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(renderer.running == 1)
        await service.setMemoryBudget(1200)
        await eventually { renderer.running == 3 }
        await service.setMemoryBudget(nil)
        await service.setMaxConcurrentJobs(2)
        renderer.release()
        #expect(await service.waitUntilFinished(ids).allSatisfy { $0.status == .completed })
    }
}
