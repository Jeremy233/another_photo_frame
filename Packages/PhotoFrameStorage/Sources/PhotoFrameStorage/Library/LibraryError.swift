import Foundation
import PhotoFrameCore

/// 预设库、素材库、绑定存储的错误。`code` 是稳定的机器可读错误码（CLI `--json`、MCP 直接使用）。
///
/// 消息里只出现文件名和 ID，不出现绝对路径（MCP 调用方不一定需要知道用户目录结构）。
public enum LibraryError: Error, Hashable, Sendable {
    case presetNotFound(UUID)
    /// CLI 按名称或短名查找预设时没有匹配。
    case presetReferenceNotFound(String)
    /// 名称或短名匹配到多个预设，请改用 presetId。
    case ambiguousPresetReference(String, [UUID])
    /// 内置预设只读：要修改请先复制。
    case builtInReadOnly(UUID)
    case presetAlreadyExists(UUID)
    /// 名称为空或过长。
    case invalidName(String)
    /// 预设内容有 error 级问题。
    case invalidPreset([PresetIssue])
    /// 库里的文件无法读取（损坏、schema 版本过新等），不能对它做修改。
    case unreadableItem(id: String, reason: String)
    /// 导入或导出预设包失败；逐项修改后没通过导入检查（D-93）。
    case package(PresetPackageError)
    /// 逐项修改的路径或请求本身有问题（D-93）。
    case edit(PresetEditError)
    case assetNotFound(UUID)
    /// 预设里没有这个素材槽（或 slotId 不合法）。
    case unknownSlot(String)
    /// 素材格式不被该素材槽接受。
    case incompatibleAsset(slotId: String, format: AssetSlot.Format)
    /// 素材没有通过导入检查（§8.2、§12.2）。
    case assetRejected(AssetRejection)
    /// 存储文件的格式版本比当前程序新，拒绝写入以免丢数据。
    case newerStorageFormat(file: String, found: Int, supported: Int)
    case io(String)

    public var code: String {
        switch self {
        case .presetNotFound, .presetReferenceNotFound: "library.preset_not_found"
        case .ambiguousPresetReference: "library.ambiguous_preset"
        case .builtInReadOnly: "library.builtin_read_only"
        case .presetAlreadyExists: "library.preset_exists"
        case .invalidName: "library.invalid_name"
        case .invalidPreset: "library.invalid_preset"
        case .unreadableItem: "library.unreadable_item"
        case .package(let e): e.code
        case .edit(let e): e.code
        case .assetNotFound: "asset.not_found"
        case .unknownSlot: "binding.unknown_slot"
        case .incompatibleAsset: "binding.incompatible_format"
        case .assetRejected(let r): r.code
        case .newerStorageFormat: "library.newer_storage_format"
        case .io: "library.io"
        }
    }

    public var message: String {
        switch self {
        case .presetNotFound(let id): "找不到预设 \(id.uuidString)"
        case .presetReferenceNotFound(let ref): "找不到预设「\(ref)」"
        case .ambiguousPresetReference(let ref, let ids):
            "「\(ref)」匹配到 \(ids.count) 个预设：" + ids.map(\.uuidString).joined(separator: ", ")
        case .builtInReadOnly: "内置预设不能修改"
        case .presetAlreadyExists(let id): "已有相同 ID 的预设：\(id.uuidString)"
        case .invalidName(let why): "名称无效：\(why)"
        case .invalidPreset(let issues): "预设内容无效：" + issues.errors.map(\.message).joined(separator: "；")
        case .unreadableItem(let id, let reason): "无法读取 \(id)：\(reason)"
        case .package(let e): e.message
        case .edit(let e): e.message
        case .assetNotFound(let id): "找不到素材 \(id.uuidString)"
        case .unknownSlot(let s): "预设中没有素材槽 \(s)"
        case .incompatibleAsset(let s, let f): "素材槽 \(s) 不接受 \(f.rawValue.uppercased()) 素材"
        case .assetRejected(let r): r.message
        case .newerStorageFormat(let file, let found, let supported):
            "\(file) 的格式版本是 \(found)，当前程序只支持到 \(supported)"
        case .io(let d): "读写文件失败：\(d)"
        }
    }

    public var hint: String? {
        switch self {
        case .builtInReadOnly: "先复制一份内置预设，再修改副本"
        case .ambiguousPresetReference: "请改用 presetId"
        case .newerStorageFormat: "请升级 PhotoFrame"
        case .unreadableItem: "该文件已被跳过；可以删除它，或用较新的 PhotoFrame 打开"
        case .package(let e): e.hint
        case .edit(let e): e.hint
        case .assetRejected(let r): r.hint
        default: nil
        }
    }
}

/// 素材被拒绝的原因。
public struct AssetRejection: Error, Hashable, Sendable, Codable {
    public var code: String
    public var message: String
    public var hint: String?

    public init(code: String, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }

    static func unsupportedType(_ ext: String) -> Self {
        .init(code: "asset.unsupported_type", message: "不支持的素材类型：\(ext.isEmpty ? "(无扩展名)" : ext)",
              hint: "素材只支持 PNG 和受限 SVG")
    }

    static func typeMismatch(expected: AssetSlot.Format) -> Self {
        .init(code: "asset.type_mismatch", message: "文件内容不是 \(expected.rawValue.uppercased())",
              hint: "文件扩展名与内容不符，请重新导出素材")
    }

    static func tooLarge(bytes: Int, limit: Int) -> Self {
        .init(code: "asset.too_large", message: "素材文件 \(bytes) 字节，超过上限 \(limit) 字节")
    }

    static func dimensions(_ size: PixelSize, _ why: String) -> Self {
        .init(code: "asset.invalid_dimensions", message: "素材尺寸 \(size.width)×\(size.height) 无效：\(why)")
    }

    static func corrupted(_ why: String) -> Self {
        .init(code: "asset.corrupted", message: "素材文件已损坏：\(why)")
    }

    static func svg(_ why: String) -> Self {
        .init(code: "asset.svg_rejected", message: "SVG 素材不符合受限格式：\(why)",
              hint: "只支持基本图形与路径：请导出为不含脚本、外部引用和文字的 SVG，或改用 PNG")
    }
}

/// 读取库时跳过的项目或其他不阻止操作的问题。一项坏了不影响整个库。
public struct LibraryWarning: Error, Hashable, Sendable, Codable, CustomStringConvertible {
    public var code: String
    /// 出问题的条目：文件名或 ID，不含路径。
    public var item: String
    public var message: String

    public init(code: String, item: String, message: String) {
        self.code = code
        self.item = item
        self.message = message
    }

    public var description: String { "\(code) @ \(item): \(message)" }
}
