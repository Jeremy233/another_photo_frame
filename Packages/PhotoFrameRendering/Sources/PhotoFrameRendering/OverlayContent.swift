import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import PhotoFrameCore

/// 一个图层的绘制内容：先给出自然尺寸（交给 `OverlayLayer.geometry(contentSize:)`），
/// 再按 Core 解析出的最终尺寸绘制成工作空间里的 CIImage（extent = (0, 0, size)）。
///
/// 文字和 SVG 用 CG 画进 extended linear Rec.2020 的 RGBAh 上下文（PoC 坑 8：非 extended 或 8-bit 上下文
/// 会截断广色域、在 gamma 空间混合）；PNG 素材用双线性缩放（PoC 坑 7：透明素材不用 Lanczos）。
enum OverlayContent {
    case text(TextBlock)
    case bitmap(CGImage)
    case vector(RestrictedSVG)

    var naturalSize: PixelSize {
        switch self {
        case .text(let t): t.naturalSize
        case .bitmap(let img): PixelSize(width: img.width, height: img.height)
        case .vector(let svg):
            // 素材导入时已限制尺寸；绕过导入的文件（例如被替换）也不能因为超大或非有限的尺寸让整数转换崩溃。
            PixelSize(width: Self.pixels(svg.size.width), height: Self.pixels(svg.size.height))
        }
    }

    /// SVG 固有尺寸 → 像素，限制在 1…1 << 20（非有限值按 1）。
    static func pixels(_ v: Double) -> Int {
        v.isFinite ? Int(min(max(v.rounded(), 1), Double(1 << 20))) : 1
    }

    // MARK: - 准备

    static func load(asset: RenderAsset) throws(RenderError) -> OverlayContent {
        let data: Data
        do { data = try Data(contentsOf: asset.fileURL, options: .mappedIfSafe) } catch {
            throw RenderError(code: "render.asset_unreadable", message: "无法读取素材 \(asset.fileURL.lastPathComponent)")
        }
        switch asset.format {
        case .svg:
            return .vector(try RestrictedSVG.parse(data))
        case .png:
            let bytes = [UInt8](data.prefix(8))
            guard bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= 16384, h <= 16384,
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else {
                throw RenderError(code: "render.asset_invalid", message: "素材 \(asset.fileURL.lastPathComponent) 不是有效的 PNG（或尺寸超过 16384）")
            }
            return .bitmap(img)
        }
    }

    // MARK: - 绘制

    /// - Parameters:
    ///   - size: 图层框在导出页面上的像素尺寸（Core 解析出的最终尺寸）。排版只看它。
    ///   - pixels: 实际输出的像素尺寸，默认等于 `size`。预览时是映射到预览页面后的图层框：同一份排版整体缩放进去，
    ///     文字与 SVG 按矢量重画，不先画大图再缩小。
    func render(size: PixelSize, alignment: OverlayAlignment, pixels: PixelSize? = nil) throws(RenderError) -> CIImage {
        let target = pixels ?? size
        let sx = Double(target.width) / Double(size.width), sy = Double(target.height) / Double(size.height)
        switch self {
        case .text(let block):
            return try Self.draw(size: target) { ctx in
                if pixels != nil { ctx.scaleBy(x: sx, y: sy) }
                block.draw(in: ctx, box: size, alignment: alignment)
            }
        case .vector(let svg):
            return try Self.draw(size: target) { ctx in
                if pixels != nil { ctx.scaleBy(x: sx, y: sy) }
                svg.draw(in: ctx, box: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            }
        case .bitmap(let full):
            // 等比放进图层框并居中，不变形。缩小超过一半时先降采样到目标的两倍，避免双线性混叠。
            let s = min(Double(size.width) / Double(full.width), Double(size.height) / Double(full.height))
            let effective = s * min(sx, sy)
            var img = PixelSize(width: full.width, height: full.height)
            if effective < 0.5 {
                let long = Double(max(full.width, full.height))
                let scale = (long * effective * 2).rounded(.up) / long
                img = PixelSize(width: max(1, Int((Double(full.width) * scale).rounded())),
                                height: max(1, Int((Double(full.height) * scale).rounded())))
            }
            let k = s * Double(full.width) / Double(img.width)
            let w = Double(img.width) * k, h = Double(img.height) * k
            let dx = (Double(size.width) - w) / 2, dy = (Double(size.height) - h) / 2
            // 先用 CG 画进预乘的工作空间 RGBAh：CI 直接对非预乘 PNG 做双线性采样时，会把透明像素里的
            // RGB（常是黑色）插值进边缘，浅色背景上出现灰边（测试 alphaHalo 实测 233 vs 250）。
            // 降采样也在这里做（不用 ImageIO 缩略图：它在非预乘值上重采样，缩到四分之一以下同样出灰边）；
            // 用中等插值，高质量插值的负瓣在透明边缘仍会压暗一两个码值。
            let premultiplied = try Self.draw(size: img) { ctx in
                if img.width != full.width || img.height != full.height { ctx.interpolationQuality = .medium }
                ctx.draw(full, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            }
            var transform = CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: dx, y: dy))
            if pixels != nil { transform = transform.concatenating(CGAffineTransform(scaleX: sx, y: sy)) }
            return premultiplied
                .transformed(by: transform)
                .cropped(to: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        }
    }

    static func draw(size: PixelSize, _ body: (CGContext) -> Void) throws(RenderError) -> CIImage {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGImageByteOrderInfo.order16Little.rawValue
        guard size.isPositive, size.width <= 16384, size.height <= 16384,
              let ctx = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 16, bytesPerRow: 0,
                                  space: WorkingColor.space, bitmapInfo: info)
        else { throw RenderError(code: "render.overlay_too_large", message: "装饰尺寸无效或过大：\(size)") }
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.interpolationQuality = .high
        body(ctx)
        guard let image = ctx.makeImage() else {
            throw RenderError(code: "render.overlay_failed", message: "装饰绘制失败")
        }
        return CIImage(cgImage: image)
    }
}

