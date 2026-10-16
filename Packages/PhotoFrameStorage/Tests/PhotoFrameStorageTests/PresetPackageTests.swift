import Foundation
import Testing
import PhotoFrameCore
@testable import PhotoFrameStorage

func makePreset() -> ExportPreset {
    ExportPreset(
        presetId: UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!,
        name: "Gallery",
        platform: "xiaohongshu",
        canvas: CanvasSettings(width: 1080, height: 1080),
        panorama: PanoramaSettings(enabled: true),
        layers: [
            OverlayLayer(layerId: "badge", type: .cameraBadge, sizePx: Pair(48, 48), slotId: "camera.badge"),
            OverlayLayer(layerId: "sig", type: .text, anchor: .bottomLeft, text: TextStyle(content: "J. Photo")),
        ],
        assetSlots: [AssetSlot(slotId: "camera.badge", label: "相机线稿")],
        extensions: ["x-author": .string("J")])
}

/// 把 manifest JSON 原样打包，绕过导出时的校验，用来构造各种导入输入。
func package(manifest: String, extra: [ZipWriter.Entry] = []) -> Data {
    var zip = ZipWriter()
    zip.add(name: "manifest.json", data: Data(manifest.utf8))
    for e in extra { zip.add(e) }
    return zip.finish()
}

func manifestJSON(_ preset: ExportPreset) -> String {
    String(decoding: try! PresetSchema.encode(preset), as: UTF8.self)
}

@Suite("ZIP 读写")
struct ZipTests {
    @Test("CRC-32 已知值")
    func crc() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test("压缩与存储条目都能往返")
    func roundTrip() throws {
        let big = Data(String(repeating: "PhotoFrame ", count: 2000).utf8)
        let small = Data("x".utf8)
        var w = ZipWriter()
        w.add(name: "a.txt", data: big)
        w.add(ZipWriter.Entry(name: "dir/b.bin", data: small, compress: false))
        w.add(name: "empty", data: Data())
        let zip = try ZipReader(data: w.finish(), limits: .presetPackage)
        #expect(zip.entries.map(\.name) == ["a.txt", "dir/b.bin", "empty"])
        #expect(zip.entries[0].method == ZipFormat.methodDeflate)
        #expect(zip.entries[0].compressedSize < big.count)
        #expect(try zip.contents(of: zip.entries[0]) == big)
        #expect(try zip.contents(of: zip.entries[1]) == small)
        #expect(try zip.contents(of: zip.entries[2]) == Data())
    }

    @Test("系统 unzip 能读我们写的包")
    func interoperability() throws {
        let data = try PresetPackage.export(makePreset())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("p.photoframe")
        try data.write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", file.path, "-d", dir.appendingPathComponent("out").path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let manifest = try Data(contentsOf: dir.appendingPathComponent("out/manifest.json"))
        #expect(try PresetSchema.decode(manifest).preset == makePreset())
    }

    @Test("我们能读系统 zip 写的包")
    func readsSystemZip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try PresetSchema.encode(makePreset()).write(to: dir.appendingPathComponent("manifest.json"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", "-X", "p.photoframe", "manifest.json"]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let imported = try PresetPackage.importPreset(Data(contentsOf: dir.appendingPathComponent("p.photoframe")))
        #expect(imported.preset == makePreset())
    }
}

@Suite("预设包往返")
struct PresetPackageRoundTripTests {
    @Test("导出 → 导入，内容不变，输出是确定性的")
    func roundTrip() throws {
        let preset = makePreset()
        let data = try PresetPackage.export(preset)
        #expect(try PresetPackage.export(preset) == data)
        let imported = try PresetPackage.importPreset(data)
        #expect(imported.preset == preset)
        #expect(imported.originalSchemaVersion == 1)
        #expect(imported.warnings.isEmpty)
        let zip = try ZipReader(data: data, limits: .presetPackage)
        #expect(zip.entries.map(\.name) == ["manifest.json"])
    }

    @Test("写文件再读文件")
    func fileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).photoframe")
        defer { try? FileManager.default.removeItem(at: url) }
        try PresetPackage.export(makePreset(), to: url)
        let imported = try PresetPackage.importPreset(PresetPackage.readFile(at: url))
        #expect(imported.preset == makePreset())
    }

    @Test("拒绝导出无效预设，或包含本地路径的预设")
    func exportChecks() {
        var bad = makePreset()
        bad.layers.append(bad.layers[0])
        #expect(throws: PresetPackageError.self) { try PresetPackage.export(bad) }

        var leaky = makePreset()
        leaky.extensions["x-source"] = .string("/Users/jeremy/Pictures/logo.png")
        leaky.layers[1].text?.content = "file:///Volumes/Photos/sig.svg"
        #expect(throws: PresetPackageError.privateData(["layers[1].text.content", "x-source"])) {
            try PresetPackage.export(leaky)
        }
    }

    @Test("所有内置预设都能导出并导入")
    func builtInsRoundTrip() throws {
        let catalog = try PlatformCatalogStore.builtIn()
        for preset in BuiltInPresets.all(catalog: catalog) {
            let imported = try PresetPackage.importPreset(PresetPackage.export(preset), options: .init(platforms: catalog))
            #expect(imported.preset == preset)
        }
    }
}

