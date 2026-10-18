import CoreImage
import Foundation
import PhotoFrameCore

/// 把预设换成每页的合成参数。几何只调用 PhotoFrameCore（FitLayout / CropLayout / PanoramaLayout /
/// OverlayPlacement），这里只做组装。
struct PageLayout {
    enum Kind {
        case fit(FitLayout)
        case crop(CropLayout)
        case panorama(PanoramaLayout)
    }

    var kind: Kind
    var pages: [PagePlan]
    /// 照片在输出中的最大像素尺寸（显示方向），决定降采样解码的目标（D-18）。
    var neededPhotoSize: PixelSize

    static func make(
        preset: ExportPreset, source: SourceImage, maxCarouselItems: Int?, warnings: inout [RenderWarning]
    ) throws(RenderError) -> PageLayout {
        let canvas = preset.canvas
        let display = source.displaySize
        let whole = Rect(x: 0, y: 0, width: Double(display.width), height: Double(display.height))
        do {
            if preset.panorama.enabled {
                let p = preset.panorama
                if canvas.mode == .crop {
                    warnings.append(RenderWarning(code: "render.crop_ignored_for_panorama",
                                                  message: "全景模式始终不裁切（D-21），忽略画布的比例裁切设置"))
                }
                let count: SlideCount = switch p.tileCount {
                case .auto: .automatic
                case .fixed(let n): .manual(n)
                }
                let pano = try PanoramaLayout(
                    tile: canvas.size, source: source, coverMinimumMargin: canvas.minMarginPx,
                    verticalMargin: p.verticalMarginPx, slideCount: count, maxCarouselItems: maxCarouselItems,
                    includesCover: p.cover)
                warnings += pano.warnings.map { warning in
                    if case .exceedsCarouselLimit(let total, let limit) = warning, !p.cover {
                        return RenderWarning(code: warning.code, message: "切片共 \(total) 张，超过平台轮播上限 \(limit) 张")
                    }
                    return RenderWarning(code: warning.code, message: warning.message)
                }
                let pad: PresetColor = switch p.padColor {
                case .canvasBackground: canvas.background
                case .color(let c): c
                }
                var pages: [PagePlan] = []
                if p.cover {
                    pages.append(PagePlan(role: .cover, canvas: canvas.size, background: canvas.background,
                                          photo: .region(whole, rect: pano.cover.pixelRect), overlays: []))
                }
                for slice in pano.slices {
                    pages.append(PagePlan(
                        role: .slide(slice.index), canvas: canvas.size, background: pad,
                        photo: slice.imageRect == nil ? .none : .strip(pano.pixelImageRect, sliceOriginX: slice.frame.x),
                        overlays: []))
                }
                let needed = PixelSize(width: max(pano.cover.pixelRect.width, pano.pixelImageRect.width),
                                       height: max(pano.cover.pixelRect.height, pano.pixelImageRect.height))
                return PageLayout(kind: .panorama(pano), pages: pages, neededPhotoSize: needed)
            }
            switch canvas.mode {
            case .fit:
                let fit = try FitLayout(canvas: canvas.size, minimumMargin: canvas.minMarginPx, source: source)
                return PageLayout(
                    kind: .fit(fit),
                    pages: [PagePlan(role: .single, canvas: canvas.size, background: canvas.background,
                                     photo: .region(whole, rect: fit.pixelRect), overlays: [])],
                    neededPhotoSize: fit.pixelRect.size)
            case .crop:
                let settings = canvas.crop ?? CropSettings()
                let ratio = settings.aspectRatio.map { AspectRatio(width: $0.first, height: $0.second) }
                let crop = try CropLayout(
                    canvas: canvas.size, minimumMargin: canvas.minMarginPx, source: source, aspectRatio: ratio,
                    anchor: Point(x: settings.anchor.first, y: settings.anchor.second))
                let c = crop.cropRect
                // 裁切区域在整张源图上需要的分辨率 = 显示尺寸 × Fit 缩放。
                let needed = PixelSize(
                    width: Int((Double(display.width) * crop.fit.transform.scaleX).rounded(.up)),
                    height: Int((Double(display.height) * crop.fit.transform.scaleY).rounded(.up)))
                return PageLayout(
                    kind: .crop(crop),
                    pages: [PagePlan(role: .single, canvas: canvas.size, background: canvas.background,
                                     photo: .region(c.rect, rect: crop.fit.pixelRect), overlays: [])],
                    neededPhotoSize: needed)
            }
        } catch {
            throw .geometry(error)
        }
    }

