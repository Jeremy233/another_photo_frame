/// 逐项修改预设（D-93）：CLI `preset get` / `preset set` 与 MCP `get_preset` / `update_preset` 共用的字段路径。
///
/// 路径直接用 `manifest.json` 的字段名，`.` 分隔对象字段，`[…]` 取数组元素：
///
/// | 写法 | 含义 |
/// |---|---|
/// | `canvas.minMarginPx` | 对象字段 |
/// | `layers[0].opacity` | 按下标（从 0 开始） |
/// | `layers[exif].text.fontSizePx` | 按 `layerId` / `slotId` 找元素（方括号里不是纯数字时） |
/// | `layers[+]` | 在数组末尾追加（只能用于设置，且只能是最后一段） |
///
/// 编辑在未定型的 JSON 上进行，改完的整份 manifest 再走一遍和导入相同的 schema 校验（见 `PresetLibrary.edit`），
/// 所以这里只检查路径本身，不检查取值类型。
public struct PresetFieldPath: Hashable, Sendable, CustomStringConvertible {
    public enum Component: Hashable, Sendable {
        case key(String)
        case index(Int)
        /// 数组里 `layerId` 或 `slotId` 等于它的元素。
        case id(String)
        case append
    }

    public var components: [Component]

    /// 路径长度上限（字符）。
    public static let maxLength = 256

    /// 不能修改的字段：预设的身份和 schema 版本。
    public static let readOnlyFields: Set<String> = ["presetId", "schemaVersion"]

    public init(_ components: [Component]) {
        self.components = components
    }

    public init(parsing text: String) throws(PresetEditError) {
        guard !text.isEmpty, text.count <= Self.maxLength else { throw .invalidPath(text, "路径为空或超过 \(Self.maxLength) 个字符") }
        var components: [Component] = []
        var rest = Substring(text)
        var expectKey = true
        while !rest.isEmpty {
            if rest.first == "[" {
                guard let close = rest.firstIndex(of: "]") else { throw .invalidPath(text, "缺少 ]") }
                let inner = String(rest[rest.index(after: rest.startIndex)..<close])
                guard !inner.isEmpty else { throw .invalidPath(text, "[] 里不能为空") }
                if inner == "+" {
                    components.append(.append)
                } else if inner.allSatisfy(\.isASCII), let n = Int(inner), n >= 0, String(n) == inner {
                    components.append(.index(n))
                } else {
                    guard !inner.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                        throw .invalidPath(text, "含控制字符")
                    }
                    components.append(.id(inner))
                }
                rest = rest[rest.index(after: close)...]
                expectKey = false
            } else {
                if !expectKey {
                    guard rest.first == "." else { throw .invalidPath(text, "] 后面只能是 . 或 [") }
                    rest = rest.dropFirst()
                }
                let end = rest.firstIndex { $0 == "." || $0 == "[" } ?? rest.endIndex
                let key = String(rest[..<end])
                guard Self.isValidKey(key) else { throw .invalidPath(text, "字段名「\(key)」无效") }
                components.append(.key(key))
                rest = rest[end...]
                expectKey = false
            }
        }
        if let i = components.firstIndex(of: .append), i != components.count - 1 {
            throw .invalidPath(text, "[+] 只能是最后一段")
        }
        self.components = components
    }

    /// 字段名：字母开头，之后是字母、数字、`_`、`-`（`x-` 扩展字段）。
    static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic else { return false }
        return key.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "_" || $0 == "-") }
    }

    public var description: String {
        var out = ""
        for c in components {
            switch c {
            case .key(let k): out += out.isEmpty ? k : ".\(k)"
            case .index(let n): out += "[\(n)]"
            case .id(let s): out += "[\(s)]"
            case .append: out += "[+]"
            }
        }
        return out
    }
}

/// 一项修改。
public enum PresetEdit: Hashable, Sendable {
    /// 设置字段（字段不存在时新增；数组用 `[+]` 追加）。
    case set(PresetFieldPath, JSONValue)
    /// 删除字段或数组元素。
    case remove(PresetFieldPath)

    public var path: PresetFieldPath {
        switch self {
        case .set(let p, _), .remove(let p): p
        }
    }
}

public enum PresetEditError: Error, Hashable, Sendable {
    case invalidPath(String, String)
    case pathNotFound(String)
    case readOnlyField(String)
    case noEdits
    case tooManyEdits(Int)

    /// 一次请求最多几项修改。
    public static let maxEdits = 100

    public var code: String {
        switch self {
        case .invalidPath: "preset.invalid_path"
        case .pathNotFound: "preset.path_not_found"
        case .readOnlyField: "preset.field_read_only"
        case .noEdits, .tooManyEdits: "preset.invalid_edit"
        }
    }

