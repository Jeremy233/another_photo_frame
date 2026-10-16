import Foundation
import PhotoFrameCore
import PhotoFrameStorage

// 渲染入口的输入输出类型（规范 §9.1、§11.1）。全部是纯数据，可以跨任务队列传递。

/// 一个已解析到本地文件的素材（PNG 或受限 SVG，D-09）。
///
/// `SlotResolver` 只给出素材 ID 和格式，真实路径由素材库管理；调用方把两者合起来交给渲染器。
public struct RenderAsset: Hashable, Sendable, Codable {
    public var fileURL: URL
    public var format: AssetSlot.Format

    public init(fileURL: URL, format: AssetSlot.Format) {
        self.fileURL = fileURL
        self.format = format
    }
}

/// 用户为源图指定的输入色彩空间（D-04：无 ICC 时默认 sRGB，允许按源图或任务覆盖）。
public enum SourceColorOverride: String, Hashable, Sendable, Codable, CaseIterable {
    case sRGB
    case displayP3
    case adobeRGB
    case proPhoto
    case rec2020
}

/// 一个渲染任务：一张源图 × 一个预设快照。
public struct RenderJob: Sendable {
    /// 源图文件（只读）。
    public var sourceURL: URL
    /// 预设快照（§8.3：排队时绑定具体配置）。
    public var preset: ExportPreset
    /// slotId → 已解析的素材文件。没有出现在这里的素材图层不绘制。
    public var assets: [String: RenderAsset]
    /// 因可选素材缺失而跳过的图层（`SlotResolution.skippedLayerIds`），渲染时不再重复警告。
    public var skippedLayerIds: Set<String>
    /// 写出成品的目录，由调用方创建并负责清理（原子发布、命名、冲突处理都不在渲染器里做）。
    public var outputDirectory: URL
    /// 输入色彩空间覆盖（D-04）。nil = 按文件自带 ICC，没有时假设 sRGB 并警告。
    public var sourceColorOverride: SourceColorOverride?
    /// 平台轮播上限（含封面），用于全景警告；nil 表示不检查。
    public var maxCarouselItems: Int?
    /// `metadataText` 模板占位符的手动值，优先于 EXIF（§7.2：可从 EXIF 读取，也可手动覆盖）。
    public var metadataOverrides: [String: String]

    public init(
        sourceURL: URL,
        preset: ExportPreset,
        assets: [String: RenderAsset] = [:],
        skippedLayerIds: Set<String> = [],
        outputDirectory: URL,
        sourceColorOverride: SourceColorOverride? = nil,
        maxCarouselItems: Int? = nil,
        metadataOverrides: [String: String] = [:]
    ) {
        self.sourceURL = sourceURL
        self.preset = preset
        self.assets = assets
        self.skippedLayerIds = skippedLayerIds
        self.outputDirectory = outputDirectory
        self.sourceColorOverride = sourceColorOverride
        self.maxCarouselItems = maxCarouselItems
        self.metadataOverrides = metadataOverrides
    }
}

extension RenderJob {
    /// 由 `SlotResolver` 的结果组装素材表：`fileURL` 把素材库记录换成本地文件（素材库负责路径）。
    /// 找不到文件的素材不放进表里，对应图层渲染时会警告并跳过。
    public static func assets(
        from resolution: SlotResolution, fileURL: (AssetRecord) -> URL?
    ) -> (assets: [String: RenderAsset], skippedLayerIds: Set<String>) {
        var assets: [String: RenderAsset] = [:]
        for (slotId, slot) in resolution.resolved {
            if let url = fileURL(slot.asset) { assets[slotId] = RenderAsset(fileURL: url, format: slot.asset.format) }
        }
        return (assets, Set(resolution.skippedLayerIds))
    }
}

/// 渲染阶段，与 `JobStatus` 中处理中的三个阶段一一对应（§9.1）。
public enum RenderStage: String, Hashable, Sendable, Codable, CaseIterable {
    case decoding
    case rendering
    case encoding
}

/// 进度：真实的阶段与已完成输出项，不伪造百分比（§9.1）。
public struct RenderProgress: Hashable, Sendable, Codable {
    public var stage: RenderStage
    /// 已写出的输出文件数。
    public var completedOutputs: Int
    /// 本任务一共要写出的文件数；解码完成前为 nil。
    public var totalOutputs: Int?

    public init(stage: RenderStage, completedOutputs: Int, totalOutputs: Int?) {
        self.stage = stage
        self.completedOutputs = completedOutputs
        self.totalOutputs = totalOutputs
    }
}

/// 输出项在轮播里的角色。
public enum OutputRole: Hashable, Sendable, Codable {
    /// 普通单页（全景关闭）。
    case single
    /// 全景封面（Slide 0）。
    case cover
    /// 全景切片 k（0 起），轮播位置 k + 1。
    case slide(Int)

    /// 轮播位置：0 = 封面 / 单页，切片 k 为 k + 1（D-27）。
    public var page: Int {
        switch self {
        case .single, .cover: 0
        case .slide(let k): k + 1
        }
    }
}

