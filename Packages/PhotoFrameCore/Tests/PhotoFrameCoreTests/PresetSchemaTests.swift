import Foundation
import Testing
@testable import PhotoFrameCore

/// 字段比较全的预设，覆盖所有可选字段。
func samplePreset() -> ExportPreset {
    ExportPreset(
        presetId: UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!,
        name: "Instagram Panorama — Gallery",
        platform: "instagram",
        canvas: CanvasSettings(
            width: 1080, height: 1440,
            background: PresetColor(hex: "#FAFAF8"),
            minMarginPx: 60, mode: .crop,
            crop: CropSettings(aspectRatio: Pair(4, 5), anchor: Pair(0.5, 0.25))),
        panorama: PanoramaSettings(
            enabled: true, cover: true, tileCount: .fixed(5),
            padColor: .color(PresetColor(hex: "#000000")), verticalMarginPx: 40),
        layers: [
            OverlayLayer(
                layerId: "badge", type: .cameraBadge, anchor: .bottomRight, reference: .photo(.outside),
                offset: OverlayOffset(x: 0, y: 16), sizePx: PixelSize(width: 48, height: 48),
                opacity: 0.8, zIndex: 2, slotId: "camera.badge"),
            OverlayLayer(
                layerId: "exif", type: .metadataText, visibility: .selectedSlides([0, 2]),
                anchor: .bottomLeft, reference: .canvas, maxBoundsPx: PixelSize(width: 600, height: 40),
                text: TextStyle(template: "{camera} · {focalLength}", fontFamily: "Helvetica Neue", fontSizePx: 18)),
        ],
        assetSlots: [AssetSlot(slotId: "camera.badge", required: false, label: "相机线稿", acceptedFormats: [.svg])],
        output: OutputSettings(format: .jpeg, quality: 95, dynamicRange: .hdr,
                               metadata: .init(keepShootingInfo: true, keepGps: false)))
}

func jsonData(_ s: String) -> Data { Data(s.utf8) }

@Suite("预设序列化")
struct PresetSerializationTests {
    @Test("完整预设往返不变")
    func roundTrip() throws {
        let preset = samplePreset()
        #expect(preset.validate().errors.isEmpty)
        let data = try PresetSchema.encode(preset)
        let decoded = try PresetSchema.decode(data)
        #expect(decoded.preset == preset)
        #expect(decoded.unknownFieldPaths.isEmpty)
        #expect(!decoded.wasMigrated)
        // 编码稳定：再编码一次字节相同。
        #expect(try PresetSchema.encode(decoded.preset) == data)
    }

    @Test("整数字段写成整数，不变成 100.0")
    func integersStayIntegers() throws {
        let text = String(decoding: try PresetSchema.encode(samplePreset()), as: UTF8.self)
        #expect(text.contains("\"quality\" : 95"))
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(text.contains("\"tileCount\" : 5"))
    }

    @Test("缺省字段使用默认值：fit、#FAFAF8、60 px、Q100、SDR、元数据不写出")
    func defaults() throws {
        let json = """
        {"schemaVersion": 1, "presetId": "7C9E6679-7425-40DE-944B-E07FC1F90AE7", "name": "最小",
         "canvas": {"width": 1080, "height": 1080}}
        """
        let p = try PresetSchema.decode(jsonData(json)).preset
        #expect(p.canvas.mode == .fit)
        #expect(p.canvas.background == .defaultBackground)
        #expect(p.canvas.minMarginPx == 60)
        #expect(p.panorama == .disabled)
        #expect(p.output == OutputSettings())
        #expect(p.output.quality == 100)
        #expect(p.output.metadata.keepGps == false && p.output.metadata.keepShootingInfo == false)
        #expect(p.validate().errors.isEmpty)
    }

