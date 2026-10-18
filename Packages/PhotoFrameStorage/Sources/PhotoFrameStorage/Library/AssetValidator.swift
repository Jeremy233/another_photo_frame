import Compression
import Foundation
import ImageIO
import PhotoFrameCore

/// 素材导入上限（§8.2、§12.2）。
public struct AssetImportLimits: Hashable, Sendable {
    public var maxPNGBytes: Int
    /// 与渲染模块解析受限 SVG 的上限一致。
    public var maxSVGBytes: Int
    /// 单边最大像素。
    public var maxDimension: Int
    /// 最大像素总数。PNG 校验时按 IHDR 声明的尺寸计算解压后大小，超过这个值直接拒绝，不解压。
    public var maxPixelCount: Int
    public var maxSVGElements: Int
    public var maxSVGDepth: Int

    public init(maxPNGBytes: Int, maxSVGBytes: Int, maxDimension: Int, maxPixelCount: Int, maxSVGElements: Int, maxSVGDepth: Int) {
        self.maxPNGBytes = maxPNGBytes
        self.maxSVGBytes = maxSVGBytes
        self.maxDimension = maxDimension
        self.maxPixelCount = maxPixelCount
        self.maxSVGElements = maxSVGElements
        self.maxSVGDepth = maxSVGDepth
    }

    /// D-85：PNG ≤ 64 MiB、SVG ≤ 8 MiB、单边 ≤ 16384 px、总像素 ≤ 64 MP、SVG ≤ 50000 个元素、嵌套 ≤ 64 层。
    public static let `default` = AssetImportLimits(
        maxPNGBytes: 64 << 20, maxSVGBytes: 8 << 20, maxDimension: 16384, maxPixelCount: 64 << 20,
        maxSVGElements: 50_000, maxSVGDepth: 64)
}

/// 通过检查的素材内容。
public struct ValidatedAsset: Hashable, Sendable {
    public var format: AssetSlot.Format
    /// PNG 的像素尺寸；SVG 的固有尺寸（四舍五入）。
    public var pixelSize: PixelSize
    /// 要存进库里的字节。PNG 会去掉 IEND 之后的多余数据。
    public var data: Data
    /// 不阻止导入的问题，例如 SVG 里渲染时会被跳过的元素。
    public var warnings: [String]
}

/// 素材内容检查：类型、大小、尺寸、编码有效性（D-09、§8.2、§12.2）。不信任扩展名，按内容判断。
public enum AssetValidator {
    /// 按扩展名确定期望格式，再检查内容。
    public static func validate(_ data: Data, fileExtension: String, limits: AssetImportLimits = .default) throws(LibraryError) -> ValidatedAsset {
        guard let format = AssetSlot.Format(rawValue: fileExtension.lowercased()) else {
            throw .assetRejected(.unsupportedType(fileExtension))
        }
        return try validate(data, format: format, limits: limits)
    }

    public static func validate(_ data: Data, format: AssetSlot.Format, limits: AssetImportLimits = .default) throws(LibraryError) -> ValidatedAsset {
        do {
            switch format {
            case .png: return try validatePNG(data, limits: limits)
            case .svg: return try validateSVG(data, limits: limits)
            }
        } catch {
            throw .assetRejected(error)
        }
    }

