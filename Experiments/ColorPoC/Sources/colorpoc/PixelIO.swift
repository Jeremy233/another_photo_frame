import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 简单的 RGBA 浮点图像。值是"文件里存的编码值"或"渲染出的值"，不隐含任何色彩空间。
struct FImage {
    var w: Int, h: Int
    var px: [Float]   // RGBA，行优先

    init(w: Int, h: Int, fill: Float = 0) { self.w = w; self.h = h; px = .init(repeating: fill, count: w * h * 4) }

    subscript(x: Int, y: Int) -> SIMD4<Float> {
        get { let i = (y * w + x) * 4; return SIMD4(px[i], px[i + 1], px[i + 2], px[i + 3]) }
        set { let i = (y * w + x) * 4; px[i] = newValue.x; px[i + 1] = newValue.y; px[i + 2] = newValue.z; px[i + 3] = newValue.w }
    }
    func rgb(_ x: Int, _ y: Int) -> V3 { let p = self[x, y]; return V3(Double(p.x), Double(p.y), Double(p.z)) }
}

enum PixelFormat {
    case u8, u16, half, float32
    var bits: Int { switch self { case .u8: 8; case .u16, .half: 16; case .float32: 32 } }
}

struct RawInfo: Codable {
    var bitsPerComponent: Int
    var isFloat: Bool
    var alpha: String
    var colorSpace: String
}

/// 直接解析 CGImage 的像素内存，不经过任何颜色转换（区分"解码"与"转换"）。
func readRaw(_ img: CGImage) -> (FImage, RawInfo) {
    let w = img.width, h = img.height, bpc = img.bitsPerComponent, bpp = img.bitsPerPixel
    let info = img.bitmapInfo
    let isFloat = info.contains(.floatComponents)
    let alphaInfo = img.alphaInfo
    let ncolor = img.colorSpace?.numberOfComponents ?? 3
    let ncomp = bpp / bpc
    let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(alphaInfo) || false
    let alphaFirst = [.first, .premultipliedFirst, .noneSkipFirst].contains(alphaInfo)
    let order = CGImageByteOrderInfo(rawValue: info.rawValue & CGBitmapInfo.byteOrderMask.rawValue) ?? .orderDefault
    let little = order == .order16Little || order == .order32Little
    let data = img.dataProvider!.data! as Data
    let rowBytes = img.bytesPerRow
    var out = FImage(w: w, h: h, fill: 1)

    // 10-bit 打包格式（ImageIO 对 PQ/HDR 解码可能返回）：RGB101010 或 Apple 的 extended-range RGBCIF10。
    if bpc == 10 {
        let cif = img.pixelFormatInfo == .RGBCIF10
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for y in 0..<h {
                for x in 0..<w {
                    let o = y * rowBytes + x * 4
                    let word = little ? UInt32(raw[o]) | UInt32(raw[o + 1]) << 8 | UInt32(raw[o + 2]) << 16 | UInt32(raw[o + 3]) << 24
                                      : UInt32(raw[o]) << 24 | UInt32(raw[o + 1]) << 16 | UInt32(raw[o + 2]) << 8 | UInt32(raw[o + 3])
                    let shift: UInt32 = alphaFirst ? 0 : 2   // [x2 R10 G10 B10] 或 [R10 G10 B10 x2]
                    func c(_ i: UInt32) -> Float {
                        let v = Float((word >> (20 - 10 * i + shift)) & 0x3ff)
                        return cif ? (v - 384) / 510 : v / 1023
                    }
                    out[x, y] = SIMD4(c(0), c(1), c(2), 1)
                }
            }
        }
        return (out, RawInfo(bitsPerComponent: 10, isFloat: false, alpha: cif ? "packed CIF10" : "packed 101010",
                             colorSpace: csName(img.colorSpace)))
    }

    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        func comp(_ off: Int) -> Float {
            switch (bpc, isFloat) {
            case (8, _): return Float(raw[off]) / 255
            case (16, false):
                let v = little ? UInt16(raw[off]) | UInt16(raw[off + 1]) << 8 : UInt16(raw[off]) << 8 | UInt16(raw[off + 1])
                return Float(v) / 65535
            case (16, true):
                let v = little ? UInt16(raw[off]) | UInt16(raw[off + 1]) << 8 : UInt16(raw[off]) << 8 | UInt16(raw[off + 1])
                return Float(Float16(bitPattern: v))
            case (32, true):
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(raw[off + k]) << (little ? 8 * k : 8 * (3 - k)) }
                return Float(bitPattern: v)
            default: fatalError("unsupported bpc \(bpc) float=\(isFloat)")
            }
        }
        let bytesPerComp = bpc / 8
        // 注：32-bit little-endian 打包的 8-bit 数据（order32Little）分量顺序是反的。
        let reversed8 = bpc == 8 && order == .order32Little
        for y in 0..<h {
            for x in 0..<w {
                let base = y * rowBytes + x * (bpp / 8)
                var c = [Float](repeating: 0, count: ncomp)
                for k in 0..<ncomp { c[k] = comp(base + k * bytesPerComp) }
                if reversed8 { c.reverse() }
                var rgba = SIMD4<Float>(0, 0, 0, 1)
                let colorStart = (ncomp > ncolor && alphaFirst) ? 1 : 0
                if ncolor == 1 {
                    rgba = SIMD4(c[colorStart], c[colorStart], c[colorStart], 1)
                } else {
                    rgba = SIMD4(c[colorStart], c[colorStart + 1], c[colorStart + 2], 1)
                }
                if hasAlpha && ncomp > ncolor { rgba.w = alphaFirst ? c[0] : c[ncolor] }
                out[x, y] = rgba
            }
        }
    }
    let alphaName: String = {
        switch alphaInfo {
        case .none: "none"; case .premultipliedLast: "premultipliedLast"; case .premultipliedFirst: "premultipliedFirst"
        case .last: "last"; case .first: "first"; case .noneSkipLast: "noneSkipLast"; case .noneSkipFirst: "noneSkipFirst"
        case .alphaOnly: "alphaOnly"; @unknown default: "?"
        }
    }()
    return (out, RawInfo(bitsPerComponent: bpc, isFloat: isFloat, alpha: alphaName, colorSpace: csName(img.colorSpace)))
}

