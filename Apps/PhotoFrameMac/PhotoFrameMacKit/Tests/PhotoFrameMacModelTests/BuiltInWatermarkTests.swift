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
}
