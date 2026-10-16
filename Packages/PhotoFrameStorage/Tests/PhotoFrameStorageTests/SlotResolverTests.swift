import Foundation
import Testing
import PhotoFrameCore
@testable import PhotoFrameStorage

private let jobAsset = AssetRecord(assetId: UUID(), format: .svg, displayName: "job")
private let presetAsset = AssetRecord(assetId: UUID(), format: .svg, displayName: "preset")
private let globalAsset = AssetRecord(assetId: UUID(), format: .png, displayName: "global")
private let library = InMemoryAssetLibrary([jobAsset, presetAsset, globalAsset])

private func preset(required: Bool = false, formats: [AssetSlot.Format] = AssetSlot.Format.allCases) -> ExportPreset {
    ExportPreset(
        presetId: UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!,
        name: "p",
        canvas: CanvasSettings(width: 1080, height: 1080),
        layers: [
            OverlayLayer(layerId: "badge", type: .cameraBadge, slotId: "camera.badge"),
            OverlayLayer(layerId: "badge2", type: .asset, visibleOn: .allSlides, slotId: "camera.badge"),
            OverlayLayer(layerId: "off", type: .asset, enabled: false, slotId: "signature"),
        ],
        assetSlots: [
            AssetSlot(slotId: "camera.badge", required: required, acceptedFormats: formats),
            AssetSlot(slotId: "signature", required: true),
        ])
}

@Suite("素材绑定（D-14）")
struct SlotResolverTests {
    let p = preset()
    var allThree: AssetBindingTable {
        var t = AssetBindingTable()
        t.bindForPreset(p.presetId, slotId: "camera.badge", assetId: presetAsset.assetId)
        t.bindGlobally(slotId: "camera.badge", assetId: globalAsset.assetId)
        return t
    }

    @Test("单任务 > 预设本地 > 用户全局")
    func priority() throws {
        let resolver = SlotResolver(library: library, bindings: allThree)
        let r1 = try resolver.resolve(p, jobBindings: ["camera.badge": jobAsset.assetId])
        #expect(r1.resolved["camera.badge"]?.scope == .job)
        #expect(r1.resolved["camera.badge"]?.asset == jobAsset)

        let r2 = try resolver.resolve(p)
        #expect(r2.resolved["camera.badge"]?.scope == .presetLocal)
        #expect(r2.resolved["camera.badge"]?.asset == presetAsset)

        var onlyGlobal = allThree
        onlyGlobal.presetLocal = [:]
        let r3 = try SlotResolver(library: library, bindings: onlyGlobal).resolve(p)
        #expect(r3.resolved["camera.badge"]?.scope == .userGlobal)
        #expect(r3.warnings.isEmpty)
        #expect(BindingScope.allCases.sorted() == [.job, .presetLocal, .userGlobal])
    }

    @Test("预设本地绑定只对对应的 presetId 生效")
    func presetScopedToId() throws {
        var t = AssetBindingTable()
        t.bindForPreset(UUID(), slotId: "camera.badge", assetId: presetAsset.assetId)
        let r = try SlotResolver(library: library, bindings: t).resolve(p)
        #expect(r.resolved.isEmpty)
    }

    @Test("缺少可选素材：警告并跳过使用它的图层")
    func optionalMissing() throws {
        let r = try SlotResolver(library: library, bindings: AssetBindingTable()).resolve(p)
        #expect(r.resolved.isEmpty)
        #expect(r.skippedLayerIds == ["badge", "badge2"])
        #expect(r.warnings == [.optionalSlotMissing(slotId: "camera.badge", layerIds: ["badge", "badge2"])])
        #expect(r.warnings.map(\.code) == ["slot.optional_missing"])
    }

