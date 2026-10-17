import ArgumentParser
import Foundation
import PhotoFrameApplication
import PhotoFrameStorage

// 预设库与素材库（§8、§11.3、D-08：GUI 里对预设和素材能做的事，命令行都能做）。
// 库的根目录按 LibraryLocation.defaultRoot() 的规则选（D-78、D-124），GUI、CLI、MCP 看到同一个库；环境变量 PHOTOFRAME_LIBRARY 可以改。

extension CommandContext {
    /// 调用服务；ApplicationError 按退出码表结束命令。
    func call<T>(_ body: () async throws(ApplicationError) -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw fail(error)
        }
    }

    func presetReference(_ argument: String) -> PresetReference {
        PresetReference(argument: argument, relativeTo: env.currentDirectory)
    }
}

// MARK: - preset

/// `photoframe preset …`
struct PresetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preset", abstract: "管理预设库（内置、用户保存、导入）。",
        subcommands: [ListCommand.self, GetCommand.self, SetCommand.self, ImportCommand.self, ExportCommand.self,
                      DuplicateCommand.self, RenameCommand.self, MoveCommand.self, DeleteCommand.self])

    /// `photoframe preset list [--json]`
    struct ListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "列出预设：内置、用户保存、导入。",
            discussion: "每行：短名称、名称、来源、平台、画布、standard/panorama、presetId。短名称可以直接传给 --preset。")

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "preset list", json: json)
            let service = try ctx.makeService()
            let list = try await ctx.call { () async throws(ApplicationError) in try await service.listPresets() }
            if json {
                ctx.emit(PresetListJSON(presets: list.presets.map(PresetJSON.init), warnings: list.warnings.map(WarningJSON.init)))
                return
            }
            ctx.warn(list.warnings)
            let rows = list.presets.map { p in
                [p.slug, p.name, p.origin.kind, p.platformName ?? p.platform ?? "-", "\(p.canvas.width)x\(p.canvas.height)",
                 p.panorama == nil ? "standard" : "panorama", p.presetId.uuidString]
            }
            ctx.printTable(rows)
        }
    }

    /// `photoframe preset import <file> [--replace] [--json]`
    struct ImportCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "把 .photoframe 导入预设库（「导入」组）。",
            discussion: "presetId 与已有预设相同时默认另存为副本（新 ID，名称加 Copy，D-39、D-80）；--replace 时替换同 ID 的预设（内置预设不能替换）。")

        @Argument(help: ArgumentHelp(".photoframe 文件。", valueName: "文件"))
        var file: String

        @Flag(help: "ID 冲突时替换已有预设，而不是另存为副本。")
        var replace = false

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "preset import", json: json)
            let service = try ctx.makeService()
            let url = ctx.env.resolvePath(file)
            let result = try await ctx.call { () async throws(ApplicationError) in
                try await service.importPreset(from: url, replace: replace)
            }
            if json {
                ctx.emit(PresetResultJSON(preset: PresetJSON(result.preset), conflictResolution: result.conflictResolution,
                                          warnings: result.warnings.map(WarningJSON.init)))
                return
            }
            ctx.warn(result.warnings)
            if result.conflictResolution == "saveAsCopy" { ctx.log("presetId 与已有预设相同，已另存为副本「\(result.preset.name)」") }
            ctx.env.stdout.line("\(result.preset.presetId.uuidString)  \(result.preset.name)")
        }
    }

    /// `photoframe preset export <preset> --output <file> [--overwrite] [--json]`
    struct ExportCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "把预设导出为 .photoframe（只含布局，不含素材和本地路径）。",
            discussion: "--output 是已存在的目录时，文件名取预设名称。目标文件已存在时只有 --overwrite 才替换。")

        @Argument(help: ArgumentHelp("预设：presetId、名称或短名称。", valueName: "预设"))
        var preset: String

        @Option(name: [.short, .long], help: ArgumentHelp("目标文件或目录。", valueName: "文件"))
        var output: String

        @Flag(help: "替换已存在的文件。")
        var overwrite = false

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "preset export", json: json)
            let service = try ctx.makeService()
            let reference = ctx.presetReference(preset)
            let entry = try await ctx.call { () async throws(ApplicationError) in try await service.resolvePreset(reference) }
            var target = ctx.env.resolvePath(output)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                target = target.appending(path: PresetLibrary.suggestedFileName(for: entry.preset.name))
            }
            let destination = target
            try await ctx.call { () async throws(ApplicationError) in
                try await service.exportPreset(reference, to: destination, overwrite: overwrite)
            }
            if json {
                ctx.emit(PresetRefResultJSON(
                    preset: PresetRefJSON(presetId: entry.preset.presetId.uuidString, name: entry.preset.name), path: destination.path))
            } else {
                ctx.env.stdout.line(destination.path)
            }
        }
    }

    /// `photoframe preset duplicate <preset> [--name <名称>] [--json]`
    struct DuplicateCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "duplicate",
            abstract: "复制预设（内置预设也可以），放进「用户保存」组。",
            discussion: "默认名称「原名 Copy」（D-79）；预设本地绑定一起复制（D-84）。")

        @Argument(help: ArgumentHelp("预设：presetId、名称或短名称。", valueName: "预设"))
        var preset: String

        @Option(help: ArgumentHelp("副本名称。", valueName: "名称"))
        var name: String?

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "preset duplicate", json: json)
            let service = try ctx.makeService()
            let reference = ctx.presetReference(preset)
            let copy = try await ctx.call { () async throws(ApplicationError) in try await service.duplicatePreset(reference, name: name) }
            ctx.printPreset(copy)
        }
    }

    /// `photoframe preset rename <preset> <新名称> [--json]`
    struct RenameCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rename", abstract: "重命名库里的预设（内置预设不能改）。")

        @Argument(help: ArgumentHelp("预设：presetId、名称或短名称。", valueName: "预设"))
        var preset: String

        @Argument(help: ArgumentHelp("新名称。", valueName: "新名称"))
        var newName: String

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "preset rename", json: json)
            let service = try ctx.makeService()
            let reference = ctx.presetReference(preset)
            let renamed = try await ctx.call { () async throws(ApplicationError) in try await service.renamePreset(reference, to: newName) }
            ctx.printPreset(renamed)
        }
    }

    /// 可移动到的分组（D-81、D-94）。
    enum Group: String, CaseIterable, ExpressibleByArgument {
        case user
        case imported

        var origin: PresetOrigin {
            switch self {
            case .user: .user
            case .imported: .imported
            }
        }
    }

    /// `photoframe preset move <preset> --to user|imported [--json]`
    struct MoveCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "move", abstract: "在「用户保存」和「导入」两组之间移动预设（D-81、D-94）。",
            discussion: "内容、ID 和时间都不变；已经在目标组时什么也不做。内置预设不能移动（library.builtin_read_only，退出码 4）。")

        @Argument(help: ArgumentHelp("预设：presetId、名称或短名称。", valueName: "预设"))
        var preset: String

        @Option(help: ArgumentHelp("目标分组。", valueName: "user|imported"))
        var to: Group

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "preset move", json: json)
            let service = try ctx.makeService()
            let reference = ctx.presetReference(preset)
            let moved = try await ctx.call { () async throws(ApplicationError) in try await service.movePreset(reference, to: to.origin) }
            ctx.printPreset(moved)
        }
    }

    /// `photoframe preset delete <preset> [--json]`
    struct DeleteCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete", abstract: "删除库里的预设及其本地绑定（内置预设不能删）。")

        @Argument(help: ArgumentHelp("预设：presetId、名称或短名称。", valueName: "预设"))
        var preset: String

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "preset delete", json: json)
            let service = try ctx.makeService()
            let reference = ctx.presetReference(preset)
            let entry = try await ctx.call { () async throws(ApplicationError) in try await service.resolvePreset(reference) }
            try await ctx.call { () async throws(ApplicationError) in try await service.deletePreset(reference) }
            if json {
                ctx.emit(PresetRefResultJSON(preset: PresetRefJSON(presetId: entry.preset.presetId.uuidString, name: entry.preset.name)))
            } else {
                ctx.env.stdout.line("\(entry.preset.presetId.uuidString)  \(entry.preset.name)")
            }
        }
    }
}

