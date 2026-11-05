import ArgumentParser
import Foundation
import Testing
@testable import PhotoFrameCLI

@Suite("参数解析与退出码")
struct ParsingTests {
    @Test("export 的参数")
    func exportArguments() throws {
        let command = try #require(try RootCommand.parseAsRoot([
            "export", "a.tif", "b.jpg", "--preset", "instagram-panorama", "--preset", "./My.photoframe",
            "-o", "out", "--overwrite", "--dry-run", "--json", "--jobs", "2", "-q",
        ]) as? ExportCommand)
        #expect(command.images == ["a.tif", "b.jpg"])
        #expect(command.preset == ["instagram-panorama", "./My.photoframe"])
        #expect(command.output == "out")
        #expect(command.overwrite && command.dryRun && command.json && command.quiet)
        #expect(command.jobs == 2)
        #expect(command.assumeProfile == nil)
        for (value, expected) in [
            ("srgb", AssumedProfile.srgb), ("display-p3", .displayP3), ("adobe-rgb", .adobeRGB), ("prophoto-rgb", .proPhotoRGB), ("rec2020", .rec2020),
        ] {
            let parsed = try #require(try RootCommand.parseAsRoot(
                ["export", "a.png", "--preset", "x", "-o", "o", "--assume-profile", value]) as? ExportCommand)
            #expect(parsed.assumeProfile == expected)
        }

        let defaults = try #require(try RootCommand.parseAsRoot(["export", "a.tif", "--preset", "x", "--output", "o"]) as? ExportCommand)
        #expect(!defaults.overwrite && !defaults.dryRun && !defaults.json && !defaults.quiet && defaults.jobs == nil)
    }

    @Test("preview / image inspect / preset list 的参数")
    func otherArguments() throws {
        let preview = try #require(try RootCommand.parseAsRoot([
            "preview", "a.tif", "--preset", "xhs-panorama", "-o", "p", "--max-edge", "640", "--page", "0", "--page", "2",
        ]) as? PreviewCommand)
        #expect(preview.maxEdge == 640 && preview.pages == [0, 2] && !preview.overwrite && preview.assumeProfile == nil)
        let inspect = try #require(try RootCommand.parseAsRoot(["image", "inspect", "a.tif", "--json"]) as? ImageCommand.InspectCommand)
        #expect(inspect.image == "a.tif" && inspect.json)
        let list = try #require(try RootCommand.parseAsRoot(["preset", "list"]) as? PresetCommand.ListCommand)
        #expect(!list.json)
    }

    @Test("export / preview 的手填元数据（D-135）：只传填了的字段，值原样保留")
    func metadataArguments() async throws {
        let export = try #require(try RootCommand.parseAsRoot([
            "export", "scan.tif", "--preset", "x", "-o", "o", "--film", "Kodak Portra 400", "--camera-make", "Mamiya",
            "--camera-model", "7 II", "--aperture", "8", "--shutter", "1/250", "--iso", "400",
        ]) as? ExportCommand)
        #expect(export.metadata.overrides == [
            "film": "Kodak Portra 400", "make": "Mamiya", "model": "7 II", "aperture": "8", "shutter": "1/250", "iso": "400",
        ])
        // 空的（只有空白的也算）不传，留给 EXIF；填了的不改写（单位由渲染层补）
        let preview = try #require(try RootCommand.parseAsRoot([
            "preview", "scan.tif", "--preset", "x", "-o", "p", "--film", " Ilford HP5 Plus", "--iso", "", "--aperture", "  ",
            "--shutter", "1/60s",
        ]) as? PreviewCommand)
        #expect(preview.metadata.overrides == ["film": " Ilford HP5 Plus", "shutter": "1/60s"])
        let none = try #require(try RootCommand.parseAsRoot(["export", "a.tif", "--preset", "x", "-o", "o"]) as? ExportCommand)
        #expect(none.metadata.overrides.isEmpty)
        let noPreview = try #require(try RootCommand.parseAsRoot(["preview", "a.tif", "--preset", "x", "-o", "o"]) as? PreviewCommand)
        #expect(noPreview.metadata.overrides.isEmpty)

        let box = try Sandbox()
        for command in ["export", "preview"] {
            let help = await runCLI([command, "--help"], in: box.root)
            #expect(help.status == 0)
            for option in ["--film", "--camera-make", "--camera-model", "--aperture", "--shutter", "--iso", "优先于源图的", "胶片扫描"] {
                #expect(help.stdout.value.contains(option), "\(command) --help 缺少 \(option)")
            }
        }
    }

    @Test("用法错误：退出码 2，信息只写 stderr", arguments: [
        ["export", "a.tif", "--preset", "x"],                    // 缺 --output
        ["export", "a.tif", "-o", "out"],                        // 缺 --preset
        ["export", "--preset", "x", "-o", "out"],                // 缺图片
        ["export", "a.tif", "--preset", "x", "-o", "o", "--jobs", "0"],
        ["preview", "a.tif", "--preset", "x", "-o", "o", "--max-edge", "0"],
        ["export", "a.png", "--preset", "x", "-o", "o", "--assume-profile", "prophoto"],
        ["frobnicate"],
        ["asset", "import", "x.png"],                            // 缺 --category
        ["asset", "import", "x.png", "--category", "logo"],
        ["export", "a.png", "--preset", "x", "-o", "o", "--bind", "noequals"],
        ["export", "a.png", "--preset", "x", "-o", "o", "--film"],         // 缺值
        ["preview", "a.png", "--preset", "x", "-o", "o", "--lens", "50mm"], // D-135 只有六项
        ["mcp", "serve", "--max-active-jobs", "0"],
        ["preset", "set", "x", "canvas.minMarginPx"],            // 路径和值不成对
    ])
    func usageErrors(_ arguments: [String]) async throws {
        let box = try Sandbox()
        let result = await runCLI(arguments, in: box.root)
        #expect(result.status == PhotoFrameExitCode.usage.rawValue)
        #expect(result.stdout.value.isEmpty)
        #expect(!result.stderr.value.isEmpty)
    }

    @Test("帮助写 stdout、退出码 0")
    func help() async throws {
        let box = try Sandbox()
        let root = await runCLI(["--help"], in: box.root)
        #expect(root.status == 0)
        for name in ["export", "image", "preset", "preview", "mcp"] { #expect(root.stdout.value.contains(name)) }
        #expect(root.stderr.value.isEmpty)

        #expect(root.stdout.value.contains("asset"))
        let preset = await runCLI(["preset", "--help"], in: box.root)
        for name in ["list", "get", "set", "import", "export", "duplicate", "rename", "move", "delete"] { #expect(preset.stdout.value.contains(name)) }
        let asset = await runCLI(["asset", "--help"], in: box.root)
        for name in ["list", "import", "rename", "set-category", "delete", "bind", "unbind", "bindings"] { #expect(asset.stdout.value.contains(name)) }

        let version = await runCLI(["--version"], in: box.root)
        #expect(version.status == 0 && version.stdout.value.contains(PhotoFrameCLI.version))
    }

    @Test("退出码表稳定")
    func exitCodeTable() {
        #expect(PhotoFrameExitCode.allCases.map(\.rawValue) == [0, 1, 2, 3, 4, 5, 6, 130])
        #expect(PhotoFrameExitCode(for: .init(code: "source.not_found", message: "")) == .notFound)
        #expect(PhotoFrameExitCode(for: .init(code: "library.preset_not_found", message: "")) == .notFound)
        #expect(PhotoFrameExitCode(for: .init(code: "asset.not_found", message: "")) == .notFound)
        #expect(PhotoFrameExitCode(for: .init(code: "preset.export_exists", message: "")) == .outputUnavailable)
        #expect(PhotoFrameExitCode(for: .init(code: "library.ambiguous_preset", message: "")) == .invalidInput)
        #expect(PhotoFrameExitCode(for: .init(code: "library.builtin_read_only", message: "")) == .invalidInput)
        #expect(PhotoFrameExitCode(for: .init(code: "preset.file_not_found", message: "")) == .notFound)
        #expect(PhotoFrameExitCode(for: .init(code: "export.overwrite_refused", message: "")) == .outputUnavailable)
        #expect(PhotoFrameExitCode(for: .init(code: "job.destination_unavailable", message: "")) == .outputUnavailable)
        #expect(PhotoFrameExitCode(for: .init(code: "request.duplicate_output", message: "")) == .outputUnavailable)
        #expect(PhotoFrameExitCode(for: .init(code: "render.decode_failed", message: "")) == .invalidInput)
        #expect(PhotoFrameExitCode(for: .init(code: "slot.missing_required", message: "")) == .invalidInput)
        #expect(PhotoFrameExitCode(for: .init(code: "archive.not_zip", message: "")) == .invalidInput)
        #expect(PhotoFrameExitCode(for: .init(code: "service.unavailable", message: "")) == .internalError)
    }
}
