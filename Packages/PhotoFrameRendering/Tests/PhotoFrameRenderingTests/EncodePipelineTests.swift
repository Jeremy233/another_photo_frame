import Foundation
import PhotoFrameCore
@testable import PhotoFrameRendering
import Testing

@Suite("编码流水线")
struct EncodePipelineTests {
    func panoramaJob(_ dir: URL, format: OutputSettings.Format = .jpeg) throws -> RenderJob {
        let src = dir.appendingPathComponent("pano.png")
        if !FileManager.default.fileExists(atPath: src.path) { try writeGradientPhoto(width: 3000, height: 1000, to: src) }
        let out = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return RenderJob(sourceURL: src, preset: makePreset(panorama: PanoramaSettings(enabled: true), output: OutputSettings(format: format)),
                         outputDirectory: out)
    }

    @Test("同时渲染的任务比核数多时不会卡住，写出的文件与单独渲染时逐字节相同", .timeLimit(.minutes(2)))
    func moreJobsThanCores() async throws {
        let dir = try makeTempDirectory()
        let renderer = PhotoFrameRenderer()
        let reference = try await renderer.render(job: try panoramaJob(dir))
        let expected = try reference.outputs.map { try Data(contentsOf: $0.fileURL) }
        #expect(expected.count == 5)

        let count = ProcessInfo.processInfo.activeProcessorCount * 2 + 2
        let jobs = try (0..<count).map { _ in try panoramaJob(dir) }
        let results = try await withThrowingTaskGroup(of: RenderResult.self) { group in
            for job in jobs { group.addTask { try await renderer.render(job: job) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == count)
        for result in results {
            #expect(result.outputs.map(\.role) == reference.outputs.map(\.role))
            #expect(try result.outputs.map { try Data(contentsOf: $0.fileURL) } == expected)
        }
    }

    @Test("中间一页写不出：报这一页的错误，已写出的其他页全部删除，原有文件不动")
    func failureInTheMiddle() async throws {
        let dir = try makeTempDirectory()
        for format in [OutputSettings.Format.jpeg, .png] {
            let job = try panoramaJob(dir, format: format)
            let ext = format == .jpeg ? "jpg" : "png"
            let blocker = job.outputDirectory.appendingPathComponent("02.\(ext)")
            try Data("keep".utf8).write(to: blocker)
            do {
                _ = try await PhotoFrameRenderer().render(job: job)
                Issue.record("应当失败")
            } catch let error as RenderError {
                #expect(error.code == "render.write_failed")
                #expect(error.message.contains("02.\(ext)"))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: job.outputDirectory.path) == ["02.\(ext)"])
            #expect(try Data(contentsOf: blocker) == Data("keep".utf8))
        }
    }

    @Test("在途页数按画布大小限制：大画布退回逐页编码")
    func depthFollowsCanvas() {
        #expect(EncodePipeline(pageBytes: 1080 * 1440 * 4).depth == 4)
        #expect(EncodePipeline(pageBytes: 4000 * 3000 * 4).depth == 1)
        #expect(EncodePipeline(pageBytes: 2160 * 2880 * 4).depth == 2)
        #expect(EncodePipeline(pageBytes: 0).depth == 4)
    }
}
