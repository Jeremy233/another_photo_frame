import Foundation
import ImageIO
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameStorage
import Testing
import UniformTypeIdentifiers
@testable import PhotoFrameCLI

@Suite("preset list / image inspect / preview")
struct InfoCommandTests {
    @Test("preset list：文本第一列是短名称；JSON 结构稳定")
    func presetList() async throws {
        let box = try Sandbox()
        let text = await runCLI(["preset", "list"], in: box.root)
        #expect(text.status == 0)
        #expect(text.stdout.lines.map { String($0.split(separator: " ")[0]) } == [
            "instagram-standard", "instagram-panorama", "xhs-standard", "xhs-panorama", "douyin-standard", "douyin-panorama",
        ])

        let json = try await runCLI(["preset", "list", "--json"], in: box.root).stdout.json()
        #expect(json["formatVersion"] as? Int == 1)
        #expect(json["command"] as? String == "preset list")
        #expect(json["ok"] as? Bool == true)
        #expect(json["exitCode"] as? Int == 0)
        let presets = try #require(json["presets"] as? [[String: Any]])
        #expect(presets.count == 6)
        let pano = try #require(presets.first { $0["slug"] as? String == "xhs-panorama" })
        #expect(pano["presetId"] as? String == "16AE8FDA-85CA-4BBC-B4C2-9C1A47324EA1")
        #expect(pano["origin"] as? String == "builtIn")
        #expect(pano["readOnly"] as? Bool == true)
        #expect((json["warnings"] as? [Any])?.isEmpty == true)
        #expect((pano["canvas"] as? [String: Int]) == ["width": 1080, "height": 1080])
        #expect(pano["panorama"] is [String: Any])
        #expect(pano["format"] as? String == "jpeg")
        #expect(pano["dynamicRange"] as? String == "auto", "内置预设跟随源图（D-125）")
        #expect(presets.first?["panorama"] == nil)
    }

    @Test("image inspect：16-bit Adobe RGB TIFF")
    func inspectTIFF() async throws {
        let box = try Sandbox()
        try box.photo("Scan.tif", width: 640, height: 400, type: .tiff, bits: 16)
        let result = await runCLI(["image", "inspect", "Scan.tif", "--json"], in: box.root)
        #expect(result.status == 0)
        let image = try #require(try result.stdout.json()["image"] as? [String: Any])
        #expect(image["format"] as? String == "tiff")
        #expect(image["bitDepth"] as? Int == 16)
        #expect((image["pixelSize"] as? [String: Int]) == ["width": 640, "height": 400])
        #expect(image["orientation"] as? Int == 1)
        let profile = try #require(image["colorProfile"] as? [String: Any])
        #expect(profile["embedded"] as? Bool == true)
        #expect(profile["origin"] as? String == "embedded")
        #expect((image["hdr"] as? [String: Any])?["kind"] as? String == "none")
        #expect(image["hasGPS"] as? Bool == false)
        #expect(image["path"] as? String == box.root.appending(path: "Scan.tif").path)

        let text = await runCLI(["image", "inspect", "Scan.tif"], in: box.root)
        #expect(text.stdout.lines.contains("pixelSize: 640x400"))
        #expect(text.stdout.lines.contains("bitDepth: 16"))
    }

    @Test("image inspect：没有 ICC 时按 sRGB 并警告（D-04）")
    func inspectNoProfile() async throws {
        let box = try Sandbox()
        try box.photo("NoICC.png", width: 300, height: 200, type: .png, profile: false)
        let result = await runCLI(["image", "inspect", "NoICC.png", "--json"], in: box.root)
        let image = try #require(try result.stdout.json()["image"] as? [String: Any])
        #expect((image["colorProfile"] as? [String: Any])?["origin"] as? String == "assumedSRGB")
        #expect((image["warnings"] as? [[String: String]])?.contains { $0["code"] == "source.profile_missing" } == true)

        let text = await runCLI(["image", "inspect", "NoICC.png"], in: box.root)
        #expect(text.stderr.value.contains("source.profile_missing"))
    }

    @Test("image inspect：错误的退出码与 JSON 错误")
    func inspectErrors() async throws {
        let box = try Sandbox()
        let missing = await runCLI(["image", "inspect", "nope.jpg", "--json"], in: box.root)
        #expect(missing.status == PhotoFrameExitCode.notFound.rawValue)
        let json = try missing.stdout.json()
        #expect(json["ok"] as? Bool == false)
        #expect(json["exitCode"] as? Int == 3)
        #expect((json["error"] as? [String: Any])?["code"] as? String == "source.not_found")
        #expect(missing.stderr.value.contains("source.not_found"))

        try Data("text".utf8).write(to: box.root.appending(path: "Fake.jpg"))
        let fake = await runCLI(["image", "inspect", "Fake.jpg"], in: box.root)
        #expect(fake.status == PhotoFrameExitCode.invalidInput.rawValue)
        #expect(fake.stdout.value.isEmpty)
        #expect(fake.stderr.value.contains("render.unsupported_format"))
    }

    @Test("preview：写 sRGB PNG，按页过滤；已存在时拒绝，--overwrite 替换")
    func preview() async throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 3000, height: 1000)
        let args = ["preview", "Badlands.jpg", "--preset", "instagram-panorama", "-o", "previews", "--max-edge", "400", "--json"]
        let result = await runCLI(args, in: box.root)
        #expect(result.status == 0, "\(result.stderr.value)")
        let json = try result.stdout.json()
        let files = try #require(json["files"] as? [[String: Any]])
        let positions = try #require(json["positions"] as? [Int])
        #expect(files.count == positions.count && positions.first == 0)
        #expect(files.map { ($0["path"] as? String).map { URL(filePath: $0).lastPathComponent } } == positions.map {
            "Badlands_Panorama_preview_" + ($0 == 0 ? "00_Cover.png" : String(format: "%02d_Slide.png", $0))
        })
        for file in files {
            let info = imageInfo(URL(filePath: file["path"] as! String))
            #expect(info.width == 300 && info.height == 400)
            #expect(file["exportWidth"] as? Int == 1080)
            #expect(info.profile?.contains("sRGB") == true)
        }

        let again = await runCLI(Array(args.dropLast()), in: box.root)
        #expect(again.status == PhotoFrameExitCode.outputUnavailable.rawValue)
        #expect(again.stderr.value.contains("preview.file_exists"))

        let cover = await runCLI(["preview", "Badlands.jpg", "--preset", "instagram-panorama", "-o", "previews",
                                  "--max-edge", "400", "--page", "0", "--overwrite"], in: box.root)
        #expect(cover.status == 0)
        #expect(cover.stdout.lines.map { URL(filePath: $0).lastPathComponent } == ["Badlands_Panorama_preview_00_Cover.png"])
    }

    @Test("preview --dynamic-range hdr（D-106）：HDR 输出的页写成 gain map JPEG；预设输出 SDR 时仍是 PNG 并警告")
    func hdrPreview() async throws {
        let box = try Sandbox()
        try box.hdrPhoto("Bright.tif", width: 800, height: 600)
        #expect(await runCLI(["preset", "duplicate", "instagram-standard", "--name", "HDR"], in: box.root).status == 0)
        #expect(await runCLI(["preset", "set", "HDR", "output.dynamicRange", "hdr"], in: box.root).status == 0)

        let hdr = await runCLI(["preview", "Bright.tif", "--preset", "HDR", "-o", "p", "--max-edge", "400",
                                "--dynamic-range", "hdr", "--json"], in: box.root)
        #expect(hdr.status == 0, "\(hdr.stderr.value)")
        let file = try #require((try hdr.stdout.json()["files"] as? [[String: Any]])?.first)
        #expect(file["dynamicRange"] as? String == "hdr")
        #expect((file["hdrHeadroom"] as? Double ?? 0) > 1)
        let path = try #require(file["path"] as? String)
        #expect(path.hasSuffix("Bright_Standard_preview_00_Cover.jpg"))
        let image = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil)!
        #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(image, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil)

        // 内置预设跟随源图（D-125）：HDR 源图同样写 gain map JPEG。
        let auto = await runCLI(["preview", "Bright.tif", "--preset", "instagram-standard", "-o", "p", "--dynamic-range", "hdr",
                                 "--overwrite"], in: box.root)
        #expect(auto.status == 0, "\(auto.stderr.value)")
        #expect(auto.stdout.lines.first?.hasSuffix("_preview_00_Cover.jpg") == true)
        #expect(!auto.stderr.value.contains("preview.output_sdr"))

        #expect(await runCLI(["preset", "set", "HDR", "output.dynamicRange", "sdr"], in: box.root).status == 0)
        let sdr = await runCLI(["preview", "Bright.tif", "--preset", "HDR", "-o", "p", "--dynamic-range", "hdr"],
                               in: box.root)
        #expect(sdr.status == 0, "\(sdr.stderr.value)")
        #expect(sdr.stdout.lines.first?.hasSuffix("_preview_00_Cover.png") == true)
        #expect(sdr.stderr.value.contains("preview.output_sdr"))

        // 预览模式只有 sdr / hdr。
        #expect(await runCLI(["preview", "Bright.tif", "--preset", "HDR", "-o", "p", "--dynamic-range", "auto"], in: box.root).status != 0)
    }
}

