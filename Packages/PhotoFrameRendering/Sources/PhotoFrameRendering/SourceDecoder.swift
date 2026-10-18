import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PhotoFrameCore

/// 解码后的源图。图像都已做方向校正，extent 原点为 (0, 0)；分辨率可能低于原图（D-18 降采样解码），
/// 合成时按各自的 extent 缩放到目标尺寸，所以 SDR 与 HDR 两份的分辨率不必相同。
struct DecodedSource {
    var format: SourceFileFormat
    var storedSize: PixelSize
    var orientation: ExifOrientation
    var bitDepth: Int
    var isFloat: Bool
    var hasAlpha: Bool
    var hasEmbeddedProfile: Bool
    var sourceProfile: String
    var sourceProfileOrigin: String
    /// SDR 版本：SDR 源本身，或源文件自带的 SDR 版本。PQ / HLG / 纯浮点 HDR 源为 nil（需要 tone map）。
    var sdr: CIImage?
    /// HDR 版本（extended 线性值可 > 1）。SDR 源为 nil。
    var hdr: CIImage?
    var hdrKind: SourceHDRKind
    /// HDR headroom（线性倍数）。
    var headroom: Double?
    /// ImageIO 读出的属性（EXIF、GPS、TIFF 字典），用于元数据文字和可选的元数据输出。
    var properties: [CFString: Any]
    /// 作者与版权（含 XMP），只在「保留作者和版权」打开时写出。
    var author: AuthorInfo
    var transformSteps: [String]
    var warnings: [RenderWarning]
    /// 解码出的位图占用的字节数（gain map JPEG 的 HDR 版本由 CI 按需展开，不计入）。预览的解码缓存按它限制总量。
    var pixelBytes = 0

    var displaySize: PixelSize { SourceImage(storedSize: storedSize, orientation: orientation).displaySize }
}

/// 源图解码（规范 §6.2、§6.3 第一段）。
struct SourceDecoder {
    var context: CIContext

    /// 峰值不超过它就视为没有超过 SDR 白（浮点噪声容差）。
    static let sdrWhiteTolerance = 1.0001

