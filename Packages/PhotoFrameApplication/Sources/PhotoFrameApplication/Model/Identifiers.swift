import Foundation

/// 以 UUID 为值的强类型 ID。JSON 中编码为 UUID 字符串。
public protocol UUIDIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

extension UUIDIdentifier {
    public init() { self.init(rawValue: UUID()) }

    public init?(_ string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.init(rawValue: uuid)
    }

    public var description: String { rawValue.uuidString }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(UUID.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// 一张源图（§9.1 Source）。
public struct SourceID: UUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// 一个导出任务：一张源图 × 一个预设快照（§9.1 Job）。
public struct JobID: UUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// 任务的一次执行。重试生成新的 AttemptID，旧的保留在历史里（§9.1）。
public struct AttemptID: UUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}
