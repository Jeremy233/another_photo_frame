import Foundation
import MCP
import PhotoFrameApplication

// MCP 工具的名字和 JSON Schema（§11.4）。字段名与 CLI `--json` 一致（docs/CLI.md、docs/MCP.md）。
// Schema 用下面的小函数拼，不写大段嵌套字面量（旧版编译器对 `Value` 的大字面量类型推断很慢）。

enum MCPToolName: String, CaseIterable {
    case listPresets = "list_presets"
    case getPreset = "get_preset"
    case updatePreset = "update_preset"
    case inspectImage = "inspect_image"
    case listAssets = "list_assets"
    case validateExport = "validate_export"
    case previewExport = "preview_export"
    case createExportJob = "create_export_job"
    case getJobStatus = "get_job_status"
    case cancelExportJob = "cancel_export_job"
}

enum Schema {
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var o: [String: Value] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }

    static func string(_ description: String, oneOf values: [String]? = nil) -> Value {
        var o: [String: Value] = ["type": "string", "description": .string(description)]
        if let values { o["enum"] = .array(values.map { .string($0) }) }
        return .object(o)
    }

    static func integer(_ description: String, minimum: Int, maximum: Int? = nil) -> Value {
        var o: [String: Value] = ["type": "integer", "description": .string(description), "minimum": .int(minimum)]
        if let maximum { o["maximum"] = .int(maximum) }
        return .object(o)
    }

    static func boolean(_ description: String) -> Value {
        .object(["type": "boolean", "description": .string(description)])
    }

    static func array(_ items: Value, _ description: String, minItems: Int = 0, maxItems: Int? = nil) -> Value {
        var o: [String: Value] = ["type": "array", "items": items, "description": .string(description), "minItems": .int(minItems)]
        if let maxItems { o["maxItems"] = .int(maxItems) }
        return .object(o)
    }

    static func any(_ description: String) -> Value {
        .object(["description": .string(description)])
    }

    /// 输出：成功和失败都有 `ok`；失败时有 `error`。其余字段见 docs/MCP.md。
    static func output(_ properties: [String: Value]) -> Value {
        var all = properties
        all["ok"] = boolean("工具是否成功执行")
        all["error"] = errorObject
        return .object(["type": "object", "properties": .object(all), "required": ["ok"]])
    }

    static let errorObject: Value = .object([
        "type": "object",
        "description": "失败原因：稳定的错误码、说明和可选的修复提示",
        "properties": .object(["code": string("错误码"), "message": string("说明"), "hint": string("修复提示")]),
        "required": ["code", "message"],
    ])

    static let anyArray: Value = .object(["type": "array"])
    static let anyObject: Value = .object(["type": "object"])
}

extension MCPToolName {
    // 常用参数
    private static let preset = Schema.string("预设：presetId、完整名称或短名称（list_presets 的 slug），只在预设库里查找，不读文件")
    private static let image = Schema.string("源图的绝对路径（JPEG / PNG / TIFF），必须在允许读取的目录内")
    private static let outputDirectory = Schema.string("输出根目录的绝对路径，必须在允许写入的目录内；不存在时创建")
    private static let assumeProfile = Schema.string("没有 ICC 的源图按什么色彩空间解释（D-75）", oneOf: AssumedProfile.allCases.map(\.rawValue))
    private static let bindings: Value = .object([
        "type": "object", "description": "单任务素材绑定：slotId → 素材（assetId 或名称），D-14 最高优先级",
        "additionalProperties": Schema.string("assetId 或素材名称"),
    ])
    private static let overwrite = Schema.boolean("显式允许覆盖（D-49）：替换本软件之前导出的作品目录 / 已存在的预览文件。默认 false，加版本后缀或拒绝")
    private static let jobId = Schema.string("create_export_job 返回的 jobId")

    private static var exportInput: Value {
        Schema.object([
            "images": Schema.array(image, "源图", minItems: 1, maxItems: PhotoFrameMCPServer.maxListItems),
            "presets": Schema.array(preset, "预设，每张图 × 每个预设一个任务", minItems: 1, maxItems: PhotoFrameMCPServer.maxListItems),
            "outputDirectory": outputDirectory,
            "overwrite": overwrite,
            "assumeProfile": assumeProfile,
            "bindings": bindings,
        ], required: ["images", "presets", "outputDirectory"])
    }

