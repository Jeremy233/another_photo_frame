import Foundation
import PhotoFrameCore

/// 一张源图（§9.1、§11.1 `PhotoSource`）。
///
/// 应用层只记录文件引用；像素尺寸、ICC、EXIF 由渲染模块检查后填入 `image` 等字段。
/// 源文件**只读**：应用层不会写入、移动或覆盖它（§12.2）。
public struct PhotoSource: Hashable, Sendable, Codable, Identifiable {
    public var sourceId: SourceID
    public var fileURL: URL
    /// 文件名（含扩展名），用于显示和输出命名。
    public var displayName: String
    public var fileSizeBytes: Int64?
    /// 方向校正前的像素尺寸与 EXIF 方向；未检查时为 nil。用于估算内存。
    public var image: SourceImage?
    public var addedAt: Date

    public var id: SourceID { sourceId }

    public init(
        sourceId: SourceID = SourceID(),
        fileURL: URL,
        displayName: String? = nil,
        fileSizeBytes: Int64? = nil,
        image: SourceImage? = nil,
        addedAt: Date = Date()
    ) {
        self.sourceId = sourceId
        self.fileURL = fileURL
        self.displayName = displayName ?? fileURL.lastPathComponent
        self.fileSizeBytes = fileSizeBytes
        self.image = image
        self.addedAt = addedAt
    }

    /// 去掉扩展名的文件名，作为默认作品名（§9.2）。
    public var baseName: String {
        (displayName as NSString).deletingPathExtension
    }

    /// V1 接受的输入扩展名（D-02：JPEG / PNG / TIFF；HEIC 放到 V2）。
    public static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff"]
}
