// 装饰图层在画布中的像素矩形（规范 §7.1、D-12）。
//
// 输入是照片在画布中的像素矩形（FitLayout / CropLayout 的 pixelRect，或全景切片的 imageRect）。
// 计算全部是整数：
// - 对齐到边缘或放在外侧时，位置 = 边缘 ± 偏移 ± 图层尺寸，没有取整。
// - 居中时与 D-22 一致：左／上 = floor((参照长度 − 图层长度) / 2)，多出的 1 px 留在右／下。
// - `.fitting` 缩小后的尺寸取最近的整数（.5 进位），不超过最大尺寸，与照片尺寸的取整相同。
//
// 外侧方向：锚点在上／下行时向上／下伸出（水平方向仍按左、中、右对齐照片边缘），
// 中间行的左／右锚点向左／右伸出，正中锚点没有外侧。

/// 画布或照片的一条边。
public enum OverlayEdge: String, Hashable, Sendable, Codable {
    case top, left, bottom, right
}

/// 图层定位的提示。都不阻止计算；是否禁止导出由上层决定。
public enum OverlayWarning: Hashable, Sendable, Codable {
    /// 图层超出画布，`overflow` 是各边超出的像素数（未超出的边为 0）。
    case exceedsCanvas(overflow: PixelInsets)
    /// 留白模式下图层遮挡了照片，`intersection` 是被遮挡的区域。
    case overlapsPhoto(intersection: PixelRect)
    /// 照片外侧这一边的留白放不下图层：需要 `required` = 偏移 + 图层尺寸，实际只有 `available`。
    case insufficientMargin(edge: OverlayEdge, available: Int, required: Int)

    public var code: String {
        switch self {
        case .exceedsCanvas: "overlay.exceeds_canvas"
        case .overlapsPhoto: "overlay.overlaps_photo"
        case .insufficientMargin: "overlay.insufficient_margin"
        }
    }
}

/// 一个图层在一页画布上的定位结果。
public struct OverlayPlacement: Hashable, Sendable, Codable {
    public var canvas: PixelSize
    /// 参照的照片矩形（画布坐标）。只有全景中整张都是底色、且以画布为参照的切片上为 nil。
    public var photoRect: PixelRect?
    public var geometry: OverlayGeometry
    /// 解析后的图层尺寸。
    public var size: PixelSize
    /// 图层在画布中的像素矩形，可能部分超出画布（见 `warnings`）。
    public var rect: PixelRect
    public var warnings: [OverlayWarning]

    public init(canvas: PixelSize, photoRect: PixelRect, geometry: OverlayGeometry) throws(OverlayError) {
        try self.init(canvas: canvas, optionalPhotoRect: photoRect, geometry: geometry)
    }

    /// `photoRect` 为 nil 时只允许以画布为参照。
    init(canvas: PixelSize, optionalPhotoRect photoRect: PixelRect?, geometry: OverlayGeometry) throws(OverlayError) {
        guard canvas.isPositive else { throw .invalidCanvas(canvas) }
        if let photoRect {
            guard photoRect.size.isPositive, photoRect.minX >= 0, photoRect.minY >= 0,
                  photoRect.maxX <= canvas.width, photoRect.maxY <= canvas.height
            else { throw .invalidPhotoRect(photoRect) }
        } else {
            precondition(geometry.reference == .canvas, "以照片为参照时必须有照片矩形")
        }
        try geometry.visibility.validate()

        let size = try geometry.size.resolved()
        let canvasRect = PixelRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let anchor = geometry.anchor

        let rect: PixelRect
        var warnings: [OverlayWarning] = []
        switch geometry.reference {
        case .canvas:
            rect = PixelRect(
                x: alignInside(canvasRect.minX, canvasRect.maxX, size.width, anchor.horizontal, geometry.offset.x),
                y: alignInside(canvasRect.minY, canvasRect.maxY, size.height, anchor.vertical, geometry.offset.y),
                width: size.width, height: size.height)
        case .photo(.inside):
            let photoRect = photoRect!
            rect = PixelRect(
                x: alignInside(photoRect.minX, photoRect.maxX, size.width, anchor.horizontal, geometry.offset.x),
                y: alignInside(photoRect.minY, photoRect.maxY, size.height, anchor.vertical, geometry.offset.y),
                width: size.width, height: size.height)
        case .photo(.outside):
            let photoRect = photoRect!
            if anchor.vertical != .center {
                let (y, margin) = extendOutside(
                    photoRect.minY, photoRect.maxY, 0, canvas.height,
                    size.height, anchor.vertical, geometry.offset.y)
                rect = PixelRect(
                    x: alignInside(photoRect.minX, photoRect.maxX, size.width, anchor.horizontal, geometry.offset.x),
                    y: y, width: size.width, height: size.height)
                if margin.required > margin.available {
                    warnings.append(.insufficientMargin(
                        edge: anchor.vertical == .start ? .top : .bottom,
                        available: margin.available, required: margin.required))
                }
            } else if anchor.horizontal != .center {
                let (x, margin) = extendOutside(
                    photoRect.minX, photoRect.maxX, 0, canvas.width,
                    size.width, anchor.horizontal, geometry.offset.x)
                rect = PixelRect(
                    x: x,
                    y: alignInside(photoRect.minY, photoRect.maxY, size.height, anchor.vertical, geometry.offset.y),
                    width: size.width, height: size.height)
                if margin.required > margin.available {
                    warnings.append(.insufficientMargin(
                        edge: anchor.horizontal == .start ? .left : .right,
                        available: margin.available, required: margin.required))
                }
            } else {
                throw .centerAnchorOutside
            }
        }

        let overflow = PixelInsets(
            top: max(0, -rect.minY),
            left: max(0, -rect.minX),
            bottom: max(0, rect.maxY - canvas.height),
            right: max(0, rect.maxX - canvas.width))
        if overflow != PixelInsets(top: 0, left: 0, bottom: 0, right: 0) {
            warnings.append(.exceedsCanvas(overflow: overflow))
        }
        if geometry.reference.avoidsPhoto, let photoRect, let hit = rect.intersection(photoRect) {
            warnings.append(.overlapsPhoto(intersection: hit))
        }

        self.canvas = canvas
        self.photoRect = photoRect
        self.geometry = geometry
        self.size = size
        self.rect = rect
        self.warnings = warnings
    }

