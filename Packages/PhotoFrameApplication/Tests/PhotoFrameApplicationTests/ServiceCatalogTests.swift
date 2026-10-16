import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameStorage
import Testing

/// 假的图像分析：每个预设固定输出封面 + `slides` 张切片。
struct FakeAnalyzer: ImageAnalyzer {
    var slides = 2

    func inspect(_ fileURL: URL) async throws -> SourceInspection {
        SourceInspection(
            fileURL: fileURL, fileSizeBytes: 1, format: "tiff", pixelSize: PixelSize(width: 30, height: 10), orientation: 1,
            displaySize: PixelSize(width: 30, height: 10), bitDepth: 16, isFloat: false, hasAlpha: false,
            colorProfile: .init(embedded: false, description: "sRGB", origin: "assumedSRGB"), hdr: .init(kind: "none", headroom: nil),
            metadata: [:], hasGPS: false, hasAuthorOrCopyright: false, warnings: [])
    }

    func roles(_ preset: ExportPreset) -> [JobOutputRole] {
        preset.panorama.enabled ? [.cover] + (1...slides).map { .slide(position: $0) } : [.cover]
    }

    func plan(_ request: JobRenderRequest) async throws -> ExportPlan {
        ExportPlan(outputs: roles(request.preset).map { PlannedOutput(role: $0, pixelSize: request.preset.canvas.size) },
                   warnings: [ApplicationWarning(code: "test.plan", message: "plan")])
    }

    func preview(_ request: JobRenderRequest, options: PreviewOptions) async throws -> ExportPreview {
        let roles = roles(request.preset)
        let pages = roles.filter { options.pages?.contains($0.carouselPosition) ?? true }.map {
            PreviewImage(role: $0, pixelSize: PixelSize(width: 3, height: 4), exportPixelSize: request.preset.canvas.size, pngData: Data([1]))
        }
        return ExportPreview(pages: pages, roles: roles, warnings: [])
    }
}

/// 固定的预设列表。
struct ListPresetProvider: PresetProvider {
    var entries: [CatalogPreset]
    func presets() async throws(ApplicationError) -> [CatalogPreset] { entries }
}

extension ExportPreset {
    /// 带一个必需素材槽的预设。
    static let withRequiredSlot = ExportPreset(
        name: "Signed", platform: "instagram",
        canvas: CanvasSettings(width: 1080, height: 1440, background: .defaultBackground, minMarginPx: 60, mode: .fit),
        layers: [OverlayLayer(layerId: "sig", type: .asset, sizePx: PixelSize(width: 100, height: 40), slotId: "signature")],
        assetSlots: [AssetSlot(slotId: "signature", required: true)])
}

@Suite("预设来源与解析")
struct PresetCatalogTests {
    @Test("参数解析：文件、ID、名称")
    func referenceParsing() {
        let base = URL(filePath: "/tmp/work", directoryHint: .isDirectory)
        #expect(PresetReference(argument: "./Minimal.photoframe", relativeTo: base) == .file(URL(filePath: "/tmp/work/Minimal.photoframe")))
        #expect(PresetReference(argument: "presets/x.PHOTOFRAME", relativeTo: base) == .file(URL(filePath: "/tmp/work/presets/x.PHOTOFRAME")))
        #expect(PresetReference(argument: "60978D90-F0A0-4369-B82D-6EEEE52F89BA") == .id(UUID(uuidString: "60978D90-F0A0-4369-B82D-6EEEE52F89BA")!))
        #expect(PresetReference(argument: "instagram-panorama") == .name("instagram-panorama"))
        #expect(PresetReference.normalizedName("  XHS   Standard ") == "xhs-standard")
        #expect(PresetReference.normalizedName("Douyin_Panorama") == "douyin-panorama")
    }

    @Test("默认只有内置预设；按短名称、名称、ID 查找")
    func builtIns() async throws {
        let service = LocalPhotoFrameService(renderer: FakeRenderer())
        let list = try await service.listPresets()
        #expect(list.map(\.slug) == ["instagram-standard", "instagram-panorama", "xhs-standard", "xhs-panorama", "douyin-standard", "douyin-panorama"])
        #expect(list.allSatisfy { $0.origin == .builtIn })
        #expect(list[1].panorama != nil && list[0].panorama == nil)
        #expect(list[2].platformName != nil)

        #expect(try await service.resolvePreset(.name("xhs-panorama")).preset.name == "XHS Panorama")
        #expect(try await service.resolvePreset(.name("Douyin Standard")).preset.name == "Douyin Standard")
        #expect(try await service.resolvePreset(.id(list[0].presetId)).preset.name == "Instagram Standard")
        await #expect { try await service.resolvePreset(.name("tiktok")) } throws: { ($0 as? ApplicationError)?.code == "preset.not_found" }
    }

