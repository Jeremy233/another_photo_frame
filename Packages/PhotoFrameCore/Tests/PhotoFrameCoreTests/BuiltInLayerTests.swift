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
}
