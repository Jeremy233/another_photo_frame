import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PhotoFrameCore
import UniformTypeIdentifiers

/// 编码与写出（§6.3 最后两段、§6.8）。
///
/// - SDR：CI 显式渲染成 sRGB 8-bit，再交给 ImageIO 编码。ImageIO 拿到 float / extended 图像会自作主张转换
///   （PoC 坑 3），拿到 sRGB 8-bit 不改像素。
/// - HDR：只走 CI 的 `.hdrImage` 路线（PoC 坑 4、5），显式标源 headroom、RGB gain map（坑 17）。
/// - ImageIO 写 sRGB JPEG 不嵌 ICC（坑 2），写完后检查，缺了就自己插入 APP2 ICC_PROFILE 段（§6.8、§6.9）。
struct OutputEncoder {
    var context: CIContext

    struct Written {
        var byteCount: Int
        var warnings: [String]
    }

    func writeSDR(
        _ page: CIImage, size: PixelSize, settings: OutputSettings, metadata: [CFString: Any], to url: URL
    ) throws(RenderError) -> Written {
        try Self.encodeSDR(try renderSRGB8(page, size: size), settings: settings, metadata: metadata, to: url)
    }

    /// ``writeSDR(_:size:settings:metadata:to:)`` 的后半段：已经渲染好的 sRGB 8-bit 位图交给 ImageIO 编码并写出。
    /// 不用 CI，可以在别的线程上与下一页的渲染同时进行。
    static func encodeSDR(_ cg: CGImage, settings: OutputSettings, metadata: [CFString: Any], to url: URL) throws(RenderError) -> Written {
        let type: UTType = settings.format == .jpeg ? .jpeg : .png
        var props = metadata
        if settings.format == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = Double(min(max(settings.quality, 1), 100)) / 100
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw encodeFailed(url, "无法创建编码器")
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw encodeFailed(url, "ImageIO 编码失败") }
        var bytes = data as Data
        if settings.format == .jpeg { bytes = try Self.ensureICC(bytes) }
        try write(bytes, to: url)
        return Written(byteCount: bytes.count, warnings: [])
    }

    /// 带 ISO 21496-1 gain map 的 JPEG：SDR 底图 + gain map（不支持 HDR 的设备显示底图）。
    func writeHDRJPEG(
        sdr: CIImage, hdr: CIImage, headroom: Double, size: PixelSize, settings: OutputSettings,
        metadata: [CFString: Any], to url: URL
    ) throws(RenderError) -> Written {
        var bytes = try hdrJPEGData(sdr: sdr, hdr: hdr, headroom: headroom, size: size, quality: settings.quality, name: url.lastPathComponent)
        var warnings: [String] = []
        if !metadata.isEmpty {
            if let merged = Self.mergingMetadata(bytes, metadata) {
                bytes = merged
            } else {
                warnings.append("HDR 输出无法在保留 gain map 的同时写入所选元数据，已省略元数据")
            }
        }
        bytes = try Self.ensureICC(bytes) // 合并元数据可能去掉 ICC
        try Self.write(bytes, to: url)
        return Written(byteCount: bytes.count, warnings: warnings)
    }

    /// gain map JPEG 的字节（已嵌入 sRGB ICC）。导出与 HDR 预览（D-106）共用。
    func hdrJPEGData(
        sdr: CIImage, hdr: CIImage, headroom: Double, size: PixelSize, quality: Int, name: String = "预览"
    ) throws(RenderError) -> Data {
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String):
                Double(min(max(quality, 1), 100)) / 100,
            .hdrImage: hdr.cropped(to: rect).settingContentHeadroom(Float(headroom)),
            .hdrGainMapAsRGB: true,
        ]
        guard let bytes = context.jpegRepresentation(of: sdr.cropped(to: rect), colorSpace: WorkingColor.sRGB, options: options) else {
            throw RenderError(code: "render.encode_failed", message: "编码 \(name) 失败：Core Image 无法写出 gain map JPEG")
        }
        return try Self.ensureICC(bytes)
    }

    /// 工作空间 → sRGB 8-bit（超出色域逐通道截断，PoC §3.2）。不带 alpha：页面总是不透明的。
    func renderSRGB8(_ page: CIImage, size: PixelSize) throws(RenderError) -> CGImage {
        let rowBytes = size.width * 4
        var pixels = Data(count: rowBytes * size.height)
        pixels.withUnsafeMutableBytes { buf in
            context.render(page, toBitmap: buf.baseAddress!, rowBytes: rowBytes,
                           bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                           format: .RGBA8, colorSpace: WorkingColor.sRGB)
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let cg = CGImage(width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: rowBytes, space: WorkingColor.sRGB,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw RenderError(code: "render.encode_failed", message: "无法构造 sRGB 位图") }
        return cg
    }

    private static func write(_ data: Data, to url: URL) throws(RenderError) {
        do { try data.write(to: url, options: .withoutOverwriting) } catch {
            throw RenderError(code: "render.write_failed", message: "无法写出 \(url.lastPathComponent)：\(error.localizedDescription)",
                              hint: "检查临时目录是否可写、磁盘空间是否足够，以及目标文件是否已存在")
        }
    }

    private static func encodeFailed(_ url: URL, _ why: String) -> RenderError {
        RenderError(code: "render.encode_failed", message: "编码 \(url.lastPathComponent) 失败：\(why)")
    }

    // MARK: - JPEG 后处理

    /// JPEG 没有 APP2 ICC_PROFILE 时，在 SOI 与 JFIF / EXIF 段之后插入 sRGB ICC。
    ///
    /// 插在 MPF（APP2 "MPF"）段之前：MPF 里副图（gain map）的偏移相对于 MPF 头本身，
    /// 整体后移不影响它，gain map 仍能读回（测试覆盖）。
    static func ensureICC(_ jpeg: Data) throws(RenderError) -> Data {
        let d = Data(jpeg)
        if JPEGSegments.contains(d, marker: 0xE2, prefix: Data("ICC_PROFILE\0".utf8)) { return d }
        guard let icc = WorkingColor.sRGB.copyICCData() as Data?, icc.count + 16 < 0xFFFF else {
            throw RenderError(code: "render.encode_failed", message: "无法取得 sRGB ICC 数据")
        }
        var payload = Data("ICC_PROFILE\0".utf8)
        payload.append(1) // 序号
        payload.append(1) // 总段数
        payload += icc
        var segment = Data([0xFF, 0xE2])
        segment.append(UInt8((payload.count + 2) >> 8))
        segment.append(UInt8((payload.count + 2) & 0xFF))
        segment += payload
        let insertAt = JPEGSegments.headerSegments(d)
            .prefix { $0.marker == 0xE0 || $0.marker == 0xE1 }
            .last.map { $0.offset + 2 + $0.length } ?? 2
        var out = d
        out.insert(contentsOf: segment, at: out.startIndex + insertAt)
        return out
    }

    /// 无损替换元数据；如果结果里 gain map 丢了就放弃（返回 nil）。
    static func mergingMetadata(_ jpeg: Data, _ metadata: [CFString: Any]) -> Data? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let type = CGImageSourceGetType(src),
              let meta = imageMetadata(for: metadata) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil) else { return nil }
        let result = out as Data
        guard let check = CGImageSourceCreateWithData(result as CFData, nil),
              CGImageSourceCopyAuxiliaryDataInfoAtIndex(check, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        else { return nil }
        return result
    }

    /// 由属性字典得到与 SDR 输出相同的元数据（XMP 形式），供 HDR 文件合并。
    ///
    /// 不能逐项用 `CGImageMetadataSetValueMatchingImageProperty` 填：有理数（光圈、快门、焦距、曝光补偿、GPS 海拔）
    /// 会存成十进制字符串，写回 EXIF 时只剩整数部分（f/5.6 → 5，1/250 s → 0）。这里让 ImageIO 按属性字典
    /// 编码一张 1×1 的 JPEG（与 SDR 输出写元数据的方式相同），取它的元数据，再去掉这张小图自己的尺寸与色彩空间。
    static func imageMetadata(for properties: [CFString: Any]) -> CGImageMetadata? {
        var pixel: UInt32 = 0
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(bytes: &pixel, count: 4) as CFData),
              let tiny = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                 space: WorkingColor.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, tiny, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let copied = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let meta = CGImageMetadataCreateMutableCopy(copied)
        else { return nil }
        for path in ["exif:PixelXDimension", "exif:PixelYDimension", "exif:ColorSpace"] {
            CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString)
        }
        return meta
    }
}