    // MARK: - PNG

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func validatePNG(_ data: Data, limits: AssetImportLimits) throws(AssetRejection) -> ValidatedAsset {
        guard data.count <= limits.maxPNGBytes else { throw .tooLarge(bytes: data.count, limit: limits.maxPNGBytes) }
        guard data.count >= 8, data.starts(with: pngSignature) else { throw .typeMismatch(expected: .png) }

        // 1. 逐块检查结构和 CRC，先拿到 IHDR，确认尺寸再解压。直接按下标读 `data`，CRC 在切片上算，不复制文件内容。
        let base = data.startIndex
        var offset = 8
        var header: (width: Int, height: Int, bitDepth: UInt8, colorType: UInt8, interlace: UInt8)?
        var idatRanges: [Range<Int>] = []
        var idatSize = 0
        var sawPalette = false
        var end: Int?
        func byte(_ i: Int) -> UInt8 { data[base + i] }
        func be32(_ i: Int) -> UInt32 {
            UInt32(byte(i)) << 24 | UInt32(byte(i + 1)) << 16 | UInt32(byte(i + 2)) << 8 | UInt32(byte(i + 3))
        }
        /// `data` 中的一段（切片与 `data` 共用存储）。
        func bytes(_ r: Range<Int>) -> Data { data[(base + r.lowerBound)..<(base + r.upperBound)] }
        while end == nil {
            guard offset + 12 <= data.count else { throw .corrupted("文件被截断（缺少 IEND）") }
            let length = Int(be32(offset))
            guard length <= data.count - offset - 12 else { throw .corrupted("数据块长度越界") }
            let type = String(decoding: bytes((offset + 4)..<(offset + 8)), as: UTF8.self)
            let body = (offset + 8)..<(offset + 8 + length)
            let crc = be32(offset + 8 + length)
            guard CRC32.checksum(bytes((offset + 4)..<(offset + 8 + length))) == crc else {
                throw .corrupted("数据块 \(type) 校验和不符")
            }
            if header == nil, type != "IHDR" { throw .corrupted("第一个数据块不是 IHDR") }
            switch type {
            case "IHDR":
                guard header == nil, length == 13 else { throw .corrupted("IHDR 无效") }
                let b = body.lowerBound
                header = (Int(be32(b)), Int(be32(b + 4)), byte(b + 8), byte(b + 9), byte(b + 12))
                guard byte(b + 10) == 0, byte(b + 11) == 0, byte(b + 12) <= 1 else { throw .corrupted("IHDR 的压缩、过滤或隔行方式无效") }
            case "PLTE":
                sawPalette = true
            case "IDAT":
                guard idatSize + length <= limits.maxPNGBytes else { throw .corrupted("IDAT 过大") }
                idatSize += length
                idatRanges.append(body)
            case "acTL", "fcTL", "fdAT":
                throw AssetRejection(code: "asset.unsupported_type", message: "不支持动画 PNG", hint: "请导出为静态 PNG")
            case "IEND":
                end = offset + 12 + length
            default:
                break
            }
            offset += 12 + length
        }
        guard let h = header else { throw .corrupted("缺少 IHDR") }
        let size = PixelSize(width: h.width, height: h.height)
        guard h.width > 0, h.height > 0 else { throw .dimensions(size, "宽高必须大于 0") }
        guard h.width <= limits.maxDimension, h.height <= limits.maxDimension else {
            throw .dimensions(size, "单边不能超过 \(limits.maxDimension) px")
        }
        guard h.width * h.height <= limits.maxPixelCount else {
            throw .dimensions(size, "像素总数不能超过 \(limits.maxPixelCount)")
        }
        guard let channels = channelCount(colorType: h.colorType, bitDepth: h.bitDepth) else {
            throw .corrupted("不支持的颜色类型 \(h.colorType) / 位深 \(h.bitDepth)")
        }
        if h.colorType == 3, !sawPalette { throw .corrupted("索引色 PNG 缺少调色板") }
        guard idatSize > 0 else { throw .corrupted("没有图像数据") }

        // 2. 流式解压，只数字节、不保留输出：大小必须与 IHDR 推算的完全一致（防压缩炸弹、防截断）。
        // zlib 流可以跨多个 IDAT，按顺序拼起来；只有一个 IDAT 时直接用切片，不复制。
        let idat = idatRanges.count == 1
            ? bytes(idatRanges[0])
            : idatRanges.reduce(into: Data(capacity: idatSize)) { $0.append(bytes($1)) }
        let expected = inflatedSize(width: h.width, height: h.height, bitsPerPixel: channels * Int(h.bitDepth), interlaced: h.interlace == 1)
        try checkZlibStream(idat, expectedSize: expected)

        // 3. 交给 ImageIO 实际解码一次。
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) != nil
        else { throw .corrupted("系统无法解码该 PNG") }

