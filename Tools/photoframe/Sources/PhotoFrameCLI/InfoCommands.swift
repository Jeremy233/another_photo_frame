import ArgumentParser
import Foundation
import PhotoFrameApplication

/// `photoframe image …`
struct ImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image", abstract: "检查源图。", subcommands: [InspectCommand.self])

    /// `photoframe image inspect <图片> [--json]`
    struct InspectCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "读取源图的尺寸、方向、位深、ICC、HDR 判定和 EXIF 摘要。",
            discussion: "GPS 和作者信息只报告有无，不输出内容。")

        @Argument(help: ArgumentHelp("源图（JPEG / PNG / TIFF）。", valueName: "图片"))
        var image: String

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "image inspect", json: json)
            let service = try ctx.makeService()
            let info: SourceInspection
            do {
                info = try await service.inspectSource(.file(ctx.env.resolvePath(image)))
            } catch {
                throw ctx.fail(error)
            }
            if json {
                ctx.emit(InspectJSON(info))
                return
            }
            ctx.warn(info.warnings)
            let out = ctx.env.stdout
            out.line("path: \(info.fileURL.path)")
            if let size = info.fileSizeBytes { out.line("fileSize: \(size)") }
            out.line("format: \(info.format)")
            out.line("pixelSize: \(info.pixelSize.width)x\(info.pixelSize.height)")
            out.line("orientation: \(info.orientation)")
            out.line("displaySize: \(info.displaySize.width)x\(info.displaySize.height)")
            out.line("bitDepth: \(info.bitDepth)\(info.isFloat ? " float" : "")")
            out.line("alpha: \(info.hasAlpha)")
            out.line("colorProfile: \(info.colorProfile.description) (\(info.colorProfile.origin))")
            out.line("hdr: \(info.hdr.kind)\(info.hdr.headroom.map { String(format: " headroom %.2f", $0) } ?? "")")
            for key in info.metadata.keys.sorted() { out.line("exif.\(key): \(info.metadata[key]!)") }
            out.line("gps: \(info.hasGPS ? "present" : "none")")
            out.line("authorOrCopyright: \(info.hasAuthorOrCopyright ? "present" : "none")")
        }
    }
}

/// `photoframe preset …`
struct PresetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preset", abstract: "查看预设。", subcommands: [ListCommand.self])

    /// `photoframe preset list [--json]`
    struct ListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "列出内置预设。",
            discussion: "第一列是可以直接传给 --preset 的短名称。")

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "preset list", json: json)
            let service = try ctx.makeService()
            let presets: [PresetListing]
            do {
                presets = try await service.listPresets()
            } catch {
                throw ctx.fail(error)
            }
            if json {
                ctx.emit(PresetListJSON(presets: presets.map(PresetJSON.init)))
                return
            }
            let rows = presets.map { p in
                [p.slug, p.name, p.platformName ?? p.platform ?? "-", "\(p.canvas.width)x\(p.canvas.height)",
                 p.panorama == nil ? "standard" : "panorama", p.presetId.uuidString]
            }
            let widths = (0..<6).map { column in rows.map { $0[column].count }.max() ?? 0 }
            for row in rows {
                let cells = row.enumerated().map { i, cell in
                    i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
                }
                ctx.env.stdout.line(cells.joined(separator: "  "))
            }
        }
    }
}