// MARK: - asset

/// 命令行里的素材分组名。
enum AssetCategoryArgument: String, CaseIterable, ExpressibleByArgument {
    case signature
    case watermark
    case cameraBadge = "camera-badge"

    init(_ category: AssetCategory) {
        switch category {
        case .signature: self = .signature
        case .watermark: self = .watermark
        case .cameraBadge: self = .cameraBadge
        }
    }

    var category: AssetCategory {
        switch self {
        case .signature: .signature
        case .watermark: .watermark
        case .cameraBadge: .cameraBadge
        }
    }
}

/// `photoframe asset …`
struct AssetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "asset", abstract: "管理本地素材库（签名、水印、相机贴图）和素材绑定。",
        discussion: "素材引用：assetId，或显示名称（不区分大小写，必须唯一）。",
        subcommands: [ListCommand.self, ImportCommand.self, RenameCommand.self, SetCategoryCommand.self, DeleteCommand.self,
                      BindCommand.self, UnbindCommand.self, BindingsCommand.self])

    /// `photoframe asset list [--category <分组>] [--json]`
    struct ListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "列出素材（不输出文件路径）。",
            discussion: "每行：assetId、名称、分组、格式、尺寸。")

        @Option(help: ArgumentHelp("只列这个分组。", valueName: "signature|watermark|camera-badge"))
        var category: AssetCategoryArgument?

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "asset list", json: json)
            let service = try ctx.makeService()
            let list = await service.listAssets(category: category?.category)
            if json {
                ctx.emit(AssetListJSON(assets: list.assets.map(AssetJSON.init), warnings: list.warnings.map(WarningJSON.init)))
                return
            }
            ctx.warn(list.warnings)
            ctx.printTable(list.assets.map {
                [$0.assetId.uuidString, $0.displayName, AssetCategoryArgument($0.category).rawValue, $0.format.rawValue,
                 "\($0.pixelSize.width)x\($0.pixelSize.height)"]
            })
        }
    }

    /// `photoframe asset import <file> --category <分组> [--name <名称>] [--json]`
    struct ImportCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import", abstract: "校验并把 PNG / 受限 SVG 复制进素材库（D-09、D-85、D-86）。",
            discussion: "内容与库里已有素材相同时仍然导入，只提示（D-88）。stdout 输出新素材的 assetId。")

        @Argument(help: ArgumentHelp("PNG 或 SVG 文件。", valueName: "文件"))
        var file: String

        @Option(help: ArgumentHelp("分组（只用于整理，不限制绑定，D-89）。", valueName: "signature|watermark|camera-badge"))
        var category: AssetCategoryArgument

        @Option(help: ArgumentHelp("显示名称，默认取文件名。", valueName: "名称"))
        var name: String?

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "asset import", json: json)
            let service = try ctx.makeService()
            let url = ctx.env.resolvePath(file)
            let result = try await ctx.call { () async throws(ApplicationError) in
                try await service.importAsset(from: url, category: category.category, name: name)
            }
            if json {
                ctx.emit(AssetResultJSON(asset: AssetJSON(result.asset), duplicateOf: result.duplicateOf.map(\.uuidString),
                                         warnings: result.warnings.map(WarningJSON.init)))
                return
            }
            ctx.warn(result.warnings)
            if !result.duplicateOf.isEmpty {
                ctx.log("note: 库里已有内容相同的素材：\(result.duplicateOf.map(\.uuidString).joined(separator: ", "))")
            }
            ctx.env.stdout.line(result.asset.assetId.uuidString)
        }
    }

    /// `photoframe asset rename <asset> <新名称> [--json]`
    struct RenameCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rename", abstract: "重命名素材。")

        @Argument(help: ArgumentHelp("素材：assetId 或名称。", valueName: "素材"))
        var asset: String

        @Argument(help: ArgumentHelp("新名称。", valueName: "新名称"))
        var newName: String

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "asset rename", json: json)
            let service = try ctx.makeService()
            let info = try await ctx.call { () async throws(ApplicationError) in
                let found = try await service.resolveAsset(asset)
                return try await service.renameAsset(found.assetId, to: newName)
            }
            if json {
                ctx.emit(AssetResultJSON(asset: AssetJSON(info)))
            } else {
                ctx.env.stdout.line("\(info.assetId.uuidString)  \(info.displayName)")
            }
        }
    }

    /// `photoframe asset set-category <asset> <分组> [--json]`
    struct SetCategoryCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-category", abstract: "改素材分组（D-95）。",
            discussion: "分组只用于整理，不影响能绑定到哪个素材槽，也不改动已有的绑定（D-89）。")

        @Argument(help: ArgumentHelp("素材：assetId 或名称。", valueName: "素材"))
        var asset: String

        @Argument(help: ArgumentHelp("新分组。", valueName: "signature|watermark|camera-badge"))
        var category: AssetCategoryArgument

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "asset set-category", json: json)
            let service = try ctx.makeService()
            let info = try await ctx.call { () async throws(ApplicationError) in
                let found = try await service.resolveAsset(asset)
                return try await service.setAssetCategory(found.assetId, to: category.category)
            }
            if json {
                ctx.emit(AssetResultJSON(asset: AssetJSON(info)))
            } else {
                ctx.env.stdout.line("\(info.assetId.uuidString)  \(info.displayName)  \(AssetCategoryArgument(info.category).rawValue)")
            }
        }
    }

    /// `photoframe asset delete <asset> [--json]`
    struct DeleteCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete", abstract: "删除素材。",
            discussion: "指向它的绑定保留（D-83）：导出时按 D-28 警告并回退到下一级绑定。这些绑定写到 stderr（--json 时在结果里）。")

        @Argument(help: ArgumentHelp("素材：assetId 或名称。", valueName: "素材"))
        var asset: String

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "asset delete", json: json)
            let service = try ctx.makeService()
            let (id, affected) = try await ctx.call { () async throws(ApplicationError) in
                let found = try await service.resolveAsset(asset)
                return (found.assetId, try await service.deleteAsset(found.assetId))
            }
            if json {
                ctx.emit(AssetDeleteJSON(assetId: id.uuidString, bindings: affected.map(BindingJSON.init)))
                return
            }
            for b in affected {
                ctx.log("warning: [binding.asset_deleted] 绑定 \(b.slotId)\(b.presetId.map { "（预设 \($0.uuidString)）" } ?? "（默认）") 仍指向已删除的素材")
            }
            ctx.env.stdout.line(id.uuidString)
        }
    }

    /// `photoframe asset bind <asset> --slot <slotId> [--preset <预设>]`
    struct BindCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bind", abstract: "把素材绑定到素材槽（保存在本机，不随预设导出）。",
            discussion: """
                给 --preset 时是该预设的本地绑定（D-14 第二级），否则是本用户的默认绑定（第三级，按 slotId 对所有预设生效，D-90）。
                单个任务的绑定用 export / preview 的 --bind。
                """)

        @Argument(help: ArgumentHelp("素材：assetId 或名称。", valueName: "素材"))
        var asset: String

        @Option(help: ArgumentHelp("素材槽 ID。", valueName: "slotId"))
        var slot: String

        @Option(help: ArgumentHelp("只对这个预设生效：presetId、名称或短名称。", valueName: "预设"))
        var preset: String?

        func run() async throws {
            let ctx = CommandContext(command: "asset bind", json: false)
            let service = try ctx.makeService()
            let reference = preset.map(ctx.presetReference)
            try await ctx.call { () async throws(ApplicationError) in
                let found = try await service.resolveAsset(asset)
                try await service.bindAsset(found.assetId, slotId: slot, preset: reference)
            }
        }
    }

    /// `photoframe asset unbind --slot <slotId> [--preset <预设>]`
    struct UnbindCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "unbind", abstract: "清除素材槽的预设本地绑定（给 --preset）或默认绑定。")

        @Option(help: ArgumentHelp("素材槽 ID。", valueName: "slotId"))
        var slot: String

        @Option(help: ArgumentHelp("预设：presetId、名称或短名称。", valueName: "预设"))
        var preset: String?

        func run() async throws {
            let ctx = CommandContext(command: "asset unbind", json: false)
            let service = try ctx.makeService()
            let reference = preset.map(ctx.presetReference)
            try await ctx.call { () async throws(ApplicationError) in try await service.bindAsset(nil, slotId: slot, preset: reference) }
        }
    }

    /// `photoframe asset bindings [--json]`
    struct BindingsCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bindings", abstract: "列出保存的绑定。", discussion: "每行：preset|default、presetId（默认绑定为 -）、slotId、assetId。")

        @Flag(help: "stdout 输出 JSON。")
        var json = false

        func run() async throws {
            let ctx = CommandContext(command: "asset bindings", json: json)
            let service = try ctx.makeService()
            let list = await service.listBindings()
            if json {
                ctx.emit(BindingListJSON(bindings: list.bindings.map(BindingJSON.init), warnings: list.warnings.map(WarningJSON.init)))
                return
            }
            ctx.warn(list.warnings)
            ctx.printTable(list.bindings.map { b in
                let j = BindingJSON(b)
                return [j.scope, j.presetId ?? "-", j.slotId, j.assetId]
            })
        }
    }
}

