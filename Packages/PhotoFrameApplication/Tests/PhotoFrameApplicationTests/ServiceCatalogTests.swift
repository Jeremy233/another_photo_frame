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
            PreviewImage(role: $0, pixelSize: PixelSize(width: 3, height: 4), exportPixelSize: request.preset.canvas.size, data: Data([1]))
        }
        return ExportPreview(pages: pages, roles: roles, warnings: [])
    }
}

extension ExportPreset {
    /// 带一个必需素材槽的预设。
    static let withRequiredSlot = ExportPreset(
        name: "Signed", platform: "instagram",
        canvas: CanvasSettings(width: 1080, height: 1440, background: .defaultBackground, minMarginPx: 60, mode: .fit),
        layers: [OverlayLayer(layerId: "sig", type: .asset, sizePx: PixelSize(width: 100, height: 40), slotId: "signature")],
        assetSlots: [AssetSlot(slotId: "signature", required: true)])
}

/// 临时目录里的本地库。
func makeLibrary(_ box: Sandbox) throws -> LocalLibrary {
    LocalLibrary(root: box.root.appending(path: "Library", directoryHint: .isDirectory), platforms: try PlatformCatalogStore.builtIn())
}

func code(_ error: any Error) -> String? { (error as? ApplicationError)?.code }

@Suite("预设库与素材库（经由服务）")
struct PresetCatalogTests {
    @Test("参数解析：文件或预设库引用")
    func referenceParsing() {
        let base = URL(filePath: "/tmp/work", directoryHint: .isDirectory)
        #expect(PresetReference(argument: "./Minimal.photoframe", relativeTo: base) == .file(URL(filePath: "/tmp/work/Minimal.photoframe")))
        #expect(PresetReference(argument: "presets/x.PHOTOFRAME", relativeTo: base) == .file(URL(filePath: "/tmp/work/presets/x.PHOTOFRAME")))
        #expect(PresetReference(argument: "/abs/y.photoframe", relativeTo: base) == .file(URL(filePath: "/abs/y.photoframe")))
        #expect(PresetReference(argument: "60978D90-F0A0-4369-B82D-6EEEE52F89BA") == .library("60978D90-F0A0-4369-B82D-6EEEE52F89BA"))
        #expect(PresetReference(argument: " instagram-panorama ") == .library("instagram-panorama"))
    }

    @Test("空库只有内置预设；按短名、名称、ID 查找（PresetLibrary.find，D-76）")
    func builtIns() async throws {
        let service = LocalPhotoFrameService(renderer: FakeRenderer())
        let list = try await service.listPresets()
        #expect(list.presets.map(\.slug) == ["instagram-standard", "instagram-panorama", "xhs-standard", "xhs-panorama", "douyin-standard", "douyin-panorama"])
        #expect(list.presets.allSatisfy { $0.origin == .builtIn && $0.readOnly })
        #expect(list.presets[1].panorama != nil && list.presets[0].panorama == nil)
        #expect(list.presets[2].platformName != nil)

        #expect(try await service.resolvePreset(.library("xhs-panorama")).preset.name == "XHS Panorama")
        #expect(try await service.resolvePreset(.library("douyin standard")).preset.name == "Douyin Standard")
        #expect(try await service.resolvePreset(.library(list.presets[0].presetId.uuidString)).preset.name == "Instagram Standard")
        await #expect { try await service.resolvePreset(.library("tiktok")) } throws: { code($0) == "library.preset_not_found" }
    }

    @Test("导入（默认另存为副本 / 替换）、导出、复制、重命名、删除")
    func presetLifecycle() async throws {
        let box = try Sandbox()
        let service = LocalPhotoFrameService(renderer: FakeRenderer(), library: try makeLibrary(box))
        var custom = ExportPreset.testPanorama
        custom.presetId = UUID()
        custom.name = "My Landscape"
        let file = box.root.appending(path: "My.photoframe")
        try PresetPackage.export(custom, to: file)

        let first = try await service.importPreset(from: file, replace: false)
        #expect(first.preset.presetId == custom.presetId && first.preset.origin == .imported && first.conflictResolution == nil)
        let copy = try await service.importPreset(from: file, replace: false)
        #expect(copy.conflictResolution == "saveAsCopy" && copy.preset.name == "My Landscape Copy" && copy.preset.presetId != custom.presetId)
        let replaced = try await service.importPreset(from: file, replace: true)
        #expect(replaced.conflictResolution == "replace" && replaced.preset.presetId == custom.presetId)
        await #expect { try await service.importPreset(from: box.root.appending(path: "nope.photoframe"), replace: false) } throws: {
            code($0) == "preset.file_not_found"
        }

