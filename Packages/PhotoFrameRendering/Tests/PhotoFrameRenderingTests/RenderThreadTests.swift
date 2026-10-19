import Foundation
import PhotoFrameCore
@testable import PhotoFrameRendering
import Synchronization
import Testing

/// 渲染在协作线程池之外的专用线程上执行（D-128）。
@Suite("渲染线程")
struct RenderThreadTests {
    @Test("同时渲染的任务比核数多、都停在进度回调里时，协作线程池仍然空闲：预览和其他异步工作照常完成",
          .timeLimit(.minutes(3)))
    func rendersLeaveCooperativePoolFree() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("photo.png")
        try writeGradientPhoto(width: 600, height: 400, to: src)
        let preset = makePreset(width: 300, height: 400, margin: 20)
        let renderer = PhotoFrameRenderer()
        let count = ProcessInfo.processInfo.activeProcessorCount + 1
        let jobs = try (0..<count).map { _ in
            let out = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            return RenderJob(sourceURL: src, preset: preset, outputDirectory: out)
        }

        // 每个渲染在第一次报告进度时停住，直到测试放行。以前的实现里渲染占着协作线程，线程池会被占满；
        // 闸门最多等 30 秒，测试只会失败，不会挂住。
        let gate = DispatchSemaphore(value: 0)
        let entered = LockedValue(0)
        let renders = Task {
            try await withThrowingTaskGroup(of: RenderResult.self) { group in
                for job in jobs {
                    group.addTask {
                        try await renderer.render(job: job) { progress in
                            guard progress.stage == .decoding else { return }
                            entered.withLock { $0 += 1 }
                            _ = gate.wait(timeout: .now() + 30)
                        }
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
        }

        let start = ContinuousClock.now
        while entered.value < count, ContinuousClock.now - start < .seconds(10) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.value == count, "\(count) 个渲染应当同时停在进度回调里")
        // 渲染全都停着的时候：别的异步工作和预览照常完成。
        let small = await withTaskGroup(of: Int.self) { group in
            for i in 0..<count { group.addTask { i } }
            return await group.reduce(0, +)
        }
        #expect(small == count * (count - 1) / 2)
        let preview = try await renderer.renderPreview(PreviewRequest(sourceURL: src, preset: preset, size: .maxLongEdge(200)))
        #expect(preview.pages.count == 1)
        #expect(ContinuousClock.now - start < .seconds(10), "预览等到了渲染放行之后才完成：\(ContinuousClock.now - start)")
        #expect(entered.value == count)

        for _ in 0..<count { gate.signal() }
        let results = try await renders.value
        #expect(results.count == count)
        #expect(results.allSatisfy { $0.outputs.count == 1 })
    }

    @Test("取消：停在进度回调里的渲染被取消后，放行时抛出 CancellationError 并删除已写出的文件；没取消的照常完成")
    func cancelWhileBlocked() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("photo.png")
        try writeGradientPhoto(width: 600, height: 400, to: src)
        let renderer = PhotoFrameRenderer()
        func job() throws -> RenderJob {
            let out = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            return RenderJob(sourceURL: src, preset: makePreset(width: 300, height: 400, margin: 20), outputDirectory: out)
        }
        let (canceled, kept) = (try job(), try job())
        let gate = DispatchSemaphore(value: 0)
        let entered = LockedValue(0)
        let progress: @Sendable (RenderProgress) -> Void = { p in
            guard p.stage == .decoding else { return }
            entered.withLock { $0 += 1 }
            _ = gate.wait(timeout: .now() + 30)
        }
        let a = Task { try await renderer.render(job: canceled, progress: progress) }
        let b = Task { try await renderer.render(job: kept, progress: progress) }
        while entered.value < 2 { try await Task.sleep(for: .milliseconds(5)) }
        a.cancel()
        gate.signal(); gate.signal()
        await #expect(throws: CancellationError.self) { _ = try await a.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: canceled.outputDirectory.path).isEmpty)
        #expect(try await b.value.outputs.count == 1)
    }

    @Test("Task 已经取消时，渲染一开始就抛出 CancellationError")
    func canceledBeforeStart() async throws {
        let ran = LockedValue(false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RenderThread.run { cancellation in
                try cancellation.checkCancellation()
                ran.value = true
                return 1
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!ran.value)
    }

    @Test("专用线程的优先级跟随调用方的 Task")
    func priorityFollowsTask() async throws {
        let qos = try await Task(priority: .userInitiated) {
            try await RenderThread.run { _ in qos_class_self() }
        }.value
        #expect(qos == QOS_CLASS_USER_INITIATED)
        #expect(DispatchQoS.QoSClass(TaskPriority.background) == .background)
        #expect(DispatchQoS.QoSClass(TaskPriority.utility) == .utility)
        #expect(DispatchQoS.QoSClass(TaskPriority.medium) == .default)
    }
}

/// 加锁的值：在 `@Sendable` 闭包里读写。
final class LockedValue<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    func withLock<R: Sendable>(_ body: (inout Value) -> R) -> R { storage.withLock { body(&$0) } }
}