    public init(fit: FitLayout, geometry: OverlayGeometry) throws(OverlayError) {
        try self.init(canvas: fit.canvas, photoRect: fit.pixelRect, geometry: geometry)
    }

    public init(crop: CropLayout, geometry: OverlayGeometry) throws(OverlayError) {
        try self.init(fit: crop.fit, geometry: geometry)
    }
}

/// 全景中某一页的图层定位。
public struct OverlayPagePlacement: Hashable, Sendable, Codable {
    /// 轮播位置：0 = 封面，k + 1 = 切片 k。
    public var page: Int
    /// 以照片为参照、而这张切片上没有照片（整张都是底色）时为 nil，图层不绘制。
    public var placement: OverlayPlacement?
}

/// 一个图层在全景各页上的定位。
public struct PanoramaOverlayPlan: Hashable, Sendable, Codable {
    /// 显示该图层的页，按页码升序。
    public var pages: [OverlayPagePlacement]
    /// `selectedSlides` 中超出实际页数的页码（例如手动张数改少后残留的选择）。
    public var missingPages: [Int]
}

extension PanoramaLayout {
    /// 计算图层在封面与各切片上的位置。
    ///
    /// 封面以 `cover.pixelRect` 为照片矩形。切片上以照片为参照时，参照的是**这张切片里的照片部分**
    /// （`PanoramaSlice.imageRect`，本地坐标），不是整张切片；以画布为参照时是整张切片。
    public func overlayPlan(for geometry: OverlayGeometry) throws(OverlayError) -> PanoramaOverlayPlan {
        try geometry.visibility.validate()
        var pages: [OverlayPagePlacement] = []
        if geometry.visibility.includes(page: 0) {
            pages.append(OverlayPagePlacement(page: 0, placement: try OverlayPlacement(fit: cover, geometry: geometry)))
        }
        for slice in slices where geometry.visibility.includes(page: slice.index + 1) {
            let placement: OverlayPlacement?
            switch (geometry.reference, slice.imageRect) {
            case (.canvas, let imageRect):
                placement = try OverlayPlacement(canvas: tile, optionalPhotoRect: imageRect, geometry: geometry)
            case (.photo, let imageRect?):
                placement = try OverlayPlacement(canvas: tile, photoRect: imageRect, geometry: geometry)
            case (.photo, nil):
                placement = nil
            }
            pages.append(OverlayPagePlacement(page: slice.index + 1, placement: placement))
        }
        var missing: [Int] = []
        if case .selectedSlides(let selected) = geometry.visibility {
            missing = selected.filter { $0 > slideCount }.sorted()
        }
        return PanoramaOverlayPlan(pages: pages, missingPages: missing)
    }
}

extension OverlayVisibility {
    func validate() throws(OverlayError) {
        if case .selectedSlides(let pages) = self, let bad = pages.filter({ $0 < 0 }).min() {
            throw .invalidPage(bad)
        }
    }
}

extension OverlaySize {
    func resolved() throws(OverlayError) -> PixelSize {
        switch self {
        case .fixed(let size):
            guard size.isPositive else { throw .invalidSize(size) }
            return size
        case .fitting(let content, let maximum):
            guard content.isPositive else { throw .invalidSize(content) }
            guard maximum.isPositive else { throw .invalidMaximumSize(maximum) }
            guard content.width > maximum.width || content.height > maximum.height else { return content }
            let scale = min(
                Double(maximum.width) / Double(content.width),
                Double(maximum.height) / Double(content.height))
            return PixelSize(
                width: snapNearest(Double(content.width) * scale, limit: maximum.width),
                height: snapNearest(Double(content.height) * scale, limit: maximum.height))
        }
    }
}

extension PixelRect {
    /// 与另一矩形的交集；没有正面积的交集时为 nil。
    func intersection(_ other: PixelRect) -> PixelRect? {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// 在 `[lo, hi)` 内按对齐方式放置长度为 `length` 的区间，返回起点。
private func alignInside(_ lo: Int, _ hi: Int, _ length: Int, _ alignment: OverlayAlignment, _ offset: Int) -> Int {
    switch alignment {
    case .start: lo + offset
    case .end: hi - length - offset
    case .center: lo + floorDiv(hi - lo - length, 2) + offset
    }
}

/// 放在 `[lo, hi)` 的外侧（start = 之前，end = 之后），返回起点和这一侧留白的需求与可用量。
private func extendOutside(
    _ lo: Int, _ hi: Int, _ canvasLo: Int, _ canvasHi: Int,
    _ length: Int, _ alignment: OverlayAlignment, _ offset: Int
) -> (Int, (available: Int, required: Int)) {
    let required = offset + length
    switch alignment {
    case .start: return (lo - offset - length, (lo - canvasLo, required))
    case .end: return (hi + offset, (canvasHi - hi, required))
    case .center: preconditionFailure("居中轴没有外侧")
    }
}

/// 向负无穷取整的整数除法（图层比参照宽时差值为负）。
private func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}