    @Test("同名预设报 preset.ambiguous")
    func ambiguous() async throws {
        var a = ExportPreset.testStandard
        a.presetId = UUID()
        var b = a
        b.presetId = UUID()
        let service = LocalPhotoFrameService(renderer: FakeRenderer(), presets: ListPresetProvider(entries: [
            CatalogPreset(preset: a, origin: .library), CatalogPreset(preset: b, origin: .library),
        ]))
        await #expect { try await service.resolvePreset(.name("instagram standard")) } throws: { ($0 as? ApplicationError)?.code == "preset.ambiguous" }
    }

    @Test(".photoframe 文件：只读不安装，之后出现在列表里；文件缺失或损坏有稳定错误码")
    func presetFile() async throws {
        let box = try Sandbox()
        var custom = ExportPreset.testPanorama
        custom.presetId = UUID()
        custom.name = "My Landscape"
        let file = box.root.appending(path: "My.photoframe")
        try PresetPackage.export(custom, to: file)

        let service = LocalPhotoFrameService(renderer: FakeRenderer())
        let entry = try await service.resolvePreset(.file(file))
        #expect(entry.preset == custom)
        #expect(entry.origin == .file(file))
        #expect(try await service.listPresets().contains { $0.slug == "my-landscape" && $0.origin == .file(file) })
        #expect(try await service.resolvePreset(.name("my landscape")).preset.presetId == custom.presetId)

        await #expect { try await service.resolvePreset(.file(box.root.appending(path: "nope.photoframe"))) } throws: {
            ($0 as? ApplicationError)?.code == "preset.file_not_found"
        }
        let broken = box.root.appending(path: "Broken.photoframe")
        try Data("not a zip".utf8).write(to: broken)
        await #expect { try await service.resolvePreset(.file(broken)) } throws: {
            ($0 as? ApplicationError)?.code.hasPrefix("archive.") ?? false
        }
    }

    @Test("CatalogPresetOrigin 的 JSON 形式")
    func originCoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode([CatalogPresetOrigin.builtIn, .file(URL(filePath: "/a/b.photoframe")), .library])
        #expect(String(decoding: data, as: UTF8.self) == #"[{"kind":"builtIn"},{"kind":"file","path":"\/a\/b.photoframe"},{"kind":"library"}]"#)
        #expect(try JSONDecoder().decode([CatalogPresetOrigin].self, from: data) == [.builtIn, .file(URL(filePath: "/a/b.photoframe")), .library])
    }
}

@Suite("服务：检查、校验、预览")
struct ServiceValidationTests {
    func service(_ config: QueueConfiguration = QueueConfiguration(), analyzer: (any ImageAnalyzer)? = FakeAnalyzer()) -> LocalPhotoFrameService {
        LocalPhotoFrameService(renderer: FakeRenderer(), analyzer: analyzer, configuration: config)
    }