    /// 图层在各页上的像素矩形（页码 → 矩形）。全景切片上没有照片、又以照片为参照时不绘制（D-43）。
    func placements(for layer: OverlayLayer, geometry: OverlayGeometry, warnings: inout [RenderWarning])
        throws(RenderError) -> [Int: OverlayPlacement]
    {
        var result: [Int: OverlayPlacement] = [:]
        func note(_ p: OverlayPlacement, page: Int) {
            warnings += p.warnings.map {
                RenderWarning(code: $0.code, message: $0.message, page: page, layerId: layer.layerId)
            }
        }
        do {
            switch kind {
            case .fit(let fit):
                if geometry.visibility.includes(page: 0) {
                    let p = try OverlayPlacement(fit: fit, geometry: geometry)
                    note(p, page: 0)
                    result[0] = p
                }
            case .crop(let crop):
                if geometry.visibility.includes(page: 0) {
                    let p = try OverlayPlacement(crop: crop, geometry: geometry)
                    note(p, page: 0)
                    result[0] = p
                }
            case .panorama(let pano):
                let plan = try pano.overlayPlan(for: geometry)
                let hasCover = pages.contains { $0.role == .cover }
                for page in plan.pages {
                    guard let p = page.placement, page.page != 0 || hasCover else { continue }
                    note(p, page: page.page)
                    result[page.page] = p
                }
            }
        } catch {
            throw .overlay(error, layerId: layer.layerId)
        }
        // 要显示的页不存在时只提示（D-44）：指定页码超出实际页数（单页版式只有第 0 页），
        // 或者图层只在封面、而全景不输出封面。
        let existing = Set(pages.map(\.role.page))
        switch geometry.visibility {
        case .coverOnly where !existing.contains(0):
            warnings.append(RenderWarning(
                code: "overlay.missing_pages", message: "图层只显示在封面，但不输出封面（D-44）", layerId: layer.layerId))
        case .selectedSlides(let selected):
            let missing = selected.filter { !existing.contains($0) }.sorted()
            if !missing.isEmpty {
                warnings.append(RenderWarning(
                    code: "overlay.missing_pages",
                    message: "指定页码超出实际页数：\(missing.map(String.init).joined(separator: ", "))（D-44）",
                    layerId: layer.layerId))
            }
        default:
            break
        }
        return result
    }
}

/// 一个已放进版式的图层：内容与它在导出页面上的尺寸（所有页相同）。绘制留给导出或预览，各自按需要的像素尺寸画。
struct PlannedOverlay {
    var content: OverlayContent
    var size: PixelSize
    var alignment: OverlayAlignment
}

/// 图层：解析内容、计算尺寸与位置（§7.1、§8.2）。
enum OverlayPlanner {
    /// 把图层放进 `layout.pages`，返回 layerId → 图层内容与尺寸。
    static func plan(
        inputs: RenderInputs, layout: inout PageLayout, properties: [CFString: Any], warnings: inout [RenderWarning]
    ) throws(RenderError) -> [String: PlannedOverlay] {
        let metadataValues = MetadataText.values(from: properties).merging(inputs.metadataOverrides) { $1 }
        let layers = inputs.preset.layers.enumerated()
            .filter { $0.element.enabled && !inputs.skippedLayerIds.contains($0.element.layerId) }
            .sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }
            .map(\.element)