    @Test("缺少必需素材：返回错误；未启用图层的必需 slot 不影响输出")
    func requiredMissing() {
        // "signature" 是必需的，但引用它的图层被关闭，所以不报错。
        #expect(throws: SlotResolutionError(missingRequiredSlots: ["camera.badge"], warnings: [])) {
            try SlotResolver(library: library, bindings: AssetBindingTable()).resolve(preset(required: true))
        }
        #expect(SlotResolutionError(missingRequiredSlots: ["camera.badge"], warnings: []).code == "slot.missing_required")
    }

    @Test("高优先级绑定失效（素材已删除）时回退到下一层并警告")
    func staleFallsThrough() throws {
        let deleted = UUID()
        let r = try SlotResolver(library: library, bindings: allThree).resolve(p, jobBindings: ["camera.badge": deleted])
        #expect(r.resolved["camera.badge"]?.scope == .presetLocal)
        #expect(r.warnings == [.staleBinding(slotId: "camera.badge", scope: .job, assetId: deleted)])
    }

    @Test("格式不被 slot 接受时回退到下一层；全部不符则按缺失处理")
    func incompatibleFormat() throws {
        let pngOnly = preset(required: true, formats: [.png])
        let r = try SlotResolver(library: library, bindings: allThree).resolve(pngOnly, jobBindings: ["camera.badge": jobAsset.assetId])
        #expect(r.resolved["camera.badge"]?.scope == .userGlobal)
        #expect(r.warnings.map(\.code) == ["slot.incompatible_format", "slot.incompatible_format"])

        var noGlobal = allThree
        noGlobal.userGlobal = [:]
        do {
            _ = try SlotResolver(library: library, bindings: noGlobal).resolve(pngOnly)
            Issue.record("应缺少必需素材")
        } catch {
            #expect(error.missingRequiredSlots == ["camera.badge"])
            #expect(error.warnings.map(\.code) == ["slot.incompatible_format"])
        }
    }

    @Test("单任务绑定了未使用的 slot：提示")
    func unusedJobBinding() throws {
        let r = try SlotResolver(library: library, bindings: allThree).resolve(p, jobBindings: ["nope": jobAsset.assetId])
        #expect(r.warnings == [.unusedJobBinding(slotId: "nope")])
    }

    @Test("绑定表可序列化，presetLocal 以 UUID 字符串为键")
    func bindingTableCodable() throws {
        let data = try JSONEncoder().encode(allThree)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(json["presetLocal"]?[p.presetId.uuidString]?["camera.badge"] == .string(presetAsset.assetId.uuidString))
        #expect(try JSONDecoder().decode(AssetBindingTable.self, from: data) == allThree)
    }
}

@Suite("平台配置与内置预设")
struct PlatformTests {
    @Test("内置平台配置：三个平台、画布尺寸、HDR 状态")
    func catalog() throws {
        let c = try PlatformCatalogStore.builtIn()
        #expect(c.platforms.map(\.platformId) == ["instagram", "xiaohongshu", "douyin"])
        #expect(c.profile(id: "instagram")?.standardCanvas == PixelSize(width: 1080, height: 1440))
        #expect(c.profile(id: "xiaohongshu")?.standardCanvas == PixelSize(width: 1080, height: 1080))
        #expect(c.profile(id: "douyin")?.standardCanvas == PixelSize(width: 1080, height: 1920))
        #expect(c.profile(id: "instagram")?.hdr.status == .supported)
        #expect(c.profile(id: "instagram")?.hdr.formats == [.jpegGainMap])
        #expect(c.profile(id: "xiaohongshu")?.hdr.status == .pendingVerification)
        #expect(c.profile(id: "douyin")?.hdr.status == .pendingVerification)
        for p in c.platforms {
            #expect(p.outputFormats.contains(.jpeg))
            #expect(p.maxCarouselItems > 1)
        }
    }