func csName(_ cs: CGColorSpace?) -> String {
    guard let cs else { return "nil" }
    if let n = cs.name { return (n as String).replacingOccurrences(of: "kCGColorSpace", with: "") }
    if let icc = cs.copyICCData() as Data? { return "ICC(\(icc.count)B, \(iccDescription(icc) ?? "?"))" }
    return cs.model == .rgb ? "unnamed RGB" : "model \(cs.model.rawValue)"
}

/// 读 ICC 的 desc 标签（v2 'desc' 或 v4 'mluc'），只用于诊断。
func iccDescription(_ d: Data) -> String? {
    guard d.count > 132 else { return nil }
    func be32(_ o: Int) -> Int { d[d.startIndex + o..<d.startIndex + o + 4].reduce(0) { $0 << 8 | Int($1) } }
    let n = be32(128)
    for i in 0..<n {
        let o = 132 + i * 12
        guard o + 12 <= d.count else { break }
        let sig = String(bytes: d[d.startIndex + o..<d.startIndex + o + 4], encoding: .ascii)
        guard sig == "desc" else { continue }
        let off = be32(o + 4)
        let typ = String(bytes: d[d.startIndex + off..<d.startIndex + off + 4], encoding: .ascii)
        if typ == "desc" {
            let len = be32(off + 8)
            return String(bytes: d[d.startIndex + off + 12..<d.startIndex + off + 12 + max(0, len - 1)], encoding: .ascii)
        } else if typ == "mluc" {
            let recSize = be32(off + 12), strLen = be32(off + 20), strOff = be32(off + 24)
            _ = recSize
            let s = d[d.startIndex + off + strOff..<d.startIndex + off + strOff + strLen]
            return String(data: Data(s), encoding: .utf16BigEndian)
        }
    }
    return nil
}

