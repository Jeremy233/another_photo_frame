import Testing
@testable import PhotoFrameCore

private let landscape = PixelSize(width: 6000, height: 4000)
private let badge = OverlaySize.fixed(PixelSize(width: 48, height: 48))

private func place(
    _ canvas: PixelSize, _ source: PixelSize, _ anchor: OverlayAnchor,
    reference: OverlayReference = .default, offset: OverlayOffset, size: OverlaySize = badge
) throws -> OverlayPlacement {
    let fit = try FitLayout(canvas: canvas, minimumMargin: 60, source: source)
    return try OverlayPlacement(
        fit: fit, geometry: OverlayGeometry(anchor: anchor, reference: reference, offset: offset, size: size))
}

@Suite("装饰图层：九宫格锚点")
struct OverlayAnchorTests {
    // 3:2 横图在三个平台上都是 960×640，只是上下位置不同：
    // IG (60, 400)、XHS (60, 220)、抖音 (60, 640)。
    @Test("照片外侧（默认）：三个平台封面上的八个锚点", arguments: [
        (instagram, 400), (xiaohongshu, 220), (douyin, 640),
    ])
    func outsidePhotoOnCovers(canvas: PixelSize, photoTop: Int) throws {
        let offset = OverlayOffset(x: 8, y: 16)
        let y0 = photoTop
        let expected: [(OverlayAnchor, PixelRect)] = [
            // 上下行：竖直方向伸出照片 16 px，水平方向距照片左右边缘 8 px，居中列再右移 8 px。
            (.topLeft, PixelRect(x: 68, y: y0 - 64, width: 48, height: 48)),
            (.top, PixelRect(x: 524, y: y0 - 64, width: 48, height: 48)),
            (.topRight, PixelRect(x: 964, y: y0 - 64, width: 48, height: 48)),
            // 中间行：水平方向伸出照片 8 px，竖直居中（floor((640−48)/2) = 296）再下移 16 px。
            (.left, PixelRect(x: 4, y: y0 + 312, width: 48, height: 48)),
            (.right, PixelRect(x: 1028, y: y0 + 312, width: 48, height: 48)),
            (.bottomLeft, PixelRect(x: 68, y: y0 + 656, width: 48, height: 48)),
            (.bottom, PixelRect(x: 524, y: y0 + 656, width: 48, height: 48)),
            (.bottomRight, PixelRect(x: 964, y: y0 + 656, width: 48, height: 48)),
        ]
        for (anchor, rect) in expected {
            let p = try place(canvas, landscape, anchor, offset: offset)
            #expect(p.rect == rect, "\(anchor)")
            #expect(p.warnings.isEmpty, "\(anchor)")
        }
        #expect(throws: OverlayError.centerAnchorOutside) {
            try place(canvas, landscape, .center, offset: offset)
        }
    }

    @Test("照片内侧：九个锚点，允许叠在照片上")
    func insidePhoto() throws {
        let offset = OverlayOffset(x: 8, y: 16)
        let expected: [(OverlayAnchor, Int, Int)] = [
            (.topLeft, 68, 416), (.top, 524, 416), (.topRight, 964, 416),
            (.left, 68, 712), (.center, 524, 712), (.right, 964, 712),
            (.bottomLeft, 68, 976), (.bottom, 524, 976), (.bottomRight, 964, 976),
        ]
        for (anchor, x, y) in expected {
            let p = try place(instagram, landscape, anchor, reference: .photo(.inside), offset: offset)
            #expect(p.rect == PixelRect(x: x, y: y, width: 48, height: 48), "\(anchor)")
            #expect(p.warnings.isEmpty, "\(anchor)")
        }
    }

    @Test("以画布为参照：九个锚点，正中会遮挡照片")
    func canvasReference() throws {
        let offset = OverlayOffset(x: 8, y: 16)
        let expected: [(OverlayAnchor, Int, Int)] = [
            (.topLeft, 8, 16), (.top, 524, 16), (.topRight, 1024, 16),
            (.left, 8, 712), (.center, 524, 712), (.right, 1024, 712),
            (.bottomLeft, 8, 1376), (.bottom, 524, 1376), (.bottomRight, 1024, 1376),
        ]
        for (anchor, x, y) in expected {
            let p = try place(instagram, landscape, anchor, reference: .canvas, offset: offset)
            let rect = PixelRect(x: x, y: y, width: 48, height: 48)
            #expect(p.rect == rect, "\(anchor)")
            #expect(p.warnings == (anchor == .center ? [.overlapsPhoto(intersection: rect)] : []), "\(anchor)")
        }
    }

    @Test("居中取整与 D-22 一致：多出的 1 px 在右／下，图层比参照宽时向下取整")
    func centerRounding() throws {
        // 照片宽 960，图层宽 49：左 = floor(911/2) = 455，右 = 456。
        let odd = try place(instagram, landscape, .bottom, offset: .zero,
                            size: .fixed(PixelSize(width: 49, height: 10)))
        #expect(odd.rect.x == 60 + 455)
        #expect(1020 - odd.rect.maxX == 456)
        // 竖图照片 (100, 60, 880×1320)，图层宽 1201：floor(−321/2) = −161。
        let wide = try place(instagram, PixelSize(width: 4000, height: 6000), .top,
                             reference: .photo(.inside), offset: .zero,
                             size: .fixed(PixelSize(width: 1201, height: 10)))
        #expect(wide.rect.x == 100 - 161)
    }
}

