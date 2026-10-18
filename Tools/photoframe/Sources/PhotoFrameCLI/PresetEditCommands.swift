import ArgumentParser
import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameStorage

// 逐项查看与修改预设内容（D-93）。CLI `preset get` / `preset set` 与 MCP `get_preset` / `update_preset`
// 用同一种字段路径（`PresetFieldPath`）和同一套校验（`PresetLibrary.edit`：与导入相同的检查，原子写入）。

/// 预设内容（与 `manifest.json` 相同）或其中一个字段。
enum PresetContent {
    static func manifest(_ preset: ExportPreset) throws(ApplicationError) -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: PresetSchema.encode(preset))
        } catch {
            throw ApplicationError(code: "cli.internal", message: "编码预设失败：\(error)")
        }
    }

    static func value(_ preset: ExportPreset, at path: String?) throws(ApplicationError) -> JSONValue {
        let manifest = try manifest(preset)
        guard let path else { return manifest }
        do {
            return try PresetEditor.value(at: PresetFieldPath(parsing: path), in: manifest)
        } catch {
            throw ApplicationError(error)
        }
    }

    static func path(_ text: String) throws(ApplicationError) -> PresetFieldPath {
        do {
            return try PresetFieldPath(parsing: text)
        } catch {
            throw ApplicationError(error)
        }
    }
}

extension ApplicationError {
    init(_ error: PresetEditError) {
        self.init(code: error.code, message: error.message, hint: error.hint)
    }
}

struct PresetGetJSON: Encodable {
    var preset: PresetJSON
    /// 请求的字段路径；整份预设时没有。
    var path: String?
    var value: JSONValue
}

struct PresetUpdateJSON: Encodable {
    var preset: PresetJSON
    /// 修改过的字段路径，按应用顺序。
    var changed: [String]
    var warnings: [WarningJSON]
}

extension PresetCommand {
    /// `photoframe preset get <preset> [<path>] [--json]`
    struct GetCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "输出预设内容（与 manifest.json 相同的 JSON），或其中一个字段。",
            discussion: """
                字段路径（D-93）：canvas.minMarginPx、layers[0].opacity、layers[exif].text.fontSizePx（方括号里不是数字时按 layerId / slotId 找）。
                不带 --json 时 stdout 只有这个 JSON 值。
                """)

        @Argument(help: ArgumentHelp("预设：presetId、名称、短名称或 .photoframe 文件。", valueName: "预设"))
        var preset: String

        @Argument(help: ArgumentHelp("字段路径；省略时输出整份预设。", valueName: "路径"))
        var path: String?

        @Flag(help: "stdout 输出 JSON（外层带 preset、path、value）。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "preset get", json: json)
            let service = try ctx.makeService()
            let reference = ctx.presetReference(preset)
            let entry = try await ctx.call { () async throws(ApplicationError) in try await service.resolvePreset(reference) }
            let value = try await ctx.call { () async throws(ApplicationError) in try PresetContent.value(entry.preset, at: path) }
            // 读预设时的警告不在结果 JSON 里：--json 时也写到 stderr。
            ctx.warn(entry.warnings, evenWithJSON: true)
            if json {
                let summary = CatalogPresetSummary(entry, catalog: try? PlatformCatalogStore.builtIn())
                ctx.emit(PresetGetJSON(preset: PresetJSON(summary), path: path, value: value))
            } else {
                ctx.env.stdout.line(JSONOutput.encode(value))
            }
        }
    }

    /// `photoframe preset set <preset> [<path> <value>]... [--unset <path>]... [--json]`
    struct SetCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "逐项修改库里的预设（D-93）。",
            discussion: """
                例：photoframe preset set "My IG" canvas.minMarginPx 80 canvas.background.hex '#FFFFFF' --unset layers[exif]
                值先按 JSON 解析（80、true、[0,16]、{"…": …}），解析不了时当作字符串；要写字符串 "80" 用 '"80"'。
                layers[+] 在数组末尾追加。先按顺序应用全部设置，再应用 --unset。
                改完的预设要通过与导入相同的检查，才原子写入；任何一项不通过都不修改。内置预设只读，先 preset duplicate。
                """)

        @Argument(help: ArgumentHelp("预设：presetId、名称或短名称。", valueName: "预设"))
        var preset: String

        /// `.allUnrecognized`：负数（`-1`、`-0.5`）也是值，不当成选项；`--unset`、`--json` 照常可以写在任何位置。
        @Argument(parsing: .allUnrecognized, help: ArgumentHelp("成对的字段路径和值。", valueName: "路径 值"))
        var assignments: [String] = []

        @Option(name: .customLong("unset"), help: ArgumentHelp("删除字段或数组元素。可重复。", valueName: "路径"))
        var unset: [String] = []

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func validate() throws {
            guard assignments.count.isMultiple(of: 2) else { throw ValidationError("路径和值要成对出现。") }
            // 字段路径不会以 - 开头：在路径的位置上出现的是写错的选项（值可以是负数）。
            if let option = stride(from: 0, to: assignments.count, by: 2).lazy.map({ assignments[$0] }).first(where: { $0.hasPrefix("-") }) {
                throw ValidationError("未知选项：\(option)")
            }
            guard !assignments.isEmpty || !unset.isEmpty else { throw ValidationError("至少需要一项修改。") }
        }

        func run() async throws {
            let ctx = CommandContext(command: "preset set", json: json)
            let service = try ctx.makeService()
            var edits: [PresetEdit] = []
            for i in stride(from: 0, to: assignments.count, by: 2) {
                let path = try await ctx.call { () throws(ApplicationError) in try PresetContent.path(assignments[i]) }
                edits.append(.set(path, Self.parseValue(assignments[i + 1])))
            }
            for text in unset {
                edits.append(.remove(try await ctx.call { () throws(ApplicationError) in try PresetContent.path(text) }))
            }
            let reference = ctx.presetReference(preset)
            let changes = edits
            let result = try await ctx.call { () async throws(ApplicationError) in
                try await service.updatePreset(reference, edits: changes)
            }
            if json {
                ctx.emit(PresetUpdateJSON(preset: PresetJSON(result.preset), changed: edits.map(\.path.description),
                                          warnings: result.warnings.map(WarningJSON.init)))
            } else {
                ctx.warn(result.warnings)
                ctx.env.stdout.line("\(result.preset.presetId.uuidString)  \(result.preset.name)")
            }
        }

        /// 先按 JSON 解析（允许顶层是数字、布尔、null 等），失败时当作字符串。
        static func parseValue(_ text: String) -> JSONValue {
            (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
        }
    }
}
