import Darwin
import Foundation
import ImageIO
@testable import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameStorage
import Synchronization
import Testing

@Suite("导出回归")
struct ExportRegressionTests {
    func spec(_ box: Sandbox, _ source: PhotoSource, policy: ConflictPolicy = .versionSuffix, workName: String) -> JobSpec {
        JobSpec(source: source, preset: .testPanorama,
                destination: ExportDestination(rootDirectory: box.exports, naming: OutputNaming(workNameTemplate: workName), conflictPolicy: policy))
    }

    /// 写出 `roles` 对应的假 JPEG 并发布。
    @discardableResult
    func export(_ exporter: AtomicExporter, _ spec: JobSpec, roles: [JobOutputRole], marker: UInt8 = 1) throws -> OutputManifest {
        let area = try exporter.makeStaging(destinationRoot: spec.destination.rootDirectory, attemptId: AttemptID())
        let outputs = try roles.enumerated().map { i, role in
            let url = area.renderDirectory.appending(path: "f\(i)")
            try Data([0xFF, 0xD8, 0xFF, marker]).write(to: url)
            return JobRenderedOutput(role: role, fileURL: url, pixelSize: PixelSize(width: 1080, height: 1440), colorProfile: "sRGB")
        }
        return try exporter.publish(JobRenderResult(outputs: outputs), spec: spec, jobId: JobID(), staging: area, startedAt: Date())
    }

    func slides(_ range: ClosedRange<Int>) -> [JobOutputRole] { range.map { .slide(position: $0) } }

    @Test("不支持 RENAME_EXCL 的卷：目标已存在（目录、文件、悬空链接）时 EEXIST，不覆盖")
    func renameUnlessExists() throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let from = box.root.appending(path: "from")
        try fm.createDirectory(at: from, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: from.appending(path: "f"))
        func rename(_ to: URL) -> Int32 {
            from.path.withCString { f in to.path.withCString { t in RenameOperation.renameUnlessExists(f, t) } }
        }