/// 按指定格式把 FImage 打包成 CGImage（像素值原样写入，colorSpace 只是标签）。
func makeCGImage(_ img: FImage, format: PixelFormat, colorSpace: CGColorSpace, alpha: Bool) -> CGImage {
    let ncomp = alpha ? 4 : 3
    let bytesPerComp = format.bits / 8
    let rowBytes = img.w * ncomp * bytesPerComp
    var data = Data(count: rowBytes * img.h)
    data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        for y in 0..<img.h {
            for x in 0..<img.w {
                let p = img[x, y]
                let comps = [p.x, p.y, p.z, p.w]
                for k in 0..<ncomp {
                    let off = y * rowBytes + (x * ncomp + k) * bytesPerComp
                    let v = comps[k]
                    switch format {
                    case .u8: raw[off] = UInt8(max(0, min(255, (v * 255).rounded())))
                    case .u16:
                        let q = UInt16(max(0, min(65535, (v * 65535).rounded())))
                        raw[off] = UInt8(q & 0xff); raw[off + 1] = UInt8(q >> 8)
                    case .half:
                        let q = Float16(v).bitPattern
                        raw[off] = UInt8(q & 0xff); raw[off + 1] = UInt8(q >> 8)
                    case .float32:
                        let q = v.bitPattern
                        for b in 0..<4 { raw[off + b] = UInt8((q >> (8 * b)) & 0xff) }
                    }
                }
            }
        }
    }
    var info: UInt32 = alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue
    switch format {
    case .u8: break
    case .u16: info |= CGImageByteOrderInfo.order16Little.rawValue
    case .half: info |= CGImageByteOrderInfo.order16Little.rawValue | CGBitmapInfo.floatComponents.rawValue
    case .float32: info |= CGImageByteOrderInfo.order32Little.rawValue | CGBitmapInfo.floatComponents.rawValue
    }
    return CGImage(width: img.w, height: img.h, bitsPerComponent: format.bits, bitsPerPixel: format.bits * ncomp,
                   bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info),
                   provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

func writeImage(_ img: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw PoCError("cannot create destination \(url.path)")
    }
    CGImageDestinationAddImage(dest, img, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw PoCError("finalize failed \(url.lastPathComponent)") }
}

struct PoCError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

/// ImageIO 看到的文件信息（不解码像素）。
struct FileInfo: Codable {
    var file: String
    var type: String
    var width: Int
    var height: Int
    var depth: Int?
    var isFloat: Bool?
    var hasAlpha: Bool?
    var profileName: String?
    var colorModel: String?
    var orientation: Int?
    var decodedColorSpace: String
    var hasISOGainMap: Bool
    var hasAppleGainMap: Bool
    var metadataDictionaries: [String]
    var jpegSubsampling: String?
}

func fileInfo(_ url: URL) -> FileInfo? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    let iso = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
    let apple = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    let dicts = props.compactMap { k, v in v is [CFString: Any] ? (k as String) : nil }.sorted()
    let type = (CGImageSourceGetType(src) as String?) ?? "?"
    return FileInfo(
        file: url.lastPathComponent, type: type,
        width: props[kCGImagePropertyPixelWidth] as? Int ?? 0, height: props[kCGImagePropertyPixelHeight] as? Int ?? 0,
        depth: props[kCGImagePropertyDepth] as? Int, isFloat: props[kCGImagePropertyIsFloat] as? Bool,
        hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool, profileName: props[kCGImagePropertyProfileName] as? String,
        colorModel: props[kCGImagePropertyColorModel] as? String, orientation: props[kCGImagePropertyOrientation] as? Int,
        decodedColorSpace: csName(img?.colorSpace), hasISOGainMap: iso, hasAppleGainMap: apple,
        metadataDictionaries: dicts,
        jpegSubsampling: type == UTType.jpeg.identifier ? jpegSubsampling(url) : nil)
}

/// 从 JPEG 的 SOF 段读色度采样因子，判断是 4:4:4 还是 4:2:0。
func jpegSubsampling(_ url: URL) -> String? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    var i = 2
    while i + 4 < d.count {
        guard d[i] == 0xFF else { i += 1; continue }
        let marker = d[i + 1]
        let len = Int(d[i + 2]) << 8 | Int(d[i + 3])
        if (0xC0...0xC2).contains(marker) {
            let n = Int(d[i + 9])
            var parts: [String] = []
            for c in 0..<n {
                let f = d[i + 10 + c * 3 + 1]
                parts.append("\(f >> 4)x\(f & 0xF)")
            }
            let y = parts.first ?? "?"
            let label = y == "1x1" ? "4:4:4" : (y == "2x2" ? "4:2:0" : (y == "2x1" ? "4:2:2" : y))
            return "\(label) (\(parts.joined(separator: ",")))"
        }
        if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2 } else { i += 2 + len }
    }
    return nil
}

func decodeRaw(_ url: URL, options: [CFString: Any] = [:]) -> (CGImage, FImage, RawInfo)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary) else { return nil }
    let (f, info) = readRaw(img)
    return (img, f, info)
}