    public var message: String {
        switch self {
        case .invalidPath(let path, let why): "字段路径「\(path)」无效：\(why)"
        case .pathNotFound(let path): "预设里没有 \(path)"
        case .readOnlyField(let path): "\(path) 不能修改"
        case .noEdits: "没有要做的修改"
        case .tooManyEdits(let n): "一次最多修改 \(Self.maxEdits) 项（收到 \(n) 项）"
        }
    }

    public var hint: String? {
        switch self {
        case .invalidPath: "写法如 canvas.minMarginPx、layers[0].opacity、layers[exif].text.fontSizePx、layers[+]"
        case .pathNotFound: "上一级对象不存在时先设置整个对象；用 get 查看现有内容"
        case .readOnlyField: "presetId 和 schemaVersion 不能改；要换名称用 name 或 rename"
        default: nil
        }
    }
}

/// 在 manifest（未定型的 JSON）上读取和应用修改。
public enum PresetEditor {
    /// 读取路径上的值。
    public static func value(at path: PresetFieldPath, in manifest: JSONValue) throws(PresetEditError) -> JSONValue {
        var current = manifest
        for component in path.components {
            guard let next = child(of: current, component) else { throw .pathNotFound(path.description) }
            current = next
        }
        return current
    }

    /// 按顺序应用全部修改；任何一项失败都不返回结果（调用方不会写入半改的预设）。
    public static func apply(_ edits: [PresetEdit], to manifest: JSONValue) throws(PresetEditError) -> JSONValue {
        guard !edits.isEmpty else { throw .noEdits }
        guard edits.count <= PresetEditError.maxEdits else { throw .tooManyEdits(edits.count) }
        var result = manifest
        for edit in edits {
            let path = edit.path
            guard case .key(let top)? = path.components.first else { throw .invalidPath(path.description, "必须以字段名开头") }
            if PresetFieldPath.readOnlyFields.contains(top) { throw .readOnlyField(top) }
            switch edit {
            case .set(_, let value): try update(&result, path.components[...], path, to: value)
            case .remove: try update(&result, path.components[...], path, to: nil)
            }
        }
        return result
    }

    private static func child(of value: JSONValue, _ component: PresetFieldPath.Component) -> JSONValue? {
        switch (value, component) {
        case (.object(let o), .key(let k)): o[k]
        case (.array(let a), .index(let i)): i < a.count ? a[i] : nil
        case (.array(let a), .id(let id)): index(of: id, in: a).map { a[$0] }
        default: nil
        }
    }

    /// `[id]` 指向的元素：先按 `layerId` 找，没有再按 `slotId` 找。图层的 `slotId` 是它引用的素材槽，
    /// 几个图层可以共用一个槽；不分先后地找，`layers[x]` 可能落到前面一个只是用了槽 `x` 的图层上。
    private static func index(of id: String, in array: [JSONValue]) -> Int? {
        array.firstIndex { $0["layerId"]?.stringValue == id } ?? array.firstIndex { $0["slotId"]?.stringValue == id }
    }

    /// 沿路径走到最后一段，把它设为 `newValue`（nil 表示删除）。中间各级必须已经存在。
    private static func update(
        _ value: inout JSONValue, _ rest: ArraySlice<PresetFieldPath.Component>, _ path: PresetFieldPath, to newValue: JSONValue?
    ) throws(PresetEditError) {
        guard let component = rest.first else { return }
        let last = rest.count == 1
        let notFound = PresetEditError.pathNotFound(path.description)
        switch (value, component) {
        case (.object(var o), .key(let k)):
            if last {
                // 删除不存在的字段视为路径错误，避免拼错的路径悄悄「成功」。
                if newValue == nil, o[k] == nil { throw notFound }
                o[k] = newValue
            } else {
                guard var next = o[k] else { throw notFound }
                try update(&next, rest.dropFirst(), path, to: newValue)
                o[k] = next
            }
            value = .object(o)
        case (.array(var a), .index), (.array(var a), .id):
            let i: Int? = switch component {
            case .index(let n): n < a.count ? n : nil
            case .id(let id): index(of: id, in: a)
            default: nil
            }
            guard let i else { throw notFound }
            if !last {
                try update(&a[i], rest.dropFirst(), path, to: newValue)
            } else if let newValue {
                a[i] = newValue
            } else {
                a.remove(at: i)
            }
            value = .array(a)
        case (.array(var a), .append):
            guard let newValue else { throw .invalidPath(path.description, "[+] 只能用于设置") }
            a.append(newValue)
            value = .array(a)
        default:
            throw notFound
        }
    }
}
