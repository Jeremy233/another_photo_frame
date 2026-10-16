import Foundation
import PhotoFrameCore
import PhotoFrameRendering
import PhotoFrameStorage

// 服务的两个外部注入点：素材来源（以后接 PhotoFrameStorage 的素材库）和图像分析（由渲染模块实现）。

/// 素材来源（§8.2）。现阶段没有素材库，用 ``NoAssetLibrary``；素材库做好后实现这个协议接进来。
public protocol AssetProvider: Sendable {
    /// 当前的素材表与绑定（D-14）。每次校验任务时调用一次，所以素材库可以随时变化。
    func slotResolver() -> SlotResolver
    /// 素材记录对应的本地文件；找不到时返回 nil（对应图层渲染时警告并跳过）。
    func fileURL(for asset: AssetRecord) -> URL?
}

/// 没有素材库：所有素材槽都解析不到。必需素材缺失照常报 `slot.missing_required`，可选素材跳过图层并警告（D-28、D-29）。
public struct NoAssetLibrary: AssetProvider {
    public init() {}
    public func slotResolver() -> SlotResolver { SlotResolver(library: InMemoryAssetLibrary(), bindings: AssetBindingTable()) }
    public func fileURL(for asset: AssetRecord) -> URL? { nil }
}

/// 只读的图像分析：检查源图、预估输出、预览。正常实现是 ``RenderingBackend``；测试可以换成假的。
public protocol ImageAnalyzer: Sendable {
    func inspect(_ fileURL: URL) async throws -> SourceInspection
    /// 不解码像素，只按文件属性和版式算出会写出哪些页。
    func plan(_ request: JobRenderRequest) async throws -> ExportPlan
    func preview(_ request: JobRenderRequest, options: PreviewOptions) async throws -> ExportPreview
}

/// 源图检查结果（§11.2 `SourceInspection`、§11.4 `inspect_image`）。
public struct SourceInspection: Hashable, Sendable, Codable {
    public struct ColorProfile: Hashable, Sendable, Codable {
        /// 文件里是否真的带颜色描述。
        public var embedded: Bool
        /// 解码时使用的输入色彩空间。
        public var description: String
        /// `embedded`、`assumedSRGB`（D-04）、`override`。
        public var origin: String

        public init(embedded: Bool, description: String, origin: String) {
            self.embedded = embedded
            self.description = description
            self.origin = origin
        }
    }

    public struct HDR: Hashable, Sendable, Codable {
        /// `none`、`gainMap`、`gainMapTIFF`、`transferFunction`、`floatLinear`（D-62）。
        public var kind: String
        public var headroom: Double?

        public init(kind: String, headroom: Double?) {
            self.kind = kind
            self.headroom = headroom
        }
    }

    public var fileURL: URL
    public var fileSizeBytes: Int64?
    /// `jpeg`、`png`、`tiff`。
    public var format: String
    public var pixelSize: PixelSize
    /// EXIF 方向 1…8。
    public var orientation: Int
    public var displaySize: PixelSize
    public var bitDepth: Int
    public var isFloat: Bool
    public var hasAlpha: Bool
    public var colorProfile: ColorProfile
    public var hdr: HDR
    /// 图层文字可用的 EXIF 值（`camera`、`lens`、`focalLength`、`aperture`、`shutter`、`iso`、`date`…）。
    public var metadata: [String: String]
    /// 只报告有无，不输出坐标（§12.3）。
    public var hasGPS: Bool
    public var hasAuthorOrCopyright: Bool
    public var warnings: [ApplicationWarning]

