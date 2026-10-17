import Foundation
import MCP
import PhotoFrameApplication
@testable import PhotoFrameCLI
import PhotoFrameStorage
import Testing

// 每个工具的正常路径和错误路径。安全规则见 MCPSecurityTests。

@Suite("MCP 工具")
struct MCPToolTests {
    @Test("tools/list 列出全部工具，带输入和输出 schema")
    func listTools() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let (tools, _) = try await h.client.listTools()
        let names = Set(tools.map(\.name))
        #expect(names == Set(MCPToolName.allCases.map(\.rawValue)))
        for tool in tools {
            #expect(tool.inputSchema.objectValue?["type"]?.stringValue == "object")
            #expect(tool.outputSchema != nil)
        }
        let readOnly = tools.filter { $0.annotations.readOnlyHint == true }.map(\.name)
        #expect(readOnly.contains("list_presets"))
        #expect(!readOnly.contains("create_export_job"))
    }

    @Test("list_presets 与 CLI 的 preset list --json 字段相同")
    func listPresets() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let reply = try await h.call("list_presets")
        #expect(reply.ok && !reply.isError)
        let presets = reply["presets"]?.arrayValue ?? []
        #expect(presets.count == 6)
        let slugs = presets.compactMap { $0.objectValue?["slug"]?.stringValue }
        #expect(slugs.contains("instagram-panorama"))
        let first = presets.first?.objectValue ?? [:]
        for key in ["presetId", "name", "origin", "readOnly", "canvas", "format"] {
            #expect(first[key] != nil, "缺少 \(key)")
        }
        // text 内容是同一份 JSON
        let text = try JSONDecoder().decode(Value.self, from: Data(reply.text.utf8))
        #expect(text.objectValue?["presets"]?.arrayValue?.count == 6)
    }

    @Test("参数不合法、未知工具")
    func invalidArguments() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let extra = try await h.call("list_presets", ["bogus": .bool(true)])
        #expect(extra.isError && extra.code == "mcp.invalid_arguments")
        let wrongType = try await h.call("inspect_image", ["path": .int(3)])
        #expect(wrongType.code == "mcp.invalid_arguments")
        let missing = try await h.call("get_preset")
        #expect(missing.code == "mcp.invalid_arguments")
        await #expect(throws: MCPError.self) {
            _ = try await h.call("delete_everything")
        }
    }

    @Test("get_preset：整份、单个字段、路径错误、找不到")
    func getPreset() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let whole = try await h.call("get_preset", ["preset": .string("xhs-standard")])
        #expect(whole.ok)
        let manifest = whole["value"]?.objectValue ?? [:]
        #expect(manifest["schemaVersion"]?.intValue == 1)
        #expect(manifest["canvas"]?.objectValue?["width"]?.intValue == 1080)

        let field = try await h.call("get_preset", ["preset": .string("xhs-standard"), "path": .string("canvas.minMarginPx")])
        #expect(field["value"]?.intValue == 60)
        #expect(field["path"]?.stringValue == "canvas.minMarginPx")

        let bad = try await h.call("get_preset", ["preset": .string("xhs-standard"), "path": .string("canvas..x")])
        #expect(bad.code == "preset.invalid_path")
        let absent = try await h.call("get_preset", ["preset": .string("xhs-standard"), "path": .string("canvas.nope")])
        #expect(absent.code == "preset.path_not_found")
        let unknown = try await h.call("get_preset", ["preset": .string("tiktok")])
        #expect(unknown.code == "library.preset_not_found")
        // 只在库里找，不把参数当文件读
        let file = try await h.call("get_preset", ["preset": .string("/etc/passwd")])
        #expect(file.code == "library.preset_not_found")
        #expect(!file.text.contains("/etc/passwd"))
    }

    @Test("update_preset：修改、追加、删除；内置只读；校验失败不写入")
    func updatePreset() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let builtIn = try await h.call("update_preset", [
            "preset": .string("instagram-standard"),
            "edits": .array([.object(["path": .string("canvas.minMarginPx"), "value": .int(80)])]),
        ])
        #expect(builtIn.code == "library.builtin_read_only")

        let copy = try await h.service.duplicatePreset(.library("instagram-standard"), name: "Mine")
        let id = copy.presetId.uuidString
        let layer = try Value.json("""
            {"layerId": "note", "type": "text", "enabled": true, "visibleOn": "coverOnly", "anchor": "bottomLeft",
             "reference": "photo", "side": "outside", "offsetPx": [0, 16], "maxBoundsPx": [600, 48], "opacity": 1, "zIndex": 0,
             "text": {"content": "Hello", "fontSizePx": 18, "lineHeight": 1.2, "color": {"colorSpace": "sRGB", "hex": "#3A3A38"}, "paddingPx": 0}}
            """)
        let edits: [Value] = [
            .object(["path": .string("canvas.minMarginPx"), "value": .int(80)]),
            .object(["path": .string("canvas.background.hex"), "value": .string("#FFFFFF")]),
            .object(["path": .string("layers[+]"), "value": layer]),
            .object(["path": .string("layers[note].opacity"), "value": .double(0.5)]),
        ]
        let updated = try await h.call("update_preset", ["preset": .string(id), "edits": .array(edits)])
        #expect(updated.ok, "\(updated.text)")
        #expect(updated["changed"]?.arrayValue?.count == 4)
        #expect(updated["preset"]?.objectValue?["minMarginPx"]?.intValue == 80)
        #expect(updated["preset"]?.objectValue?["layerCount"]?.intValue == 1)

        let opacity = try await h.call("get_preset", ["preset": .string(id), "path": .string("layers[0].opacity")])
        #expect(opacity["value"]?.doubleValue == 0.5)

        // 不认识的字段：与导入相同的检查，拒绝，整批都不写入
        let unknownField = try await h.call("update_preset", ["preset": .string(id), "edits": .array([
            .object(["path": .string("canvas.minMarginPx"), "value": .int(10)]),
            .object(["path": .string("canvas.blur"), "value": .int(3)]),
        ])])
        #expect(unknownField.code == "package.unknown_field" || unknownField.code == "package.invalid_preset")
        let wrongType = try await h.call("update_preset", ["preset": .string(id), "edits": .array([
            .object(["path": .string("canvas.minMarginPx"), "value": .string("wide")]),
        ])])
        #expect(wrongType.code == "preset.invalid_field")
        let after = try await h.call("get_preset", ["preset": .string(id), "path": .string("canvas.minMarginPx")])
        #expect(after["value"]?.intValue == 80)

        let readOnly = try await h.call("update_preset", ["preset": .string(id), "edits": .array([
            .object(["path": .string("presetId"), "value": .string(UUID().uuidString)]),
        ])])
        #expect(readOnly.code == "preset.field_read_only")
        let both = try await h.call("update_preset", ["preset": .string(id), "edits": .array([
            .object(["path": .string("layers[note]"), "value": .null, "remove": .bool(true)]),
        ])])
        #expect(both.code == "mcp.invalid_arguments")

        let removed = try await h.call("update_preset", ["preset": .string(id), "edits": .array([
            .object(["path": .string("layers[note]"), "remove": .bool(true)]),
        ])])
        #expect(removed["preset"]?.objectValue?["layerCount"]?.intValue == 0)
        let missing = try await h.call("update_preset", ["preset": .string(id), "edits": .array([
            .object(["path": .string("layers[note]"), "remove": .bool(true)]),
        ])])
        #expect(missing.code == "preset.path_not_found")
    }

    @Test("inspect_image")
    func inspectImage() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let url = try h.photo("in/photo.jpg", width: 320, height: 200)
        let reply = try await h.call("inspect_image", ["path": .string(url.path)])
        #expect(reply.ok, "\(reply.text)")
        let image = reply["image"]?.objectValue ?? [:]
        #expect(image["pixelSize"]?.objectValue?["width"]?.intValue == 320)
        #expect(image["format"]?.stringValue == "jpeg")
        #expect(MCPAccessPolicy.realPath(image["path"]?.stringValue ?? "") == url.path)

        let missing = try await h.call("inspect_image", ["path": .string(h.inputs.appending(path: "nope.jpg").path)])
        #expect(missing.code == "source.not_found")
        try Data("not an image".utf8).write(to: h.inputs.appending(path: "notes.txt"))
        let wrongFormat = try await h.call("inspect_image", ["path": .string(h.inputs.appending(path: "notes.txt").path)])
        #expect(wrongFormat.code == "source.unsupported_format")
    }

    @Test("list_assets 不返回文件路径")
    func listAssets() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let png = try h.sandbox.photo("badge.png", width: 64, height: 64, type: .png)
        _ = try await h.service.importAsset(from: png, category: .cameraBadge, name: "Badge")
        let reply = try await h.call("list_assets")
        #expect(reply.ok)
        let assets = reply["assets"]?.arrayValue ?? []
        #expect(assets.count == 1)
        #expect(assets.first?.objectValue?["name"]?.stringValue == "Badge")
        #expect(assets.first?.objectValue?["path"] == nil)
        #expect(!reply.text.contains(h.sandbox.root.lastPathComponent))
        let filtered = try await h.call("list_assets", ["category": .string("signature")])
        #expect(filtered["assets"]?.arrayValue?.isEmpty == true)
        let bad = try await h.call("list_assets", ["category": .string("logos")])
        #expect(bad.code == "mcp.invalid_arguments")
    }

    @Test("validate_export 列出将写出的文件，不写任何东西")
    func validateExport() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let url = try h.photo("in/Badlands.jpg")
        let target = h.outputs.appending(path: "Exports")
        let reply = try await h.call("validate_export", exportArguments([url], output: target))
        #expect(reply.ok && reply["valid"]?.boolValue == true, "\(reply.text)")
        let job = reply["jobs"]?.arrayValue?.first?.objectValue ?? [:]
        #expect(job["directory"]?.stringValue == target.appending(path: "Instagram/Badlands_Standard").path)
        #expect(job["outputs"]?.arrayValue?.count == 1)
        #expect(!FileManager.default.fileExists(atPath: target.path))

        let badPreset = try await h.call("validate_export", exportArguments([url], preset: "tiktok", output: target))
        #expect(badPreset.code == "library.preset_not_found")
    }

    @Test("preview_export：内联图片、写文件、覆盖需要显式授权")
    func previewExport() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let url = try h.photo("in/Wide.jpg", width: 900, height: 300)
        var args: [String: Value] = ["image": .string(url.path), "preset": .string("instagram-panorama"), "maxEdge": .int(200)]
        let inline = try await h.call("preview_export", args)
        #expect(inline.ok, "\(inline.text)")
        let pages = inline["positions"]?.arrayValue?.count ?? 0
        #expect(pages > 1)
        #expect(inline.images == pages)
        #expect(inline["files"]?.arrayValue?.first?.objectValue?["path"] == nil)

        args["pages"] = .array([.int(0)])
        args["outputDirectory"] = .string(h.outputs.appending(path: "previews").path)
        let written = try await h.call("preview_export", args)
        #expect(written.ok && written.images == 0)
        let path = written["files"]?.arrayValue?.first?.objectValue?["path"]?.stringValue ?? ""
        #expect(path.hasSuffix("Wide_Panorama_preview_00_Cover.png"))
        #expect(FileManager.default.fileExists(atPath: path))

        let again = try await h.call("preview_export", args)
        #expect(again.code == "preview.file_exists")
        #expect(again.object["error"]?.objectValue?["hint"]?.stringValue?.contains("overwrite: true") == true)
        args["overwrite"] = .bool(true)
        let replaced = try await h.call("preview_export", args)
        #expect(replaced.ok)

        // dynamicRange（D-106）：SDR 输出的预设只有 PNG，并说明原因；取值之外的报参数错误。
        args["dynamicRange"] = .string("hdr")
        let hdr = try await h.call("preview_export", args)
        #expect(hdr.ok, "\(hdr.text)")
        #expect(hdr["warnings"]?.arrayValue?.contains { $0.objectValue?["code"]?.stringValue == "preview.output_sdr" } == true)
        #expect(hdr["files"]?.arrayValue?.first?.objectValue?["dynamicRange"]?.stringValue == "sdr")
        args["dynamicRange"] = .string("edr")
        #expect(try await h.call("preview_export", args).code == "mcp.invalid_arguments")
        args["dynamicRange"] = .string("auto")
        #expect(try await h.call("preview_export", args).code == "mcp.invalid_arguments")
    }

    @Test("create_export_job → get_job_status → 文件落盘；版本后缀与显式覆盖")
    func exportJob() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let url = try h.photo("in/Badlands.jpg")
        let created = try await h.call("create_export_job", exportArguments([url], output: h.outputs))
        #expect(created.ok, "\(created.text)")
        let jobId = created["jobs"]?.arrayValue?.first?.objectValue?["jobId"]?.stringValue ?? ""
        let job = try await h.waitForJob(jobId)
        #expect(job["status"]?.stringValue == "completed", "\(job)")
        let first = job["outputs"]?.arrayValue?.first?.objectValue?["path"]?.stringValue ?? ""
        #expect(first == h.outputs.appending(path: "Instagram/Badlands_Standard/00_Cover.jpg").path)
        #expect(imageInfo(URL(filePath: first)).width == 1080)
        #expect(job["progress"]?.objectValue?["stage"]?.stringValue == "completed")

        // 默认不覆盖：加版本后缀
        let second = try await h.call("create_export_job", exportArguments([url], output: h.outputs))
        let secondJob = try await h.waitForJob(second["jobs"]?.arrayValue?.first?.objectValue?["jobId"]?.stringValue ?? "")
        #expect(secondJob["directory"]?.stringValue?.hasSuffix("Badlands_Standard_v2") == true)

        // 显式覆盖：替换第一个目录，不再加后缀
        let third = try await h.call("create_export_job", exportArguments([url], output: h.outputs, overwrite: true))
        let thirdJob = try await h.waitForJob(third["jobs"]?.arrayValue?.first?.objectValue?["jobId"]?.stringValue ?? "")
        #expect(thirdJob["status"]?.stringValue == "completed")
        #expect(thirdJob["directory"]?.stringValue?.hasSuffix("Instagram/Badlands_Standard") == true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: h.outputs.appending(path: "Instagram").path).sorted()
        #expect(entries == ["Badlands_Standard", "Badlands_Standard_v2"])

        let all = try await h.call("get_job_status")
        #expect(all["jobs"]?.arrayValue?.count == 3)
        let done = try await h.call("cancel_export_job", ["jobId": .string(jobId)])
        #expect(done.code == "job.not_cancelable")
    }

    @Test("create_export_job 校验不通过时什么都不写")
    func exportInvalid() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let url = try h.photo("in/A.jpg")
        let copy = try await h.service.duplicatePreset(.library("instagram-standard"), name: "Needs Badge")
        let slot = try Value.json(#"{"slotId": "badge", "kind": "image", "required": true, "acceptedFormats": ["png"]}"#)
        let layer = try Value.json("""
            {"layerId": "badge", "type": "cameraBadge", "enabled": true, "visibleOn": "coverOnly", "anchor": "bottomRight",
             "reference": "photo", "side": "outside", "offsetPx": [0, 16], "sizePx": [48, 48], "opacity": 1, "zIndex": 0, "slotId": "badge"}
            """)
        let updated = try await h.call("update_preset", ["preset": .string(copy.presetId.uuidString), "edits": .array([
            .object(["path": .string("assetSlots[+]"), "value": slot]),
            .object(["path": .string("layers[+]"), "value": layer]),
        ])])
        #expect(updated.ok, "\(updated.text)")
        let reply = try await h.call("create_export_job", exportArguments([url], preset: "needs-badge", output: h.outputs))
        #expect(reply.isError && reply["valid"]?.boolValue == false)
        #expect(reply.code == "slot.missing_required")
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.outputs.path).isEmpty)
        let none = try await h.call("get_job_status")
        #expect(none["jobs"]?.arrayValue?.isEmpty == true)
    }

    @Test("cancel_export_job 只取消本服务器的任务；退出时取消未完成的任务")
    func cancelJob() async throws {
        let h = try await MCPHarness.start(renderer: HoldingRenderer())
        let url = try h.photo("in/A.jpg")
        let created = try await h.call("create_export_job", exportArguments([url], output: h.outputs))
        let jobId = created["jobs"]?.arrayValue?.first?.objectValue?["jobId"]?.stringValue ?? ""
        let canceled = try await h.call("cancel_export_job", ["jobId": .string(jobId)])
        #expect(canceled.ok, "\(canceled.text)")
        #expect(canceled["job"]?.objectValue?["status"]?.stringValue == "canceled")
        // 已取消的任务再取消：什么也不做
        let twice = try await h.call("cancel_export_job", ["jobId": .string(jobId)])
        #expect(twice.ok && twice["job"]?.objectValue?["status"]?.stringValue == "canceled")
        let stranger = try await h.call("cancel_export_job", ["jobId": .string(UUID().uuidString)])
        #expect(stranger.code == "job.unknown")
        let garbage = try await h.call("get_job_status", ["jobId": .string("../../etc")])
        #expect(garbage.code == "job.unknown")

        // 进程退出（shutdown）时取消还在执行的任务，并清理临时目录
        let running = try await h.call("create_export_job", exportArguments([url], output: h.outputs))
        let runningId = JobID(running["jobs"]?.arrayValue?.first?.objectValue?["jobId"]?.stringValue ?? "")!
        await h.stop()
        let record = try await h.service.status(runningId)
        #expect(record.status == .canceled)
        #expect(h.sandbox.tree(h.outputs).filter { !$0.hasPrefix(".photoframe-staging") }.isEmpty)
        let staging = h.outputs.appending(path: ".photoframe-staging")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test("resources：列表、访问范围、预设、字段说明；不能读任意文件")
    func resources() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let (list, _) = try await h.client.listResources()
        #expect(Set(list.map(\.uri)) == Set(MCPResources.list.map(\.uri)))
        let (templates, _) = try await h.client.listResourceTemplates()
        #expect(templates.first?.uriTemplate == "photoframe://presets/{presetId}")

        let access = try await h.client.readResource(uri: MCPResources.access)
        let accessJSON = try JSONDecoder().decode(Value.self, from: Data((access.first?.text ?? "").utf8))
        #expect(accessJSON.objectValue?["readDirectories"]?.arrayValue?.first?.stringValue == h.inputs.path)
        #expect(accessJSON.objectValue?["writeDirectories"]?.arrayValue?.first?.stringValue == h.outputs.path)

        let schema = try await h.client.readResource(uri: MCPResources.presetSchema)
        #expect(schema.first?.text?.contains("layers[+]") == true)
        let platforms = try await h.client.readResource(uri: MCPResources.platforms)
        #expect(platforms.first?.text?.contains("instagram") == true)
        let presets = try await h.client.readResource(uri: MCPResources.presets)
        #expect(presets.first?.text?.contains("instagram-panorama") == true)
        let one = try await h.client.readResource(uri: "photoframe://presets/xhs-standard")
        #expect(one.first?.text?.contains("\"schemaVersion\"") == true)

        await #expect(throws: MCPError.self) { _ = try await h.client.readResource(uri: "file:///etc/passwd") }
        await #expect(throws: MCPError.self) { _ = try await h.client.readResource(uri: "photoframe://presets/nope") }
    }
}
