import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 候选工作空间。
struct WorkingSpace {
    let id: String
    let cg: CGColorSpace
    let math: RGBSpace

    static let all: [WorkingSpace] = [
        WorkingSpace(id: "extLinearSRGB", cg: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, math: Spaces.linearSRGB),
        WorkingSpace(id: "extLinearP3", cg: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!, math: Spaces.linearP3),
        WorkingSpace(id: "extLinear2020", cg: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!, math: Spaces.linear2020),
    ]
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let extSRGB = CGColorSpace(name: CGColorSpace.extendedSRGB)!

/// 照片在画布上的位置（左上角原点，像素）。
struct Placement {
    var canvas: CGSize
    var origin: CGPoint      // 左上角
    var scale: Double
    var size: CGSize

    /// 源图（左上原点）矩形 → 输出画布（左上原点）矩形
    func map(_ r: CGRect) -> CGRect {
        CGRect(x: origin.x + r.minX * scale, y: origin.y + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }
}

/// 一条 Core Image 渲染管线：解码 → 工作空间 → 缩放 → 合成到背景 → 叠加水印 → 输出。
/// 工作空间和中间格式由 CIContext 决定；所有转换都由 CI 在渲染时插入。
final class Pipeline {
    let ws: WorkingSpace
    let ctx: CIContext
    let format: CIFormat

    init(_ ws: WorkingSpace, workingFormat: CIFormat = .RGBAh) {
        self.ws = ws
        self.format = workingFormat
        ctx = CIContext(options: [.workingColorSpace: ws.cg, .workingFormat: workingFormat.rawValue, .cacheIntermediates: false])
    }

    func load(_ url: URL, expandHDR: Bool = true) -> CIImage {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: expandHDR])!
    }

    /// 背景：sRGB 编码 (r,g,b)/255，经受管理的转换进入工作空间。
    func background(_ size: CGSize, srgb8 c: (Int, Int, Int)) -> CIImage {
        let color = CIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, colorSpace: sRGB)!
        return CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size))
    }

    func scaled(_ img: CIImage, by s: Double) -> CIImage {
        guard abs(s - 1) > 1e-9 else { return img }
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = img; f.scale = Float(s); f.aspectRatio = 1
        return f.outputImage!
    }

    /// 等比缩放并放进画布（整数像素对齐）。
    /// clampEdges = true：先 clampedToExtent 再缩放、按整数尺寸裁回，照片边缘是硬边，不会把透明区卷进滤波核
    /// （否则 Lanczos 会在照片与背景交界处振铃，见报告）。
    func fit(_ img: CIImage, canvas: CGSize, margin: Double, allowUpscale: Bool = false, clampEdges: Bool = true) -> (CIImage, Placement) {
        let e = img.extent
        var s = min((canvas.width - 2 * margin) / e.width, (canvas.height - 2 * margin) / e.height)
        if !allowUpscale { s = min(s, 1) }
        let origin0 = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let scaledImg = clampEdges && abs(s - 1) > 1e-9
            ? scaled(origin0.clampedToExtent(), by: s).cropped(to: CGRect(x: 0, y: 0, width: (e.width * s).rounded(), height: (e.height * s).rounded()))
            : scaled(origin0, by: s)
        let se = scaledImg.extent
        let ox = ((canvas.width - se.width) / 2).rounded(), oyTop = ((canvas.height - se.height) / 2).rounded()
        let ciY = canvas.height - oyTop - se.height
        let placed = scaledImg.transformed(by: CGAffineTransform(translationX: ox - se.minX, y: ciY - se.minY))
        return (placed, Placement(canvas: canvas, origin: CGPoint(x: ox, y: oyTop), scale: Double(se.width / e.width), size: se.size))
    }

    /// 把图层（左上原点）放到画布坐标
    func place(_ img: CIImage, topLeft: CGPoint, canvas: CGSize) -> CIImage {
        let e = img.extent
        return img.transformed(by: CGAffineTransform(translationX: topLeft.x - e.minX, y: canvas.height - topLeft.y - e.height - e.minY))
    }

    // MARK: 渲染

    /// 渲染为 RGBAf（预乘）。返回左上原点的 FImage。
    func renderFloat(_ img: CIImage, rect: CGRect, colorSpace: CGColorSpace? = nil) -> FImage {
        let w = Int(rect.width), h = Int(rect.height)
        var f = FImage(w: w, h: h)
        f.px.withUnsafeMutableBytes { buf in
            ctx.render(img, toBitmap: buf.baseAddress!, rowBytes: w * 16, bounds: rect, format: .RGBAf,
                       colorSpace: colorSpace ?? ws.cg)
        }
        return f
    }

    func renderRGBA8(_ img: CIImage, rect: CGRect, colorSpace: CGColorSpace = sRGB) -> FImage {
        let w = Int(rect.width), h = Int(rect.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            ctx.render(img, toBitmap: buf.baseAddress!, rowBytes: w * 4, bounds: rect, format: .RGBA8, colorSpace: colorSpace)
        }
        var f = FImage(w: w, h: h)
        for i in 0..<bytes.count { f.px[i] = Float(bytes[i]) / 255 }
        return f
    }

    // MARK: 输出

    func writePNG(_ img: CIImage, to url: URL, sixteen: Bool = false, colorSpace: CGColorSpace = sRGB) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ctx.writePNGRepresentation(of: img, to: url, format: sixteen ? .RGBA16 : .RGBA8, colorSpace: colorSpace)
    }

    func writeJPEG(_ img: CIImage, to url: URL, colorSpace: CGColorSpace = sRGB, hdr: CIImage? = nil, rgbGainMap: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0
        ]
        if let hdr { opts[.hdrImage] = hdr }
        if rgbGainMap { opts[.hdrGainMapAsRGB] = true }
        try ctx.writeJPEGRepresentation(of: img, to: url, colorSpace: colorSpace, options: opts)
    }

    /// HDR 输出的另一条路线：CI 渲染为 extended 浮点 CGImage，再交给 ImageIO 编码成 ISO gain map JPEG。
    /// 注意：extended 浮点 CGImage 必须用 CGImageCreateCopyWithContentHeadroom 标上 headroom，否则 ImageIO 当 SDR 处理。
    func writeGainMapJPEGViaImageIO(_ hdr: CIImage, to url: URL, renderSpace: CGColorSpace, baseSpace: CGColorSpace?, headroom: Float) throws {
        let raw = ctx.createCGImage(hdr, from: hdr.extent, format: .RGBAh, colorSpace: renderSpace)!
        let cg = CGImageCreateCopyWithContentHeadroom(max(headroom, 1), raw)!
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap,
        ]
        if let baseSpace { props[kCGImageDestinationEncodeRequestOptions] = [kCGImageDestinationEncodeBaseColorSpace: baseSpace] }
        try writeImage(cg, to: url, type: .jpeg, properties: props)
    }

    /// 只对照片图层做 HDR→SDR tone map（背景和水印本来就是 SDR，不应被曲线改动）。
    func toneMapToSDR(_ img: CIImage, sourceHeadroom: Float) -> CIImage {
        let f = CIFilter.toneMapHeadroom()
        f.inputImage = img; f.sourceHeadroom = sourceHeadroom; f.targetHeadroom = 1
        return f.outputImage!
    }
}