@Suite("装饰图层：跟随照片")
struct OverlayFollowTests {
    @Test("照片比例变化时，右下角下方 16 px 的图层跟着照片走",
          arguments: [
            (PixelSize(width: 6000, height: 4000), PixelRect(x: 972, y: 1056, width: 48, height: 48)),
            (PixelSize(width: 4000, height: 4000), PixelRect(x: 972, y: 1216, width: 48, height: 48)),
            (PixelSize(width: 6500, height: 2400), PixelRect(x: 972, y: 913, width: 48, height: 48)),
            (PixelSize(width: 4000, height: 5000), PixelRect(x: 972, y: 1336, width: 48, height: 48)),
          ])
    func followsPhoto(source: PixelSize, expected: PixelRect) throws {
        let p = try place(instagram, source, .bottomRight, offset: OverlayOffset(x: 0, y: 16))
        #expect(p.rect == expected)
        let photo = try #require(p.photoRect)
        #expect(p.rect.maxX == photo.maxX)
        #expect(p.rect.minY == photo.maxY + 16)
    }

    @Test("CropLayout：参照裁切后的照片矩形")
    func followsCrop() throws {
        let crop = try CropLayout(canvas: instagram, minimumMargin: 60, source: landscape,
                                  aspectRatio: AspectRatio(width: 1, height: 1))
        let p = try OverlayPlacement(crop: crop, geometry: OverlayGeometry(
            anchor: .bottomLeft, offset: OverlayOffset(x: 0, y: 16), size: badge))
        // 1:1 裁切 → 960×960，位于 (60, 240)。
        #expect(crop.fit.pixelRect == PixelRect(x: 60, y: 240, width: 960, height: 960))
        #expect(p.rect == PixelRect(x: 60, y: 1216, width: 48, height: 48))
    }
}

@Suite("装饰图层：边界与警告")
struct OverlayWarningTests {
    // 4000×6000 竖图在 IG 上是 (100, 60, 880×1320)，下方留白正好 60 px。
    let portrait = PixelSize(width: 4000, height: 6000)

    @Test("恰好贴住画布下边：没有警告")
    func flushWithCanvas() throws {
        let p = try place(instagram, portrait, .bottom, offset: OverlayOffset(x: 0, y: 16),
                          size: .fixed(PixelSize(width: 200, height: 44)))
        #expect(p.rect.maxY == instagram.height)
        #expect(p.warnings.isEmpty)
    }

    @Test("恰好贴住照片（间隙 0）：不算遮挡")
    func flushWithPhoto() throws {
        let p = try place(instagram, portrait, .bottom, offset: .zero,
                          size: .fixed(PixelSize(width: 200, height: 60)))
        #expect(p.rect.minY == 1380)
        #expect(p.warnings.isEmpty)
    }