@Suite("导入预览（§8.3）")
struct PresetPreviewTests {
    @Test("摘要包含尺寸、图层、slots、目标格式、schema 版本")
    func summary() throws {
        let catalog = try PlatformCatalogStore.builtIn()
        var preset = makePreset()
        preset.output.dynamicRange = .hdr
        let preview = try PresetPackage.preview(PresetPackage.export(preset), options: .init(platforms: catalog))
        #expect(preview.canImport)
        #expect(preview.schemaVersion == 1)
        #expect(preview.name == "Gallery")
        #expect(preview.presetId == "7C9E6679-7425-40DE-944B-E07FC1F90AE7")
        let s = try #require(preview.summary)
        #expect(s.canvas == PixelSize(width: 1080, height: 1080))
        #expect(s.background == "#FAFAF8")
        #expect(s.panorama == PresetSummary.Panorama(cover: true, tileCount: nil, verticalMarginPx: 0))
        #expect(s.layers.map(\.layerId) == ["badge", "sig"])
        #expect(s.slots.map(\.slotId) == ["camera.badge"])
        #expect(s.format == .jpeg && s.quality == 100 && s.dynamicRange == .hdr)
        #expect(s.platformName == "小红书")
        #expect(s.extensionFieldCount == 1)
        // 不可用能力：小红书 HDR 待实测。
        #expect(preview.issues.map(\.code) == ["platform.hdr_unverified"])
        // 预览可以序列化给 CLI / MCP。
        _ = try JSONEncoder().encode(preview)
    }

    @Test("较新版本：仍能显示名称和版本，但不能导入，提示升级")
    func newerVersion() throws {
        var json = manifestJSON(makePreset())
        json = json.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 7")
        let data = package(manifest: json)
        let preview = try PresetPackage.preview(data)
        #expect(!preview.canImport)
        #expect(preview.requiresNewerApp)
        #expect(preview.schemaVersion == 7)
        #expect(preview.name == "Gallery")
        #expect(preview.summary == nil)
        #expect(preview.issues.map(\.code) == ["preset.newer_schema_version"])
        #expect(throws: PresetPackageError.schema(.newerSchemaVersion(found: 7, supported: 1))) {
            try PresetPackage.importPreset(data)
        }
    }

    @Test("已有相同 presetId：警告，不阻止")
    func duplicatePresetId() throws {
        let preset = makePreset()
        let preview = try PresetPackage.preview(PresetPackage.export(preset), options: .init(existingPresetIds: [preset.presetId]))
        #expect(preview.canImport)
        #expect(preview.issues.map(\.code) == ["package.preset_id_exists"])
    }

    @Test("不认识的字段：默认拒绝；keep 策略下保留并警告；x- 字段始终放行")
    func unknownFields() throws {
        let json = manifestJSON(makePreset()).replacingOccurrences(of: "\"name\" : \"Gallery\"", with: "\"name\" : \"Gallery\", \"bleedPx\" : 3")
        let data = package(manifest: json)
        let rejected = try PresetPackage.preview(data)
        #expect(!rejected.canImport)
        #expect(rejected.issues.errors.map(\.path) == ["bleedPx"])
        #expect(throws: PresetPackageError.self) { try PresetPackage.importPreset(data) }

        let kept = try PresetPackage.importPreset(data, options: .init(unknownFields: .keep))
        #expect(kept.warnings.map(\.code) == ["package.unknown_field"])
        #expect(kept.preset.extensions["bleedPx"] == .number(3))
        #expect(kept.preset.extensions["x-author"] == .string("J"))
    }

    @Test("重复的图层 ID / slot ID 阻止导入")
    func duplicateIds() throws {
        var p = makePreset()
        p.layers.append(OverlayLayer(layerId: "sig", type: .text))
        p.assetSlots.append(AssetSlot(slotId: "camera.badge"))
        let preview = try PresetPackage.preview(package(manifest: manifestJSON(p)))
        #expect(!preview.canImport)
        #expect(Set(preview.issues.errors.map(\.code)) == ["preset.duplicate_layer_id", "preset.duplicate_slot_id"])
    }

    @Test("非法 manifest：JSON 错误、缺字段、错误枚举值")
    func invalidManifest() throws {
        for json in ["{oops", "[]", #"{"schemaVersion": 1}"#,
                     manifestJSON(makePreset()).replacingOccurrences(of: "\"cameraBadge\"", with: "\"hologram\"")] {
            let preview = try PresetPackage.preview(package(manifest: json))
            #expect(!preview.canImport, "\(json.prefix(30))")
            #expect(preview.summary == nil)
            #expect(throws: PresetPackageError.self) { try PresetPackage.importPreset(package(manifest: json)) }
        }
    }

    @Test("额外文件被忽略并提示")
    func extraEntries() throws {
        let data = package(manifest: manifestJSON(makePreset()), extra: [
            ZipWriter.Entry(name: "assets/", data: Data()),
            ZipWriter.Entry(name: "assets/logo.png", data: Data([1, 2, 3])),
        ])
        let preview = try PresetPackage.preview(data)
        #expect(preview.canImport)
        #expect(preview.issues.map(\.code) == ["package.ignored_entry"])
    }
}