    @Test("覆盖文件：revision 更大才生效，无效时回退到内置")
    func override() throws {
        let bundled = try PlatformCatalogStore.builtIn()
        var newer = bundled
        newer.revision = bundled.revision + 1
        newer.platforms[0].maxCarouselItems = 10
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try JSONEncoder().encode(newer).write(to: url)
        #expect(try PlatformCatalogStore.load(overrideAt: url).profile(id: "instagram")?.maxCarouselItems == 10)

        var older = newer
        older.revision = bundled.revision
        try JSONEncoder().encode(older).write(to: url)
        #expect(try PlatformCatalogStore.load(overrideAt: url) == bundled)

        try Data("garbage".utf8).write(to: url)
        #expect(try PlatformCatalogStore.load(overrideAt: url) == bundled)
        #expect(try PlatformCatalogStore.load(overrideAt: nil) == bundled)
    }

    @Test("拒绝重复 platformId 或无效取值")
    func invalidCatalog() throws {
        var c = try PlatformCatalogStore.builtIn()
        c.platforms.append(c.platforms[0])
        #expect(throws: PlatformCatalogError.self) { try PlatformCatalogStore.decode(JSONEncoder().encode(c)) }
        var d = try PlatformCatalogStore.builtIn()
        d.platforms[0].maxCarouselItems = 0
        #expect(throws: PlatformCatalogError.self) { try PlatformCatalogStore.decode(JSONEncoder().encode(d)) }
    }

    @Test("平台检查：不支持的格式报错，HDR 待实测报警告")
    func platformCheck() throws {
        let c = try PlatformCatalogStore.builtIn()
        var p = makePreset()
        p.output.format = .heic
        p.output.dynamicRange = .hdr
        let issues = c.profile(id: "xiaohongshu")!.check(p)
        #expect(issues.map(\.code) == ["platform.unsupported_format", "platform.hdr_unverified"])
        #expect(issues.map(\.severity) == [.error, .warning])
        p.output.format = .jpeg
        #expect(c.profile(id: "instagram")!.check(p).isEmpty)
    }

    @Test("6 个内置预设：名称、尺寸、#FAFAF8、60 px、Q100 SDR、ID 固定且唯一、通过校验")
    func builtIns() throws {
        let c = try PlatformCatalogStore.builtIn()
        let all = BuiltInPresets.all(catalog: c)
        #expect(all.map(\.name) == [
            "Instagram Standard", "Instagram Panorama", "XHS Standard", "XHS Panorama", "Douyin Standard", "Douyin Panorama",
        ])
        #expect(Set(all.map(\.presetId)).count == 6)
        #expect(all.map(\.presetId) == BuiltInPresets.all(catalog: c).map(\.presetId))
        for p in all {
            #expect(p.canvas.background.hex == "#FAFAF8")
            #expect(p.canvas.minMarginPx == 60)
            #expect(p.canvas.mode == .fit)
            #expect(p.output == OutputSettings())
            #expect(p.validate().isEmpty, "\(p.name): \(p.validate())")
            let profile = try #require(c.profile(id: p.platform!))
            #expect(p.canvas.size == (p.panorama.enabled ? profile.panoramaTile : profile.standardCanvas))
            #expect(p.panorama.enabled == p.name.hasSuffix("Panorama"))
            #expect(profile.check(p).isEmpty)
            #expect(BuiltInPresets.isBuiltIn(p.presetId))
        }
    }

    @Test("内置全景预设配合几何计算：65:24 → IG 4 张切片，在轮播上限内")
    func builtInWithGeometry() throws {
        let c = try PlatformCatalogStore.builtIn()
        let ig = BuiltInPresets.all(catalog: c).first { $0.name == "Instagram Panorama" }!
        let layout = try PanoramaLayout(
            tile: ig.canvas.size,
            source: SourceImage(storedSize: PixelSize(width: 6500, height: 2400)),
            coverMinimumMargin: ig.canvas.minMarginPx,
            verticalMargin: ig.panorama.verticalMarginPx,
            maxCarouselItems: c.profile(id: "instagram")!.maxCarouselItems)
        #expect(layout.slideCount == 4)
        #expect(layout.warnings.isEmpty)
    }
}
