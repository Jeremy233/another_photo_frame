import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameRendering
import PhotoFrameStorage
import Synchronization
import Testing

/// D-128：渲染不占协作线程池；并发数设置不超过本机核数。
@Suite("并发与协作线程池")
struct ConcurrencyTests {
    static let catalog = try! PlatformCatalogStore.builtIn()

    static func preset(_ name: String) -> ExportPreset {
        BuiltInPresets.all(catalog: catalog).first { $0.name == name }!
    }

    @Test("同时渲染的任务比核数多时：检查源图、预览、导出任务的进度事件和发布都照常进行", .timeLimit(.minutes(3)))
    func serviceKeepsWorkingWhileRendersFillTheCores() async throws {
        let box = try Sandbox()
        let photo = try box.photo("Badlands.jpg", width: 1200, height: 800)
        let service = try LocalPhotoFrameService.makeDefault(.init(libraryRoot: box.root.appending(path: "Library")))
        let events = EventLog(await service.events())

        // 比核数多的渲染同时停在进度回调里（相当于正在做的导出）。以前渲染占着协作线程，线程池会被占满，
        // 下面服务的每一步都要等它们结束；闸门最多等 30 秒，测试只会失败，不会挂住。
        let renderer = PhotoFrameRenderer()
        let count = ProcessInfo.processInfo.activeProcessorCount + 1
        let gate = DispatchSemaphore(value: 0)
        let entered = Counter()
        let blocked = try (0..<count).map { i in
            let out = box.root.appending(path: "blocked-\(i)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let job = RenderJob(sourceURL: photo, preset: Self.preset("XHS Standard"), outputDirectory: out)
            return Task {
                try await renderer.render(job: job) { progress in
                    guard progress.stage == .decoding else { return }
                    entered.increment()
                    _ = gate.wait(timeout: .now() + 30)
                }
            }
        }
        defer { for _ in 0..<count { gate.signal() } }
        let start = ContinuousClock.now
        await eventually(timeout: .seconds(10)) { entered.value == count }

        let source = try await service.addSource(photo)
        let preview = try await service.renderPreview(ExportPreviewRequest(
            source: .id(source.sourceId), preset: Self.preset("Instagram Standard"), options: PreviewOptions(maxLongEdge: 360)))
        #expect(preview.pages.first?.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)

        let ids = try await service.submit(ExportRequest(
            sourceIds: [source.sourceId], presets: [Self.preset("Instagram Panorama")],
            destination: ExportDestination(rootDirectory: box.exports)))
        let record = try #require(await service.waitUntilFinished(ids).first)
        #expect(record.status == .completed, "\(String(describing: record.error))")
        await eventually { events.progress(of: record.jobId).last?.bytesWritten == record.manifest?.totalBytes }
        #expect(events.progress(of: record.jobId).contains { $0.completedOutputs == 1 }, "导出过程中收到了进度事件")
        #expect(ContinuousClock.now - start < .seconds(20), "服务等到了渲染放行之后才继续：\(ContinuousClock.now - start)")
        #expect(entered.value == count, "这时那些渲染还停着")

        for _ in 0..<count { gate.signal() }
        for task in blocked { #expect(try await task.value.outputs.count == 1) }
    }

    @Test("并发数上限：最多 8，且不超过本机核数；默认值（D-53）不变")
    func limit() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        #expect(QueueConfiguration.maxConcurrentJobsLimit == min(8, cores))
        #expect(QueueConfiguration.clampedMaxConcurrentJobs(0) == 1)
        #expect(QueueConfiguration.clampedMaxConcurrentJobs(1) == 1)
        #expect(QueueConfiguration.clampedMaxConcurrentJobs(64) == min(8, cores))
        #expect(QueueConfiguration.clampedMaxConcurrentJobs(cores + 1) == min(8, cores))
        #expect(QueueConfiguration.defaultMaxConcurrentJobs == min(4, max(1, cores / 2)))
    }

    @Test("服务：创建时（CLI、MCP 的 --jobs）和运行中修改（GUI 设置）都按上限截断")
    func serviceClamps() async throws {
        let box = try Sandbox()
        let limit = QueueConfiguration.maxConcurrentJobsLimit
        let library = box.root.appending(path: "Library")
        let big = try LocalPhotoFrameService.makeDefault(.init(maxConcurrentJobs: 64, libraryRoot: library))
        #expect(await big.queue.configuration.maxConcurrentJobs == limit)
        let auto = try LocalPhotoFrameService.makeDefault(.init(libraryRoot: library))
        #expect(await auto.queue.configuration.maxConcurrentJobs == QueueConfiguration.defaultMaxConcurrentJobs)

        await auto.setMaxConcurrentJobs(limit + 1)
        #expect(await auto.queue.configuration.maxConcurrentJobs == limit)
        await auto.setMaxConcurrentJobs(1)
        #expect(await auto.queue.configuration.maxConcurrentJobs == 1)
    }
}

/// 加锁的计数器（在渲染线程上的回调里加一）。
final class Counter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