    @Test("没有图像分析器时 inspect / preview 报 service.unavailable")
    func noAnalyzer() async throws {
        let box = try Sandbox()
        let service = service(analyzer: nil)
        let source = try box.makeSource()
        await #expect { try await service.inspectSource(.file(source.fileURL)) } throws: { ($0 as? ApplicationError)?.code == "service.unavailable" }
        await #expect { try await service.renderPreview(ExportPreviewRequest(source: .file(source.fileURL), preset: .testStandard)) } throws: {
            ($0 as? ApplicationError)?.code == "service.unavailable"
        }
        await #expect { try await service.inspectSource(.file(box.root.appending(path: "nope.tif"))) } throws: {
            ($0 as? ApplicationError)?.code == "source.not_found"
        }
    }

    @Test("校验：预估文件名、版本后缀（磁盘已有 + 同一请求内同名），不写任何文件")
    func predictsVersions() async throws {
        let box = try Sandbox()
        let service = service()
        try FileManager.default.createDirectory(at: box.exports.appending(path: "Instagram/Badlands_Panorama"), withIntermediateDirectories: true)
        let a = try await service.addSource(try box.makeSource("Badlands.tif").fileURL)
        let b = try await service.addSource(try box.makeSource("Other/Badlands.jpg").fileURL)
        let before = box.exportTree()

        let result = try await service.validate(ExportRequest(
            sourceIds: [a.sourceId, b.sourceId], presets: [.testPanorama, .testStandard],
            destination: ExportDestination(rootDirectory: box.exports)))
        #expect(result.isValid)
        #expect(result.items.map { $0.directory.lastPathComponent } == [
            "Badlands_Panorama_v2", "Badlands_Standard", "Badlands_Panorama_v3", "Badlands_Standard_v2",
        ])
        #expect(result.items[0].outputs.map(\.fileName) == ["00_Cover.jpg", "01_Slide.jpg", "02_Slide.jpg"])
        #expect(result.items[0].warnings.contains { $0.code == "test.plan" })
        #expect(box.exportTree() == before)
    }

    @Test("覆盖：同一请求两个任务指向同一目录、旧目录不是本软件发布的，都在校验时报错")
    func overwriteChecks() async throws {
        let box = try Sandbox()
        let service = service()
        let a = try await service.addSource(try box.makeSource("Badlands.tif").fileURL)
        let b = try await service.addSource(try box.makeSource("Other/Badlands.jpg").fileURL)
        let destination = ExportDestination(rootDirectory: box.exports, conflictPolicy: .overwrite)

        let dup = try await service.validate(ExportRequest(sourceIds: [a.sourceId, b.sourceId], presets: [.testStandard], destination: destination))
        #expect(dup.items[0].errors.isEmpty)
        #expect(dup.items[1].errors.map(\.code) == ["request.duplicate_output"])

        try FileManager.default.createDirectory(at: box.exports.appending(path: "Instagram/Badlands_Standard"), withIntermediateDirectories: true)
        let foreign = try await service.validate(ExportRequest(sourceIds: [a.sourceId], presets: [.testStandard], destination: destination))
        #expect(foreign.errors.map(\.code) == ["export.overwrite_refused"])
    }

    @Test("校验：输出目录不可用、缺少必需素材、预设无效")
    func perItemErrors() async throws {
        let box = try Sandbox()
        let service = service(QueueConfiguration(assets: NoAssetLibrary()))
        let source = try await service.addSource(try box.makeSource().fileURL)

        let file = box.root.appending(path: "NotADir")
        try Data().write(to: file)
        let bad = try await service.validate(ExportRequest(
            sourceIds: [source.sourceId], presets: [.testStandard], destination: ExportDestination(rootDirectory: file)))
        #expect(bad.errors.map(\.code) == ["job.destination_unavailable"])

        let nested = box.root.appending(path: "a/b/c")
        let ok = try await service.validate(ExportRequest(
            sourceIds: [source.sourceId], presets: [.testStandard], destination: ExportDestination(rootDirectory: nested)))
        #expect(ok.isValid)
        #expect(!FileManager.default.fileExists(atPath: box.root.appending(path: "a").path))

        var invalid = ExportPreset.testStandard
        invalid.output.quality = 0
        let result = try await service.validate(ExportRequest(
            sourceIds: [source.sourceId], presets: [.withRequiredSlot, invalid], destination: ExportDestination(rootDirectory: box.exports)))
        #expect(result.items[0].errors.map(\.code) == ["slot.missing_required"])
        #expect(result.items[1].errors.map(\.code) == ["job.invalid_preset"])
        #expect(result.items.allSatisfy { $0.outputs.isEmpty })

        await #expect { try await service.validate(ExportRequest(sourceIds: [], presets: [.testStandard], destination: ExportDestination(rootDirectory: box.exports))) } throws: {
            ($0 as? ApplicationError)?.code == "request.empty"
        }
    }

    @Test("素材来源在队列校验时生效：缺少必需素材的任务失败")
    func queueUsesAssetProvider() async throws {
        let box = try Sandbox()
        let service = service(QueueConfiguration(assets: NoAssetLibrary()))
        let source = try await service.addSource(try box.makeSource().fileURL)
        let ids = try await service.submit(ExportRequest(sourceIds: [source.sourceId], presets: [.withRequiredSlot], destination: ExportDestination(rootDirectory: box.exports)))
        let record = try #require(await service.waitUntilFinished(ids).first)
        #expect(record.status == .failed)
        #expect(record.error?.code == "slot.missing_required")
    }

    @Test("预览：按文件登记源图，转交页码")
    func preview() async throws {
        let box = try Sandbox()
        let service = service()
        let source = try box.makeSource()
        let preview = try await service.renderPreview(ExportPreviewRequest(
            source: .file(source.fileURL), preset: .testPanorama, options: PreviewOptions(maxLongEdge: 100, pages: [0, 2])))
        #expect(preview.pages.map(\.role) == [.cover, .slide(position: 2)])
        #expect(preview.roles.count == 3)
        #expect(await service.sources().count == 1)
        #expect(try await service.inspectSource(.file(source.fileURL)).format == "tiff")
    }
}