        var planned: [String: PlannedOverlay] = [:]
        for layer in layers {
            guard let content = try content(for: layer, assets: inputs.assets, values: metadataValues, warnings: &warnings)
            else { continue }
            let geometry: OverlayGeometry
            do { geometry = try layer.geometry(contentSize: content.naturalSize) } catch {
                throw .overlay(error, layerId: layer.layerId)
            }
            let placements = try layout.placements(for: layer, geometry: geometry, warnings: &warnings)
            guard let size = placements.values.first?.size else { continue }
            planned[layer.layerId] = PlannedOverlay(content: content, size: size, alignment: layer.anchor.horizontal)
            for i in layout.pages.indices {
                if let p = placements[layout.pages[i].role.page] {
                    layout.pages[i].overlays.append((layer, p.rect))
                }
            }
        }
        return planned
    }

    static func content(
        for layer: OverlayLayer, assets: [String: RenderAsset], values: [String: String], warnings: inout [RenderWarning]
    ) throws(RenderError) -> OverlayContent? {
        switch layer.type {
        case .text, .metadataText:
            guard let style = layer.text else {
                warnings.append(RenderWarning(code: "overlay.missing_text", message: "文字图层没有 text 设置，已跳过",
                                              layerId: layer.layerId))
                return nil
            }
            var text: String
            if layer.type == .text {
                text = style.content ?? ""
            } else {
                let filled = MetadataText.fill(style.template ?? "", values: values)
                text = filled.text
                if !filled.missing.isEmpty {
                    warnings.append(RenderWarning(
                        code: "overlay.metadata_missing",
                        message: "源图没有这些信息：\(filled.missing.joined(separator: ", "))（可手动填写）",
                        layerId: layer.layerId))
                }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                // metadataText 的字段全部缺失时整个图层不画（D-64），上面已给出 overlay.metadata_missing。
                warnings.append(RenderWarning(code: "overlay.empty_text", message: "文字为空，已跳过", layerId: layer.layerId))
                return nil
            }
            let (block, notes) = try TextBlock.make(text: text, style: style)
            warnings += notes.map { RenderWarning(code: "overlay.font_missing", message: $0, layerId: layer.layerId) }
            return .text(block)
        case .asset, .cameraBadge:
            guard let slotId = layer.slotId, let asset = assets[slotId] else {
                warnings.append(RenderWarning(code: "overlay.asset_missing", message: "素材槽 \(layer.slotId ?? "?") 没有可用素材，已跳过",
                                              layerId: layer.layerId))
                return nil
            }
            let content = try OverlayContent.load(asset: asset)
            if case .vector(let svg) = content {
                warnings += svg.warnings.map { RenderWarning(code: "overlay.svg_partial", message: $0, layerId: layer.layerId) }
            }
            return content
        }
    }
}

extension PanoramaWarning {
    var message: String {
        switch self {
        case .notLandscape(let r): "竖图或方图（比例 \(String(format: "%.3f", r))），全景切片通常没有意义"
        case .notWideEnough(let n): "照片不够宽：只需 \(n) 张切片"
        case .exceedsCarouselLimit(let total, let limit): "封面 + 切片共 \(total) 张，超过平台轮播上限 \(limit) 张"
        case .increasedSlideCount(let auto, let n): "手动张数 \(n) 多于自动张数 \(auto)，长卷两端补底色"
        }
    }
}

extension OverlayWarning {
    var message: String {
        switch self {
        case .exceedsCanvas(let o): "图层超出画布（上 \(o.top) 左 \(o.left) 下 \(o.bottom) 右 \(o.right) px）"
        case .overlapsPhoto(let r): "图层遮挡照片：\(r)"
        case .insufficientMargin(let edge, let available, let required):
            "\(edge.rawValue) 侧留白 \(available) px，放下图层需要 \(required) px"
        }
    }
}