    @Test("留白不足 1 px：同时报留白不足和超出画布")
    func insufficientMargin() throws {
        let p = try place(instagram, portrait, .bottom, offset: OverlayOffset(x: 0, y: 16),
                          size: .fixed(PixelSize(width: 200, height: 45)))
        #expect(p.warnings == [
            .insufficientMargin(edge: .bottom, available: 60, required: 61),
            .exceedsCanvas(overflow: PixelInsets(top: 0, left: 0, bottom: 1, right: 0)),
        ])
        #expect(p.warnings.map(\.code) == ["overlay.insufficient_margin", "overlay.exceeds_canvas"])
    }

    @Test("左右外侧留白不足")
    func insufficientSideMargin() throws {
        let p = try place(instagram, landscape, .left, offset: OverlayOffset(x: 16, y: 0))
        // 左边只有 60 px，需要 16 + 48 = 64 px。
        #expect(p.rect.x == -4)
        #expect(p.warnings == [
            .insufficientMargin(edge: .left, available: 60, required: 64),
            .exceedsCanvas(overflow: PixelInsets(top: 0, left: 4, bottom: 0, right: 0)),
        ])
    }

    @Test("图层比画布宽：两侧都超出")
    func widerThanCanvas() throws {
        let p = try place(instagram, portrait, .bottom, offset: .zero,
                          size: .fixed(PixelSize(width: 1200, height: 20)))
        #expect(p.rect.x == -60)
        #expect(p.warnings == [.exceedsCanvas(overflow: PixelInsets(top: 0, left: 60, bottom: 0, right: 60))])
    }

    @Test("留白模式下负偏移压到照片上：报遮挡")
    func overlapsPhoto() throws {
        let p = try place(instagram, portrait, .bottom, offset: OverlayOffset(x: 0, y: -10),
                          size: .fixed(PixelSize(width: 200, height: 40)))
        #expect(p.warnings == [.overlapsPhoto(intersection: PixelRect(x: 440, y: 1370, width: 200, height: 10))])
    }

    @Test("照片内侧超出照片但仍在画布内：不报警")
    func insideMayCoverPhoto() throws {
        let p = try place(instagram, portrait, .bottomRight, reference: .photo(.inside),
                          offset: OverlayOffset(x: -20, y: -20))
        #expect(p.rect == PixelRect(x: 952, y: 1352, width: 48, height: 48))
        #expect(p.warnings.isEmpty)
    }
}

@Suite("装饰图层：尺寸与参数")
struct OverlaySizeTests {
    @Test("最大尺寸：等比缩小，取最近整数，不放大")
    func fittingSize() throws {
        #expect(try OverlaySize.fitting(PixelSize(width: 400, height: 100),
                                        maximum: PixelSize(width: 200, height: 200)).resolved()
                == PixelSize(width: 200, height: 50))
        // 333×100 → ×0.3003 → 100×30.03 → 100×30。
        #expect(try OverlaySize.fitting(PixelSize(width: 333, height: 100),
                                        maximum: PixelSize(width: 100, height: 100)).resolved()
                == PixelSize(width: 100, height: 30))
        #expect(try OverlaySize.fitting(PixelSize(width: 40, height: 30),
                                        maximum: PixelSize(width: 100, height: 100)).resolved()
                == PixelSize(width: 40, height: 30))
    }

    @Test("参数错误")
    func invalidParameters() throws {
        #expect(throws: OverlayError.invalidSize(PixelSize(width: 0, height: 10))) {
            try place(instagram, landscape, .top, offset: .zero, size: .fixed(PixelSize(width: 0, height: 10)))
        }
        #expect(throws: OverlayError.invalidMaximumSize(PixelSize(width: 10, height: 0))) {
            try place(instagram, landscape, .top, offset: .zero,
                      size: .fitting(PixelSize(width: 10, height: 10), maximum: PixelSize(width: 10, height: 0)))
        }
        #expect(throws: OverlayError.invalidPhotoRect(PixelRect(x: 0, y: 0, width: 2000, height: 10))) {
            try OverlayPlacement(canvas: instagram, photoRect: PixelRect(x: 0, y: 0, width: 2000, height: 10),
                                 geometry: OverlayGeometry(anchor: .top, size: badge))
        }
    }

    @Test("默认值：照片外侧、仅封面")
    func defaults() {
        let g = OverlayGeometry(anchor: .bottomRight, size: badge)
        #expect(g.reference == .photo(.outside))
        #expect(g.visibility == .coverOnly)
        #expect(g.reference.avoidsPhoto)
        #expect(OverlayReference.canvas.avoidsPhoto)
        #expect(!OverlayReference.photo(.inside).avoidsPhoto)
    }
}