        let dir = box.root.appending(path: "dir")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = box.root.appending(path: "file")
        try Data("old".utf8).write(to: file)
        let dangling = box.root.appending(path: "dangling")
        try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: box.root.appending(path: "missing").path)
        for target in [dir, file, dangling] {
            #expect(rename(target) == EEXIST, "\(target.lastPathComponent)")
        }
        #expect(try Data(contentsOf: file) == Data("old".utf8))
        #expect(try fm.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(rename(box.root.appending(path: "missing-parent/x")) == ENOENT)

        let free = box.root.appending(path: "free")
        #expect(rename(free) == 0)
        #expect(try Data(contentsOf: free.appending(path: "f")) == Data("new".utf8))
        #expect(!fm.fileExists(atPath: from.path))
    }

    @Test("作品名与临时目录里的固定名字相同（render、replaced、work）也能导出和覆盖")
    func reservedWorkNames() throws {
        let box = try Sandbox()
        let exporter = AtomicExporter()
        let source = try box.makeSource()
        for name in ["render", "replaced", "work"] {
            let first = try export(exporter, spec(box, source, workName: name), roles: [.cover, .slide(position: 1)])
            #expect(first.directory.lastPathComponent == name)
            #expect(first.items.map(\.fileName) == ["00_Cover.jpg", "01_Slide.jpg"])

            let second = try export(exporter, spec(box, source, policy: .overwrite, workName: name), roles: [.cover], marker: 2)
            #expect(second.directory == first.directory)
            #expect(try FileManager.default.contentsOfDirectory(atPath: second.directory.path).filter { !$0.hasPrefix(".") } == ["00_Cover.jpg"])
            #expect(try Data(contentsOf: second.directory.appending(path: "00_Cover.jpg")).last == 2)
        }
        #expect(!box.stagingExists)
    }

    @Test("覆盖时新目录无法就位、旧目录既不能恢复也不能挪走：旧目录留在临时目录里，不被清理")
    func keepsReplacedWhenEverythingFails() throws {
        let box = try Sandbox()
        let source = try box.makeSource()
        let first = try export(AtomicExporter(), spec(box, source, workName: "Badlands_Panorama"), roles: [.cover, .slide(position: 1)])

        // 改名序列：1 发布到目标（EEXIST）→ 2 挪开旧目录 → 3 新目录就位 → 4 恢复旧目录 → 5 挪出临时目录；3、4、5 都失败。
        let calls = Mutex(0)
        var exporter = AtomicExporter()
        exporter.renameOperation = RenameOperation { from, to in
            let n = calls.withLock { $0 += 1; return $0 }
            return n >= 3 ? EIO : RenameOperation.exclusive.rename(from, to)
        }
        do {
            try export(exporter, spec(box, source, policy: .overwrite, workName: "Badlands_Panorama"), roles: [.cover], marker: 2)
            Issue.record("应当失败")
        } catch let error as ApplicationError {
            #expect(error.code == "export.publish_failed")
            #expect(error.message.contains("仍在"))
        }
        #expect(calls.withLock { $0 } == 5)
        #expect(!FileManager.default.fileExists(atPath: first.directory.path))

        let attempts = try FileManager.default.contentsOfDirectory(atPath: box.stagingRoot.path)
        #expect(attempts.count == 1)
        let attempt = box.stagingRoot.appending(path: try #require(attempts.first))
        #expect(try FileManager.default.contentsOfDirectory(atPath: attempt.path) == ["replaced"])
        let kept = attempt.appending(path: "replaced")
        #expect(try Data(contentsOf: kept.appending(path: "00_Cover.jpg")).last == 1)
        #expect(try Data(contentsOf: kept.appending(path: "01_Slide.jpg")).last == 1)
        #expect(AtomicExporter.isPublishedByPhotoFrame(kept))
    }

    @Test("恢复失败但能挪出临时目录：旧目录改名保留在原处旁边，临时目录照常清理")
    func rescuesBesideTarget() throws {
        let box = try Sandbox()
        let source = try box.makeSource()
        let first = try export(AtomicExporter(), spec(box, source, workName: "Badlands_Panorama"), roles: [.cover])
        let calls = Mutex(0)
        var exporter = AtomicExporter()
        exporter.renameOperation = RenameOperation { from, to in
            let n = calls.withLock { $0 += 1; return $0 }
            return n == 3 || n == 4 ? EIO : RenameOperation.exclusive.rename(from, to)
        }
        #expect(throws: ApplicationError.self) {
            try export(exporter, spec(box, source, policy: .overwrite, workName: "Badlands_Panorama"), roles: [.cover], marker: 2)
        }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: first.directory.deletingLastPathComponent().path)
        let rescued = try #require(siblings.first { $0.hasPrefix("Badlands_Panorama.previous-") })
        #expect(try Data(contentsOf: first.directory.deletingLastPathComponent().appending(path: "\(rescued)/00_Cover.jpg")).last == 1)
        #expect(!box.stagingExists)
    }

    @Test("不输出封面的全景超过 99 张切片：序号按最大位置补位，位数一致")
    func padsWithoutCover() throws {
        #expect(OutputNaming.positionCount(of: [.cover, .slide(position: 1), .slide(position: 2)]) == 3)
        #expect(OutputNaming.positionCount(of: slides(1...99)) == 100)
        #expect(OutputNaming.positionCount(of: slides(1...100)) == 101)
        #expect(OutputNaming.positionCount(of: []) == 0)

        let box = try Sandbox()
        let manifest = try export(AtomicExporter(), spec(box, try box.makeSource(), workName: "Wide"), roles: slides(1...100))
        let names = manifest.items.map(\.fileName)
        #expect(names.first == "001_Slide.jpg")
        #expect(names.last == "100_Slide.jpg")
        #expect(Set(names.map(\.count)) == [13])

        let withCover = try export(AtomicExporter(), spec(box, try box.makeSource(), workName: "Wide2"), roles: [.cover] + slides(1...99))
        #expect(withCover.items.first?.fileName == "00_Cover.jpg")
        #expect(withCover.items.last?.fileName == "99_Slide.jpg")
    }

    @Test("撞名键：区分大小写的卷按原样比较，不区分的卷按大小写折叠")
    func collisionKeys() throws {
        let a = URL(filePath: "/x/Instagram/Badlands_Panorama")
        let b = URL(filePath: "/x/Instagram/BADLANDS_Panorama")
        #expect(OutputNaming.collisionKey(for: a, caseSensitive: true) != OutputNaming.collisionKey(for: b, caseSensitive: true))
        #expect(OutputNaming.collisionKey(for: a, caseSensitive: false) == OutputNaming.collisionKey(for: b, caseSensitive: false))

        // 还不存在的目录按最近的已存在上级判断。
        let box = try Sandbox()
        #expect(OutputNaming.volumeIsCaseSensitive(box.root.appending(path: "a/b/c"))
            == OutputNaming.volumeIsCaseSensitive(box.root))
    }
}

