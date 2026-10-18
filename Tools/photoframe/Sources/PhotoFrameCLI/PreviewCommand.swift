import ArgumentParser
import Foundation
import PhotoFrameApplication
import PhotoFrameCore

extension OutputSettings.DynamicRange: @retroactive ExpressibleByArgument {}

/// `photoframe preview <图片> --preset … --output <目录>`：与 GUI 预览区相同的预览（§6.3「预览 ≈ 导出」、§11.2
/// `renderPreview`），写成 sRGB PNG，供脚本或 AI 客户端查看版式。`--dynamic-range hdr` 时，导出写 HDR 的页
/// 写成带 gain map 的 JPEG（D-106）。
///
/// 文件名 `<源文件名>_<Standard|Panorama>_preview_00_Cover.png`（HDR 页 `.jpg`）、`…_01_Slide.png`。目标文件已存在时报错，
/// `--overwrite` 时替换。预览文件不是成品：长边受 `--max-edge` 限制，不带元数据。
struct PreviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: "渲染预览图（与导出同一条管线，按预览尺寸缩小）。",
        discussion: "stdout 每行一个写出的文件路径（--json 时为结构化结果）。")

    @Argument(help: ArgumentHelp("源图（JPEG / PNG / TIFF）。", valueName: "图片"))
    var image: String

    @Option(name: .long, help: ArgumentHelp("预设：presetId、名称或 .photoframe 文件。", valueName: "id|名称|文件"))
    var preset: String

    @Option(name: [.short, .long], help: ArgumentHelp("写预览文件的目录，不存在时创建。", valueName: "目录"))
    var output: String

    @Option(name: .customLong("max-edge"), help: ArgumentHelp("预览页长边上限（像素），不超过导出尺寸。", valueName: "px"))
    var maxEdge = 1200

    @Option(name: .customLong("page"), help: ArgumentHelp("只预览这些轮播页（0 = 封面，切片 k 为 k + 1）。可重复。", valueName: "n"))
    var pages: [Int] = []

    @Option(name: .customLong("dynamic-range"), help: ArgumentHelp(
        "sdr：sRGB PNG（默认）；hdr：导出写 HDR 的页写成带 gain map 的 JPEG，其余页仍是 PNG。", valueName: "sdr|hdr"))
    var dynamicRange: OutputSettings.DynamicRange = .sdr

    @Option(name: .customLong("assume-profile"), help: AssumedProfile.help)
    var assumeProfile: AssumedProfile?

    @Option(name: .customLong("bind"), help: JobBinding.help)
    var bindings: [JobBinding] = []

    @Flag(help: "替换已存在的同名预览文件。")
    var overwrite = false

    @Flag(help: "stdout 输出 JSON。")
    var json = false

    func validate() throws {
        guard maxEdge > 0 else { throw ValidationError("--max-edge 应为正整数。") }
        guard pages.allSatisfy({ $0 >= 0 }) else { throw ValidationError("--page 不能为负数。") }
        // 预览的颜色模式只有 sdr / hdr；预设的 auto（D-125）不是预览模式。
        guard dynamicRange != .auto else { throw ValidationError("--dynamic-range 只能是 sdr、hdr。") }
    }

    func run() async throws {
        let ctx = CommandContext(command: "preview", json: json)
        let env = ctx.env
        let service = try ctx.makeService()

        let assetBindings = try await ctx.resolveBindings(bindings, service: service)
        let entry: CatalogPreset
        let source: PhotoSource
        let preview: ExportPreview
        do {
            entry = try await service.resolvePreset(PresetReference(argument: preset, relativeTo: env.currentDirectory))
            source = try await service.addSource(env.resolvePath(image))
            preview = try await service.renderPreview(ExportPreviewRequest(
                source: .id(source.sourceId), preset: entry.preset,
                options: PreviewOptions(maxLongEdge: maxEdge, pages: pages.isEmpty ? nil : Set(pages), dynamicRange: dynamicRange),
                assetBindings: assetBindings, sourceColorOverride: assumeProfile?.override))
        } catch {
            throw ctx.fail(error)
        }

        let targets: [URL]
        do {
            targets = try PreviewFiles.write(preview, source: source, preset: entry.preset, to: env.resolvePath(output), overwrite: overwrite)
        } catch {
            throw ctx.fail(error)
        }

        if json {
            ctx.emit(PreviewJSON(
                source: source.fileURL.path,
                preset: PresetRefJSON(presetId: entry.preset.presetId.uuidString, name: entry.preset.name),
                files: zip(preview.pages, targets).map { PreviewFileJSON($0, path: $1.path) },
                positions: preview.roles.map(\.carouselPosition),
                warnings: (entry.warnings + preview.warnings).map(WarningJSON.init)))
        } else {
            ctx.warn(entry.warnings + preview.warnings)
            for url in targets { env.stdout.line(url.path) }
        }
    }
}

/// 把预览页写成文件（CLI `preview` 与 MCP `preview_export` 共用，D-74）：SDR 页 PNG，HDR 页 gain map JPEG（D-106）。
enum PreviewFiles {
    /// 先检查全部目标，任何一个已存在（且没有 `overwrite`）就什么都不写。返回写出的文件，与 `preview.pages` 一一对应。
    static func write(
        _ preview: ExportPreview, source: PhotoSource, preset: ExportPreset, to directory: URL, overwrite: Bool
    ) throws(ApplicationError) -> [URL] {
        let workName = OutputNaming().workName(source: source, preset: preset)
        let targets = preview.pages.map { page in
            directory.appending(path: "\(workName)_preview_" + OutputNaming.fileName(for: page.role, format: page.format, outputCount: OutputNaming.positionCount(of: preview.roles)))
        }
        if !overwrite, let existing = targets.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            throw ApplicationError(code: "preview.file_exists", message: "预览文件已存在：\(existing.path)",
                                   hint: "换一个输出目录，或加 --overwrite 替换")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (page, url) in zip(preview.pages, targets) {
                try page.data.write(to: url, options: .atomic)
            }
        } catch {
            throw ApplicationError(code: "preview.write_failed", message: "无法写入预览文件：\(error.localizedDescription)")
        }
        return targets
    }
}