        let out = box.root.appending(path: "Out.photoframe")
        try await service.exportPreset(.library("my-landscape"), to: out, overwrite: false)
        #expect(try PresetPackage.importPreset(try Data(contentsOf: out)).preset.presetId == custom.presetId)
        await #expect { try await service.exportPreset(.library("my-landscape"), to: out, overwrite: false) } throws: { code($0) == "preset.export_exists" }
        try await service.exportPreset(.library("Instagram Standard"), to: out, overwrite: true)

        let dup = try await service.duplicatePreset(.library("xhs-standard"), name: nil)
        #expect(dup.origin == .user && dup.name == "XHS Standard Copy" && !dup.readOnly)
        let renamed = try await service.renamePreset(.library(dup.presetId.uuidString), to: "Square")
        #expect(renamed.name == "Square")
        await #expect { try await service.renamePreset(.library("xhs-standard"), to: "X") } throws: { code($0) == "library.builtin_read_only" }
        await #expect { try await service.deletePreset(.file(file)) } throws: { code($0) == "library.preset_not_in_library" }

        // 分组移动（D-81、D-94）：内置预设不能移动；文件预设不在库里。
        let moved = try await service.movePreset(.library("square"), to: .imported)
        #expect(moved.origin == .imported && moved.presetId == dup.presetId)
        #expect(try await service.movePreset(.library("square"), to: .user).origin == .user)
        await #expect { try await service.movePreset(.library("xhs-standard"), to: .user) } throws: { code($0) == "library.builtin_read_only" }
        await #expect { try await service.movePreset(.library("square"), to: .builtIn) } throws: { code($0) == "library.builtin_read_only" }
        await #expect { try await service.movePreset(.file(file), to: .user) } throws: { code($0) == "library.preset_not_in_library" }

        let names = try await service.listPresets().presets.map(\.name)
        #expect(names.contains("Square") && names.contains("My Landscape") && names.contains("My Landscape Copy"))
        try await service.deletePreset(.library("square"))
        #expect(try await !service.listPresets().presets.contains { $0.name == "Square" })

