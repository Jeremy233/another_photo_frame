/// 任意 JSON 值。用来原样保存 `x-` 扩展字段，以及在 schema 迁移时操作未定型的 manifest。
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "不是合法的 JSON 值")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // 整数值按整数写出，避免 `1` 往返后变成 `1.0`。
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { o[key] } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { o } else { nil }
    }

    public var stringValue: String? {
        if case .string(let s) = self { s } else { nil }
    }

    /// 只有数值且恰好是整数时返回。
    public var intValue: Int? {
        if case .number(let n) = self, n.rounded() == n, abs(n) <= Double(Int32.max) { Int(n) } else { nil }
    }
}
