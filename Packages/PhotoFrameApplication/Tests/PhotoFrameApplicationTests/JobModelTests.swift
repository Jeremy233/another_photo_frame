import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import Testing

@Suite("状态机")
struct JobStatusTests {
    @Test("流水线只能逐步前进")
    func pipelineOrder() {
        #expect(JobStatus.pipeline == [.queued, .validating, .decoding, .rendering, .encoding, .writing, .completed])
        for (a, b) in zip(JobStatus.pipeline, JobStatus.pipeline.dropFirst()) {
            #expect(a.canTransition(to: b))
            #expect(!b.canTransition(to: a), "\(b) 不能回到 \(a)")
        }
        #expect(!JobStatus.queued.canTransition(to: .rendering))
        #expect(!JobStatus.decoding.canTransition(to: .writing))
        #expect(!JobStatus.validating.canTransition(to: .validating))
    }

    @Test("处理中任意状态都能失败或取消")
    func failOrCancelFromProcessing() {
        for status in JobStatus.allCases where status.isProcessing {
            #expect(status.canTransition(to: .failed))
            #expect(status.canTransition(to: .canceled))
        }
        #expect(JobStatus.queued.canTransition(to: .canceled))
        #expect(!JobStatus.queued.canTransition(to: .failed))
    }

    @Test("终态不再变化")
    func terminalStates() {
        for terminal in [JobStatus.completed, .failed, .canceled] {
            #expect(terminal.isTerminal)
            for target in JobStatus.allCases {
                #expect(!terminal.canTransition(to: target))
            }
        }
    }
}

@Suite("任务模型")
struct JobRecordTests {
    @Test("JobRecord 可以 JSON 往返（D-13）")
    func codableRoundTrip() throws {
        let source = PhotoSource(fileURL: URL(filePath: "/tmp/Badlands.tif"), image: SourceImage(storedSize: PixelSize(width: 6500, height: 2400)))
        var record = JobRecord(spec: JobSpec(
            source: source, preset: .testPanorama,
            destination: ExportDestination(rootDirectory: URL(filePath: "/tmp/out")),
            assetBindings: ["camera.badge": UUID()]))
        record.currentAttempt.status = .failed
        record.currentAttempt.error = ApplicationError(code: "render.failed", message: "x", hint: "y")
        record.attempts.append(AttemptRecord(number: 2))
        record.currentAttempt.manifest = OutputManifest(
            jobId: record.jobId, attemptId: record.currentAttempt.attemptId,
            directory: URL(filePath: "/tmp/out/Instagram/Badlands_Panorama"),
            items: [OutputManifestItem(
                role: .slide(position: 1), fileURL: URL(filePath: "/tmp/out/Instagram/Badlands_Panorama/01_Slide.jpg"),
                fileName: "01_Slide.jpg", pixelSize: PixelSize(width: 1080, height: 1440), colorProfile: "sRGB",
                fileSizeBytes: 123, sha256: "ab", warnings: [])],
            warnings: [], startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(JobRecord.self, from: data)
        #expect(decoded.jobId == record.jobId)
        #expect(decoded.attempts.count == 2)
        #expect(decoded.attempts[0].error == record.attempts[0].error)
        #expect(decoded.currentAttempt.manifest?.items.first?.role == .slide(position: 1))
        #expect(decoded.spec.preset == record.spec.preset)
        #expect(decoded.spec.assetBindings == record.spec.assetBindings)

        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""kind":"slide""#))
        #expect(json.contains(record.jobId.description))
    }

    @Test("事件可以 JSON 往返")
    func eventCodable() throws {
        let event = JobEvent.progress(jobId: JobID(), attemptId: AttemptID(), progress: JobProgress(stage: .rendering, completedOutputs: 2, plannedOutputs: 5))
        let decoded = try JSONDecoder().decode(JobEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
    }
}

@Suite("输出命名（§9.2）")
struct OutputNamingTests {
    @Test("文件名：00_Cover、01_Slide…，超过 99 项时补位")
    func fileNames() {
        #expect(OutputNaming.fileName(for: .cover, format: .jpeg, outputCount: 5) == "00_Cover.jpg")
        #expect(OutputNaming.fileName(for: .slide(position: 1), format: .jpeg, outputCount: 5) == "01_Slide.jpg")
        #expect(OutputNaming.fileName(for: .slide(position: 12), format: .png, outputCount: 20) == "12_Slide.png")
        #expect(OutputNaming.fileName(for: .slide(position: 7), format: .jpeg, outputCount: 120) == "007_Slide.jpg")
        #expect(OutputNaming.fileName(for: .cover, format: .jpeg, outputCount: 101) == "000_Cover.jpg")
    }

    @Test("平台目录名与 §9.2 一致")
    func platformFolders() {
        #expect(OutputNaming.platformFolderName(for: "instagram") == "Instagram")
        #expect(OutputNaming.platformFolderName(for: "xiaohongshu") == "Xiaohongshu")
        #expect(OutputNaming.platformFolderName(for: "douyin") == "Douyin")
        #expect(OutputNaming.platformFolderName(for: nil) == "Custom")
        #expect(OutputNaming.platformFolderName(for: "threads") == "Threads")
        #expect(OutputNaming.platformFolderName(for: "../evil") == "_evil")
    }

    @Test("作品名默认 {source}_{variant}")
    func workNames() {
        let source = PhotoSource(fileURL: URL(filePath: "/x/Badlands.tif"))
        let naming = OutputNaming()
        #expect(naming.workName(source: source, preset: .testPanorama) == "Badlands_Panorama")
        #expect(naming.workName(source: source, preset: .testStandard) == "Badlands_Standard")
        #expect(OutputNaming(workNameTemplate: "{preset} - {source}").workName(source: source, preset: .testStandard)
            == "Instagram Standard - Badlands")
        // 源文件名里的占位符文字不会再次展开；未知占位符原样保留。
        let tricky = PhotoSource(fileURL: URL(filePath: "/x/{variant}.jpg"))
        #expect(OutputNaming(workNameTemplate: "{source}-{nope}-{").workName(source: tricky, preset: .testPanorama) == "{variant}-{nope}-{")
    }

    @Test("作品名清理：路径分隔符、隐藏前缀、空名")
    func sanitize() {
        #expect(OutputNaming.sanitize("a/b:c") == "a_b_c")
        #expect(OutputNaming.sanitize("../../etc") == "_.._etc")
        #expect(OutputNaming.sanitize("  .hidden ") == "hidden")
        #expect(OutputNaming.sanitize("...") == "Untitled")
        #expect(OutputNaming.sanitize("line\nbreak") == "line_break")
        #expect(OutputNaming.sanitize(String(repeating: "长", count: 300)).count == 120)
    }

    @Test("版本后缀")
    func versions() {
        #expect(OutputNaming.versioned("Badlands_Panorama", version: 1) == "Badlands_Panorama")
        #expect(OutputNaming.versioned("Badlands_Panorama", version: 2) == "Badlands_Panorama_v2")
    }
}