    public init(
        fileURL: URL, fileSizeBytes: Int64?, format: String, pixelSize: PixelSize, orientation: Int, displaySize: PixelSize,
        bitDepth: Int, isFloat: Bool, hasAlpha: Bool, colorProfile: ColorProfile, hdr: HDR,
        metadata: [String: String], hasGPS: Bool, hasAuthorOrCopyright: Bool, warnings: [ApplicationWarning]
    ) {
        self.fileURL = fileURL
        self.fileSizeBytes = fileSizeBytes
        self.format = format
        self.pixelSize = pixelSize
        self.orientation = orientation
        self.displaySize = displaySize
        self.bitDepth = bitDepth
        self.isFloat = isFloat
        self.hasAlpha = hasAlpha
        self.colorProfile = colorProfile
        self.hdr = hdr
        self.metadata = metadata
        self.hasGPS = hasGPS
        self.hasAuthorOrCopyright = hasAuthorOrCopyright
        self.warnings = warnings
    }
}

/// 预估的一个输出项。
public struct PlannedOutput: Hashable, Sendable, Codable {
    public var role: JobOutputRole
    public var pixelSize: PixelSize

    public init(role: JobOutputRole, pixelSize: PixelSize) {
        self.role = role
        self.pixelSize = pixelSize
    }
}

/// 预估的输出（按轮播顺序）和版式警告（例如超出平台轮播上限）。
public struct ExportPlan: Hashable, Sendable, Codable {
    public var outputs: [PlannedOutput]
    public var warnings: [ApplicationWarning]

    public init(outputs: [PlannedOutput], warnings: [ApplicationWarning] = []) {
        self.outputs = outputs
        self.warnings = warnings
    }
}

/// 预览参数。
public struct PreviewOptions: Hashable, Sendable, Codable {
    /// 页面长边不超过这么多像素；预览从不大于导出尺寸。
    public var maxLongEdge: Int
    /// 只渲染这些轮播页（0 = 封面）；nil 为全部。
    public var pages: Set<Int>?

    public init(maxLongEdge: Int = 1200, pages: Set<Int>? = nil) {
        self.maxLongEdge = maxLongEdge
        self.pages = pages
    }
}

/// 一页预览：sRGB PNG（与 SDR 导出编码前的像素相同，按预览尺寸缩小）。
public struct PreviewImage: Hashable, Sendable, Codable {
    public var role: JobOutputRole
    public var pixelSize: PixelSize
    /// 同一页导出时的尺寸。
    public var exportPixelSize: PixelSize
    public var pngData: Data

    public init(role: JobOutputRole, pixelSize: PixelSize, exportPixelSize: PixelSize, pngData: Data) {
        self.role = role
        self.pixelSize = pixelSize
        self.exportPixelSize = exportPixelSize
        self.pngData = pngData
    }
}

/// 预览结果（§11.2 `PreviewResult`）。可序列化，MCP 的 `preview_export` 也能用。
public struct ExportPreview: Hashable, Sendable, Codable {
    public var pages: [PreviewImage]
    /// 导出会写出的全部页。
    public var roles: [JobOutputRole]
    public var warnings: [ApplicationWarning]

    public init(pages: [PreviewImage], roles: [JobOutputRole], warnings: [ApplicationWarning]) {
        self.pages = pages
        self.roles = roles
        self.warnings = warnings
    }
}

/// 指定一张源图：已登记的 ID，或文件路径（§11.2 `SourceReference`）。
public enum SourceReference: Hashable, Sendable {
    case id(SourceID)
    case file(URL)
}

/// 预览请求（§11.2 `PreviewRequest`）。
public struct ExportPreviewRequest: Hashable, Sendable {
    public var source: SourceReference
    public var preset: ExportPreset
    public var options: PreviewOptions
    public var assetBindings: [String: UUID]
    /// 没有 ICC 的源图按什么色彩空间解释（D-04）。
    public var sourceColorOverride: SourceColorOverride?

    public init(
        source: SourceReference, preset: ExportPreset, options: PreviewOptions = PreviewOptions(),
        assetBindings: [String: UUID] = [:], sourceColorOverride: SourceColorOverride? = nil
    ) {
        self.source = source
        self.preset = preset
        self.options = options
        self.assetBindings = assetBindings
        self.sourceColorOverride = sourceColorOverride
    }
}