@Suite("装饰图层：全景可见性")
struct OverlayPanoramaTests {
    // 65:24 → IG：4 张切片，照片在长卷中 (210, 0, 3900×1440)。
    // 切片 0 的照片部分 (210, 0, 870×1440)，切片 1、2 铺满，切片 3 (0, 0, 870×1440)。
    let panorama = try! PanoramaLayout(tile: instagram, source: PixelSize(width: 6500, height: 2400))

    @Test("默认只在封面")
    func coverOnly() throws {
        let plan = try panorama.overlayPlan(for: OverlayGeometry(
            anchor: .bottomRight, offset: OverlayOffset(x: 0, y: 16), size: badge))
        #expect(plan.pages.map(\.page) == [0])
        let cover = try #require(plan.pages[0].placement)
        #expect(cover.photoRect == panorama.cover.pixelRect)
        #expect(cover.rect == PixelRect(x: 972, y: panorama.cover.pixelRect.maxY + 16, width: 48, height: 48))
        #expect(plan.missingPages.isEmpty)
    }

    @Test("所有页：切片上参照这张切片里的照片部分")
    func allSlidesFollowPhotoPart() throws {
        let plan = try panorama.overlayPlan(for: OverlayGeometry(
            anchor: .bottomRight, reference: .photo(.inside), offset: OverlayOffset(x: 16, y: 16),
            size: badge, visibility: .allSlides))
        #expect(plan.pages.map(\.page) == [0, 1, 2, 3, 4])
        let xs = plan.pages.dropFirst().map { $0.placement?.rect.x }
        // 切片 3 的照片部分只到 x = 870，图层随之左移。
        #expect(xs == [1016, 1016, 1016, 806])
        #expect(plan.pages.dropFirst().allSatisfy { $0.placement?.rect.y == 1376 })
        #expect(plan.pages.allSatisfy { $0.placement?.warnings.isEmpty == true })
    }

    @Test("切片上照片铺满高度：外侧没有留白")
    func outsideOnFullHeightSlice() throws {
        let plan = try panorama.overlayPlan(for: OverlayGeometry(
            anchor: .bottom, offset: OverlayOffset(x: 0, y: 16), size: badge,
            visibility: .selectedSlides([2])))
        let p = try #require(plan.pages.first?.placement)
        #expect(p.warnings.contains(.insufficientMargin(edge: .bottom, available: 0, required: 64)))
    }

    @Test("指定页：超出实际页数的页码单独列出")
    func selectedSlides() throws {
        let plan = try panorama.overlayPlan(for: OverlayGeometry(
            anchor: .topLeft, reference: .canvas, size: badge, visibility: .selectedSlides([0, 2, 9])))
        #expect(plan.pages.map(\.page) == [0, 2])
        #expect(plan.missingPages == [9])
        #expect(throws: OverlayError.invalidPage(-1)) {
            try panorama.overlayPlan(for: OverlayGeometry(
                anchor: .topLeft, size: badge, visibility: .selectedSlides([-1])))
        }
    }

    @Test("整张底色的切片：照片参照不绘制，画布参照照常")
    func blankSlice() throws {
        // 手动 6 张：长卷 6480，照片 3900，左补边 1290，切片 0 没有照片。
        let wide = try PanoramaLayout(tile: instagram, source: PixelSize(width: 6500, height: 2400),
                                      slideCount: .manual(6))
        #expect(wide.slices[0].imageRect == nil)
        let photoPlan = try wide.overlayPlan(for: OverlayGeometry(
            anchor: .bottomLeft, reference: .photo(.inside), size: badge, visibility: .selectedSlides([1, 2])))
        #expect(photoPlan.pages.map(\.page) == [1, 2])
        #expect(photoPlan.pages[0].placement == nil)
        #expect(photoPlan.pages[1].placement?.rect.x == 210)

        let canvasPlan = try wide.overlayPlan(for: OverlayGeometry(
            anchor: .center, reference: .canvas, size: badge, visibility: .selectedSlides([1])))
        let p = try #require(canvasPlan.pages[0].placement)
        #expect(p.photoRect == nil)
        #expect(p.rect == PixelRect(x: 516, y: 696, width: 48, height: 48))
        #expect(p.warnings.isEmpty)
    }
}