@Suite("服务回归")
struct ServiceRegressionTests {
    /// 记录 `slotResolver()` 被调用了几次的素材来源。
    final class CountingAssets: AssetProvider {
        let calls = Mutex(0)
        func slotResolver() -> SlotResolver {
            calls.withLock { $0 += 1 }
            return SlotResolver(library: InMemoryAssetLibrary(), bindings: AssetBindingTable())
        }
        func fileURL(for asset: AssetRecord) -> URL? { nil }
        var count: Int { calls.withLock { $0 } }
    }

    @Test("校验：只差大小写的作品名在不区分大小写的卷上是同一个目录")
    func caseInsensitiveCollision() async throws {
        let box = try Sandbox()
        // 一次一个任务，发布顺序与请求顺序一致。
        let service = LocalPhotoFrameService(renderer: FakeRenderer(), analyzer: FakeAnalyzer(), configuration: QueueConfiguration(maxConcurrentJobs: 1))
        let a = try await service.addSource(try box.makeSource("Badlands.tif").fileURL)
        let b = try await service.addSource(try box.makeSource("Other/BADLANDS.tif").fileURL)
        let caseSensitive = OutputNaming.volumeIsCaseSensitive(box.root)

        let overwrite = try await service.validate(ExportRequest(
            sourceIds: [a.sourceId, b.sourceId], presets: [.testStandard],
            destination: ExportDestination(rootDirectory: box.exports, conflictPolicy: .overwrite)))
        #expect(overwrite.items[0].errors.isEmpty)
        #expect(overwrite.items[1].errors.map(\.code) == (caseSensitive ? [] : ["request.duplicate_output"]))

        let versioned = try await service.validate(ExportRequest(
            sourceIds: [a.sourceId, b.sourceId], presets: [.testStandard], destination: ExportDestination(rootDirectory: box.exports)))
        #expect(versioned.items.map { $0.directory.lastPathComponent }
            == ["Badlands_Standard", caseSensitive ? "BADLANDS_Standard" : "BADLANDS_Standard_v2"])