        _ = try await service.renamePreset(.library("My Landscape Copy"), to: "My Landscape")
        await #expect { try await service.resolvePreset(.library("my landscape")) } throws: { code($0) == "library.ambiguous_preset" }
    }

    @Test("逐项修改预设（D-93）：内置只读、文件预设不在库里、修改后列表和快照都更新")
    func updatePreset() async throws {
        let box = try Sandbox()
        let service = LocalPhotoFrameService(renderer: FakeRenderer(), library: try makeLibrary(box))
        let margin = try PresetFieldPath(parsing: "canvas.minMarginPx")
        await #expect { try await service.updatePreset(.library("xhs-standard"), edits: [.set(margin, .number(80))]) } throws: {
            code($0) == "library.builtin_read_only"
        }
        let file = box.root.appending(path: "X.photoframe")
        try PresetPackage.export(ExportPreset.testPanorama, to: file)
        await #expect { try await service.updatePreset(.file(file), edits: [.set(margin, .number(80))]) } throws: {
            code($0) == "library.preset_not_in_library"
        }
        let dup = try await service.duplicatePreset(.library("xhs-standard"), name: "Square")
        let updated = try await service.updatePreset(.library("square"), edits: [.set(margin, .number(80))])
        #expect(updated.preset.presetId == dup.presetId && updated.preset.minMarginPx == 80)
        #expect(updated.content.canvas.minMarginPx == 80)
        #expect(try await service.resolvePreset(.library("square")).preset.canvas.minMarginPx == 80)
        await #expect { try await service.updatePreset(.library("square"), edits: []) } throws: { code($0) == "preset.invalid_edit" }
    }

    @Test(".photoframe 文件：只读取不放进库，之后出现在列表里；损坏文件有稳定错误码")
    func presetFile() async throws {
        let box = try Sandbox()
        var custom = ExportPreset.testPanorama
        custom.presetId = UUID()
        custom.name = "Loose File"
        let file = box.root.appending(path: "Loose.photoframe")
        try PresetPackage.export(custom, to: file)

        let service = LocalPhotoFrameService(renderer: FakeRenderer(), library: try makeLibrary(box))
        let entry = try await service.resolvePreset(.file(file))
        #expect(entry.preset == custom && entry.origin == .file(file))
        #expect(try await service.listPresets().presets.contains { $0.slug == "loose-file" && $0.origin == .file(file) && $0.readOnly })
        #expect(service.library.presets.list().user.isEmpty && service.library.presets.list().imported.isEmpty)

        await #expect { try await service.resolvePreset(.file(box.root.appending(path: "nope.photoframe"))) } throws: { code($0) == "preset.file_not_found" }
        let broken = box.root.appending(path: "Broken.photoframe")
        try Data("not a zip".utf8).write(to: broken)
        await #expect { try await service.resolvePreset(.file(broken)) } throws: { code($0)?.hasPrefix("archive.") ?? false }
    }

    @Test("素材：导入、按名称找、绑定、列出绑定、删除（绑定保留，D-83）")
    func assets() async throws {
        let box = try Sandbox()
        let service = LocalPhotoFrameService(renderer: FakeRenderer(), library: try makeLibrary(box))
        let png = try box.photo("Sig.png", width: 120, height: 40, type: .png)
        let imported = try await service.importAsset(from: png, category: .signature, name: "My Signature")
        #expect(imported.asset.format == .png && imported.asset.pixelSize == PixelSize(width: 120, height: 40))
        #expect(try await service.resolveAsset("my signature").assetId == imported.asset.assetId)
        #expect(try await service.resolveAsset(imported.asset.assetId.uuidString).displayName == "My Signature")
        await #expect { try await service.resolveAsset("nope") } throws: { code($0) == "asset.not_found" }
        await #expect { try await service.importAsset(from: box.root.appending(path: "x.png"), category: .watermark, name: nil) } throws: {
            code($0) == "asset.file_not_found"
        }
        let svg = box.root.appending(path: "Bad.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><script/></svg>"#.utf8).write(to: svg)
        await #expect { try await service.importAsset(from: svg, category: .watermark, name: nil) } throws: { code($0) == "asset.svg_rejected" }

        let recategorized = try await service.setAssetCategory(imported.asset.assetId, to: .watermark)
        #expect(recategorized.category == .watermark)
        #expect(await service.listAssets(category: .watermark).assets.map(\.assetId) == [imported.asset.assetId])
        await #expect { try await service.setAssetCategory(UUID(), to: .signature) } throws: { code($0) == "asset.not_found" }

        try await service.bindAsset(imported.asset.assetId, slotId: "signature", preset: nil)
        let dup = try await service.duplicatePreset(.library("instagram-standard"), name: "Signed")
        var signed = ExportPreset.withRequiredSlot
        signed.presetId = dup.presetId
        signed.name = "Signed"
        _ = try service.library.presets.update(signed)
        try await service.bindAsset(imported.asset.assetId, slotId: "signature", preset: .library("signed"))
        await #expect { try await service.bindAsset(imported.asset.assetId, slotId: "nope", preset: .library("signed")) } throws: {
            code($0) == "binding.unknown_slot"
        }
        let bindings = await service.listBindings().bindings
        #expect(bindings.count == 2)
        #expect(Set(bindings.map(\.scope)) == [.presetLocal, .userGlobal])

        let affected = try await service.deleteAsset(imported.asset.assetId)
        #expect(affected.count == 2)
        #expect(await service.listAssets(category: nil).assets.isEmpty)
        try await service.bindAsset(nil, slotId: "signature", preset: nil)
        #expect(await service.listBindings().bindings.count == 1)
    }

    @Test("CatalogPresetOrigin 的 JSON 形式")
    func originCoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let all: [CatalogPresetOrigin] = [.builtIn, .user, .imported, .file(URL(filePath: "/a/b.photoframe"))]
        let data = try encoder.encode(all)
        #expect(String(decoding: data, as: UTF8.self) == #"[{"kind":"builtIn"},{"kind":"user"},{"kind":"imported"},{"kind":"file","path":"\/a\/b.photoframe"}]"#)
        #expect(try JSONDecoder().decode([CatalogPresetOrigin].self, from: data) == all)
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