    @Test("tileCount 接受 \"auto\" 和整数")
    func tileCount() throws {
        let d = JSONDecoder()
        #expect(try d.decode(PanoramaSettings.TileCount.self, from: jsonData("\"auto\"")) == .auto)
        #expect(try d.decode(PanoramaSettings.TileCount.self, from: jsonData("7")) == .fixed(7))
        #expect(throws: DecodingError.self) { try d.decode(PanoramaSettings.TileCount.self, from: jsonData("\"many\"")) }
    }

    /// 从规范 §8.1 中取出示例 JSON，保证规范里的示例始终能被导入（D-24）。
    static func specExampleJSON() throws -> Data {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let spec = try String(contentsOf: repo.appendingPathComponent("PhotoFrame_V1_Specification.md"), encoding: .utf8)
        let section = try #require(spec.range(of: "### 8.1 结构与文件格式"))
        let fence = try #require(spec.range(of: "```json\n", range: section.upperBound..<spec.endIndex))
        let end = try #require(spec.range(of: "\n```", range: fence.upperBound..<spec.endIndex))
        return Data(spec[fence.upperBound..<end.lowerBound].utf8)
    }

    @Test("规范 §8.1 示例能完整导入：没有不认识的字段、通过校验、往返不变")
    func specExample() throws {
        let decoded = try PresetSchema.decode(Self.specExampleJSON())
        #expect(decoded.unknownFieldPaths.isEmpty)
        let p = decoded.preset
        #expect(p.validate().isEmpty, "\(p.validate())")
        #expect(p.panorama.tileCount == .auto)
        #expect(p.platform == "instagram")
        #expect(p.assetSlots.map(\.slotId) == ["camera.badge"])
        let badge = try #require(p.layers.first { $0.type == .cameraBadge })
        #expect(badge.slotId == "camera.badge")
        #expect(badge.anchor == .bottomRight)
        #expect(badge.reference == .photo(.outside))
        #expect(badge.offset == OverlayOffset(x: 0, y: 16))
        #expect(badge.sizePx == PixelSize(width: 48, height: 48))
        #expect(try PresetSchema.decode(PresetSchema.encode(p)).preset == p)
    }
}

@Suite("扩展字段（D-15）")
struct ExtensionFieldTests {
    let json = """
    {
      "schemaVersion": 1, "presetId": "7C9E6679-7425-40DE-944B-E07FC1F90AE7", "name": "ext",
      "x-author": {"name": "J", "tags": ["landscape", 3, true, null, 1.5]},
      "canvas": {"width": 1080, "height": 1080, "x-guide": "rule-of-thirds",
                 "background": {"hex": "#FAFAF8", "x-note": "warm"}},
      "layers": [{"layerId": "sig", "type": "text", "text": {"content": "J", "x-kerning": 0.2}, "x-locked": true}],
      "output": {"metadata": {"x-copyright": "© J"}}
    }
    """

    @Test("各层的 x- 字段原样往返，不算作不认识的字段")
    func roundTrip() throws {
        let decoded = try PresetSchema.decode(jsonData(json))
        #expect(decoded.unknownFieldPaths.isEmpty)
        let p = decoded.preset
        #expect(p.extensions["x-author"]?["tags"] == .array([.string("landscape"), .number(3), .bool(true), .null, .number(1.5)]))
        #expect(p.canvas.extensions["x-guide"] == .string("rule-of-thirds"))
        #expect(p.canvas.background.extensions["x-note"] == .string("warm"))
        #expect(p.layers[0].extensions["x-locked"] == .bool(true))
        #expect(p.layers[0].text?.extensions["x-kerning"] == .number(0.2))
        #expect(p.output.metadata.extensions["x-copyright"] == .string("© J"))

        let again = try PresetSchema.decode(PresetSchema.encode(p))
        #expect(again.preset == p)
        let original = try PresetSchema.parseManifest(jsonData(json))
        let rewritten = try PresetSchema.parseManifest(PresetSchema.encode(p))
        #expect(rewritten["x-author"] == original["x-author"])
    }