/// 一个写出的成品文件。
public struct RenderedOutput: Hashable, Sendable, Codable {
    public var role: OutputRole
    /// 写在 `RenderJob.outputDirectory` 里的临时文件。
    public var fileURL: URL
    public var pixelSize: PixelSize
    public var format: OutputSettings.Format
    /// 实际写出的动态范围（请求 HDR 但源图是 SDR 时为 `.sdr`，并有警告）。
    public var dynamicRange: OutputSettings.DynamicRange
    /// 嵌入文件的 ICC 描述，例如 `sRGB IEC61966-2.1`。
    public var colorProfile: String
    /// HDR 输出写入的 headroom（线性，相对 SDR 白）；SDR 输出为 nil。
    public var hdrHeadroom: Double?
    public var byteCount: Int
    /// 照片在本页的像素矩形（左上原点）；整张都是底色的切片为 nil。
    public var photoRect: PixelRect?
    /// 本页绘制的图层及其像素矩形，按绘制顺序（GUI 预览与导出共用这份位置）。
    public var layers: [RenderedLayer]
}

/// 一个图层在某页上的位置。
public struct RenderedLayer: Hashable, Sendable, Codable {
    public var layerId: String
    public var rect: PixelRect
}

/// 不阻止输出的提示。`code` 是稳定的机器可读码。
public struct RenderWarning: Hashable, Sendable, Codable, CustomStringConvertible {
    public var code: String
    public var message: String
    /// 相关的轮播页码（0 = 封面 / 单页）；与具体页无关时为 nil。
    public var page: Int?
    public var layerId: String?

    public init(code: String, message: String, page: Int? = nil, layerId: String? = nil) {
        self.code = code
        self.message = message
        self.page = page
        self.layerId = layerId
    }

    public var description: String {
        var s = "[\(code)] \(message)"
        if let page { s += "（第 \(page) 页）" }
        if let layerId { s += "（图层 \(layerId)）" }
        return s
    }
}

/// 源图 HDR 的形式。
public enum SourceHDRKind: String, Hashable, Sendable, Codable {
    case none
    /// ISO 21496-1（或 Apple）gain map JPEG：自带 SDR 底图。
    case gainMap
    /// Lightroom「最大化兼容性」TIFF：IFD0 是 SDR 版本，SubIFD 是 gain map（§6.2）。
    case gainMapTIFF
    /// PQ / HLG 编码（PNG、TIFF）。
    case transferFunction
    /// 浮点线性数据，峰值 > SDR 白。
    case floatLinear
}

/// HDR → SDR 用了什么办法（§6.7）。
public enum SDRRenditionMethod: Hashable, Sendable, Codable {
    /// 源图本来就是 SDR。
    case none
    /// 使用源文件自带的 SDR 版本（gain map 底图、兼容 TIFF 主图）。
    case sourceRendition
    /// `CIToneMapHeadroom`，sourceHeadroom = 画面实测峰值，targetHeadroom = 1。
    case toneMapHeadroom(sourceHeadroom: Double, targetHeadroom: Double)
}

/// 渲染报告（§6.3 `RenderDiagnostics`、§9.1 输出清单）：每一步颜色决策都可追踪（§6.1 第 7 条）。
public struct RenderDiagnostics: Hashable, Sendable, Codable {
    /// 由文件头判断的格式：`jpeg`、`png`、`tiff`。
    public var sourceFormat: String
    /// 文件中存储的像素尺寸。
    public var sourcePixelSize: PixelSize
    public var orientation: ExifOrientation
    /// 方向校正后的显示尺寸（布局用的 S_w × S_h）。
    public var displaySize: PixelSize
    public var bitDepth: Int
    public var isFloat: Bool
    public var hasAlpha: Bool
    /// 文件里是否真的带颜色描述（自己解析文件得出，不信 ImageIO 的 ProfileName，见 PoC 坑 1）。
    public var hasEmbeddedProfile: Bool
    /// 解码时实际使用的输入色彩空间描述。
    public var sourceProfile: String
    /// 输入色彩空间是怎么来的：`embedded`、`assumedSRGB`、`override`。
    public var sourceProfileOrigin: String
    public var hdrKind: SourceHDRKind
    /// 源 HDR headroom（线性）；SDR 源为 nil。
    public var sourceHeadroom: Double?
    /// 工作空间（D-03）。
    public var workingSpace: String
    public var workingFormat: String
    public var sdrMethod: SDRRenditionMethod
    /// 按顺序记录的颜色变换步骤，便于排查二次转换。
    public var transformSteps: [String]
}

public struct RenderResult: Sendable {
    /// 按轮播顺序：封面（或单页）在前，切片按序号。
    public var outputs: [RenderedOutput]
    public var diagnostics: RenderDiagnostics
    public var warnings: [RenderWarning]
}

/// 阻止输出的错误。`code` 稳定，`message` 给人看，`hint` 说明怎么修（§10.1）。
public struct RenderError: Error, Hashable, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var hint: String?

    public init(code: String, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }

    public var description: String { "[\(code)] \(message)" + (hint.map { "；\($0)" } ?? "") }

    static func unsupportedFormat(_ what: String) -> RenderError {
        RenderError(code: "render.unsupported_format", message: "不支持的输入格式：\(what)",
                    hint: "V1 支持 JPEG、PNG、TIFF（D-02）；HEIC 请先在后期软件中导出为 JPEG 或 TIFF")
    }

    static func decodeFailed(_ url: URL, _ why: String) -> RenderError {
        RenderError(code: "render.decode_failed", message: "无法解码 \(url.lastPathComponent)：\(why)")
    }

    static func geometry(_ e: GeometryError) -> RenderError {
        RenderError(code: e.code, message: e.message)
    }

    static func overlay(_ e: OverlayError, layerId: String) -> RenderError {
        RenderError(code: e.code, message: "图层 \(layerId)：\(e.message)")
    }
}
