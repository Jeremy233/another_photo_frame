import Foundation
@testable import PhotoFrameApplication
import PhotoFrameCore
import Testing

@Suite("原子导出")
struct AtomicExporterTests {
    let exporter = AtomicExporter()

    /// 在临时目录里写出若干文件，模拟渲染结果。
    func render(_ area: StagingArea, slides: Int, corrupt: Int? = nil) throws -> JobRenderResult {
        let roles: [JobOutputRole] = [.cover] + (0..<slides).map { .slide(position: $0 + 1) }
        // 故意倒序返回，发布时应按轮播顺序排列。
        let outputs = try roles.enumerated().reversed().map { i, role in
            let url = area.renderDirectory.appending(path: "tmp-\(i)")
            let data = i == corrupt ? Data("garbage".utf8) : Data([0xFF, 0xD8, 0xFF, 0xDB, UInt8(i)])
            try data.write(to: url)
            return JobRenderedOutput(role: role, fileURL: url, pixelSize: PixelSize(width: 1080, height: 1440), colorProfile: "sRGB IEC61966-2.1")
        }
        return JobRenderResult(outputs: outputs)
    }

    @Test("发布完整作品目录，生成清单，清理临时文件")
    func publishes() throws {
        let box = try Sandbox()
        let spec = box.spec(try box.makeSource(), hashes: true)
        let area = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
        let result = try render(area, slides: 3)

        let manifest = try exporter.publish(result, spec: spec, jobId: JobID(), staging: area, startedAt: Date())

        #expect(manifest.directory.path == box.exports.appending(path: "Instagram/Badlands_Panorama").path)
        #expect(manifest.items.map(\.fileName) == ["00_Cover.jpg", "01_Slide.jpg", "02_Slide.jpg", "03_Slide.jpg"])
        #expect(manifest.items.map(\.role) == [.cover, .slide(position: 1), .slide(position: 2), .slide(position: 3)])
        for item in manifest.items {
            #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
            #expect(item.fileSizeBytes == 5)
            #expect(item.sha256?.count == 64)
            #expect(item.colorProfile == "sRGB IEC61966-2.1")
            #expect(item.pixelSize == PixelSize(width: 1080, height: 1440))
        }
        #expect(manifest.totalBytes == 20)
        #expect(!box.stagingExists, "临时目录应被删除")
        #expect(box.exportTree() == [
            "Instagram", "Instagram/Badlands_Panorama",
            "Instagram/Badlands_Panorama/00_Cover.jpg", "Instagram/Badlands_Panorama/01_Slide.jpg",
            "Instagram/Badlands_Panorama/02_Slide.jpg", "Instagram/Badlands_Panorama/03_Slide.jpg",
        ])
    }

    @Test("不开 hash 时清单里没有 hash")
    func hashOptional() throws {
        let box = try Sandbox()
        let spec = box.spec(try box.makeSource())
        let area = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
        let manifest = try exporter.publish(try render(area, slides: 0), spec: spec, jobId: JobID(), staging: area, startedAt: Date())
        #expect(manifest.items.count == 1)
        #expect(manifest.items[0].sha256 == nil)
    }

    @Test("作品目录已存在：加版本后缀，不碰已有文件")
    func versionSuffixOnConflict() throws {
        let box = try Sandbox()
        let spec = box.spec(try box.makeSource())
        let existing = box.exports.appending(path: "Instagram/Badlands_Panorama")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let keep = existing.appending(path: "00_Cover.jpg")
        try Data("user's earlier export".utf8).write(to: keep)
        try FileManager.default.createDirectory(at: box.exports.appending(path: "Instagram/Badlands_Panorama_v2"), withIntermediateDirectories: true)

        let area = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
        let manifest = try exporter.publish(try render(area, slides: 1), spec: spec, jobId: JobID(), staging: area, startedAt: Date())

        #expect(manifest.directory.lastPathComponent == "Badlands_Panorama_v3")
        #expect(try Data(contentsOf: keep) == Data("user's earlier export".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.exports.appending(path: "Instagram/Badlands_Panorama_v2").path).isEmpty)
    }

    @Test("同名作品先后发布：第二个得到 _v2")
    func sequentialSameName() throws {
        let box = try Sandbox()
        let spec = box.spec(try box.makeSource())
        var names: [String] = []
        for _ in 0..<3 {
            let area = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
            names.append(try exporter.publish(try render(area, slides: 1), spec: spec, jobId: JobID(), staging: area, startedAt: Date()).directory.lastPathComponent)
        }
        #expect(names == ["Badlands_Panorama", "Badlands_Panorama_v2", "Badlands_Panorama_v3"])
    }

    @Test("中途校验失败：目的地没有半成品，临时文件全部删除")
    func failureLeavesNothing() throws {
        let box = try Sandbox()
        let spec = box.spec(try box.makeSource())
        let area = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
        // 第 3 个文件是坏的：前两个已经校验通过，也不能出现在目的地。
        let result = try render(area, slides: 3, corrupt: 2)

        #expect(throws: ApplicationError.self) {
            try exporter.publish(result, spec: spec, jobId: JobID(), staging: area, startedAt: Date())
        }
        #expect(box.exportTree().isEmpty, "\(box.exportTree())")
    }

    @Test("最终改名前取消：不发布任何东西")
    func cancelBeforeRename() throws {
        let box = try Sandbox()
        let spec = box.spec(try box.makeSource())
        let area = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
        let result = try render(area, slides: 2)
        #expect(throws: CancellationError.self) {
            try exporter.publish(result, spec: spec, jobId: JobID(), staging: area, startedAt: Date(), isCanceled: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: box.exports.appending(path: "Instagram/Badlands_Panorama").path))
        #expect(!box.stagingExists)
    }

    @Test("拒绝临时目录以外的文件、符号链接和硬链接，原图不受影响")
    func rejectsForeignFiles() throws {
        let box = try Sandbox()
        let source = try box.makeSource()
        let spec = box.spec(source)
        let original = try Data(contentsOf: source.fileURL)

        func attempt(_ makeURL: (StagingArea) throws -> URL) throws -> ApplicationError? {
            let area = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
            var result = try render(area, slides: 1)
            result.outputs[0].fileURL = try makeURL(area)
            do {
                _ = try exporter.publish(result, spec: spec, jobId: JobID(), staging: area, startedAt: Date())
                return nil
            } catch let e as ApplicationError {
                return e
            }
        }

        #expect(try attempt { _ in source.fileURL }?.code == "export.output_outside_staging")
        #expect(try attempt { $0.renderDirectory.appending(path: "../../../../Originals/Badlands.tif") }?.code == "export.output_outside_staging")
        #expect(try attempt { area in
            let link = area.renderDirectory.appending(path: "sym.jpg")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.fileURL)
            return link
        }?.code == "export.output_outside_staging")
        #expect(try attempt { area in
            let link = area.renderDirectory.appending(path: "hard.jpg")
            try FileManager.default.linkItem(at: source.fileURL, to: link)
            return link
        }?.code == "export.output_not_regular_file")
        #expect(try attempt { $0.renderDirectory.appending(path: "missing.jpg") }?.code == "export.output_missing")

        #expect(FileManager.default.fileExists(atPath: source.fileURL.path))
        #expect(try Data(contentsOf: source.fileURL) == original)
        #expect(box.exportTree().isEmpty, "\(box.exportTree())")
    }

    @Test("重复的输出位置、空结果、空文件")
    func rejectsBadResults() throws {
        let box = try Sandbox()
        let spec = box.spec(try box.makeSource())

        var area = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
        var result = try render(area, slides: 1)
        result.outputs[0].role = .cover  // 倒序：[0] 原本是切片
        #expect(throws: ApplicationError.duplicateRole(.cover)) {
            try exporter.publish(result, spec: spec, jobId: JobID(), staging: area, startedAt: Date())
        }

        area = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
        #expect(throws: ApplicationError.noOutputs()) {
            try exporter.publish(JobRenderResult(outputs: []), spec: spec, jobId: JobID(), staging: area, startedAt: Date())
        }

        area = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
        result = try render(area, slides: 0)
        try Data().write(to: result.outputs[0].fileURL)
        #expect(throws: ApplicationError.outputEmpty(result.outputs[0].fileURL.path)) {
            try exporter.publish(result, spec: spec, jobId: JobID(), staging: area, startedAt: Date())
        }
        #expect(box.exportTree().isEmpty)
    }

    @Test("PNG 输出检查 PNG 签名")
    func pngSignature() throws {
        let box = try Sandbox()
        var preset = ExportPreset.testStandard
        preset.output.format = .png
        let spec = box.spec(try box.makeSource(), preset: preset)
        let area = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
        let jpeg = try render(area, slides: 0)
        #expect(throws: ApplicationError.self) {
            try exporter.publish(jpeg, spec: spec, jobId: JobID(), staging: area, startedAt: Date())
        }

        let area2 = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
        let url = area2.renderDirectory.appending(path: "x")
        try Data(SignatureOutputVerifier.signature(for: .png) + [0]).write(to: url)
        let manifest = try exporter.publish(
            JobRenderResult(outputs: [JobRenderedOutput(role: .cover, fileURL: url, pixelSize: PixelSize(width: 1080, height: 1440), colorProfile: nil)]),
            spec: spec, jobId: JobID(), staging: area2, startedAt: Date())
        #expect(manifest.items.map(\.fileName) == ["00_Cover.png"])
        #expect(manifest.directory.lastPathComponent == "Badlands_Standard")
    }

    @Test("清理只删除本次执行的目录，保留别的任务的临时目录")
    func discardOnlyOwn() throws {
        let box = try Sandbox()
        let mine = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
        let other = try exporter.makeStaging(destinationRoot: box.exports, attemptId: AttemptID())
        try Data("x".utf8).write(to: other.renderDirectory.appending(path: "keep"))
        exporter.discard(mine)
        #expect(!FileManager.default.fileExists(atPath: mine.directory.path))
        #expect(FileManager.default.fileExists(atPath: other.renderDirectory.appending(path: "keep").path))
        exporter.discard(other)
        #expect(!box.stagingExists)
    }
}
