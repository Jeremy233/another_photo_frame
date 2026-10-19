import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import Testing

@Suite("PhotoFrameService")
struct PhotoFrameServiceTests {
    @Test("添加源图：检查存在与格式，同一路径不重复登记")
    func addSource() async throws {
        let box = try Sandbox()
        let service = LocalPhotoFrameService(renderer: FakeRenderer())
        let tif = try box.makeSource("Badlands.tif")

        let added = try await service.addSource(tif.fileURL)
        #expect(added.displayName == "Badlands.tif")
        #expect(added.fileSizeBytes == 15)
        #expect(try await service.addSource(tif.fileURL).sourceId == added.sourceId)

        let heic = try box.makeSource("Phone.HEIC")
        await #expect(throws: ApplicationError.self) { try await service.addSource(heic.fileURL) }
        await #expect(throws: ApplicationError.self) { try await service.addSource(box.root.appending(path: "nope.jpg")) }
        await #expect(throws: ApplicationError.self) { try await service.addSource(box.root) }
        #expect(await service.sources().count == 1)
    }

    @Test("源图 × 预设生成任务（§3.1），GUI 式先排队后开始")
    func submitCrossProduct() async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer()
        let service = LocalPhotoFrameService(renderer: renderer, configuration: QueueConfiguration(startsPaused: true))
        let a = try await service.addSource(try box.makeSource("Badlands.tif").fileURL)
        let b = try await service.addSource(try box.makeSource("Aurora.jpg").fileURL)
        let events = EventLog(await service.events())

        let ids = try await service.submit(ExportRequest(
            sourceIds: [a.sourceId, b.sourceId], presets: [.testStandard, .testPanorama],
            destination: ExportDestination(rootDirectory: box.exports)))
        #expect(ids.count == 4)
        #expect(try await service.status(ids[0]).status == .queued)
        #expect(renderer.calls == 0)

        await service.start()
        let records = await service.waitUntilFinished(ids)
        #expect(records.allSatisfy { $0.status == .completed })
        #expect(records.map(\.spec.source.sourceId) == [a.sourceId, a.sourceId, b.sourceId, b.sourceId])
        let dirs = try await ids.asyncMap { try await service.manifest($0)?.directory.lastPathComponent }
        #expect(dirs == ["Badlands_Standard", "Badlands_Panorama", "Aurora_Standard", "Aurora_Panorama"])
        #expect(await service.jobs().count == 4)
        await eventually { events.all.contains(.queueResumed) }
    }

    @Test("重新链接源图：sourceId 不变，失败的任务重试时读新位置，已完成的不变")
    func relinkSource() async throws {
        let box = try Sandbox()
        let service = LocalPhotoFrameService(renderer: FakeRenderer(), configuration: QueueConfiguration(startsPaused: true))
        let old = try box.makeSource("Badlands.tif")
        let source = try await service.addSource(old.fileURL)
        let destination = ExportDestination(rootDirectory: box.exports)
        let done = try await service.submit(ExportRequest(sourceIds: [source.sourceId], presets: [.testStandard], destination: destination))
        await service.start()
        #expect(await service.waitUntilFinished(done).first?.status == .completed)

        // 原图被移走：新提交的任务失败。
        let moved = box.root.appending(path: "Moved/Badlands renamed.tif")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old.fileURL, to: moved)
        let failed = try await service.submit(ExportRequest(sourceIds: [source.sourceId], presets: [.testStandard], destination: destination))
        #expect(await service.waitUntilFinished(failed).first?.status == .failed)

        await #expect(throws: ApplicationError.self) { try await service.relinkSource(source.sourceId, to: box.root.appending(path: "nope.tif")) }
        await #expect(throws: ApplicationError.self) { try await service.relinkSource(SourceID(), to: moved) }
        let relinked = try await service.relinkSource(source.sourceId, to: moved)
        #expect(relinked.sourceId == source.sourceId)
        #expect(relinked.displayName == "Badlands renamed.tif")
        #expect(await service.sources().map(\.fileURL) == [moved.standardizedFileURL])
        // 新路径登记在同一张源图下；旧路径不再指向它。
        #expect(try await service.addSource(moved).sourceId == source.sourceId)

        #expect(try await service.status(done[0]).spec.source.fileURL == old.fileURL)
        #expect(try await service.status(failed[0]).spec.source.fileURL == moved.standardizedFileURL)
        _ = try await service.retry(failed[0])
        #expect(await service.waitUntilFinished(failed).first?.status == .completed)
    }

    @Test("请求错误")
    func requestErrors() async throws {
        let box = try Sandbox()
        let service = LocalPhotoFrameService(renderer: FakeRenderer())
        let destination = ExportDestination(rootDirectory: box.exports)
        await #expect(throws: ApplicationError.self) {
            try await service.submit(ExportRequest(sourceIds: [], presets: [.testStandard], destination: destination))
        }
        await #expect(throws: ApplicationError.self) {
            try await service.submit(ExportRequest(sourceIds: [SourceID()], presets: [.testStandard], destination: destination))
        }
        await #expect(throws: ApplicationError.self) { try await service.status(JobID()) }
    }

    @Test("取消与重试经由服务")
    func cancelAndRetry() async throws {
        let box = try Sandbox()
        let renderer = FakeRenderer(holds: true)
        let service = LocalPhotoFrameService(renderer: renderer)
        let source = try await service.addSource(try box.makeSource().fileURL)
        let ids = try await service.submit(ExportRequest(sourceIds: [source.sourceId], presets: [.testPanorama], destination: ExportDestination(rootDirectory: box.exports)))
        await eventually { renderer.running == 1 }
        try await service.cancel(ids[0])
        #expect(await service.waitUntilFinished(ids).first?.status == .canceled)
        #expect(try await service.manifest(ids[0]) == nil)

        renderer.release()
        let attempt = try await service.retry(ids[0])
        let record = try #require(await service.waitUntilFinished(ids).first)
        #expect(record.status == .completed)
        #expect(try await service.manifest(ids[0])?.attemptId == attempt)
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