        var warnings: [String] = []
        var stored = data
        if let end, end < data.count {
            stored = data.prefix(end)
            warnings.append("已去掉 IEND 之后 \(data.count - end) 字节的多余数据")
        }
        // 下标从 0 开始时（通常如此）直接用，不再复制一份。
        return ValidatedAsset(format: .png, pixelSize: size, data: stored.startIndex == 0 ? stored : Data(stored), warnings: warnings)
    }

    static func channelCount(colorType: UInt8, bitDepth: UInt8) -> Int? {
        switch (colorType, bitDepth) {
        case (0, 1), (0, 2), (0, 4), (0, 8), (0, 16): 1
        case (2, 8), (2, 16): 3
        case (3, 1), (3, 2), (3, 4), (3, 8): 1
        case (4, 8), (4, 16): 2
        case (6, 8), (6, 16): 4
        default: nil
        }
    }

    /// 每行前有 1 字节过滤类型；Adam7 隔行时按 7 个子图分别计算。
    static func inflatedSize(width: Int, height: Int, bitsPerPixel: Int, interlaced: Bool) -> Int {
        func rows(_ w: Int, _ h: Int) -> Int { w == 0 || h == 0 ? 0 : h * (1 + (w * bitsPerPixel + 7) / 8) }
        guard interlaced else { return rows(width, height) }
        let passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
        return passes.reduce(0) { sum, p in
            let w = width > p.0 ? (width - p.0 + p.2 - 1) / p.2 : 0
            let h = height > p.1 ? (height - p.1 + p.3 - 1) / p.3 : 0
            return sum + rows(w, h)
        }
    }

    /// zlib 流：2 字节头 + raw deflate + 4 字节 Adler-32。只检查 deflate 部分能完整解出恰好 `expectedSize` 字节。
    static func checkZlibStream(_ zlib: Data, expectedSize: Int) throws(AssetRejection) {
        guard zlib.count > 6 else { throw .corrupted("图像数据过短") }
        let cmf = zlib[zlib.startIndex], flg = zlib[zlib.startIndex + 1]
        guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0, flg & 0x20 == 0 else {
            throw .corrupted("图像数据的 zlib 头无效")
        }
        let deflate = zlib.dropFirst(2)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw .corrupted("无法初始化解压")
        }
        defer { compression_stream_destroy(stream) }
        let chunk = 1 << 16
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var total = 0
        var failure: String?
        deflate.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = src.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let before = stream.pointee.src_size
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                total += produced
                if total > expectedSize { failure = "解压后的数据比声明的尺寸大"; return }
                if status == COMPRESSION_STATUS_END { return }
                if status != COMPRESSION_STATUS_OK { failure = "图像数据无法解压"; return }
                if produced == 0, stream.pointee.src_size == before { failure = "图像数据被截断"; return }
            }
        }
        if let failure { throw .corrupted(failure) }
        guard total == expectedSize else { throw .corrupted("解压后的数据比声明的尺寸小") }
    }

    // MARK: - SVG

    /// 受限 SVG 的规则（D-09、D-87）。与 PhotoFrameRendering 的 `RestrictedSVG` 保持一致：导入时拒绝的，渲染时也一定拒绝。
    public enum SVGPolicy {
        /// 导入时出现即拒绝整个文件 = 渲染也拒绝的 ``renderingForbiddenElements`` + 动画元素（D-87：渲染时跳过它们，导入时没必要接受）。
        public static let forbiddenElements: Set<String> = renderingForbiddenElements.union(animationElements)
        /// 渲染模块（`RestrictedSVG`）也拒绝的元素：脚本、外部内容、样式表、链接。
        public static let renderingForbiddenElements: Set<String> = [
            "script", "foreignObject", "image", "use", "iframe", "style", "feImage", "a", "handler", "listener",
        ]
        /// 动画元素：导入时拒绝，渲染时连同子树跳过并警告。
        public static let animationElements: Set<String> = ["animate", "animateMotion", "animateTransform", "set"]
        public static let ignoredElements: Set<String> = ["title", "desc", "metadata"]
        public static let shapeElements: Set<String> = ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon"]
        public static let containerElements: Set<String> = ["svg", "g"]
    }

    static func validateSVG(_ data: Data, limits: AssetImportLimits) throws(AssetRejection) -> ValidatedAsset {
        guard data.count <= limits.maxSVGBytes else { throw .tooLarge(bytes: data.count, limit: limits.maxSVGBytes) }
        guard !data.starts(with: pngSignature), let text = String(data: data, encoding: .utf8) else {
            throw .typeMismatch(expected: .svg)
        }
        let lower = text.lowercased()
        guard lower.contains("<svg") else { throw .typeMismatch(expected: .svg) }
        if lower.contains("<!doctype") || lower.contains("<!entity") { throw .svg("不允许 DOCTYPE / ENTITY 声明") }

        let checker = SVGChecker(limits: limits)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = checker
        let ok = parser.parse()
        if let reason = checker.failure { throw .svg(reason) }
        guard ok else { throw .svg("XML 解析失败") }
        guard let size = checker.size else { throw .svg("没有 <svg> 根元素") }
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            throw .svg("缺少有效的 width / height 或 viewBox")
        }
        // ≥ 2^63 时 Int(_:) 会崩溃：按 Int.max 算，交给下面的范围检查拒绝。
        func pixels(_ v: Double) -> Int { max(1, Int(exactly: v.rounded()) ?? .max) }
        let pixel = PixelSize(width: pixels(size.width), height: pixels(size.height))
        guard pixel.width <= limits.maxDimension * 4, pixel.height <= limits.maxDimension * 4 else {
            throw .svg("固有尺寸 \(pixel.width)×\(pixel.height) 过大")
        }
        var warnings = checker.skipped.sorted().map { "渲染时会跳过不支持的元素 <\($0)>" }
        if checker.shapeCount == 0 { warnings.append("SVG 里没有可绘制的基本图形或路径") }
        return ValidatedAsset(format: .svg, pixelSize: pixel, data: data, warnings: warnings)
    }

    final class SVGChecker: NSObject, XMLParserDelegate {
        let limits: AssetImportLimits
        var failure: String?
        var size: (width: Double, height: Double)?
        var elementCount = 0
        var depth = 0
        var shapeCount = 0
        var skipped: Set<String> = []
        /// > 0 时处于渲染会跳过的子树中。
        var skipDepth = 0

        init(limits: AssetImportLimits) { self.limits = limits }

        func fail(_ parser: XMLParser, _ why: String) {
            if failure == nil { failure = why }
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            elementCount += 1
            depth += 1
            guard elementCount <= limits.maxSVGElements else { return fail(parser, "元素超过 \(limits.maxSVGElements) 个") }
            guard depth <= limits.maxSVGDepth else { return fail(parser, "嵌套超过 \(limits.maxSVGDepth) 层") }
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if SVGPolicy.forbiddenElements.contains(local) { return fail(parser, "不允许 <\(local)>") }
            for (key, value) in attributes {
                let k = key.lowercased()
                if k.hasSuffix("href") { return fail(parser, "不允许外部引用（\(key)）") }
                if k.hasPrefix("on") { return fail(parser, "不允许事件属性（\(key)）") }
                let v = value.lowercased()
                if v.contains("url(") || v.contains("javascript:") || v.contains("data:") {
                    return fail(parser, "不允许引用（\(key)）")
                }
            }
            if size == nil {
                guard local == "svg" else { return fail(parser, "根元素不是 <svg>") }
                size = Self.intrinsicSize(attributes)
                return
            }
            if skipDepth > 0 { skipDepth += 1; return }
            if SVGPolicy.ignoredElements.contains(local) { skipDepth = 1; return }
            if SVGPolicy.shapeElements.contains(local) {
                shapeCount += 1
            } else if !SVGPolicy.containerElements.contains(local) {
                skipped.insert(local)
                skipDepth = 1
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            depth -= 1
            if skipDepth > 0 { skipDepth -= 1 }
        }

        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            // `<?xml …?>` 声明不会走到这里；其他处理指令（如 xml-stylesheet）可能引用外部资源。
            fail(parser, "不允许处理指令 <?\(target)?>")
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            fail(parser, "不允许 ENTITY 声明")
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            fail(parser, "不允许 ENTITY 声明")
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            if failure == nil { failure = "XML 解析失败（第 \(parser.lineNumber) 行）" }
        }

        /// 与渲染模块相同：width / height 缺省取 viewBox；只给一个时按 viewBox 比例推算。
        static func intrinsicSize(_ a: [String: String]) -> (width: Double, height: Double) {
            let w = a["width"].flatMap(length), h = a["height"].flatMap(length)
            var vb: (Double, Double)?
            if let v = a["viewBox"].map(numbers), v.count == 4, v[2] > 0, v[3] > 0 { vb = (v[2], v[3]) }
            var width = w ?? vb?.0 ?? 0
            var height = h ?? vb?.1 ?? 0
            if w == nil, let h, let vb { width = h * vb.0 / vb.1 }
            if h == nil, let w, let vb { height = w * vb.1 / vb.0 }
            return (width, height)
        }

        /// 只接受无单位或 px；百分比等相对单位视为没有给出。
        static func length(_ s: String) -> Double? {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("px") { t.removeLast(2) }
            return Double(t)
        }

        static func numbers(_ s: String) -> [Double] {
            s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }).compactMap { Double($0) }
        }
    }
}