    /// - Parameter neededSize: 输出中照片需要的最大像素尺寸（显示方向）。解码时降采样到不小于它的两倍，
    ///   既控制内存（D-18），又给 Lanczos 留出足够的源像素。
    func decode(_ url: URL, neededSize: PixelSize, override: SourceColorOverride?) throws(RenderError) -> DecodedSource {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw .decodeFailed(url, "无法读取文件（\(error.localizedDescription)）")
        }
        let format = try SourceFileFormat.sniff(data)
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw .decodeFailed(url, "ImageIO 无法读取图像属性") }

        let orientation = ExifOrientation(rawValue: props[kCGImagePropertyOrientation] as? Int ?? 1) ?? .up
        let stored = PixelSize(width: width, height: height)
        let embedded = SourceFileFormat.hasEmbeddedColorDescription(data, format: format)
        var out = DecodedSource(
            format: format, storedSize: stored, orientation: orientation,
            bitDepth: props[kCGImagePropertyDepth] as? Int ?? 8,
            isFloat: props[kCGImagePropertyIsFloat] as? Bool ?? false,
            hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false,
            hasEmbeddedProfile: embedded, sourceProfile: "", sourceProfileOrigin: "embedded",
            sdr: nil, hdr: nil, hdrKind: .none, headroom: nil, properties: props,
            author: AuthorInfo(properties: props, xmp: CGImageSourceCopyMetadataAtIndex(src, 0, nil)),
            transformSteps: [], warnings: [])

        let display = out.displaySize
        let longSource = max(display.width, display.height)
        let longNeeded = max(neededSize.width, neededSize.height, 1)
        let decodeLong = min(longSource, 2 * longNeeded)
        out.transformSteps.append("decode: \(format.rawValue) \(stored) orientation \(orientation.rawValue) → 解码长边 \(decodeLong)")

        // Lightroom「最大化兼容性」TIFF：自己读 SubIFD 里的 gain map（§6.2）。
        if format == .tiff {
            do {
                if let gm = try GainMapTIFF.detect(data) {
                    // 在副本上尝试：失败（D-69 降级）时不留下这次尝试追加的警告（inout 参数在抛错时也会写回）。
                    var attempt = out
                    try decodeGainMapTIFF(gm, into: &attempt, step: max(1, longSource / (2 * longNeeded)), override: override)
                    return attempt
                }
            } catch {
                out.warnings.append(RenderWarning(
                    code: "source.hdr_not_read",
                    message: "HDR 部分未读取：文件带 gain map，但无法解析（\(error)），按 SDR 读入"))
            }
        }

        // gain map 只对 JPEG 生效。先看容器属性有没有列出 gain map（只解析文件结构）；没列出时再读辅助数据确认，
        // 它会解码整张 gain map（4500 万像素的源图要 0.1–0.2 秒），没有 gain map 的文件几乎不花时间。
        let listsGainMap = format == .jpeg && Self.listsGainMap(src)
        let hasGainMap = format == .jpeg && (listsGainMap || Self.hasGainMapAuxiliaryData(src))

        var cg = try decodeCGImage(src, url: url, longEdge: decodeLong, sourceLong: longSource)
        cg = try applyProfilePolicy(cg, embedded: embedded, override: override, into: &out)

        if out.isFloat {
            // PoC 坑 15：CI 直接使用大尺寸 RGB 浮点源会渲染出错位图块，先用 CG 转成 RGBAh（§6.2）。
            cg = try toRGBAh(cg)
            out.transformSteps.append("float source → RGBAh（CG，extended，不截断）")
        }
        out.pixelBytes = cg.bytesPerRow * cg.height
        var image = CIImage(cgImage: cg)
        if !CGImageSourceThumbnailAppliedOrientation(decodedLong: decodeLong, sourceLong: longSource) {
            image = image.oriented(CGImagePropertyOrientation(rawValue: UInt32(orientation.rawValue)) ?? .up)
        }
        image = image.translatedToOrigin()

        // gain map JPEG：底图就是摄影师确认过的 SDR 版本（§6.7 第 1 条）；HDR 由 CI 展开。
        // 只凭容器属性判定时，展开失败或没有余量再读辅助数据确认一次，结论与只看辅助数据时相同：
        // 辅助数据也读不出 gain map 就当作没有 gain map，继续下面的判定。
        let expanded = hasGainMap
            ? CIImage(contentsOf: url, options: [.expandToHDR: true, .applyOrientationProperty: true]) : nil
        if hasGainMap, !listsGainMap || (expanded?.contentHeadroom ?? 1) > 1 || Self.hasGainMapAuxiliaryData(src) {
            guard let hdr = expanded else {
                throw .decodeFailed(url, "无法展开 gain map")
            }
            out.sdr = image
            out.hdr = hdr.translatedToOrigin()
            out.hdrKind = .gainMap
            out.headroom = max(Double(hdr.contentHeadroom), 1)
            out.transformSteps.append("gain map 展开：CIImage expandToHDR，headroom \(fmt(out.headroom!))（文件元数据）")
            return out
        }

        // 「明确是 HDR」的判定（D-62）：文件本身带 HDR 标记，或浮点数据里有超过 SDR 白的值。
        // 标记：gain map（上面两种）、ICC / cICP 使用 PQ / HLG 传递函数（ImageIO 把 PNG 的 cICP 也映射成颜色空间）。
        // 没有标记的整数图一律按 SDR；没有标记、峰值 ≤ 1 的浮点图也按 SDR。
        if let space = cg.colorSpace, CGColorSpaceUsesITUR_2100TF(space) || space.isHDR() {
            // PQ / HLG：没有 SDR 版本，SDR 输出时按画面实测峰值 tone map（§6.7 第 2 条）。
            out.hdr = image
            out.hdrKind = .transferFunction
            out.headroom = estimatePeak(image)
            out.transformSteps.append("PQ/HLG：画面峰值 \(fmt(out.headroom!))（不用元数据默认 headroom）")
            if out.headroom! <= Self.sdrWhiteTolerance {
                // 标为 HDR 但没有超过 SDR 白的内容：仍记为 HDR 源，headroom = 1；SDR 版本就是它本身，
                // 不做 tone map（曲线在 headroom 1 时没有意义）；请求 HDR 输出时改写 SDR 并警告。
                out.sdr = image
                out.transformSteps.append("标为 HDR，但画面峰值 ≤ SDR 白：headroom 取 1，SDR 输出不做 tone map")
            }
            return out
        }

        if out.isFloat {
            let peak = estimatePeak(image)
            if peak > Self.sdrWhiteTolerance {
                out.hdr = image
                out.hdrKind = .floatLinear
                out.headroom = peak
                out.transformSteps.append("浮点 HDR：画面峰值 \(fmt(peak))")
                return out
            }
        }
        out.sdr = image
        return out
    }

    /// 容器属性（`kCGImagePropertyFileContentsDictionary`）里第一张图有没有列出 gain map 辅助图像。
    /// 只解析文件结构，不解码像素。
    static func listsGainMap(_ src: CGImageSource) -> Bool {
        guard let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any],
              let contents = props[kCGImagePropertyFileContentsDictionary] as? [CFString: Any],
              let images = contents[kCGImagePropertyImages] as? [[CFString: Any]],
              let auxiliary = images.first?[kCGImagePropertyAuxiliaryData] as? [[CFString: Any]]
        else { return false }
        return auxiliary.contains { item in
            guard let type = item[kCGImagePropertyAuxiliaryDataType] as? String else { return false }
            return type == kCGImageAuxiliaryDataTypeISOGainMap as String || type == kCGImageAuxiliaryDataTypeHDRGainMap as String
        }
    }

    /// ImageIO 能读出 ISO 21496-1 或 Apple gain map 辅助数据（会解码 gain map）。
    static func hasGainMapAuxiliaryData(_ src: CGImageSource) -> Bool {
        CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }

    // MARK: - 解码

    private func decodeCGImage(_ src: CGImageSource, url: URL, longEdge: Int, sourceLong: Int) throws(RenderError) -> CGImage {
        let image: CGImage?
        if longEdge < sourceLong {
            // ImageIO 缩略图 API 按需降采样解码，保留颜色空间与位深（PoC §4），并应用方向。
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longEdge,
                kCGImageSourceShouldAllowFloat: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary)
        }
        guard let image else { throw .decodeFailed(url, "ImageIO 解码失败") }
        return image
    }

    /// 输入颜色描述的决策（D-04、PoC 坑 1 与坑 20）。只改颜色空间标签，不改像素。
    private func applyProfilePolicy(
        _ cg: CGImage, embedded: Bool, override: SourceColorOverride?, into out: inout DecodedSource
    ) throws(RenderError) -> CGImage {
        let current = cg.colorSpace
        let profileMissing = Self.profileMissing
        // 坑 20 / D-58：TRC 为 BT.709 / BT.2020 逆 OETF 参数曲线时改写成采样曲线。嵌入的 ICC 和覆盖（Rec. 2020）都要改。
        func rewritingTRC(_ space: CGColorSpace?) -> CGImage? {
            guard let data = space?.copyICCData() as Data?, let icc = ICCProfile(data), let p = icc.bt709FamilyParametricTRC,
                  let fixed = CGColorSpace(iccData: icc.replacingTRC(samples: ICCProfile.sampledCurve(p)) as CFData),
                  let retagged = cg.copy(colorSpace: fixed)
            else { return nil }
            out.transformSteps.append("ICC TRC 为 BT.709/2020 逆 OETF 参数曲线 → 改写为 4096 点采样曲线（PoC 坑 20）")
            return retagged
        }
        // 覆盖只用于没有颜色描述的源图（§6.2「无 ICC 策略」、D-04）；文件自带 ICC 时以文件为准，忽略覆盖并警告。
        if let override, embedded {
            out.warnings.append(Self.overrideIgnored(override, embedded: WorkingColor.describe(current)))
        } else if let override {
            let space = WorkingColor.space(for: override)
            guard current?.model == .rgb, let retagged = cg.copy(colorSpace: space) else {
                // 非 RGB：覆盖用不上，与没有覆盖时一样按缺少颜色描述处理（像素保持原颜色空间）。
                out.warnings.append(RenderWarning(code: "source.override_ignored", message: "源图不是 RGB 图像，忽略指定的输入色彩空间"))
                out.warnings.append(profileMissing)
                out.sourceProfile = WorkingColor.describe(current)
                out.sourceProfileOrigin = "assumedSRGB"
                return cg
            }
            out.sourceProfile = override.displayName
            out.sourceProfileOrigin = "override"
            out.transformSteps.append("输入色彩空间覆盖为 \(override.displayName)")
            return rewritingTRC(space) ?? retagged
        }
        if !embedded {
            // 非 RGB 图像保留自己的颜色空间（不改标签），诊断里写它本身，不写 sRGB。
            out.sourceProfile = current?.model == .rgb ? "sRGB IEC61966-2.1" : WorkingColor.describe(current)
            out.sourceProfileOrigin = "assumedSRGB"
            out.warnings.append(profileMissing)
            if current?.model == .rgb, current?.name != CGColorSpace.sRGB, let tagged = cg.copy(colorSpace: WorkingColor.sRGB) {
                return tagged
            }
            return cg
        }
        out.sourceProfile = WorkingColor.describe(current)
        return rewritingTRC(current) ?? cg
    }

    /// 没有 ICC（D-04）：GUI、CLI、MCP 都显示这一句。
    static let profileMissing = RenderWarning(code: "source.profile_missing", message: "源图没有 ICC，按 sRGB 解释")

    static func overrideIgnored(_ override: SourceColorOverride, embedded: String) -> RenderWarning {
        RenderWarning(code: "source.override_ignored",
                      message: "源图自带 ICC（\(embedded)），忽略指定的输入色彩空间 \(override.displayName)：它只用于没有 ICC 的源图")
    }

    private func decodeGainMapTIFF(
        _ gm: GainMapTIFF, into out: inout DecodedSource, step: Int, override: SourceColorOverride?
    ) throws {
        var iccData = gm.file.bytes(gm.base, 34675)
        if let override, iccData != nil {
            out.warnings.append(Self.overrideIgnored(override, embedded: "嵌入的 ICC"))
        } else if let override {
            iccData = WorkingColor.space(for: override).copyICCData() as Data?
            out.sourceProfileOrigin = "override"
        } else if iccData == nil {
            iccData = WorkingColor.sRGB.copyICCData() as Data?
            out.sourceProfileOrigin = "assumedSRGB"
            out.warnings.append(Self.profileMissing)
        }
        guard let iccData, let icc = ICCProfile(iccData), let trc = icc.trcFunctions,
              let linearSpace = CGColorSpace(iccData: icc.linearized as CFData),
              let extended = CGColorSpaceCreateExtended(linearSpace)
        else { throw TIFFError("底图 ICC 无法用于线性化") }

        let isFloatBase = (try? gm.file.int(gm.base, 339)) == 3
        // 浮点底图本来就是线性值（Lightroom 32 位「Linear Rec. 2020」）；整数底图按 ICC 曲线自己线性化（绕开坑 20）。
        let r = try gm.reconstruct(step: step) { v, c in isFloatBase ? v : trc[c](v) }
        func image(_ bytes: Data) throws -> CIImage {
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGImageByteOrderInfo.order16Little.rawValue
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let cg = CGImage(width: r.width, height: r.height, bitsPerComponent: 16, bitsPerPixel: 64,
                                   bytesPerRow: r.width * 8, space: extended, bitmapInfo: CGBitmapInfo(rawValue: info),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw TIFFError("无法构造线性图像") }
            return CIImage(cgImage: cg)
                .oriented(CGImagePropertyOrientation(rawValue: UInt32(out.orientation.rawValue)) ?? .up)
                .translatedToOrigin()
        }
        out.sdr = try image(r.sdr)
        out.hdr = try image(r.hdr)
        out.pixelBytes = 2 * r.width * r.height * 8
        out.hdrKind = .gainMapTIFF
        out.headroom = gm.metadata.headroom
        out.hasEmbeddedProfile = gm.file.bytes(gm.base, 34675) != nil
        out.sourceProfile = icc.descriptionText ?? "ICC"
        out.transformSteps.append(
            "gain map TIFF：SubIFD 解析，ISO 21496-1 完全展开，headroom \(fmt(gm.metadata.headroom))；"
                + "底图\(isFloatBase ? "为线性浮点" : "按 ICC 曲线自己线性化")，降采样 1/\(step)")
    }

    // MARK: - 工具

    /// 画在同一颜色空间（extended 版本）的 RGBAh 位图里，不截断 > 1 或负值。
    private func toRGBAh(_ img: CGImage) throws(RenderError) -> CGImage {
        let space = img.colorSpace.flatMap { CGColorSpaceCreateExtended($0) } ?? WorkingColor.space
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGImageByteOrderInfo.order16Little.rawValue
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 16, bytesPerRow: 0,
                                  space: space, bitmapInfo: info)
        else { throw RenderError(code: "render.out_of_memory", message: "无法分配 \(img.width)×\(img.height) 的 RGBAh 缓冲") }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let out = ctx.makeImage() else { throw RenderError(code: "render.out_of_memory", message: "RGBAh 转换失败") }
        return out
    }

    /// 画面实际峰值：线性 sRGB 分量最大值的 99.95 分位（§6.7 第 2 条），至少为 1。
    func estimatePeak(_ image: CIImage) -> Double {
        let e = image.extent
        let s = min(1, 1024 / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let r = CGRect(x: 0, y: 0, width: max(1, (e.width * s).rounded(.down)), height: max(1, (e.height * s).rounded(.down)))
        let w = Int(r.width), h = Int(r.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            context.render(small, toBitmap: buf.baseAddress!, rowBytes: w * 16, bounds: r, format: .RGBAf,
                           colorSpace: WorkingColor.extendedLinearSRGB)
        }
        var maxima = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { maxima[i] = max(px[4 * i], px[4 * i + 1], px[4 * i + 2]) }
        let index = min(maxima.count - 1, Int((Double(maxima.count - 1) * 0.9995).rounded()))
        // 只要排序后第 index 个值（与 `maxima.sorted()[index]` 相同），不排序整个数组：最小堆保留最大的 n − index 个值，
        // 堆顶就是它。有 NaN 时比较不成全序，仍按原来的排序取值，结果不变。
        func sortedValue(at index: Int) -> Float {
            if maxima.contains(where: \.isNaN) { return maxima.sorted()[index] }
            let k = maxima.count - index
            var heap = [Float]()
            heap.reserveCapacity(k)
            for x in maxima {
                if heap.count < k {
                    heap.append(x)
                    var i = heap.count - 1
                    while i > 0, heap[(i - 1) / 2] > heap[i] { heap.swapAt(i, (i - 1) / 2); i = (i - 1) / 2 }
                } else if x > heap[0] {
                    heap[0] = x
                    var i = 0
                    while true {
                        let child = 2 * i + 1
                        var m = i
                        if child < k, heap[child] < heap[m] { m = child }
                        if child + 1 < k, heap[child + 1] < heap[m] { m = child + 1 }
                        if m == i { break }
                        heap.swapAt(i, m); i = m
                    }
                }
            }
            return heap[0]
        }
        return max(1, Double(sortedValue(at: index)))
    }
}

/// 缩略图 API 带 `WithTransform` 时已经按方向旋转；完整解码时没有。
private func CGImageSourceThumbnailAppliedOrientation(decodedLong: Int, sourceLong: Int) -> Bool {
    decodedLong < sourceLong
}

extension CIImage {
    /// 平移到 extent 原点为 (0, 0)。
    func translatedToOrigin() -> CIImage {
        let e = extent
        guard e.minX != 0 || e.minY != 0 else { return self }
        return transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }
}

func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
