import CoreGraphics
import Foundation
import ImageIO
import PhotoFrameCore
import PhotoFrameStorage

/// 渲染用的元数据（D-132–D-135）：模板占位符的值，以及认出的品牌和源图填的胶卷。
struct ResolvedMetadata {
    var values: [String: String]
    var brand: BuiltInWatermarks.Brand?
    var film: String? { values["film"] }
}

extension MetadataText {
    /// EXIF 加上手填的值（D-135）。手填的品牌 / 型号也用来认品牌和组成 `{camera}`；
    /// 只填数字的 ISO、光圈、快门补上单位；尼康 Z 系列的型号去掉 Z 后面的空格（D-133）。
    static func resolve(from properties: [CFString: Any], overrides: [String: String]) -> ResolvedMetadata {
        var v = values(from: properties)
        var o: [String: String] = [:]
        for (key, raw) in overrides {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { o[key] = normalizedOverride(key: key, value: t) }
        }
        let make = o["make"] ?? v["make"]
        let model = o["model"] ?? v["model"]
        let brand = BuiltInWatermarks.brand(make: make, model: model)
        let shownModel = model.map { tidyModel($0, make: make) }
        v["make"] = make
        v["model"] = shownModel
        v["camera"] = camera(make: make, model: shownModel)
        v["brand"] = brand?.text ?? make.flatMap { $0.split(separator: " ").first.map(String.init) }
        for (key, value) in o where key != "make" && key != "model" { v[key] = value }
        return ResolvedMetadata(values: v.compactMapValues { $0 }, brand: brand)
    }

    /// `{camera}`：型号已经以品牌开头时不重复品牌（`NIKON Z8`、`Canon EOS R5`、`Mamiya 7`）。
    static func camera(make: String?, model: String?) -> String? {
        switch (make, model) {
        case (let m?, let n?):
            let brand = m.split(separator: " ").first.map(String.init) ?? m
            return n.lowercased().hasPrefix(brand.lowercased()) ? n : "\(brand) \(n)"
        case (nil, let n?): return n
        case (let m?, nil): return m
        default: return nil
        }
    }

