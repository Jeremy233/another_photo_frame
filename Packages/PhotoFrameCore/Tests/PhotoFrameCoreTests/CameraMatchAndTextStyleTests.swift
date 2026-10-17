import Foundation
import Testing
@testable import PhotoFrameCore

/// D-111：相机图标按 EXIF 自动匹配、EXIF 文字字体样式。
@Suite("相机匹配与文字样式（D-111）")
struct CameraMatchAndTextStyleTests {
    static let nikon = CameraIdentity(make: "NIKON CORPORATION", model: "NIKON Z 8")
    static let canon = CameraIdentity(make: "Canon", model: "Canon EOS R5")

    @Test("品牌按包含、型号按相等匹配；不区分大小写，型号可省略开头的品牌")
    func matching() {
        #expect(CameraMatchRule(make: "Nikon", slotId: "s").matches(Self.nikon))
        #expect(CameraMatchRule(make: "  nikon  corporation ", slotId: "s").matches(Self.nikon))
        #expect(!CameraMatchRule(make: "Canon", slotId: "s").matches(Self.nikon))
        #expect(CameraMatchRule(model: "Z 8", slotId: "s").matches(Self.nikon))
        #expect(CameraMatchRule(model: "nikon z 8", slotId: "s").matches(Self.nikon))
        #expect(!CameraMatchRule(model: "Z 8II", slotId: "s").matches(Self.nikon))
        #expect(!CameraMatchRule(model: "Z", slotId: "s").matches(Self.nikon), "型号不是包含匹配")
        #expect(CameraMatchRule(make: "Canon", model: "EOS R5", slotId: "s").matches(Self.canon))
        #expect(!CameraMatchRule(make: "Nikon", model: "EOS R5", slotId: "s").matches(Self.canon), "两个条件都要满足")
        #expect(!CameraMatchRule(slotId: "s").matches(Self.canon), "空规则不匹配")
        #expect(!CameraMatchRule(make: "Canon", slotId: "s").matches(CameraIdentity(make: nil, model: "EOS R5")))
    }

    @Test("候选顺序：写了型号的规则在前，只写品牌的在后，最后是图层自己的 slotId；没有相机信息时只有 slotId")
    func candidates() {
        let layer = OverlayLayer(layerId: "badge", type: .cameraBadge, slotId: "camera.default", cameraMatch: [
            CameraMatchRule(make: "Nikon", slotId: "camera.nikon"),
            CameraMatchRule(make: "Nikon", model: "Z 8", slotId: "camera.z8"),
            CameraMatchRule(make: "Canon", slotId: "camera.canon"),
            CameraMatchRule(model: "Z 8", slotId: "camera.z8"),
        ])
        #expect(layer.slotCandidates(for: Self.nikon) == ["camera.z8", "camera.nikon", "camera.default"])
        #expect(layer.slotCandidates(for: Self.canon) == ["camera.canon", "camera.default"])
        #expect(layer.slotCandidates(for: CameraIdentity(make: nil, model: nil)) == ["camera.default"])
        #expect(layer.slotCandidates(for: nil) == ["camera.default"])
        var noDefault = layer
        noDefault.slotId = nil
        #expect(noDefault.slotCandidates(for: CameraIdentity(make: "SONY", model: "ILCE-7RM5")).isEmpty)
    }

    @Test("旧预设没有新字段：取默认值，schemaVersion 不变；新字段往返不变，空 cameraMatch 不写出")
    func compatibility() throws {
        let old = """
        {"schemaVersion": 1, "presetId": "7C9E6679-7425-40DE-944B-E07FC1F90AE7", "name": "Old",
         "canvas": {"width": 1080, "height": 1350},
         "layers": [
           {"layerId": "exif", "type": "metadataText", "text": {"template": "{camera}", "fontSizePx": 18}},
           {"layerId": "badge", "type": "cameraBadge", "slotId": "camera.badge"}
         ],
         "assetSlots": [{"slotId": "camera.badge"}]}
        """
        let decoded = try PresetSchema.decode(Data(old.utf8))
        #expect(!decoded.wasMigrated && decoded.unknownFieldPaths.isEmpty)
        let text = try #require(decoded.preset.layers[0].text)
        #expect(text.fontWeight == .regular && !text.italic && text.letterSpacingPx == 0)
        #expect(decoded.preset.layers[1].cameraMatch.isEmpty)
        let encoded = String(decoding: try PresetSchema.encode(decoded.preset), as: UTF8.self)
        #expect(!encoded.contains("cameraMatch"))
        #expect(encoded.contains("\"fontWeight\" : \"regular\""))

        var p = decoded.preset
        p.layers[0].text?.fontWeight = .semibold
        p.layers[0].text?.italic = true
        p.layers[0].text?.letterSpacingPx = 1.5
        p.layers[1].cameraMatch = [CameraMatchRule(make: "FUJIFILM", model: "X100VI", slotId: "camera.badge")]
        let again = try PresetSchema.decode(PresetSchema.encode(p))
        #expect(again.preset == p && again.unknownFieldPaths.isEmpty)
        #expect(p.validate().errors.isEmpty, "\(p.validate())")
    }

    @Test("校验：规则要有 make 或 model、只能引用已有的槽；有规则时可以不写 slotId；文字图层上的规则只警告")
    func validation() {
        var p = ExportPreset(name: "V", canvas: CanvasSettings(width: 1080, height: 1350, background: .defaultBackground, minMarginPx: 60, mode: .fit))
        p.assetSlots = [AssetSlot(slotId: "camera.nikon")]
        p.layers = [
            OverlayLayer(layerId: "badge", type: .cameraBadge, cameraMatch: [
                CameraMatchRule(make: "Nikon", slotId: "camera.nikon"),
                CameraMatchRule(slotId: "camera.nikon"),
                CameraMatchRule(make: "Canon", slotId: "camera.canon"),
            ]),
            OverlayLayer(layerId: "exif", type: .metadataText, cameraMatch: [CameraMatchRule(make: "X", slotId: "camera.nikon")],
                         text: TextStyle(template: "{camera}")),
        ]
        let issues = p.validate()
        #expect(issues.errors.map(\.path) == ["layers[0].cameraMatch[1]", "layers[0].cameraMatch[2].slotId"], "\(issues)")
        #expect(issues.warnings.contains { $0.path == "layers[1].cameraMatch" })
        #expect(!issues.contains { $0.code == "preset.unused_slot" }, "规则引用的槽算作被使用")
    }
}
