import Foundation
import PhotoFrameCore
import PhotoFrameStorage
import Testing
@testable import PhotoFrameCLI

// D-93：CLI `preset get` / `preset set`。字段路径本身的测试在 PhotoFrameCoreTests/PresetEditingTests。

@Suite("preset get / set")
struct PresetEditCommandTests {
    @Test("get：整份预设、一个字段；set：修改后 get 读回")
    func getAndSet() async throws {
        let box = try Sandbox()
        let whole = await runCLI(["preset", "get", "xhs-standard"], in: box.root)
        #expect(whole.status == 0)
        let manifest = try whole.stdout.json()
        #expect(manifest["schemaVersion"] as? Int == 1)

        let builtIn = await runCLI(["preset", "set", "xhs-standard", "canvas.minMarginPx", "80"], in: box.root)
        #expect(builtIn.status == 4)
        #expect(builtIn.stderr.value.contains("library.builtin_read_only"))

        let dup = await runCLI(["preset", "duplicate", "xhs-standard", "--name", "Mine"], in: box.root)
        #expect(dup.status == 0)
        let set = await runCLI(["preset", "set", "mine", "canvas.minMarginPx", "80", "canvas.background.hex", "#FFFFFF", "--json"],
                               in: box.root)
        #expect(set.status == 0, "\(set.stderr.value)")
        let result = try set.stdout.json()
        #expect(result["changed"] as? [String] == ["canvas.minMarginPx", "canvas.background.hex"])
        let preset = result["preset"] as? [String: Any]
        #expect(preset?["minMarginPx"] as? Int == 80 && preset?["background"] as? String == "#FFFFFF")

        let field = await runCLI(["preset", "get", "mine", "canvas.minMarginPx"], in: box.root)
        #expect(field.stdout.value.trimmingCharacters(in: .whitespacesAndNewlines) == "80")
        let json = await runCLI(["preset", "get", "mine", "canvas.background", "--json"], in: box.root)
        let value = try json.stdout.json()["value"] as? [String: Any]
        #expect(value?["hex"] as? String == "#FFFFFF")
    }

    @Test("set：文字样式与相机匹配规则（D-111）用同一种字段路径")
    func textStyleAndCameraMatch() async throws {
        let box = try Sandbox()
        _ = await runCLI(["preset", "duplicate", "instagram-standard", "--name", "Mine"], in: box.root)
        let layers = #"[{"layerId": "exif", "type": "metadataText", "text": {"template": "{camera}"}}, "#
            + #"{"layerId": "badge", "type": "cameraBadge", "slotId": "camera.badge", "sizePx": [48, 48]}]"#
        let slots = #"[{"slotId": "camera.badge"}, {"slotId": "camera.fuji"}]"#
        let base = await runCLI(["preset", "set", "mine", "layers", layers, "assetSlots", slots], in: box.root)
        #expect(base.status == 0, "\(base.stderr.value)")
        let set = await runCLI([
            "preset", "set", "mine",
            "layers[exif].text.fontWeight", "semibold", "layers[exif].text.italic", "true", "layers[exif].text.letterSpacingPx", "1.5",
            "layers[badge].cameraMatch", #"[{"make": "FUJIFILM", "slotId": "camera.fuji"}]"#,
        ], in: box.root)
        #expect(set.status == 0, "\(set.stderr.value)")
        let weight = await runCLI(["preset", "get", "mine", "layers[exif].text.fontWeight"], in: box.root)
        #expect(weight.stdout.value.contains("semibold"))
        let rule = await runCLI(["preset", "get", "mine", "layers[badge].cameraMatch[0].make"], in: box.root)
        #expect(rule.stdout.value.contains("FUJIFILM"))

        let badWeight = await runCLI(["preset", "set", "mine", "layers[exif].text.fontWeight", "extra"], in: box.root)
        #expect(badWeight.status == 4)
        let badSlot = await runCLI(["preset", "set", "mine", "layers[badge].cameraMatch[0].slotId", "nope"], in: box.root)
        #expect(badSlot.status == 4)
        #expect(badSlot.stderr.value.contains("相机匹配规则引用了不存在的素材槽"))
    }

