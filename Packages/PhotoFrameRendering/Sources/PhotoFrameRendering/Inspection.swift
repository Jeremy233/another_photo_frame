import Foundation
import ImageIO
import PhotoFrameCore

// 不渲染、只读取的两个入口：检查源图（§11.2 `inspectSource`、§11.4 `inspect_image`）
// 和预估输出（`validate` / `--dry-run`）。与导出共用解码器和 PageLayout，结论与真正导出一致。

/// 源图检查结果。
public struct InspectedSource: Hashable, Sendable, Codable {
    /// 由文件头判断的格式：`jpeg`、`png`、`tiff`。
    public var format: String
    /// 文件中存储的像素尺寸。
    public var pixelSize: PixelSize
    public var orientation: ExifOrientation
    /// 方向校正后的尺寸（布局用）。
    public var displaySize: PixelSize
    public var bitDepth: Int
    public var isFloat: Bool
    public var hasAlpha: Bool
    /// 文件里是否真的带颜色描述（自己解析，PoC 坑 1）。
    public var hasEmbeddedProfile: Bool
    /// 解码时会使用的输入色彩空间描述。
    public var sourceProfile: String
    /// `embedded`、`assumedSRGB`、`override`。
    public var sourceProfileOrigin: String
    public var hdrKind: SourceHDRKind
    /// HDR headroom（线性）。gain map 取文件元数据；PQ / HLG / 浮点源在降采样解码后测峰值，是估计值。SDR 源为 nil。
    public var hdrHeadroom: Double?
    /// `metadataText` 占位符能取到的值（`camera`、`lens`、`aperture`…，见 `MetadataText`）。
    public var metadata: [String: String]
    /// 文件带 GPS。只报告有无，不输出坐标。
    public var hasGPS: Bool
    /// 文件带作者或版权信息。只报告有无。
    public var hasAuthorOrCopyright: Bool
    public var warnings: [RenderWarning]
}

/// 预估的一个输出页。
public struct PlannedPage: Hashable, Sendable, Codable {
    public var role: OutputRole
    public var pixelSize: PixelSize
}

/// 预估的输出：页数、每页尺寸、版式警告。只读文件属性，不解码像素。
public struct RenderPlan: Hashable, Sendable, Codable {
    /// 按轮播顺序。
    public var pages: [PlannedPage]
    public var sourceDisplaySize: PixelSize
    public var warnings: [RenderWarning]
}

extension PhotoFrameRenderer {
    /// 检查一张源图：格式、尺寸、方向、位深、ICC、HDR 判定（D-62）和可用的 EXIF 文字。
    /// 按小尺寸降采样解码（判断 HDR 需要像素），不会完整解码大图。
    public func inspect(_ url: URL, sourceColorOverride: SourceColorOverride? = nil) throws -> InspectedSource {
        let decoder = SourceDecoder(context: context)
        let source = try decoder.decode(url, neededSize: PixelSize(width: 512, height: 512), override: sourceColorOverride)
        let props = source.properties
        return InspectedSource(
            format: source.format.rawValue, pixelSize: source.storedSize, orientation: source.orientation,
            displaySize: source.displaySize, bitDepth: source.bitDepth, isFloat: source.isFloat, hasAlpha: source.hasAlpha,
            hasEmbeddedProfile: source.hasEmbeddedProfile, sourceProfile: source.sourceProfile,
            sourceProfileOrigin: source.sourceProfileOrigin, hdrKind: source.hdrKind, hdrHeadroom: source.headroom,
            metadata: MetadataText.values(from: props),
            hasGPS: !((props[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]).isEmpty,
            hasAuthorOrCopyright: source.author.author != nil || source.author.copyright != nil,
            warnings: source.warnings)
    }

    /// 预估导出会写出哪些页（与 `render(job:)` 的版式完全相同），用于校验和 `--dry-run`。
    public func plan(sourceURL: URL, preset: ExportPreset, maxCarouselItems: Int? = nil) throws -> RenderPlan {
        try Self.validate(preset.output)
        let probe = try Self.probe(sourceURL)
        var warnings: [RenderWarning] = []
        let layout = try PageLayout.make(preset: preset, source: probe, maxCarouselItems: maxCarouselItems, warnings: &warnings)
        return RenderPlan(
            pages: layout.pages.map { PlannedPage(role: $0.role, pixelSize: $0.canvas) },
            sourceDisplaySize: probe.displaySize, warnings: warnings)
    }
}
