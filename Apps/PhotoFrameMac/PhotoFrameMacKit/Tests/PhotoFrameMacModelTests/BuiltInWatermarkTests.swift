import Foundation
import PhotoFrameApplication
import PhotoFrameCore
@testable import PhotoFrameMacModel
import Testing

/// D-133–D-136：内置装饰的添加菜单、源图上手填的胶卷与参数。
@MainActor @Suite struct BuiltInWatermarkTests {
    @Test("「添加装饰」的内置项：品牌 logo、三种品牌文字、三种胶卷；相机图标不在菜单里")
    func templates() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let job = try await f.addJob()
        let wb = f.workbench
        wb.selection = [.job(job)]
        #expect(!LayerTemplate.assetAndTextItems.contains(.cameraBadge))
        for template in [LayerTemplate.brandLogo, .brandText, .shotOn, .cameraSettings, .film, .filmIcon, .filmText] {
            wb.addLayer(template)
        }
        let preset = try #require(wb.job(job)?.preset)
        let layers = preset.layers.suffix(7)
        #expect(layers.map(\.type) == [.brandLogo, .metadataText, .metadataText, .metadataText, .filmIcon, .filmIcon, .filmIcon])
        #expect(layers.map { $0.text?.template } == [nil, "{brand}", "Shot on {camera}",
                                                   "{camera} · {focalLength} · {aperture} · {shutter} · {iso}", "{film}", "{film}", "{film}"])
        #expect(layers.dropFirst().allSatisfy { $0.text?.colorMode == .auto })
        #expect(layers.map { $0.filmIcon?.show } == [nil, nil, nil, nil, .iconAndText, .icon, .text])
        #expect(preset.validate().errors.isEmpty, "\(preset.validate())")
        // 界面上的名字：品牌文字、品牌文字 2、胶卷 3…
        #expect(preset.title(ofLayer: "brandLogo") == "品牌 logo")
        #expect(preset.title(ofLayer: "shotOn") == "品牌文字 2" && preset.title(ofLayer: "filmText") == "胶卷 3")
    }

    @Test("左栏「素材」选中的素材：没有选中图片时中间预览显示它")
    func assetPreview() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let wb = f.workbench
        let item = try #require(BuiltInAssetItem.groups.last?.items.first)
        wb.selectedAsset = .builtIn(item.path)
        #expect(wb.previewedAsset == nil, "左栏不在「素材」时不显示")
        wb.sidebarTab = .assets
        #expect(wb.previewedAsset?.title == item.title && wb.previewedAsset?.image == .builtIn(item.path))
        let job = try await f.addJob()
        wb.selection = [.job(job)]
        #expect(wb.previewedAsset == nil, "选中了图片时预览图片")
        wb.selection = []
        #expect(wb.previewedAsset?.title == item.title)
        wb.selectedAsset = .builtIn("missing.svg")
        #expect(wb.previewedAsset == nil)
    }

    @Test("手填的胶卷与参数：几张源图一起写、可以撤销；写进导出请求和预览")
    func manualMetadata() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let a = try await f.addJob("A.jpg")
        let b = try await f.addJob("B.jpg")
        let wb = f.workbench
        let undo = UndoManager()
        undo.groupsByEvent = false
        wb.undoManager = undo
        let sa = try #require(wb.job(a)?.sourceId), sb = try #require(wb.job(b)?.sourceId)

        wb.selection = [.source(sa), .source(sb)]
        #expect(wb.inspectorSubject == .sources([sa, sb]) && wb.inspectedSourceIds == [sa, sb])
        wb.setMetadataOverride(.film, " Kodak Gold 200 ", for: wb.inspectedSourceIds)
        wb.setMetadataOverride(.iso, "200", for: [sa])
        #expect(wb.metadataOverride(.film, for: [sa, sb]) == .single("Kodak Gold 200"))
        #expect(wb.metadataOverride(.iso, for: [sa, sb]) == .mixed)
        #expect(wb.request(for: try #require(wb.job(a))).metadataOverrides == ["film": "Kodak Gold 200", "iso": "200"])

        wb.selection = [.job(a)]
        #expect(wb.previewSubject?.metadataOverrides == ["film": "Kodak Gold 200", "iso": "200"])
        #expect(wb.previewFilm == "Kodak Gold 200")

        undo.undo()
        #expect(wb.sourceItem(sa)?.metadataOverrides == ["film": "Kodak Gold 200"])
        wb.setMetadataOverride(.film, "  ", for: [sa, sb])
        #expect(wb.sourceItem(sa)?.metadataOverrides.isEmpty == true && wb.sourceItem(sb)?.metadataOverrides.isEmpty == true,
                "空白表示不填")
    }

    @Test("内置的和自己的素材在同一个菜单里：同名加「（内置）」「（用户）」，不同名照原样（D-139）")
    func menuTitles() async throws {
        let labeled = MenuTitles.label(builtIn: [("nikon", "Nikon"), ("leica", "Leica")],
                                       user: [(1, " nikon "), (2, "My Leica")])
        #expect(labeled.builtIn.map(\.title) == ["Nikon（内置）", "Leica"])
        #expect(labeled.user.map(\.title) == [" nikon （用户）", "My Leica"])

        let f = try Fixture()
        await f.workbench.load()
        let wb = f.workbench
        await wb.importAssets([try f.assetPNG("Nikon.png")], category: .cameraBadge)
        await wb.importAssets([try f.assetPNG("Kodak Portra 400.png")], category: .filmIcon)
        let brands = wb.brandLogoChoices
        #expect(brands.current.contains { $0.id == "nikon" && $0.title == "Nikon（内置）" })
        #expect(brands.user.map(\.title) == ["Nikon（用户）"] && brands.classic.count == 13)
        let films = wb.filmChoices
        #expect(films.user.map(\.title) == ["Kodak Portra 400（用户）"])
        #expect(films.makers.flatMap(\.films).contains { $0.title == "Kodak Portra 400（内置）" })
        let slots = wb.slotChoices
        #expect(slots.builtIn.map(\.title) == ["内置 · 品牌 logo", "内置 · 经典品牌 logo", "内置 · 胶卷图标"])
        #expect(slots.builtIn.map(\.items.count) == [18, 13, 29])
        // 素材槽菜单里内置的 Nikon 叫「Nikon 字标」「Nikon 标志」，不和「Nikon」重名。
        #expect(Set(slots.user.map(\.title)) == ["Nikon", "Kodak Portra 400（用户）"])
        let portra = try #require(BuiltInAssetItem.groups[2].items.first { $0.title == "Kodak Portra 400" })
        #expect(wb.assetMenuTitle(portra.assetId) == "Kodak Portra 400（内置）")
    }

    @Test("胶卷装饰没有 text（CLI、MCP 写的预设）：右栏显示、第一次修改都按渲染用的默认文字样式，不变成 14 px 深灰")
    func filmTextDefaults() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let job = try await f.addJob()
        let wb = f.workbench
        wb.selection = [.job(job)]
        wb.addLayer(.film)
        #expect(wb.job(job)?.preset.layers.first { $0.layerId == "film" }?.text == FilmIconStyle.defaultTextStyle)
        wb.updateLayer("film") { $0.text = nil }
        var layer = try #require(wb.job(job)?.preset.layers.first { $0.layerId == "film" })
        #expect(layer.displayedTextStyle == FilmIconStyle.defaultTextStyle)

        wb.updateTextStyle("film") { $0.template = "{film} · 120" }
        layer = try #require(wb.job(job)?.preset.layers.first { $0.layerId == "film" })
        var expected = FilmIconStyle.defaultTextStyle
        expected.template = "{film} · 120"
        #expect(layer.text == expected)
        // 别的文字装饰照旧。
        #expect(OverlayLayer(layerId: "t", type: .metadataText).displayedTextStyle == TextStyle())
    }

    @Test("品牌 logo 颜色改成「自定」：写入界面上显示的默认色，预设仍然有效（D-137：custom 必须有 color）")
    func customLogoColor() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let job = try await f.addJob()
        let wb = f.workbench
        wb.selection = [.job(job)]
        wb.addLayer(.brandLogo)
        wb.setBrandLogoColorMode(.custom, forLayer: "brandLogo")
        var preset = try #require(wb.job(job)?.preset)
        var logo = try #require(preset.layers.first { $0.layerId == "brandLogo" }?.logo)
        #expect(logo.colorMode == .custom && logo.color == BrandLogoStyle.defaultCustomColor)
        #expect(preset.validate().errors.isEmpty, "\(preset.validate())")

        // 已经选过的颜色不变；改回原色时颜色留着。
        wb.updateLayer("brandLogo") { $0.logo?.color = PresetColor(hex: "#0000FF") }
        wb.setBrandLogoColorMode(.original, forLayer: "brandLogo")
        wb.setBrandLogoColorMode(.custom, forLayer: "brandLogo")
        preset = try #require(wb.job(job)?.preset)
        logo = try #require(preset.layers.first { $0.layerId == "brandLogo" }?.logo)
        #expect(logo.colorMode == .custom && logo.color == PresetColor(hex: "#0000FF"))
    }

    @Test("品牌 logo、胶卷选自己的素材：加素材槽、来源改成素材槽、按单任务绑定；改回自动时槽留着（D-139）")
    func useOwnAsset() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let job = try await f.addJob()
        let wb = f.workbench
        wb.selection = [.job(job)]
        wb.addLayer(.brandLogo)
        wb.addLayer(.filmIcon)
        await wb.importAssets([try f.assetPNG("Nikon.png")], category: .cameraBadge)
        let mine = try #require(wb.assets(in: .cameraBadge).first)

        await wb.useAsset(mine.assetId, forLayer: "brandLogo")
        var preset = try #require(wb.job(job)?.preset)
        var logo = try #require(preset.layers.first { $0.layerId == "brandLogo" })
        #expect(logo.logo?.brand == BrandLogoStyle.fromSlot && logo.slotId == "brandLogo")
        #expect(preset.assetSlots.contains { $0.slotId == "brandLogo" && $0.label == "品牌 logo" })
        #expect(wb.job(job)?.assetBindings["brandLogo"] == mine.assetId && wb.layerAsset(logo) == mine.assetId)

        // 胶卷选内置素材也走素材槽（素材槽菜单里的内置图标）。
        let portra = try #require(BuiltInAssetItem.groups[2].items.first { $0.title == "Kodak Portra 400" })
        await wb.useAsset(portra.assetId, forLayer: "filmIcon")
        preset = try #require(wb.job(job)?.preset)
        #expect(preset.layers.first { $0.layerId == "filmIcon" }?.filmIcon?.film == FilmIconStyle.fromSlot)
        #expect(wb.job(job)?.assetBindings["filmIcon"] == portra.assetId)
        #expect(preset.validate().errors.isEmpty, "\(preset.validate())")

        // 改回自动：槽和绑定留着，不再使用。
        wb.updateLayer("brandLogo") { $0.logo?.brand = BrandLogoStyle.automatic }
        preset = try #require(wb.job(job)?.preset)
        logo = try #require(preset.layers.first { $0.layerId == "brandLogo" })
        #expect(!logo.usesAssetSlot && logo.slotId == "brandLogo" && wb.layerAsset(logo) == nil)
        #expect(preset.validate().warnings.isEmpty, "\(preset.validate())")
        // 留着的单任务绑定也不在任务上警告「没有被预设使用」。
        await wb.settle()
        #expect(wb.job(job)?.assetBindings["brandLogo"] == mine.assetId)
        #expect(wb.job(job)?.validation?.warnings.contains { $0.code == "slot.unused_job_binding" } == false,
                "\(wb.job(job)?.validation?.warnings ?? [])")
    }
}