    var tool: Tool {
        let ro = Tool.Annotations(readOnlyHint: true, openWorldHint: false)
        switch self {
        case .listPresets:
            return Tool(name: rawValue, title: "列出预设",
                        description: "列出内置、用户保存、导入的预设摘要（与 photoframe preset list --json 相同）。",
                        inputSchema: Schema.object([:]), annotations: ro,
                        outputSchema: Schema.output(["presets": Schema.anyArray, "warnings": Schema.anyArray]))
        case .getPreset:
            return Tool(name: rawValue, title: "查看预设内容",
                        description: "返回预设的完整内容（与 .photoframe 里的 manifest.json 相同），或 path 指定的一个字段。字段路径写法见 photoframe://docs/preset-schema。",
                        inputSchema: Schema.object([
                            "preset": Self.preset,
                            "path": Schema.string("字段路径，如 canvas.minMarginPx、layers[0].opacity、layers[exif].text.fontSizePx；省略时返回整份预设"),
                        ], required: ["preset"]),
                        annotations: ro,
                        outputSchema: Schema.output(["preset": Schema.anyObject, "path": Schema.string("字段路径"), "value": Schema.any("字段的值")]))
        case .updatePreset:
            let edit = Schema.object([
                "path": Schema.string("字段路径；layers[+] 表示在数组末尾追加"),
                "value": Schema.any("新值（任意 JSON）；与 remove 二选一"),
                "remove": Schema.boolean("删除这个字段或数组元素"),
            ], required: ["path"])
            return Tool(name: rawValue, title: "修改预设",
                        description: "逐项修改预设库里的预设（D-93），按顺序应用。改完的预设必须通过与导入相同的检查，才原子写入；任何一项不通过都不修改。内置预设只读，先复制。presetId、schemaVersion 不能改。",
                        inputSchema: Schema.object([
                            "preset": Self.preset,
                            "edits": Schema.array(edit, "修改列表", minItems: 1, maxItems: 100),
                        ], required: ["preset", "edits"]),
                        annotations: Tool.Annotations(destructiveHint: true, idempotentHint: true, openWorldHint: false),
                        outputSchema: Schema.output(["preset": Schema.anyObject, "changed": Schema.anyArray, "warnings": Schema.anyArray]))
        case .inspectImage:
            return Tool(name: rawValue, title: "检查源图",
                        description: "读取源图的尺寸、方向、位深、ICC、HDR 判定和 EXIF 摘要。GPS 和作者信息只报告有无。",
                        inputSchema: Schema.object(["path": Self.image], required: ["path"]), annotations: ro,
                        outputSchema: Schema.output(["image": Schema.anyObject]))
        case .listAssets:
            return Tool(name: rawValue, title: "列出素材",
                        description: "列出本地素材库的元信息（名称、分组、格式、尺寸），不返回文件路径和文件内容。",
                        inputSchema: Schema.object([
                            "category": Schema.string("只列这一组", oneOf: AssetCategoryArgument.allCases.map(\.rawValue)),
                        ]),
                        annotations: ro,
                        outputSchema: Schema.output(["assets": Schema.anyArray, "warnings": Schema.anyArray]))
        case .validateExport:
            return Tool(name: rawValue, title: "校验导出",
                        description: "校验导出参数：源图、预设、缺失素材、输出目录权限、覆盖，并列出将写出的文件。不渲染、不写任何文件。",
                        inputSchema: Self.exportInput, annotations: ro,
                        outputSchema: Schema.output(["valid": Schema.boolean("全部任务都能导出"), "jobs": Schema.anyArray]))
        case .previewExport:
            return Tool(name: rawValue, title: "预览",
                        description: "按预设渲染预览（与导出同一条管线，按预览尺寸缩小，sRGB PNG）。给了 outputDirectory 时写成文件，否则以图片内容直接返回。",
                        inputSchema: Schema.object([
                            "image": Self.image,
                            "preset": Self.preset,
                            "maxEdge": Schema.integer("预览页长边上限（像素），默认 1200", minimum: 16),
                            "pages": Schema.array(Schema.integer("轮播页：0 = 封面，切片 k 为 k + 1", minimum: 0), "只预览这些页；默认全部"),
                            "outputDirectory": Schema.string("写预览文件的目录（绝对路径，必须在允许写入的目录内）；省略时直接返回图片"),
                            "overwrite": Schema.boolean("替换已存在的同名预览文件"),
                            "assumeProfile": Self.assumeProfile,
                            "bindings": Self.bindings,
                        ], required: ["image", "preset"]),
                        annotations: Tool.Annotations(destructiveHint: false, openWorldHint: false),
                        outputSchema: Schema.output(["files": Schema.anyArray, "positions": Schema.anyArray, "warnings": Schema.anyArray]))
        case .createExportJob:
            return Tool(name: rawValue, title: "创建导出任务",
                        description: "先校验（有任何问题就什么都不写），再在后台创建导出任务并立即返回 jobId；用 get_job_status 查看进度。服务器进程退出时取消未完成的任务。",
                        inputSchema: Self.exportInput,
                        annotations: Tool.Annotations(destructiveHint: false, idempotentHint: false, openWorldHint: false),
                        outputSchema: Schema.output(["valid": Schema.boolean("校验是否通过"), "jobs": Schema.anyArray]))
        case .getJobStatus:
            return Tool(name: rawValue, title: "任务状态",
                        description: "查看本服务器创建的导出任务：阶段、进度、输出文件清单、警告和错误。省略 jobId 时列出全部。",
                        inputSchema: Schema.object(["jobId": Self.jobId]), annotations: ro,
                        outputSchema: Schema.output(["job": Schema.anyObject, "jobs": Schema.anyArray]))
        case .cancelExportJob:
            return Tool(name: rawValue, title: "取消任务",
                        description: "取消本服务器创建的、尚未结束的导出任务；已发布的作品目录不受影响。",
                        inputSchema: Schema.object(["jobId": Self.jobId], required: ["jobId"]),
                        annotations: Tool.Annotations(destructiveHint: false, idempotentHint: true, openWorldHint: false),
                        outputSchema: Schema.output(["job": Schema.anyObject]))
        }
    }
}

