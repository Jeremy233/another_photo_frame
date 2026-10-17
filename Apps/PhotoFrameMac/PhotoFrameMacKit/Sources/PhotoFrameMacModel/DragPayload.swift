import Foundation

/// 应用内拖放的内容（UI 设计文档第 7 节）：预设拖到源图、位置拖到任务、素材拖到图层占位符。
///
/// 用纯文本 `photoframe:<种类>:<UUID>` 传递，不需要在 Info.plist 里声明自定义类型；从 Finder 拖入的图片走文件 URL。
public enum DragPayload: Hashable, Sendable {
    case preset(UUID)
    case location(UUID)
    case asset(UUID)

    private static let prefix = "photoframe:"

    public var string: String {
        switch self {
        case .preset(let id): "\(Self.prefix)preset:\(id.uuidString)"
        case .location(let id): "\(Self.prefix)location:\(id.uuidString)"
        case .asset(let id): "\(Self.prefix)asset:\(id.uuidString)"
        }
    }

    public init?(string: String) {
        let parts = string.split(separator: ":")
        guard parts.count == 3, parts[0] == "photoframe", let id = UUID(uuidString: String(parts[2])) else { return nil }
        switch parts[1] {
        case "preset": self = .preset(id)
        case "location": self = .location(id)
        case "asset": self = .asset(id)
        default: return nil
        }
    }
}