@Suite("export")
struct ExportCommandTests {
    @Test("端到端：合成图 → 两个预设 → 真实文件；尺寸、sRGB ICC、文件名；stdout 只有路径")
    func endToEnd() async throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 3600, height: 1200)
        try box.photo("Scans/Mesa.tif", width: 1600, height: 1200, type: .tiff, bits: 16)
        let result = await runCLI([
            "export", "Badlands.jpg", "Scans/Mesa.tif", "--preset", "instagram-panorama", "--preset", "XHS Standard", "-o", "Exports",
        ], in: box.root)
        #expect(result.status == 0, "\(result.stderr.value)")

        let paths = result.stdout.lines
        #expect(paths.allSatisfy { $0.hasPrefix(box.exports.path + "/") })
        let relative = paths.map { String($0.dropFirst(box.exports.path.count + 1)) }
        #expect(relative.contains("Instagram/Badlands_Panorama/00_Cover.jpg"))
        #expect(relative.contains("Instagram/Badlands_Panorama/01_Slide.jpg"))
        #expect(relative.contains("Xiaohongshu/Badlands_Standard/00_Cover.jpg"))
        #expect(relative.contains("Instagram/Mesa_Panorama/00_Cover.jpg"))
        #expect(relative.contains("Xiaohongshu/Mesa_Standard/00_Cover.jpg"))
        for path in paths {
            let info = imageInfo(URL(filePath: path))
            let expected = path.contains("/Instagram/") ? (1080, 1440) : (1080, 1080)
            #expect(info.width == expected.0 && info.height == expected.1, "\(path)")
            #expect(info.profile == "sRGB IEC61966-2.1", "\(path)")
        }
        // 只有作品目录，没有临时目录、清单文件或别的东西。
        #expect(Set(box.tree()) == Set(relative + ["Instagram", "Xiaohongshu", "Instagram/Badlands_Panorama", "Instagram/Mesa_Panorama",
                                                   "Xiaohongshu/Badlands_Standard", "Xiaohongshu/Mesa_Standard"]))
        // 进度按真实阶段写在 stderr。
        for stage in ["validating", "decoding", "rendering", "encoding", "writing", "completed"] {
            #expect(result.stderr.value.contains(": \(stage)"))
        }
    }

    @Test("--json：结构化结果；再次导出加 _v2；--overwrite 替换并给出警告")
    func jsonAndConflicts() async throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 1600, height: 1200)
        let args = ["export", "Badlands.jpg", "--preset", "douyin-standard", "-o", "Exports", "--json", "--quiet"]

        let first = await runCLI(args, in: box.root)
        #expect(first.status == 0)
        #expect(first.stderr.value.isEmpty)
        let json = try first.stdout.json()
        #expect(json["formatVersion"] as? Int == 1 && json["command"] as? String == "export")
        #expect(json["ok"] as? Bool == true && json["dryRun"] as? Bool == false)
        let job = try #require((json["jobs"] as? [[String: Any]])?.first)
        #expect(job["status"] as? String == "completed")
        #expect((job["preset"] as? [String: String])?["name"] == "Douyin Standard")
        #expect(job["source"] as? String == box.root.appending(path: "Badlands.jpg").path)
        #expect((job["directory"] as? String)?.hasSuffix("/Douyin/Badlands_Standard") == true)
        let output = try #require((job["outputs"] as? [[String: Any]])?.first)
        #expect(output["role"] as? String == "cover" && output["position"] as? Int == 0)
        #expect(output["fileName"] as? String == "00_Cover.jpg")
        #expect(output["width"] as? Int == 1080 && output["height"] as? Int == 1920)
        #expect(output["colorProfile"] as? String == "sRGB IEC61966-2.1")
        #expect((output["bytes"] as? Int ?? 0) > 0)
        #expect(job["error"] == nil)

        let second = try await runCLI(args, in: box.root).stdout.json()
        #expect(((second["jobs"] as? [[String: Any]])?.first?["directory"] as? String)?.hasSuffix("Badlands_Standard_v2") == true)

        let replaced = try await runCLI(args + ["--overwrite"], in: box.root).stdout.json()
        let replacedJob = try #require((replaced["jobs"] as? [[String: Any]])?.first)
        #expect((replacedJob["directory"] as? String)?.hasSuffix("/Douyin/Badlands_Standard") == true)
        #expect((replacedJob["warnings"] as? [[String: String]])?.contains { $0["code"] == "export.replaced_previous" } == true)
        #expect(box.tree().filter { !$0.contains("/") || $0.split(separator: "/").count == 2 }.sorted() == [
            "Douyin", "Douyin/Badlands_Standard", "Douyin/Badlands_Standard_v2",
        ])
    }

    @Test("--dry-run：列出将写出的文件，不写任何东西")
    func dryRun() async throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 3000, height: 1000)
        let text = await runCLI(["export", "Badlands.jpg", "--preset", "xhs-panorama", "-o", "Exports", "--dry-run"], in: box.root)
        #expect(text.status == 0)
        #expect(text.stdout.lines.first == box.exports.appending(path: "Xiaohongshu/Badlands_Panorama/00_Cover.jpg").path)
        #expect(text.stdout.lines.count >= 3)
        #expect(!FileManager.default.fileExists(atPath: box.exports.path))

        let json = try await runCLI(["export", "Badlands.jpg", "--preset", "xhs-panorama", "-o", "Exports", "--dry-run", "--json"],
                                    in: box.root).stdout.json()
        #expect(json["dryRun"] as? Bool == true && json["valid"] as? Bool == true)
        let job = try #require((json["jobs"] as? [[String: Any]])?.first)
        let outputs = try #require(job["outputs"] as? [[String: Any]])
        #expect(outputs.first?["fileName"] as? String == "00_Cover.jpg")
        #expect(outputs.allSatisfy { $0["width"] as? Int == 1080 && $0["height"] as? Int == 1080 })
        #expect((job["errors"] as? [Any])?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: box.exports.path))
    }

    @Test("--assume-profile：没有 ICC 的源图按指定色彩空间解释；有 ICC 时忽略并警告（D-04）")
    func assumeProfile() async throws {
        let box = try Sandbox()
        try box.photo("Scan.png", width: 1200, height: 800, type: .png, profile: false)
        try box.photo("Tagged.jpg", width: 1200, height: 800)

        func warnings(_ args: [String]) async throws -> [Set<String>] {
            let result = await runCLI(args + ["-o", "Exports", "--json", "-q", "--preset", "xhs-standard"], in: box.root)
            #expect(result.status == 0, "\(result.stderr.value)")
            let jobs = try #require(try result.stdout.json()["jobs"] as? [[String: Any]])
            return jobs.map { Set(($0["warnings"] as? [[String: String]] ?? []).compactMap { $0["code"] }) }
        }
        #expect(try await warnings(["export", "Scan.png"])[0].contains("source.profile_missing"))
        let assumed = try await warnings(["export", "Scan.png", "Tagged.jpg", "--assume-profile", "display-p3"])
        #expect(!assumed[0].contains("source.profile_missing") && !assumed[0].contains("source.override_ignored"))
        #expect(assumed[1].contains("source.override_ignored"))

        let preview = await runCLI(["preview", "Tagged.jpg", "--preset", "xhs-standard", "-o", "p", "--max-edge", "200",
                                    "--assume-profile", "adobe-rgb"], in: box.root)
        #expect(preview.status == 0)
        #expect(preview.stderr.value.contains("source.override_ignored"))
    }

    @Test("预设文件：--preset 直接给 .photoframe 路径")
    func presetFile() async throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 1200, height: 800)
        let preset = ExportPreset(
            name: "Square Gray", canvas: CanvasSettings(width: 800, height: 800, background: PresetColor(hex: "#808080"), minMarginPx: 40, mode: .fit),
            output: OutputSettings(format: .png))
        try PresetPackage.export(preset, to: box.root.appending(path: "Square.photoframe"))
        let result = await runCLI(["export", "Badlands.jpg", "--preset", "Square.photoframe", "-o", "Exports"], in: box.root)
        #expect(result.status == 0, "\(result.stderr.value)")
        #expect(result.stdout.lines == [box.exports.appending(path: "Custom/Badlands_Standard/00_Cover.png").path])
        let info = imageInfo(URL(filePath: result.stdout.lines[0]))
        #expect(info.width == 800 && info.height == 800)
    }

    @Test("校验失败时什么都不写，退出码按错误类别", arguments: [
        (["export", "nope.jpg", "--preset", "xhs-standard", "-o", "Exports"], PhotoFrameExitCode.notFound, "source.not_found"),
        (["export", "Badlands.jpg", "--preset", "tiktok", "-o", "Exports"], .notFound, "library.preset_not_found"),
        (["export", "Badlands.jpg", "--preset", "missing.photoframe", "-o", "Exports"], .notFound, "preset.file_not_found"),
        (["export", "Phone.heic", "--preset", "xhs-standard", "-o", "Exports"], .invalidInput, "source.unsupported_format"),
        (["export", "Fake.png", "--preset", "xhs-standard", "-o", "Exports"], .invalidInput, "render.unsupported_format"),
        (["export", "Badlands.jpg", "--preset", "xhs-standard", "-o", "Blocker"], .outputUnavailable, "job.destination_unavailable"),
        (["export", "Badlands.jpg", "Other/Badlands.jpg", "--preset", "xhs-standard", "-o", "Exports", "--overwrite"],
         .outputUnavailable, "request.duplicate_output"),
    ] as [([String], PhotoFrameExitCode, String)])
    func failures(_ arguments: [String], _ status: PhotoFrameExitCode, _ code: String) async throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 1200, height: 800)
        try box.photo("Other/Badlands.jpg", width: 1200, height: 800)
        try Data([0, 0, 0, 0x18] + Array("ftypheic".utf8)).write(to: box.root.appending(path: "Phone.heic"))
        try Data("text".utf8).write(to: box.root.appending(path: "Fake.png"))
        try Data().write(to: box.root.appending(path: "Blocker"))

        let result = await runCLI(arguments + ["--json"], in: box.root)
        #expect(result.status == status.rawValue, "\(result.stderr.value)")
        let json = try result.stdout.json()
        #expect(json["ok"] as? Bool == false)
        #expect(json["exitCode"] as? Int == Int(status.rawValue))
        #expect((json["error"] as? [String: Any])?["code"] as? String == code)
        #expect(result.stderr.value.contains(code))
        #expect(!FileManager.default.fileExists(atPath: box.exports.path))
    }

    @Test("拒绝覆盖不是本软件导出的目录：退出码 5，原目录不动")
    func overwriteRefused() async throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 1200, height: 800)
        let mine = box.exports.appending(path: "Xiaohongshu/Badlands_Standard")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: mine.appending(path: "notes.txt"))
        let result = await runCLI(["export", "Badlands.jpg", "--preset", "xhs-standard", "-o", "Exports", "--overwrite"], in: box.root)
        #expect(result.status == PhotoFrameExitCode.outputUnavailable.rawValue)
        #expect(result.stderr.value.contains("export.overwrite_refused"))
        #expect(box.tree() == ["Xiaohongshu", "Xiaohongshu/Badlands_Standard", "Xiaohongshu/Badlands_Standard/notes.txt"])
    }

    @Test("任务失败：退出码 6，JSON 里有错误码，其余任务照常完成")
    func jobFailure() async throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 1200, height: 800)
        let result = await runCLI(["export", "Badlands.jpg", "--preset", "xhs-standard", "-o", "Exports", "--json"],
                                  in: box.root, service: serviceFactory(renderer: FailingRenderer()))
        #expect(result.status == PhotoFrameExitCode.jobFailed.rawValue)
        let json = try result.stdout.json()
        #expect(json["ok"] as? Bool == false && json["exitCode"] as? Int == 6)
        let job = try #require((json["jobs"] as? [[String: Any]])?.first)
        #expect(job["status"] as? String == "failed")
        #expect((job["error"] as? [String: Any])?["code"] as? String == "render.decode_failed")
        #expect(result.stderr.value.contains("render.decode_failed"))
        #expect(box.tree().isEmpty)
    }

    @Test("提交期间按 Ctrl-C：中断处理已经登记（信号处理不会直接退出），提交后取消任务，退出码 130")
    func interruptDuringSubmit() async throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 1200, height: 800)
        let interrupts = InterruptMonitor()
        let handledAtSubmit = Locked<Bool?>(nil)
        let factory: CLIEnvironment.ServiceFactory = { options throws(ApplicationError) in
            HookedService(try serviceFactory(renderer: HoldingRenderer())(options)) { _ in
                // 信号处理按 hasHandlers 决定：有处理就取消任务，没有就立即 _exit(130)（留下临时目录）。
                handledAtSubmit.value = interrupts.hasHandlers
                interrupts.trigger()
            }
        }
        let result = await runCLI(["export", "Badlands.jpg", "--preset", "xhs-standard", "--preset", "douyin-panorama", "-o", "Exports", "--json"],
                                  in: box.root, interrupts: interrupts, service: factory)
        #expect(handledAtSubmit.value == true)
        #expect(result.status == PhotoFrameExitCode.interrupted.rawValue, "\(result.stderr.value)")
        let jobs = try #require(try result.stdout.json()["jobs"] as? [[String: Any]])
        #expect(jobs.count == 2 && jobs.allSatisfy { $0["status"] as? String == "canceled" })
        #expect(box.tree().isEmpty, "\(box.tree())")
    }

    @Test("读预设时的警告：--json 时也写到 stderr（与不加 --json 时相同），stdout 的 JSON 不变")
    func presetWarningsWithJSON() async throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 1200, height: 800)
        let preset = ExportPreset(
            name: "Spare Slot", canvas: CanvasSettings(width: 800, height: 800, background: PresetColor(hex: "#808080"), minMarginPx: 40, mode: .fit),
            assetSlots: [AssetSlot(slotId: "spare", required: false, acceptedFormats: [.png])], output: OutputSettings(format: .png))
        try PresetPackage.export(preset, to: box.root.appending(path: "Spare.photoframe"))
        let warning = "[preset.unused_slot] assetSlots[0]：素材槽没有被任何图层使用：spare"
        let export = ["export", "Badlands.jpg", "--preset", "Spare.photoframe", "-o", "Exports", "--dry-run"]

        let text = await runCLI(export, in: box.root)
        #expect(text.status == 0, "\(text.stderr.value)")
        #expect(text.stderr.lines.contains("warning: Spare Slot: \(warning)"))
        let json = await runCLI(export + ["--json"], in: box.root)
        #expect(json.status == 0, "\(json.stderr.value)")
        #expect(json.stderr.lines.contains("warning: Spare Slot: \(warning)"))
        #expect(try json.stdout.json()["valid"] as? Bool == true)

        let get = await runCLI(["preset", "get", "Spare.photoframe", "--json"], in: box.root)
        #expect(get.status == 0, "\(get.stderr.value)")
        #expect(get.stderr.lines == ["warning: \(warning)"])
        #expect((try get.stdout.json()["value"] as? [String: Any])?["name"] as? String == "Spare Slot")
        let plain = await runCLI(["preset", "get", "Spare.photoframe", "name"], in: box.root)
        #expect(plain.stderr.lines == ["warning: \(warning)"])
        #expect(plain.stdout.value == "\"Spare Slot\"\n")
    }

    @Test("Ctrl-C：取消任务、清理临时目录，退出码 130")
    func interrupt() async throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 1200, height: 800)
        try box.photo("Mesa.jpg", width: 1200, height: 800)
        let interrupts = InterruptMonitor()
        // 第一个任务进入 rendering（临时目录已创建）时模拟按下 Ctrl-C。
        let stderr = Capture { line in if line.hasSuffix(": rendering") { interrupts.trigger() } }
        let result = await runCLI(
            ["export", "Badlands.jpg", "Mesa.jpg", "--preset", "xhs-standard", "--preset", "douyin-panorama", "-o", "Exports", "--json", "--jobs", "1"],
            in: box.root, interrupts: interrupts, stderr: stderr, service: serviceFactory(renderer: HoldingRenderer()))
        #expect(result.status == PhotoFrameExitCode.interrupted.rawValue)
        let jobs = try #require(try result.stdout.json()["jobs"] as? [[String: Any]])
        #expect(jobs.count == 4)
        #expect(jobs.allSatisfy { $0["status"] as? String == "canceled" })
        #expect(box.tree().isEmpty, "临时目录已删除，没有发布任何东西：\(box.tree())")
    }
}