    @Test("不认识的非 x- 字段被登记路径，并且保留不丢")
    func unknownFields() throws {
        let json = """
        {"schemaVersion": 1, "presetId": "7C9E6679-7425-40DE-944B-E07FC1F90AE7", "name": "u", "futureThing": 1,
         "canvas": {"width": 10, "height": 10, "minMarginPx": 0, "bleed": 3},
         "layers": [{"layerId": "a", "type": "text"}, {"layerId": "b", "type": "text", "blur": 2}]}
        """
        let decoded = try PresetSchema.decode(jsonData(json))
        #expect(decoded.unknownFieldPaths == ["canvas.bleed", "futureThing", "layers[1].blur"])
        #expect(decoded.preset.layers[1].extensions["blur"] == .number(2))
        let rewritten = try PresetSchema.parseManifest(PresetSchema.encode(decoded.preset))
        #expect(rewritten["futureThing"] == .number(1))
    }

    @Test("扩展字段不能覆盖同名的正式字段")
    func extensionCannotShadowKnownKey() throws {
        var p = samplePreset()
        p.extensions["name"] = .string("evil")
        let decoded = try PresetSchema.decode(PresetSchema.encode(p)).preset
        #expect(decoded.name == "Instagram Panorama — Gallery")
    }
}

@Suite("schema 版本与迁移")
struct PresetMigrationTests {
    func manifest(version: JSONValue?) -> Data {
        var o: [String: JSONValue] = ["presetId": .string("7C9E6679-7425-40DE-944B-E07FC1F90AE7"), "name": .string("v"),
                                      "canvas": .object(["width": .number(100), "height": .number(100), "minMarginPx": .number(0)])]
        if let version { o["schemaVersion"] = version }
        return try! JSONEncoder().encode(JSONValue.object(o))
    }

    @Test("较新的 schemaVersion 报 newerSchemaVersion 并提示升级")
    func newerVersion() {
        #expect(throws: PresetError.newerSchemaVersion(found: 2, supported: 1)) {
            try PresetSchema.decode(manifest(version: .number(2)))
        }
        #expect(PresetError.newerSchemaVersion(found: 2, supported: 1).hint != nil)
    }

    @Test("缺失或非法的 schemaVersion")
    func invalidVersion() {
        #expect(throws: PresetError.missingSchemaVersion) { try PresetSchema.decode(manifest(version: nil)) }
        #expect(throws: PresetError.self) { try PresetSchema.decode(manifest(version: .string("1"))) }
        #expect(throws: PresetError.self) { try PresetSchema.decode(manifest(version: .number(0))) }
        #expect(throws: PresetError.self) { try PresetSchema.decode(manifest(version: .number(1.5))) }
    }

    /// 一个虚构的 3 版迁移链：v1 的 `margin` 在 v2 改名为 `minMarginPx`，v3 新增 `x-migrated`。
    let migrator = PresetMigrator(targetVersion: 3, migrations: [
        PresetMigration(from: 2) { m in m["x-migrated"] = .bool(true) },
        PresetMigration(from: 1) { m in
            guard var canvas = m["canvas"]?.objectValue else { throw PresetError.migrationFailed(from: 1, reason: "缺少 canvas") }
            canvas["minMarginPx"] = canvas.removeValue(forKey: "margin")
            m["canvas"] = .object(canvas)
        },
    ])

    @Test("按版本顺序逐步迁移，并更新 schemaVersion")
    func stepwiseMigration() throws {
        let v1: [String: JSONValue] = ["schemaVersion": .number(1), "canvas": .object(["margin": .number(60)])]
        let (out, original) = try migrator.migrate(v1)
        #expect(original == 1)
        #expect(out["schemaVersion"] == .number(3))
        #expect(out["canvas"]?["minMarginPx"] == .number(60))
        #expect(out["canvas"]?["margin"] == nil)
        #expect(out["x-migrated"] == .bool(true))

        let (fromV2, _) = try migrator.migrate(["schemaVersion": .number(2), "canvas": .object([:])])
        #expect(fromV2["x-migrated"] == .bool(true))
        #expect(fromV2["canvas"] == .object([:]))
    }

    @Test("迁移失败、缺少迁移步骤、低于最低版本")
    func migrationFailures() {
        #expect(throws: PresetError.migrationFailed(from: 1, reason: "缺少 canvas")) {
            try migrator.migrate(["schemaVersion": .number(1)])
        }
        let gap = PresetMigrator(targetVersion: 3, migrations: [PresetMigration(from: 2) { _ in }])
        #expect(throws: PresetError.unsupportedSchemaVersion(found: 1)) {
            try gap.migrate(["schemaVersion": .number(1)])
        }
        let floor = PresetMigrator(targetVersion: 3, minimumVersion: 2, migrations: [])
        #expect(throws: PresetError.unsupportedSchemaVersion(found: 1)) {
            try floor.migrate(["schemaVersion": .number(1)])
        }
    }

    @Test("迁移后的 manifest 能解码为模型，并记录原始版本")
    func migrateThenDecode() throws {
        // 虚构 v1 → v2：`title` 改名为 `name`。
        let m = PresetMigrator(targetVersion: 2, migrations: [
            PresetMigration(from: 1) { m in m["name"] = m.removeValue(forKey: "title") },
        ])
        let legacy = """
        {"schemaVersion": 1, "presetId": "7C9E6679-7425-40DE-944B-E07FC1F90AE7", "title": "Old",
         "canvas": {"width": 1080, "height": 1080}}
        """
        let decoded = try PresetSchema.decode(jsonData(legacy), migrator: m)
        #expect(decoded.preset.name == "Old")
        #expect(decoded.preset.schemaVersion == 2)
        #expect(decoded.originalSchemaVersion == 1)
        #expect(decoded.wasMigrated)
        #expect(decoded.unknownFieldPaths.isEmpty)
    }
}

