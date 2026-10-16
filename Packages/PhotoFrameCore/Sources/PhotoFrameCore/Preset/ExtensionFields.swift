import Foundation

/// 预设 JSON 中程序不认识的字段（D-15）。
///
/// - 以 `x-` 开头的是自定义扩展字段，原样保留并写回。
/// - 其他不认识的字段同样保留（不默默丢失，§8.3），但解码时会登记到 ``UnknownFieldLog``，
///   由导入流程决定是拒绝还是警告。
public typealias ExtensionFields = [String: JSONValue]

/// 自定义扩展字段的前缀。
public let extensionFieldPrefix = "x-"

struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// 解码过程中收集不认识（且不是 `x-`）的字段路径，例如 `canvas.foo`、`layers[2].bar`。
///
/// 通过 `JSONDecoder.userInfo[.presetUnknownFieldLog]` 传入。
public final class UnknownFieldLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    public init() {}

    public var paths: [String] {
        lock.withLock { storage }
    }

    func record(_ path: String) {
        lock.withLock { storage.append(path) }
    }
}

extension CodingUserInfoKey {
    public static let presetUnknownFieldLog = CodingUserInfoKey(rawValue: "photoframe.unknownFieldLog")!
}

/// 把 codingPath 写成 `a.b[2].c` 形式。
func describe(_ path: [any CodingKey]) -> String {
    var out = ""
    for key in path {
        if let i = key.intValue {
            out += "[\(i)]"
        } else {
            out += out.isEmpty ? key.stringValue : ".\(key.stringValue)"
        }
    }
    return out
}

enum ExtraFieldsCoding {
    /// 读出当前对象里 `Known` 之外的所有字段。
    static func decode<Known: CodingKey & CaseIterable>(
        from decoder: any Decoder, known: Known.Type
    ) throws -> ExtensionFields {
        let knownNames = Set(Known.allCases.map(\.stringValue))
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        var extra: ExtensionFields = [:]
        let log = decoder.userInfo[.presetUnknownFieldLog] as? UnknownFieldLog
        for key in c.allKeys where !knownNames.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
            if !key.stringValue.hasPrefix(extensionFieldPrefix) {
                log?.record(describe(c.codingPath + [key]))
            }
        }
        return extra
    }

    /// 写回额外字段；与已知字段同名的会被忽略，避免覆盖正式字段。
    static func encode<Known: CodingKey & CaseIterable>(
        _ extra: ExtensionFields, known: Known.Type, to encoder: any Encoder
    ) throws {
        guard !extra.isEmpty else { return }
        let knownNames = Set(Known.allCases.map(\.stringValue))
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in extra where !knownNames.contains(key) {
            try c.encode(value, forKey: AnyCodingKey(key))
        }
    }
}