    /// 尼康 Z 系列（D-133）：`NIKON Z 8` → `NIKON Z8`，`NIKON Z 6_2` → `NIKON Z6II`，`NIKON Z f` → `NIKON Zf`。
    static func tidyModel(_ model: String, make: String?) -> String {
        guard "\(make ?? "") \(model)".lowercased().contains("nikon") else { return model }
        var s = model.replacingOccurrences(of: #"\bZ (?=\d|f)"#, with: "Z", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(Z\d+)_2\b"#, with: "$1II", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(Z\d+)_3\b"#, with: "$1III", options: .regularExpression)
        return s
    }

    /// 只填数字时补上单位：ISO `400` → `ISO 400`，光圈 `8` → `f/8`，快门 `1/250` → `1/250s`。
    static func normalizedOverride(key: String, value t: String) -> String {
        func matches(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }
        switch key {
        case "iso": return matches(#"^\d+$"#) ? "ISO \(t)" : t
        case "aperture": return matches(#"^\d+(\.\d+)?$"#) ? "f/\(t)" : t
        case "shutter": return matches(#"^[\d./]+$"#) ? "\(t)s" : t
        default: return t
        }
    }
}

/// 「自动」颜色（D-132）：背景亮度大于 128 用深色，否则用浅色。
enum AutoInk {
    static func isDark(_ background: PresetColor) -> Bool {
        let hex = background.hex.dropFirst()
        guard hex.count == 6, let n = Int(hex, radix: 16) else { return false }
        let r = Double(n >> 16), g = Double((n >> 8) & 255), b = Double(n & 255)
        return (r * 299 + g * 587 + b * 114) / 1000 <= 128
    }

    static func color(on background: PresetColor) -> PresetColor {
        PresetColor(hex: isDark(background) ? "#F2F2F2" : "#1A1A1A")
    }
}

/// 由几块组成的装饰（品牌 logo、胶卷图标 + 文字）。坐标是左上原点、导出像素。
struct CompositeArt {
    enum Graphic {
        case vector(RestrictedSVG)
        case bitmap(CGImage)
    }

    enum Part {
        case graphic(Graphic, tint: CGColor?, rect: CGRect)
        case text(TextBlock, rect: CGRect)
    }

    var parts: [Part]
    var naturalSize: PixelSize

    /// 画进 `box`：整体等比缩放到放得下（固定尺寸或最大尺寸时），水平按锚点对齐、竖直居中。
    func draw(in ctx: CGContext, box: PixelSize, alignment: OverlayAlignment) {
        let nw = Double(naturalSize.width), nh = Double(naturalSize.height)
        let s = min(Double(box.width) / nw, Double(box.height) / nh)
        let w = nw * s, h = nh * s
        let x0: Double = switch alignment {
        case .start: 0
        case .center: (Double(box.width) - w) / 2
        case .end: Double(box.width) - w
        }
        let y0 = (Double(box.height) - h) / 2
        ctx.saveGState()
        // 换成左上原点、自然尺寸的坐标。
        ctx.translateBy(x: x0, y: Double(box.height) - y0)
        ctx.scaleBy(x: s, y: s)
        for part in parts {
            switch part {
            case .graphic(let graphic, let tint, let rect):
                let r = CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height)
                if let tint { ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
                switch graphic {
                case .vector(let svg): svg.draw(in: ctx, box: r)
                case .bitmap(let image):
                    let k = min(r.width / Double(image.width), r.height / Double(image.height))
                    let iw = Double(image.width) * k, ih = Double(image.height) * k
                    ctx.interpolationQuality = .high
                    ctx.draw(image, in: CGRect(x: r.midX - iw / 2, y: r.midY - ih / 2, width: iw, height: ih))
                }
                if let tint {
                    // 只保留图形的形状，颜色换成 tint。
                    ctx.setBlendMode(.sourceIn)
                    ctx.setFillColor(tint)
                    ctx.fill(r)
                    ctx.setBlendMode(.normal)
                    ctx.endTransparencyLayer()
                }
            case .text(let block, let rect):
                ctx.saveGState()
                ctx.translateBy(x: rect.minX, y: -rect.minY - rect.height)
                block.draw(in: ctx, box: PixelSize(width: Int(rect.width.rounded(.up)), height: Int(rect.height.rounded(.up))),
                           alignment: .start)
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }
}

extension OverlayPlanner {
    /// 品牌 logo（D-132）。
    static func brandLogo(_ layer: OverlayLayer, assets: [String: RenderAsset] = [:], meta: ResolvedMetadata, background: PresetColor,
                          warnings: inout [RenderWarning]) throws(RenderError) -> OverlayContent? {
        let style = layer.logo ?? BrandLogoStyle()
        if style.brand == BrandLogoStyle.fromSlot {
            // 素材槽里的素材（D-139）：原色照原样画；自动、自定把整个图形换成一种颜色。
            guard let (graphic, ratio) = try slotGraphic(layer, assets: assets, warnings: &warnings) else { return nil }
            let tint: PresetColor? = switch style.colorMode {
            case .original: nil
            case .auto: AutoInk.color(on: background)
            case .custom: style.color ?? AutoInk.color(on: background)
            }
            let h = style.heightPx * (ratio < 1.6 ? 1.8 : 1)
            let w = h * ratio
            return .composite(CompositeArt(
                parts: [.graphic(graphic, tint: try tint.map { c throws(RenderError) in try WorkingColor.cgColor(c) },
                                 rect: CGRect(x: 0, y: 0, width: w, height: h))],
                naturalSize: PixelSize(width: max(1, Int(w.rounded(.up))), height: max(1, Int(h.rounded(.up))))))
        }
        let brand = style.brand == BrandLogoStyle.automatic ? meta.brand : BuiltInWatermarks.brand(id: style.brand)
        guard let brand else {
            if style.brand != BrandLogoStyle.automatic {
                warnings.append(RenderWarning(code: "overlay.brand_unknown", message: "没有内置品牌 \(style.brand)，已跳过", layerId: layer.layerId))
                return nil
            }
            let name = meta.values["brand"]
            guard style.fallback == .text, let name else {
                warnings.append(RenderWarning(
                    code: "overlay.brand_unknown",
                    message: name.map { "认不出相机品牌 \($0)，品牌 logo 不画" } ?? "源图没有相机品牌（可在源图上手动填写），品牌 logo 不画",
                    layerId: layer.layerId))
                return nil
            }
            let ink = style.colorMode == .custom ? (style.color ?? AutoInk.color(on: background)) : AutoInk.color(on: background)
            var text = layer.text ?? TextStyle(fontWeight: .semibold, fontSizePx: style.heightPx * 0.8)
            text.color = text.colorMode == .auto ? AutoInk.color(on: background) : ink
            let (block, notes) = try TextBlock.make(text: name, style: text)
            warnings += notes.map { RenderWarning(code: "overlay.font_missing", message: $0, layerId: layer.layerId) }
            return .text(block)
        }
        let art = try logoArt(brand, variant: style.variant, mode: style.colorMode, custom: style.color, background: background)
        let h = style.heightPx * (art.ratio < 1.6 ? 1.8 : 1)
        let w = h * art.ratio
        let size = PixelSize(width: max(1, Int(w.rounded(.up))), height: max(1, Int(h.rounded(.up))))
        return .composite(CompositeArt(parts: [.graphic(art.graphic, tint: art.tint, rect: CGRect(x: 0, y: 0, width: w, height: h))],
                                       naturalSize: size))
    }

    /// 选文件和颜色（D-132）。
    static func logoArt(_ brand: BuiltInWatermarks.Brand, variant: BrandLogoStyle.Variant, mode: BrandLogoStyle.ColorMode,
                        custom: PresetColor?, background: PresetColor)
        throws(RenderError) -> (graphic: CompositeArt.Graphic, tint: CGColor?, ratio: Double)
    {
        let dark = AutoInk.isDark(background)
        var file = brand.files.logo, kind = brand.kind, ratio = brand.ratio
        if variant == .emblem, let alt = brand.files.alt {
            file = alt
            kind = brand.altKind ?? .emblem
            ratio = brand.altRatio ?? ratio
        }
        let isMain = file == brand.files.logo
        var tint: PresetColor?
        switch (kind, mode) {
        case (.mono, .original), (.mono, .auto), (.color, .auto):
            tint = AutoInk.color(on: background)
        case (.mono, .custom), (.color, .custom):
            tint = custom ?? AutoInk.color(on: background)
        case (.emblem, .custom) where isMain && brand.files.mono != nil:
            // Kodak：只有自定颜色时换成同形状的单色版。
            file = brand.files.mono!
            ratio = brand.monoRatio ?? ratio
            tint = custom ?? AutoInk.color(on: background)
        case (.color, .original), (.emblem, _):
            if dark, isMain, let rev = brand.files.dark { file = rev }   // 深色画布用白字版
        }
        guard let data = BuiltInWatermarks.brandFileData(file) else {
            throw RenderError(code: "render.builtin_missing", message: "内置素材缺失：\(file)")
        }
        let graphic = try loadGraphic(data, name: file)
        return (graphic, try tint.map { c throws(RenderError) in try WorkingColor.cgColor(c) }, ratio)
    }

    /// 图层素材槽里的素材（内置的或导入的，D-139）和它的宽高比。没有可用素材时警告并返回 nil。
    static func slotGraphic(_ layer: OverlayLayer, assets: [String: RenderAsset], warnings: inout [RenderWarning])
        throws(RenderError) -> (CompositeArt.Graphic, ratio: Double)?
    {
        guard let slotId = layer.slotId, let asset = assets[slotId] else {
            warnings.append(RenderWarning(code: "overlay.asset_missing", message: "素材槽 \(layer.slotId ?? "?") 没有可用素材，已跳过",
                                          layerId: layer.layerId))
            return nil
        }
        switch try OverlayContent.load(asset: asset) {
        case .vector(let svg):
            warnings += svg.warnings.map { RenderWarning(code: "overlay.svg_partial", message: $0, layerId: layer.layerId) }
            let ratio = svg.size.height > 0 && svg.size.width.isFinite ? svg.size.width / svg.size.height : 1
            return (.vector(svg), ratio > 0 && ratio.isFinite ? ratio : 1)
        case .bitmap(let image):
            return (.bitmap(image), Double(image.width) / Double(max(1, image.height)))
        case .text, .composite:
            return nil
        }
    }

    static func loadGraphic(_ data: Data, name: String) throws(RenderError) -> CompositeArt.Graphic {
        if name.hasSuffix(".svg") { return .vector(try RestrictedSVG.parse(data, trusted: true)) }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw RenderError(code: "render.builtin_invalid", message: "内置素材无法读取：\(name)")
        }
        return .bitmap(image)
    }

    /// 胶卷图标和文字（D-134）。源图没填胶卷时不画（数码照片的常态，不警告）。
    static func filmIcon(_ layer: OverlayLayer, assets: [String: RenderAsset] = [:], meta: ResolvedMetadata, background: PresetColor,
                         warnings: inout [RenderWarning]) throws(RenderError) -> OverlayContent? {
        let style = layer.filmIcon ?? FilmIconStyle()
        let fromSlot = style.film == FilmIconStyle.fromSlot
        let size = style.iconSizePx
        var icon: (CompositeArt.Graphic, CGColor?, CGSize)?
        var showText = style.show != .icon
        if fromSlot {
            // 素材槽里的图标（D-139）：源图没填胶卷时也画图标，文字照常按源图填的胶卷。
            if style.show != .text {
                guard let (graphic, ratio) = try slotGraphic(layer, assets: assets, warnings: &warnings) else { return nil }
                icon = (graphic, nil, CGSize(width: size * ratio, height: size))
            }
            return try filmComposite(layer, icon: icon, showText: showText, size: size, meta: meta, background: background,
                                     warnings: &warnings)
        }
        let picked = style.film == FilmIconStyle.automatic ? nil : BuiltInWatermarks.film(id: style.film)
        let name = style.film == FilmIconStyle.automatic ? meta.film : picked?.name
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            if style.film != FilmIconStyle.automatic {
                warnings.append(RenderWarning(code: "overlay.film_unknown", message: "没有内置胶卷 \(style.film)，已跳过", layerId: layer.layerId))
            }
            return nil
        }
        if style.show != .text {
            if let film = picked ?? BuiltInWatermarks.film(named: name), let data = BuiltInWatermarks.iconData(for: film) {
                icon = (try loadGraphic(data, name: film.icon), nil, CGSize(width: size, height: size))
            } else {
                switch style.noIcon {
                case .brandLogo:
                    if let brand = BuiltInWatermarks.filmBrand(forFilmName: name) {
                        let art = try logoArt(brand, variant: .wordmark, mode: .original, custom: nil, background: background)
                        let h = size * (art.ratio < 1.6 ? 1 : 0.4)
                        icon = (art.graphic, art.tint, CGSize(width: h * art.ratio, height: h))
                    } else {
                        showText = true
                    }
                case .text: showText = true
                case .none: return nil
                }
            }
        }
        return try filmComposite(layer, icon: icon, showText: showText, size: size, meta: meta, background: background,
                                 warnings: &warnings)
    }

    /// 胶卷装饰的排法：图标在左，文字在右，竖直居中。
    private static func filmComposite(
        _ layer: OverlayLayer, icon: (CompositeArt.Graphic, CGColor?, CGSize)?, showText: Bool, size: Double,
        meta: ResolvedMetadata, background: PresetColor, warnings: inout [RenderWarning]
    ) throws(RenderError) -> OverlayContent? {
        var block: TextBlock?
        if showText {
            var text = layer.text ?? TextStyle(template: FilmIconStyle.defaultTemplate, fontWeight: .medium, fontSizePx: 20,
                                               letterSpacingPx: 1, colorMode: .auto)
            if text.colorMode == .auto { text.color = AutoInk.color(on: background) }
            let filled = MetadataText.fill(text.template ?? FilmIconStyle.defaultTemplate, values: meta.values).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !filled.isEmpty {
                let (b, notes) = try TextBlock.make(text: filled, style: text)
                warnings += notes.map { RenderWarning(code: "overlay.font_missing", message: $0, layerId: layer.layerId) }
                block = b
            }
        }
        guard icon != nil || block != nil else { return nil }
        let gap = icon != nil && block != nil ? max(4, size * 0.2) : 0
        let iconSize = icon?.2 ?? .zero
        let textSize = block.map { CGSize(width: $0.naturalSize.width, height: $0.naturalSize.height) } ?? .zero
        let height = max(iconSize.height, textSize.height)
        var parts: [CompositeArt.Part] = []
        if let icon {
            parts.append(.graphic(icon.0, tint: icon.1, rect: CGRect(x: 0, y: (height - iconSize.height) / 2,
                                                                       width: iconSize.width, height: iconSize.height)))
        }
        if let block {
            parts.append(.text(block, rect: CGRect(x: iconSize.width + gap, y: (height - textSize.height) / 2,
                                                   width: textSize.width, height: textSize.height)))
        }
        let width = iconSize.width + gap + textSize.width
        return .composite(CompositeArt(parts: parts, naturalSize: PixelSize(width: max(1, Int(width.rounded(.up))),
                                                                              height: max(1, Int(height.rounded(.up))))))
    }
}