@Suite("非法预设")
struct InvalidPresetTests {
    @Test("JSON 语法错误、顶层不是对象")
    func malformed() {
        #expect(throws: PresetError.self) { try PresetSchema.decode(jsonData("{not json")) }
        #expect(throws: PresetError.notAnObject) { try PresetSchema.decode(jsonData("[1, 2]")) }
    }

    @Test("不认识的枚举值、错误类型、缺少必填字段都给出字段路径")
    func fieldErrors() throws {
        func error(_ json: String) -> PresetError? {
            do { _ = try PresetSchema.decode(jsonData(json)); return nil } catch { return error }
        }
        let head = #""schemaVersion": 1, "presetId": "7C9E6679-7425-40DE-944B-E07FC1F90AE7", "name": "n""#
        let canvas = #""canvas": {"width": 100, "height": 100, "minMarginPx": 0}"#

        guard case .invalidField(let p1, _)? = error("{\(head), \(canvas), \"layers\": [{\"layerId\": \"a\", \"type\": \"hologram\"}]}") else {
            Issue.record("应为 invalidField"); return
        }
        #expect(p1 == "layers[0].type")
        guard case .invalidField(let p2, _)? = error("{\(head), \"canvas\": {\"width\": \"wide\", \"height\": 1}}") else {
            Issue.record("应为 invalidField"); return
        }
        #expect(p2 == "canvas.width")
        guard case .invalidField(let p3, _)? = error("{\(head)}") else { Issue.record("应为 invalidField"); return }
        #expect(p3 == "canvas")
        guard case .invalidField(let p4, _)? = error(#"{"schemaVersion": 1, "presetId": "not-a-uuid", "name": "n", \#(canvas)}"#) else {
            Issue.record("应为 invalidField"); return
        }
        #expect(p4 == "presetId")
        guard case .invalidField(let p5, _)? = error("{\(head), \(canvas), \"layers\": [{\"layerId\": \"a\", \"type\": \"text\", \"offsetPx\": [1, 2, 3]}]}") else {
            Issue.record("应为 invalidField"); return
        }
        #expect(p5.hasPrefix("layers[0].offsetPx"))
    }