    @Test("set：追加和删除图层；不通过检查时不写入；用法错误")
    func layersAndFailures() async throws {
        let box = try Sandbox()
        _ = await runCLI(["preset", "duplicate", "instagram-standard", "--name", "Mine"], in: box.root)
        let layer = """
            {"layerId": "note", "type": "text", "enabled": true, "visibleOn": "coverOnly", "anchor": "bottomLeft", "reference": "photo",
             "side": "outside", "offsetPx": [0, 16], "maxBoundsPx": [600, 48], "opacity": 1, "zIndex": 0,
             "text": {"content": "Hi", "fontSizePx": 18, "lineHeight": 1.2, "color": {"colorSpace": "sRGB", "hex": "#000000"}, "paddingPx": 0}}
            """
        let added = await runCLI(["preset", "set", "mine", "layers[+]", layer, "--json"], in: box.root)
        #expect(added.status == 0, "\(added.stderr.value)")
        #expect((try added.stdout.json()["preset"] as? [String: Any])?["layerCount"] as? Int == 1)

        let unknown = await runCLI(["preset", "set", "mine", "layers[note].blur", "3"], in: box.root)
        #expect(unknown.status == 4)
        #expect(unknown.stderr.value.contains("不认识的字段：layers[0].blur"))
        let badColor = await runCLI(["preset", "set", "mine", "layers[note].text.color.hex", "red"], in: box.root)
        #expect(badColor.status == 4)
        let opacity = await runCLI(["preset", "get", "mine", "layers[note].text.color.hex"], in: box.root)
        #expect(opacity.stdout.value.contains("#000000"))

        let removed = await runCLI(["preset", "set", "mine", "--unset", "layers[note]", "--json"], in: box.root)
        #expect((try removed.stdout.json()["preset"] as? [String: Any])?["layerCount"] as? Int == 0)

        #expect(await runCLI(["preset", "set", "mine", "canvas.minMarginPx"], in: box.root).status == 2)
        #expect(await runCLI(["preset", "set", "mine"], in: box.root).status == 2)
        let badPath = await runCLI(["preset", "set", "mine", "canvas..x", "1"], in: box.root)
        #expect(badPath.status == 4 && badPath.stderr.value.contains("preset.invalid_path"))
    }

    @Test("set：值先按 JSON 解析，解析不了就是字符串")
    func valueParsing() {
        #expect(PresetCommand.SetCommand.parseValue("80") == .number(80))
        #expect(PresetCommand.SetCommand.parseValue("true") == .bool(true))
        #expect(PresetCommand.SetCommand.parseValue("[0,16]") == .array([.number(0), .number(16)]))
        #expect(PresetCommand.SetCommand.parseValue("#FFFFFF") == .string("#FFFFFF"))
        #expect(PresetCommand.SetCommand.parseValue("\"80\"") == .string("80"))
        #expect(PresetCommand.SetCommand.parseValue("My Name") == .string("My Name"))
    }

    @Test("修改是原子的：写入后库文件仍可读，没有临时文件残留")
    func atomic() async throws {
        let box = try Sandbox()
        _ = await runCLI(["preset", "duplicate", "instagram-standard", "--name", "Mine"], in: box.root)
        for margin in [70, 80, 90] {
            #expect(await runCLI(["preset", "set", "mine", "canvas.minMarginPx", "\(margin)"], in: box.root).status == 0)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: box.root.appending(path: "Library/Presets").path)
        #expect(files.count == 1 && files[0].hasSuffix(".json"))
        let list = await runCLI(["preset", "list", "--json"], in: box.root)
        #expect(list.stderr.value.isEmpty)
    }
}
