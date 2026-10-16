import Foundation
import PhotoFrameCore

/// 一个输出项在轮播中的位置（D-27：0 = 封面，切片 k 是第 k + 1 页）。
///
/// 单图预设只有封面。JSON 形式：`{"kind": "cover"}`、`{"kind": "slide", "position": 3}`。
public enum OutputRole: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    case cover
    /// 轮播位置 `position`（≥ 1），即第 `position - 1` 张切片。
    case slide(position: Int)

    public var carouselPosition: Int {
        switch self {
        case .cover: 0
        case .slide(let p): p
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.carouselPosition < b.carouselPosition }

    public var description: String {
        switch self {
        case .cover: "封面"
        case .slide(let p): "第 \(p) 页切片"
        }
    }

    enum CodingKeys: String, CodingKey { case kind, position }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "cover": self = .cover
        case "slide": self = .slide(position: try c.decode(Int.self, forKey: .position))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "未知的输出类型 \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cover:
            try c.encode("cover", forKey: .kind)
        case .slide(let p):
            try c.encode("slide", forKey: .kind)
            try c.encode(p, forKey: .position)
        }
    }
}

/// 输出清单中的一个文件（§9.1）。
public struct OutputManifestItem: Hashable, Sendable, Codable {
    public var role: OutputRole
    /// 发布后的绝对路径。
    public var fileURL: URL
    public var fileName: String
    public var pixelSize: PixelSize
    /// 嵌入的 ICC 描述，例如 `sRGB IEC61966-2.1`；由渲染器报告。
    public var colorProfile: String?
    public var fileSizeBytes: Int64
    /// 小写十六进制 SHA-256；只在 ``ExportDestination/computeHashes`` 打开时计算。
    public var sha256: String?
    public var warnings: [ApplicationWarning]

    public init(
        role: OutputRole, fileURL: URL, fileName: String, pixelSize: PixelSize,
        colorProfile: String?, fileSizeBytes: Int64, sha256: String?, warnings: [ApplicationWarning]
    ) {
        self.role = role
        self.fileURL = fileURL
        self.fileName = fileName
        self.pixelSize = pixelSize
        self.colorProfile = colorProfile
        self.fileSizeBytes = fileSizeBytes
        self.sha256 = sha256
        self.warnings = warnings
    }
}

/// 一次成功导出的结果清单（§9.1、§11.1 `ExportResult`），GUI / CLI / MCP 都从这里读。
public struct OutputManifest: Hashable, Sendable, Codable {
    public var jobId: JobID
    public var attemptId: AttemptID
    /// 发布后的作品目录，例如 `…/Instagram/Badlands_Panorama`。
    public var directory: URL
    /// 按轮播顺序排列：封面在前，切片按位置递增。
    public var items: [OutputManifestItem]
    /// 任务级提示（素材缺失跳过图层、HDR 未读取等）。
    public var warnings: [ApplicationWarning]
    public var startedAt: Date
    public var finishedAt: Date

    public init(
        jobId: JobID, attemptId: AttemptID, directory: URL, items: [OutputManifestItem],
        warnings: [ApplicationWarning], startedAt: Date, finishedAt: Date
    ) {
        self.jobId = jobId
        self.attemptId = attemptId
        self.directory = directory
        self.items = items
        self.warnings = warnings
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.fileSizeBytes } }
}