    @Test("内容校验：重复 ID、悬空引用、颜色、边距、质量、页面")
    func validation() {
        var p = samplePreset()
        p.layers.append(OverlayLayer(layerId: "badge", type: .asset, slotId: "missing"))
        p.layers.append(OverlayLayer(layerId: "logo", type: .asset))
        p.layers.append(OverlayLayer(layerId: "bad id!", type: .text, visibility: .selectedSlides([]), opacity: 2))
        p.layers.append(OverlayLayer(layerId: "mid", type: .text, anchor: .center, reference: .photo(.outside), text: TextStyle()))
        p.assetSlots.append(AssetSlot(slotId: "camera.badge"))
        p.canvas.background.hex = "FAFAF8"
        p.canvas.minMarginPx = 600
        p.output.quality = 0
        p.output.colorSpace = "ProPhoto"
        p.panorama.tileCount = .fixed(0)
        let codes = Set(p.validate().errors.map(\.code))
        #expect(codes == [
            "preset.duplicate_layer_id", "preset.unknown_slot_reference", "preset.missing_slot_reference",
            "preset.invalid_id", "preset.invalid_opacity", "preset.invalid_slides", "preset.duplicate_slot_id",
            "preset.invalid_color", "preset.margin_too_large", "preset.invalid_quality",
            "preset.unsupported_color_space", "preset.invalid_tile_count", "preset.center_anchor_outside",
        ])
    }

    @Test("没被使用的素材槽只是警告")
    func unusedSlotWarning() {
        var p = samplePreset()
        p.assetSlots.append(AssetSlot(slotId: "signature"))
        let issues = p.validate()
        #expect(issues.errors.isEmpty)
        #expect(issues.warnings.map(\.code) == ["preset.unused_slot"])
    }
}

@Suite("图层存储与几何共用一套类型（D-23）")
struct OverlayLayerModelTests {
    let head = #""schemaVersion": 1, "presetId": "7C9E6679-7425-40DE-944B-E07FC1F90AE7", "name": "n", "canvas": {"width": 1080, "height": 1440}"#

    func layer(_ body: String) throws -> OverlayLayer {
        try PresetSchema.decode(jsonData("{\(head), \"layers\": [{\"layerId\": \"l\", \"type\": \"text\", \(body)}]}")).preset.layers[0]
    }