/// 排版后的文字块。字号、行距、内边距都是输出像素（D-45：不随画布缩放）。
struct TextBlock {
    var lines: [CTLine]
    var font: CTFont
    var lineHeightPx: Double
    var padding: Int
    var naturalSize: PixelSize

    /// - Returns: 文字块与提示（例如找不到指定字体）。
    static func make(text: String, style: TextStyle) throws(RenderError) -> (TextBlock, [String]) {
        var notes: [String] = []
        guard let color = try? WorkingColor.cgColor(style.color) else {
            throw RenderError(code: "render.invalid_color", message: "文字颜色无效：\(style.color.hex)")
        }
        let size = CGFloat(max(1, style.fontSizePx))
        var font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        if let family = style.fontFamily, !family.isEmpty {
            let candidate = CTFontCreateWithName(family as CFString, size, nil)
            let actual = CTFontCopyFamilyName(candidate) as String
            let ps = CTFontCopyPostScriptName(candidate) as String
            if actual.caseInsensitiveCompare(family) == .orderedSame || ps.caseInsensitiveCompare(family) == .orderedSame {
                font = candidate
            } else {
                notes.append("找不到字体 \(family)，改用系统字体")
            }
        }
        font = styled(font, weight: style.fontWeight, italic: style.italic, notes: &notes)
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        if style.letterSpacingPx != 0 {
            attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = style.letterSpacingPx
        }
        let lines = text.components(separatedBy: "\n").map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
        }
        let lineHeight = Double(size) * max(style.lineHeight, 0.1)
        let width = lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max() ?? 0
        let pad = max(0, style.paddingPx)
        // 先按浮点算：字号、行距、字间距、内边距极大时，转整数会溢出崩溃（预设校验已限制这些值，这里兜底）。
        let naturalWidth = width.rounded(.up) + 2 * Double(pad)
        let naturalHeight = (lineHeight * Double(lines.count)).rounded(.up) + 2 * Double(pad)
        guard naturalWidth.isFinite, naturalHeight.isFinite, naturalWidth < Double(1 << 31), naturalHeight < Double(1 << 31) else {
            throw RenderError(code: "render.overlay_too_large", message: "文字装饰尺寸无效或过大")
        }
        let natural = PixelSize(width: max(1, Int(naturalWidth)), height: max(1, Int(naturalHeight)))
        return (TextBlock(lines: lines, font: font, lineHeightPx: lineHeight, padding: pad, naturalSize: natural), notes)
    }

    /// 同一字族里最接近的字重与斜体（D-111，§7.1 文字样式）。字族没有斜体时保持正体并提示。
    static func styled(_ font: CTFont, weight: TextStyle.FontWeight, italic: Bool, notes: inout [String]) -> CTFont {
        var result = font
        if weight != .regular {
            let family = CTFontCopyFamilyName(font)
            let descriptor = CTFontDescriptorCreateWithAttributes([
                kCTFontFamilyNameAttribute: family,
                kCTFontTraitsAttribute: [kCTFontWeightTrait: weightTrait(weight)],
            ] as CFDictionary)
            result = CTFontCreateWithFontDescriptor(descriptor, CTFontGetSize(font), nil)
            if CTFontCopyFamilyName(result) as String != family as String { result = font }
        }
        if italic {
            if let slanted = CTFontCreateCopyWithSymbolicTraits(result, 0, nil, .traitItalic, .traitItalic) {
                result = slanted
            } else {
                notes.append("字体 \(CTFontCopyFamilyName(result) as String) 没有斜体，按正体绘制")
            }
        }
        return result
    }

    /// 与 `NSFont.Weight` 的取值相同。
    static func weightTrait(_ weight: TextStyle.FontWeight) -> Double {
        switch weight {
        case .ultraLight: -0.8
        case .thin: -0.6
        case .light: -0.4
        case .regular: 0
        case .medium: 0.23
        case .semibold: 0.3
        case .bold: 0.4
        case .heavy: 0.56
        case .black: 0.62
        }
    }

    /// 在图层框里绘制。框比自然尺寸小时等比缩小；不放大。水平对齐跟随锚点（左／中／右），竖直居中。
    func draw(in ctx: CGContext, box: PixelSize, alignment: OverlayAlignment) {
        let s = min(1, Double(box.width) / Double(naturalSize.width), Double(box.height) / Double(naturalSize.height))
        let w = Double(naturalSize.width) * s, h = Double(naturalSize.height) * s
        let x0: Double
        switch alignment {
        case .start: x0 = 0
        case .center: x0 = (Double(box.width) - w) / 2
        case .end: x0 = Double(box.width) - w
        }
        let yTop = (Double(box.height) - h) / 2
        ctx.saveGState()
        // 左下原点：块的左上角在 (x0, box.height − yTop)。
        ctx.translateBy(x: x0, y: Double(box.height) - yTop)
        ctx.scaleBy(x: s, y: s)
        let ascent = Double(CTFontGetAscent(font)), descent = Double(CTFontGetDescent(font))
        let inner = Double(naturalSize.width - 2 * padding)
        for (i, line) in lines.enumerated() {
            let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            let dx: Double
            switch alignment {
            case .start: dx = 0
            case .center: dx = (inner - lineWidth) / 2
            case .end: dx = inner - lineWidth
            }
            let baselineFromTop = Double(padding) + Double(i) * lineHeightPx + (lineHeightPx - ascent - descent) / 2 + ascent
            ctx.textPosition = CGPoint(x: Double(padding) + dx, y: -baselineFromTop)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }
}
