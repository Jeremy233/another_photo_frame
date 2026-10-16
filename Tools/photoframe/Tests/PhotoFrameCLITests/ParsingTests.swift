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
        for (value, expected) in [("srgb", AssumedProfile.srgb), ("display-p3", .displayP3), ("adobe-rgb", .adobeRGB)] {
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
        ["mcp", "serve"],
    ])
    func usageErrors(_ arguments: [String]) async throws {
        let box = try Sandbox()
        let result = await runCLI(arguments, in: box.root)
        #expect(result.status == PhotoFrameExitCode.usage.rawValue)
        #expect(result.stdout.value.isEmpty)
        #expect(!result.stderr.value.isEmpty)
    }

    @Test("帮助写 stdout、退出码 0；不列出这一版没有的命令")
    func help() async throws {
        let box = try Sandbox()
        let root = await runCLI(["--help"], in: box.root)
        #expect(root.status == 0)
        for name in ["export", "image", "preset", "preview"] { #expect(root.stdout.value.contains(name)) }
        #expect(!root.stdout.value.contains("mcp"))
        #expect(root.stderr.value.isEmpty)

        #expect(root.stdout.value.contains("asset"))
        let preset = await runCLI(["preset", "--help"], in: box.root)
        for name in ["list", "import", "export", "duplicate", "rename", "delete"] { #expect(preset.stdout.value.contains(name)) }
        let asset = await runCLI(["asset", "--help"], in: box.root)
        for name in ["list", "import", "rename", "delete", "bind", "unbind", "bindings"] { #expect(asset.stdout.value.contains(name)) }

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
