import Foundation
import Testing
@testable import PhotoFrameCore

/// D-132–D-134、D-137：品牌 logo、胶卷装饰和文字的「自动」颜色。
@Suite("内置品牌 logo 与胶卷装饰（D-132–D-137）")
struct BuiltInLayerTests {
    static func preset(_ layers: [OverlayLayer]) -> ExportPreset {
        var p = ExportPreset(name: "B", canvas: CanvasSettings(width: 1080, height: 1440, background: .defaultBackground, minMarginPx: 60, mode: .fit))
        p.layers = layers
        return p
    }

    @Test("新字段往返不变；缺少 logo / filmIcon 时用默认值；colorMode 只在 auto 时写出")
    func roundTrip() throws {
        let json = """
        {"schemaVersion": 1, "presetId": "7C9E6679-7425-40DE-944B-E07FC1F90AE7", "name": "Built-in",
         "canvas": {"width": 1080, "height": 1440},
         "layers": [
           {"layerId": "logo", "type": "brandLogo"},
           {"layerId": "film", "type": "filmIcon", "filmIcon": {"film": "kodak-portra-400", "show": "icon"}},
           {"layerId": "brand", "type": "metadataText", "text": {"template": "{brand}", "colorMode": "auto"}}
         ]}
        """
        let decoded = try PresetSchema.decode(Data(json.utf8))
        #expect(decoded.unknownFieldPaths.isEmpty)
        let p = decoded.preset
        #expect(p.layers[0].type == .brandLogo && p.layers[0].logo == nil)
        #expect(p.layers[1].filmIcon == FilmIconStyle(film: "kodak-portra-400", show: .icon))
        #expect(p.layers[2].text?.colorMode == .auto)
        #expect(p.validate().errors.isEmpty, "\(p.validate())")

        var q = p
        q.layers[0].logo = BrandLogoStyle(brand: "leica", fallback: .text, variant: .emblem, heightPx: 40,
                                          colorMode: .custom, color: PresetColor(hex: "#8A6D3B"))
        q.layers[2].text?.colorMode = .custom
        let encoded = try PresetSchema.encode(q)
        let again = try PresetSchema.decode(encoded)
        #expect(again.preset == q && again.unknownFieldPaths.isEmpty)
        let textJSON = try JSONEncoder().encode(try #require(q.layers[2].text))
        #expect(!String(decoding: textJSON, as: UTF8.self).contains("colorMode"), "文字的 custom 是默认值，不写出")
    }

    @Test("旧预设的文字图层没有 colorMode：按 custom 处理，编码结果不变")
    func oldTextUnchanged() throws {
        let style = TextStyle(template: "{camera}")
        #expect(style.colorMode == .custom)
        let data = try JSONEncoder().encode(style)
        #expect(!String(decoding: data, as: UTF8.self).contains("colorMode"))
    }

    @Test("校验：品牌和胶卷不能为空、尺寸为正、custom 颜色要写 color；别的装饰上的 logo / filmIcon 只警告")
    func validation() {
        let issues = Self.preset([
            OverlayLayer(layerId: "a", type: .brandLogo, logo: BrandLogoStyle(brand: " ", heightPx: 0, colorMode: .custom)),
            OverlayLayer(layerId: "b", type: .filmIcon, filmIcon: FilmIconStyle(film: "", iconSizePx: -1)),
            OverlayLayer(layerId: "c", type: .metadataText, text: TextStyle(template: "{brand}"),
                         logo: BrandLogoStyle(), filmIcon: FilmIconStyle()),
            OverlayLayer(layerId: "d", type: .filmIcon, text: TextStyle(fontSizePx: 0)),
        ]).validate()
        #expect(Set(issues.errors.map(\.path)) == [
            "layers[0].logo.brand", "layers[0].logo.heightPx", "layers[0].logo.color",
            "layers[1].filmIcon.film", "layers[1].filmIcon.iconSizePx", "layers[3].text.fontSizePx",
        ], "\(issues)")
        #expect(Set(issues.warnings.map(\.path)) == ["layers[2].logo", "layers[2].filmIcon"], "\(issues)")
        #expect(!issues.contains { $0.code == "preset.empty_text" }, "胶卷装饰没有 text 时用默认样式，不警告")
    }

    @Test("品牌 logo、胶卷选了素材槽（slot）时用 slotId；改回自动时留着的槽不报警告（D-139）")
    func slotSource() {
        var p = Self.preset([
            OverlayLayer(layerId: "logo", type: .brandLogo, slotId: "logo", logo: BrandLogoStyle(brand: BrandLogoStyle.fromSlot)),
            OverlayLayer(layerId: "film", type: .filmIcon, slotId: "film", filmIcon: FilmIconStyle(film: FilmIconStyle.fromSlot)),
        ])
        p.assetSlots = [AssetSlot(slotId: "logo", label: "品牌 logo"), AssetSlot(slotId: "film", label: "胶卷图标")]
        #expect(p.layers.allSatisfy(\.usesAssetSlot) && p.referencedSlotIds == ["logo", "film"])
        #expect(p.validate().errors.isEmpty && p.validate().warnings.isEmpty, "\(p.validate())")

        // 改回自动：槽留着，不用，也不警告。
        p.layers[0].logo?.brand = BrandLogoStyle.automatic
        p.layers[1].filmIcon?.film = "kodak-portra-400"
        #expect(!p.layers.contains(where: \.usesAssetSlot) && p.referencedSlotIds.isEmpty)
        #expect(p.validate().errors.isEmpty && p.validate().warnings.isEmpty, "\(p.validate())")

        // 选了素材槽却没有 slotId、或者槽不存在。
        p.layers[0].logo?.brand = BrandLogoStyle.fromSlot
        p.layers[0].slotId = nil
        p.layers[1].filmIcon?.film = FilmIconStyle.fromSlot
        p.layers[1].slotId = "missing"
        let issues = p.validate()
        #expect(issues.errors.map(\.code) == ["preset.missing_slot_reference", "preset.unknown_slot_reference"], "\(issues)")
    }
}