/// 工具参数。只接受 Schema 里声明的字段，类型不对时报 `mcp.invalid_arguments`。
struct MCPArguments {
    let values: [String: Value]

    init(_ values: [String: Value]?, allowed: Set<String>) throws(ApplicationError) {
        self.values = values ?? [:]
        if let unknown = self.values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw .invalidArguments("不认识的参数 \(unknown)")
        }
    }

    func string(_ key: String) throws(ApplicationError) -> String? {
        guard let v = values[key], !v.isNull else { return nil }
        guard let s = v.stringValue else { throw .invalidArguments("\(key) 应为字符串") }
        return s
    }

    func requiredString(_ key: String) throws(ApplicationError) -> String {
        guard let s = try string(key), !s.isEmpty else { throw .invalidArguments("缺少 \(key)") }
        return s
    }

    func strings(_ key: String, max: Int) throws(ApplicationError) -> [String] {
        guard let v = values[key], !v.isNull else { throw .invalidArguments("缺少 \(key)") }
        guard let a = v.arrayValue, !a.isEmpty else { throw .invalidArguments("\(key) 应为非空数组") }
        guard a.count <= max else { throw .invalidArguments("\(key) 最多 \(max) 项") }
        return try a.map { (item) throws(ApplicationError) -> String in
            guard let s = item.stringValue, !s.isEmpty else { throw .invalidArguments("\(key) 的每一项都应为非空字符串") }
            return s
        }
    }

    func bool(_ key: String) throws(ApplicationError) -> Bool {
        guard let v = values[key], !v.isNull else { return false }
        guard let b = v.boolValue else { throw .invalidArguments("\(key) 应为 true 或 false") }
        return b
    }

    func int(_ key: String) throws(ApplicationError) -> Int? {
        guard let v = values[key], !v.isNull else { return nil }
        if let i = v.intValue { return i }
        if let d = v.doubleValue, d.rounded() == d, abs(d) < 1e9 { return Int(d) }
        throw .invalidArguments("\(key) 应为整数")
    }

    func ints(_ key: String) throws(ApplicationError) -> [Int]? {
        guard let v = values[key], !v.isNull else { return nil }
        guard let a = v.arrayValue else { throw .invalidArguments("\(key) 应为整数数组") }
        return try a.map { (item) throws(ApplicationError) -> Int in
            guard let i = item.intValue ?? item.doubleValue.flatMap({ $0.rounded() == $0 && abs($0) < 1e9 ? Int($0) : nil }) else {
                throw .invalidArguments("\(key) 应为整数数组")
            }
            return i
        }
    }

    func stringMap(_ key: String) throws(ApplicationError) -> [String: String] {
        guard let v = values[key], !v.isNull else { return [:] }
        guard let o = v.objectValue else { throw .invalidArguments("\(key) 应为对象") }
        var out: [String: String] = [:]
        for (k, item) in o {
            guard let s = item.stringValue, !k.isEmpty, !s.isEmpty else { throw .invalidArguments("\(key) 的值应为非空字符串") }
            out[k] = s
        }
        return out
    }
}

extension ApplicationError {
    static func invalidArguments(_ detail: String) -> Self {
        Self(code: "mcp.invalid_arguments", message: "参数无效：\(detail)")
    }
}