    @Test("JSON 字段映射到共用类型；缺省为照片外侧右下、只在封面")
    func jsonMapping() throws {
        let d = try layer(#""text": {"content": "J"}"#)
        #expect(d.anchor == .bottomRight)
        #expect(d.reference == .photo(.outside))
        #expect(d.offset == .zero)
        #expect(d.visibility == .coverOnly)

        let l = try layer(#""anchor": "top", "reference": "photo", "side": "inside", "offsetPx": [3, -4], "visibleOn": "selectedSlides", "slides": [2, 0]"#)
        #expect(l.anchor == .top)
        #expect(l.reference == .photo(.inside))
        #expect(l.offset == OverlayOffset(x: 3, y: -4))
        #expect(l.visibility == .selectedSlides([0, 2]))

        #expect(try layer(#""reference": "canvas""#).reference == .canvas)
        let text = String(decoding: try JSONEncoder().encode(l), as: UTF8.self)
        #expect(text.contains(#""slides":[0,2]"#))
        #expect(text.contains(#""anchor":"top""#))
        #expect(text.contains(#""side":"inside""#))
    }

    @Test("没有 region 字段（D-41）；矛盾的写法报字段错误")
    func rejectsContradictions() throws {
        // region 已删除：现在是不认识的字段。
        let decoded = try PresetSchema.decode(jsonData("{\(head), \"layers\": [{\"layerId\": \"l\", \"type\": \"text\", \"region\": \"margin\"}]}"))
        #expect(decoded.unknownFieldPaths == ["layers[0].region"])
        for body in [#""visibleOn": "coverOnly", "slides": [1]"#, #""reference": "canvas", "side": "outside""#,
                     #""anchor": "middle""#, #""side": "diagonal""#] {
            #expect(throws: PresetError.self, "\(body)") { try layer(body) }
        }
    }

    @Test("锚点名称与 OverlayAnchor 一一对应")
    func anchorNames() throws {
        let names = OverlayAnchor.allCases.map(\.name)
        #expect(names == ["topLeft", "top", "topRight", "left", "center", "right", "bottomLeft", "bottom", "bottomRight"])
        for a in OverlayAnchor.allCases {
            #expect(OverlayAnchor(name: a.name) == a)
            #expect(try JSONDecoder().decode(OverlayAnchor.self, from: JSONEncoder().encode(a)) == a)
        }
    }

    @Test("转换为 OverlayGeometry 后定位：照片右下角下方 16 px（D-12）")
    func convertAndPlace() throws {
        let fit = try FitLayout(canvas: PixelSize(width: 1080, height: 1440), minimumMargin: 60, source: PixelSize(width: 6000, height: 4000))
        let badge = samplePreset().layers[0]
        let g = try badge.geometry()
        #expect(g == OverlayGeometry(anchor: .bottomRight, reference: .photo(.outside), offset: OverlayOffset(x: 0, y: 16),
                                     size: .fixed(PixelSize(width: 48, height: 48)), visibility: .coverOnly))
        let placement = try OverlayPlacement(fit: fit, geometry: g)
        // 照片 (60, 400, 960×640)：右边对齐 1020，底边 1040 再往下 16。
        #expect(placement.rect == PixelRect(x: 972, y: 1056, width: 48, height: 48))
        #expect(placement.warnings.isEmpty)
    }

    @Test("没有 sizePx 时用内容尺寸，maxBoundsPx 限制最大尺寸；都没有时报 missingSize")
    func sizeResolution() throws {
        var l = OverlayLayer(layerId: "t", type: .text, maxBoundsPx: PixelSize(width: 600, height: 40))
        #expect(try l.geometry(contentSize: PixelSize(width: 1200, height: 40)).size
                == .fitting(PixelSize(width: 1200, height: 40), maximum: PixelSize(width: 600, height: 40)))
        #expect(throws: OverlayError.missingSize) { try l.geometry() }
        l.maxBoundsPx = nil
        #expect(try l.geometry(contentSize: PixelSize(width: 10, height: 5)).size == .fixed(PixelSize(width: 10, height: 5)))
    }

    @Test("全景页面：转换后的图层按轮播页码显示（D-27、D-43、D-44）")
    func panoramaPages() throws {
        let pano = try PanoramaLayout(tile: PixelSize(width: 1080, height: 1440),
                                      source: SourceImage(storedSize: PixelSize(width: 6500, height: 2400)))
        let l = OverlayLayer(layerId: "t", type: .text, visibility: .selectedSlides([0, 4, 9]), anchor: .bottomRight,
                             reference: .photo(.inside), sizePx: PixelSize(width: 20, height: 20))
        let plan = try pano.overlayPlan(for: l.geometry())
        #expect(plan.pages.map(\.page) == [0, 4])
        #expect(plan.missingPages == [9])
    }

    @Test("颜色只接受 #RRGGBB（D-35）；输出格式没有 heic（D-36）")
    func colorAndFormat() throws {
        #expect(PresetColor(hex: "#FAFAF8").isValidHex)
        #expect(!PresetColor(hex: "#FAFAF8FF").isValidHex)
        #expect(!PresetColor(hex: "#FFF").isValidHex)
        #expect(OutputSettings.Format.allCases == [.jpeg, .png])
        #expect(throws: PresetError.self) {
            try PresetSchema.decode(jsonData("{\(head), \"output\": {\"format\": \"heic\"}}"))
        }
    }
}
