import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameRendering
import PhotoFrameStorage
import Testing
@testable import PhotoFrameEngine

@Suite("进度翻译")
struct ProgressTranslatorTests {
    static let panorama = ExportPreset(
        name: "P", canvas: CanvasSettings(width: 1080, height: 1440, background: .defaultBackground, minMarginPx: 60, mode: .fit),
        panorama: PanoramaSettings(enabled: true))

    func snapshots(_ stages: [(RenderStage, Int, Int?)]) -> [RenderProgress] {
        stages.map { RenderProgress(stage: $0.0, completedOutputs: $0.1, totalOutputs: $0.2) }
    }

    @Test("与 PhotoFrameRenderer 的报告顺序一致：阶段只前进，每写完一个文件报告一次")
    func rendererSequence() {
        let t = ProgressTranslator(preset: Self.panorama)
        let events = snapshots([
            (.decoding, 0, nil), (.rendering, 0, 3), (.encoding, 0, 3), (.encoding, 1, 3), (.encoding, 2, 3), (.encoding, 3, 3),
        ]).flatMap(t.translate)
        #expect(events == [
            .plannedOutputs(3), .stage(.rendering), .stage(.encoding),
            .outputFinished(.cover), .outputFinished(.slide(position: 1)), .outputFinished(.slide(position: 2)),
        ])
    }

    @Test("倒退或重复的阶段不报告")
    func stagesOnlyAdvance() {
        let t = ProgressTranslator(preset: Self.panorama)
        let events = snapshots([(.encoding, 0, 2), (.rendering, 0, 2), (.decoding, 0, 2), (.encoding, 0, 2)]).flatMap(t.translate)
        #expect(events == [.plannedOutputs(2), .stage(.encoding)])
    }

    @Test("没有封面的全景：第一个文件是第 1 张切片；单图是封面")
    func roles() {
        var noCover = Self.panorama
        noCover.panorama.cover = false
        #expect(ProgressTranslator(preset: noCover).role(at: 0) == .slide(position: 1))
        #expect(ProgressTranslator(preset: noCover).role(at: 2) == .slide(position: 3))
        var single = Self.panorama
        single.panorama = .disabled
        #expect(ProgressTranslator(preset: single).role(at: 0) == .cover)
        #expect(ProgressTranslator(preset: Self.panorama).role(at: 1) == .slide(position: 1))
    }

    @Test("渲染层角色 → 轮播位置（D-27）")
    func roleMapping() {
        #expect(JobOutputRole(OutputRole.single) == .cover)
        #expect(JobOutputRole(OutputRole.cover) == .cover)
        #expect(JobOutputRole(OutputRole.slide(0)) == .slide(position: 1))
        #expect(JobOutputRole(OutputRole.slide(4)) == .slide(position: 5))
    }
}

@Suite("渲染适配器 + 任务队列（真实渲染）")
struct RenderingBackendTests {
    static let catalog = try! PlatformCatalogStore.builtIn()

    static func preset(_ name: String) -> ExportPreset {
        BuiltInPresets.all(catalog: catalog).first { $0.name == name }!
    }

    @Test("全景导出：阶段完整、进度与文件一一对应、按 D-46–D-48 命名、sRGB ICC、临时目录清理")
    func panoramaExport() async throws {
        let box = try Sandbox()
        let photo = try box.photo("Badlands.jpg", width: 3000, height: 1000)
        let service = try PhotoFrameEngine.makeService()
        let events = EventLog(await service.events())
        let source = try await service.addSource(photo)
        let ids = try await service.submit(ExportRequest(
            sourceIds: [source.sourceId], presets: [Self.preset("Instagram Panorama")],
            destination: ExportDestination(rootDirectory: box.exports)))
        let record = try #require(await service.waitUntilFinished(ids).first)
        #expect(record.status == .completed, "\(String(describing: record.error))")
        #expect(record.currentAttempt.history.map(\.status) == JobStatus.pipeline)

        let manifest = try #require(record.manifest)
        #expect(manifest.directory.lastPathComponent == "Badlands_Panorama")
        #expect(manifest.directory.deletingLastPathComponent().lastPathComponent == "Instagram")
        let names = manifest.items.map(\.fileName)
        #expect(names.first == "00_Cover.jpg")
        #expect(names.dropFirst().allSatisfy { $0.hasSuffix("_Slide.jpg") })
        #expect(names.count >= 3)
        #expect(record.progress.plannedOutputs == names.count)
        #expect(record.progress.completedOutputs == names.count)
        for item in manifest.items {
            let info = imageInfo(item.fileURL)
            #expect(info.width == 1080 && info.height == 1440)
            #expect(info.profile == "sRGB IEC61966-2.1")
            #expect(item.colorProfile == "sRGB IEC61966-2.1")
        }
        #expect(box.tree().allSatisfy { !$0.contains(".photoframe-staging") })

        // 事件：outputFinished 的角色按轮播顺序，与清单一致；阶段事件严格按流水线顺序。
        await eventually { events.all.contains { if case .attemptFinished = $0 { true } else { false } } }
        let progress = events.all.compactMap { e -> JobProgress? in if case .progress(_, _, let p) = e { p } else { nil } }
        // 计划数先于任何完成数出现；完成数逐个 +1，最后的进度事件是发布字节数。
        #expect(progress.first?.plannedOutputs == names.count)
        let completed = progress.map(\.completedOutputs).reduce(into: [Int]()) { if $0.last != $1 { $0.append($1) } }
        #expect(completed == Array(0...names.count))
        #expect(progress.last?.bytesWritten == manifest.totalBytes)
        let statuses = events.all.compactMap { e -> JobStatus? in if case .statusChanged(_, _, let s) = e { s } else { nil } }
        #expect(statuses == Array(JobStatus.pipeline.dropFirst()))
    }