// MARK: - 输出

extension CommandContext {
    /// 对齐的列；最后一列不补空格。
    func printTable(_ rows: [[String]]) {
        guard let columns = rows.first?.count else { return }
        let widths = (0..<columns).map { column in rows.map { $0[column].count }.max() ?? 0 }
        for row in rows {
            let cells = row.enumerated().map { i, cell in
                i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }
            env.stdout.line(cells.joined(separator: "  "))
        }
    }

    func printPreset(_ summary: CatalogPresetSummary) {
        if json {
            emit(PresetResultJSON(preset: PresetJSON(summary)))
        } else {
            env.stdout.line("\(summary.presetId.uuidString)  \(summary.name)")
        }
    }
}

/// export / preview 的 `--bind <slotId>=<素材>`：单任务绑定（D-14 最高优先级）。
struct JobBinding: ExpressibleByArgument {
    var slotId: String
    var asset: String

    init?(argument: String) {
        guard let eq = argument.firstIndex(of: "=") else { return nil }
        slotId = String(argument[..<eq]).trimmingCharacters(in: .whitespaces)
        asset = String(argument[argument.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        guard !slotId.isEmpty, !asset.isEmpty else { return nil }
    }

    static let help = ArgumentHelp(
        "只对本次任务生效的素材绑定（D-14 最高优先级）。可重复。", valueName: "slotId=素材")
}

extension CommandContext {
    /// 把 `--bind` 的素材引用解析成 assetId。
    func resolveBindings(_ bindings: [JobBinding], service: any PhotoFrameService) async throws -> [String: UUID] {
        var result: [String: UUID] = [:]
        for binding in bindings {
            result[binding.slotId] = try await call { () async throws(ApplicationError) in
                try await service.resolveAsset(binding.asset).assetId
            }
        }
        return result
    }
}
