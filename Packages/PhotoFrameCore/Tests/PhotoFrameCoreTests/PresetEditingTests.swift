import Foundation
import Testing
@testable import PhotoFrameCore

// D-93：逐项修改预设用的字段路径（CLI `preset get` / `preset set` 与 MCP `get_preset` / `update_preset` 共用）。

@Suite("字段路径")
struct PresetFieldPathTests {
    @Test("解析与输出", arguments: [
        "canvas.minMarginPx", "layers[0].opacity", "layers[exif].text.fontSizePx", "assetSlots[camera.badge].required",
        "layers[+]", "x-note", "layers[2]",
    ])
    func roundTrip(_ text: String) throws {
        #expect(try PresetFieldPath(parsing: text).description == text)
    }

    @Test("拒绝的写法", arguments: ["", ".canvas", "canvas.", "canvas..x", "layers[", "layers[]", "layers[0]x", "layers[+].opacity",
                                     "1abc", "canvas.min margin", "layers[-1]x"])
    func invalid(_ text: String) {
        #expect(throws: PresetEditError.self) { try PresetFieldPath(parsing: text) }
    }

    @Test("方括号里的数字是下标，其余按 layerId / slotId 找")
    func components() throws {
        let path = try PresetFieldPath(parsing: "layers[01].x")
        #expect(path.components == [.key("layers"), .id("01"), .key("x")])
        #expect(try PresetFieldPath(parsing: "layers[3]").components == [.key("layers"), .index(3)])
    }

    @Test("应用：设置、追加、删除；只读字段；中间对象必须存在")
    func apply() throws {
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"schemaVersion": 1, "canvas": {"minMarginPx": 60}, "layers": [{"layerId": "a", "opacity": 1}]}
            """.utf8))
        let edited = try PresetEditor.apply([
            .set(PresetFieldPath(parsing: "canvas.minMarginPx"), .number(80)),
            .set(PresetFieldPath(parsing: "layers[+]"), .object(["layerId": .string("b")])),
            .set(PresetFieldPath(parsing: "layers[b].opacity"), .number(0.5)),
            .remove(PresetFieldPath(parsing: "layers[a]")),
        ], to: manifest)
        #expect(try PresetEditor.value(at: PresetFieldPath(parsing: "canvas.minMarginPx"), in: edited) == .number(80))
        #expect(try PresetEditor.value(at: PresetFieldPath(parsing: "layers[0].layerId"), in: edited) == .string("b"))
        #expect(try PresetEditor.value(at: PresetFieldPath(parsing: "layers[0].opacity"), in: edited) == .number(0.5))

        #expect(throws: PresetEditError.readOnlyField("schemaVersion")) {
            try PresetEditor.apply([.set(PresetFieldPath(parsing: "schemaVersion"), .number(2))], to: manifest)
        }
        #expect(throws: PresetEditError.pathNotFound("canvas.crop.anchor")) {
            try PresetEditor.apply([.set(PresetFieldPath(parsing: "canvas.crop.anchor"), .number(1))], to: manifest)
        }
        #expect(throws: PresetEditError.pathNotFound("layers[9]")) {
            try PresetEditor.apply([.set(PresetFieldPath(parsing: "layers[9]"), .null)], to: manifest)
        }
        #expect(throws: PresetEditError.noEdits) { try PresetEditor.apply([], to: manifest) }
    }

    @Test("[id] 先按 layerId 找：前面的图层只是用了同名素材槽时不会被改到")
    func layerIdBeforeSlotId() throws {
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"layers": [{"layerId": "badge", "slotId": "logo", "opacity": 1}, {"layerId": "logo", "slotId": "logo-file", "opacity": 1}],
             "assetSlots": [{"slotId": "logo"}, {"slotId": "logo-file"}]}
            """.utf8))
        let edited = try PresetEditor.apply([.set(PresetFieldPath(parsing: "layers[logo].opacity"), .number(0.5))], to: manifest)
        #expect(try PresetEditor.value(at: PresetFieldPath(parsing: "layers[0].opacity"), in: edited) == .number(1))
        #expect(try PresetEditor.value(at: PresetFieldPath(parsing: "layers[1].opacity"), in: edited) == .number(0.5))
        #expect(try PresetEditor.value(at: PresetFieldPath(parsing: "layers[logo].layerId"), in: manifest) == .string("logo"))
        let removed = try PresetEditor.apply([.remove(PresetFieldPath(parsing: "layers[logo]"))], to: manifest)
        #expect(try PresetEditor.value(at: PresetFieldPath(parsing: "layers[0].layerId"), in: removed) == .string("badge"))
        // 没有同名 layerId 时仍按 slotId 找。
        #expect(try PresetEditor.value(at: PresetFieldPath(parsing: "layers[logo-file].layerId"), in: manifest) == .string("logo"))
        #expect(try PresetEditor.value(at: PresetFieldPath(parsing: "assetSlots[logo].slotId"), in: manifest) == .string("logo"))
    }
}