    @Test("源文件不是图片：任务失败，错误码来自渲染层（render.unsupported_format），目的地什么都没有")
    func renderErrorCode() async throws {
        let box = try Sandbox()
        let fake = box.root.appending(path: "NotAPhoto.jpg")
        try Data("plain text".utf8).write(to: fake)
        let service = try PhotoFrameEngine.makeService()
        let source = try await service.addSource(fake)
        let ids = try await service.submit(ExportRequest(
            sourceIds: [source.sourceId], presets: [Self.preset("XHS Standard")],
            destination: ExportDestination(rootDirectory: box.exports)))
        let record = try #require(await service.waitUntilFinished(ids).first)
        #expect(record.status == .failed)
        #expect(record.error?.code == "render.unsupported_format")
        #expect(box.tree().isEmpty)
    }

    @Test("取消正在渲染的任务：状态 canceled，不发布，临时目录删除")
    func cancelWhileRendering() async throws {
        let box = try Sandbox()
        let photo = try box.photo("Wide.jpg", width: 9000, height: 1500)
        let service = try PhotoFrameEngine.makeService()
        let source = try await service.addSource(photo)
        let ids = try await service.submit(ExportRequest(
            sourceIds: [source.sourceId], presets: [Self.preset("XHS Panorama")],
            destination: ExportDestination(rootDirectory: box.exports)))
        await eventually { (try? await service.status(ids[0]).status.isProcessing) ?? false }
        try await service.cancel(ids[0])
        let record = try #require(await service.waitUntilFinished(ids).first)
        // 渲染很快时任务可能在取消前已发布；两种结果都要求临时目录干净。
        #expect(record.status == .canceled || record.status == .completed)
        if record.status == .canceled {
            #expect(!box.tree().contains { $0.hasPrefix("Xiaohongshu/") })
        }
        #expect(box.tree().allSatisfy { !$0.contains(".photoframe-staging") })
    }

    @Test("检查源图、预估输出、预览")
    func analyzer() async throws {
        let box = try Sandbox()
        let photo = try box.photo("Gradient.jpg", width: 1200, height: 800)
        let service = try PhotoFrameEngine.makeService()

        let info = try await service.inspectSource(.file(photo))
        #expect(info.format == "jpeg")
        #expect(info.pixelSize == PixelSize(width: 1200, height: 800))
        #expect(info.colorProfile.embedded)
        #expect(info.colorProfile.origin == "embedded")
        #expect(info.hdr.kind == "none")
        #expect(info.hasGPS == false)

        let source = try await service.addSource(photo)
        let validation = try await service.validate(ExportRequest(
            sourceIds: [source.sourceId], presets: [Self.preset("Douyin Standard"), Self.preset("XHS Panorama")],
            destination: ExportDestination(rootDirectory: box.exports)))
        #expect(validation.isValid)
        #expect(validation.items[0].outputs.map(\.fileName) == ["00_Cover.jpg"])
        #expect(validation.items[0].outputs[0].pixelSize == PixelSize(width: 1080, height: 1920))
        #expect(validation.items[0].directory.path.hasSuffix("Douyin/Gradient_Standard"))
        #expect(validation.items[1].outputs.first?.fileName == "00_Cover.jpg")
        #expect(!FileManager.default.fileExists(atPath: box.exports.path), "校验不写任何文件")

        let preview = try await service.renderPreview(ExportPreviewRequest(
            source: .id(source.sourceId), preset: Self.preset("Instagram Standard"), options: PreviewOptions(maxLongEdge: 360)))
        #expect(preview.roles == [.cover])
        let page = try #require(preview.pages.first)
        #expect(page.pixelSize == PixelSize(width: 270, height: 360))
        #expect(page.exportPixelSize == PixelSize(width: 1080, height: 1440))
        #expect(page.pngData.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("检查不支持的文件：错误码稳定")
    func inspectErrors() async throws {
        let box = try Sandbox()
        let service = try PhotoFrameEngine.makeService()
        let heic = box.root.appending(path: "Phone.heic")
        try Data([0, 0, 0, 0x18] + Array("ftypheic".utf8)).write(to: heic)
        await #expect { try await service.inspectSource(.file(heic)) } throws: { ($0 as? ApplicationError)?.code == "source.unsupported_format" }
        let fake = box.root.appending(path: "Fake.png")
        try Data("not png".utf8).write(to: fake)
        await #expect { try await service.inspectSource(.file(fake)) } throws: { ($0 as? ApplicationError)?.code == "render.unsupported_format" }
    }
}