        // 实际发布结果与校验的预估一致。
        let ids = try await service.submit(ExportRequest(
            sourceIds: [a.sourceId, b.sourceId], presets: [.testStandard], destination: ExportDestination(rootDirectory: box.exports)))
        let dirs = await service.waitUntilFinished(ids).map { $0.manifest?.directory.lastPathComponent }
        #expect(dirs == versioned.items.map { $0.directory.lastPathComponent })
    }

    @Test("校验：悬空的符号链接占着作品名，版本后缀跳过它")
    func danglingSymlinkTakesName() async throws {
        let box = try Sandbox()
        let service = LocalPhotoFrameService(renderer: FakeRenderer(), analyzer: FakeAnalyzer())
        let source = try await service.addSource(try box.makeSource().fileURL)
        let platform = box.exports.appending(path: "Instagram")
        try FileManager.default.createDirectory(at: platform, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: platform.appending(path: "Badlands_Standard").path, withDestinationPath: box.root.appending(path: "gone").path)

        let result = try await service.validate(ExportRequest(
            sourceIds: [source.sourceId], presets: [.testStandard], destination: ExportDestination(rootDirectory: box.exports)))
        #expect(result.items.map { $0.directory.lastPathComponent } == ["Badlands_Standard_v2"])
        let ids = try await service.submit(ExportRequest(
            sourceIds: [source.sourceId], presets: [.testStandard], destination: ExportDestination(rootDirectory: box.exports)))
        #expect(await service.waitUntilFinished(ids).first?.manifest?.directory.lastPathComponent == "Badlands_Standard_v2")
    }

    @Test("提交时读出源图尺寸与方向，队列按像素估算内存；读不出时仍按默认值")
    func fillsSourceImage() async throws {
        let box = try Sandbox()
        let service = LocalPhotoFrameService(renderer: FakeRenderer(), configuration: QueueConfiguration(startsPaused: true))
        let photo = try box.photo("Wide.jpg", width: 300, height: 200, properties: [kCGImagePropertyOrientation: 6])
        let real = try await service.addSource(photo)
        let fake = try await service.addSource(try box.makeSource().fileURL)

        let ids = try await service.submit(ExportRequest(
            sourceIds: [real.sourceId, fake.sourceId], presets: [.testStandard], destination: ExportDestination(rootDirectory: box.exports)))
        let records = try await ids.asyncMap { try await service.status($0) }
        let image = try #require(records[0].spec.source.image)
        #expect(image.storedSize == PixelSize(width: 300, height: 200))
        #expect(image.orientation == .right)
        #expect(records[1].spec.source.image == nil)
        #expect(await service.sources().first?.image == image)

        let config = QueueConfiguration()
        #expect(config.estimatedMemory(for: records[0].spec) != config.fallbackJobMemoryBytes)
        #expect(config.estimatedMemory(for: records[1].spec) == config.fallbackJobMemoryBytes)
    }

    @Test("没有启用素材图层的预设不读素材库；有素材图层时同一次校验只读一次")
    func readsAssetsOnlyWhenNeeded() async throws {
        let box = try Sandbox()
        let assets = CountingAssets()
        let service = LocalPhotoFrameService(renderer: FakeRenderer(), analyzer: FakeAnalyzer(), configuration: QueueConfiguration(assets: assets))
        let a = try await service.addSource(try box.makeSource("A.tif").fileURL)
        let b = try await service.addSource(try box.makeSource("B.tif").fileURL)
        let destination = ExportDestination(rootDirectory: box.exports)

        let plain = try await service.validate(ExportRequest(
            sourceIds: [a.sourceId, b.sourceId], presets: [.testStandard, .testPanorama], destination: destination))
        #expect(plain.isValid)
        #expect(assets.count == 0)

        // 单任务绑定没被使用的提示照常给出。
        let bound = try await service.validate(ExportRequest(
            sourceIds: [a.sourceId], presets: [.testStandard], destination: destination, assetBindings: ["logo": UUID()]))
        #expect(bound.items[0].warnings.map(\.code).contains("slot.unused_job_binding"))
        #expect(assets.count == 0)

        let signed = try await service.validate(ExportRequest(
            sourceIds: [a.sourceId, b.sourceId], presets: [.withRequiredSlot, .testStandard], destination: destination))
        #expect(signed.items.map { $0.errors.map(\.code) } == [["slot.missing_required"], [], ["slot.missing_required"], []])
        #expect(assets.count == 1)

        let ids = try await service.submit(ExportRequest(sourceIds: [a.sourceId], presets: [.testStandard], destination: destination))
        #expect(await service.waitUntilFinished(ids).first?.status == .completed)
        #expect(assets.count == 1)

        let failing = try await service.submit(ExportRequest(sourceIds: [a.sourceId], presets: [.withRequiredSlot], destination: destination))
        #expect(await service.waitUntilFinished(failing).first?.error?.code == "slot.missing_required")
        #expect(assets.count == 2)
    }
}
