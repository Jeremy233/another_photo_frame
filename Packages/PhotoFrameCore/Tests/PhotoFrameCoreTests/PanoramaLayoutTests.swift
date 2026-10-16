import Testing
@testable import PhotoFrameCore

/// 切片拼回长卷的不变量：无缝、无重叠、补边只在两端、所有切片共用一套全局变换。
func expectSeamless(_ p: PanoramaLayout, sourceLocation: SourceLocation = #_sourceLocation) {
    let w = p.tile.width
    #expect(p.slices.count == p.slideCount, sourceLocation: sourceLocation)
    #expect(p.stripSize == PixelSize(width: p.slideCount * w, height: p.tile.height), sourceLocation: sourceLocation)

    var nextX = 0
    var imageColumns = 0
    var nextSourceX = 0.0
    for slice in p.slices {
        // 切片帧首尾相接、等宽、满高。
        #expect(slice.frame == PixelRect(x: nextX, y: 0, width: w, height: p.tile.height), sourceLocation: sourceLocation)
        nextX = slice.frame.maxX

        // 同一缩放、平移只差 kW。
        #expect(slice.transform.scaleX == p.transform.scaleX, sourceLocation: sourceLocation)
        #expect(slice.transform.scaleY == p.transform.scaleY, sourceLocation: sourceLocation)
        #expect(slice.transform.translateX == p.transform.translateX - Double(slice.frame.x), sourceLocation: sourceLocation)
        #expect(slice.transform.translateY == p.transform.translateY, sourceLocation: sourceLocation)

        if let r = slice.imageRect {
            #expect(slice.backgroundLeft + r.width + slice.backgroundRight == w, sourceLocation: sourceLocation)
            #expect(r.x == slice.backgroundLeft, sourceLocation: sourceLocation)
            #expect(r.y == p.pixelImageRect.y && r.height == p.pixelImageRect.height, sourceLocation: sourceLocation)
            // 全局列连续。
            #expect(slice.frame.x + r.x == p.pixelImageRect.x + imageColumns, sourceLocation: sourceLocation)
            imageColumns += r.width
            // 源图区域首尾相接。
            let region = try! #require(slice.sourceRegion, sourceLocation: sourceLocation)
            #expect(abs(region.minX - nextSourceX) < 1e-6, sourceLocation: sourceLocation)
            #expect(abs(region.minY) < 1e-6 && abs(region.height - Double(p.source.height)) < 1e-6, sourceLocation: sourceLocation)
            nextSourceX = region.maxX
            // 照片不触碰切片边缘的那一侧必须是长卷外侧（内部接缝没有底色）。
            if slice.backgroundLeft > 0 { #expect(r.x + slice.frame.x == p.pixelImageRect.minX, sourceLocation: sourceLocation) }
            if slice.backgroundRight > 0 { #expect(r.maxX + slice.frame.x == p.pixelImageRect.maxX, sourceLocation: sourceLocation) }
        } else {
            #expect(slice.backgroundLeft + slice.backgroundRight == w, sourceLocation: sourceLocation)
            #expect(slice.sourceRegion == nil, sourceLocation: sourceLocation)
        }
    }
    #expect(nextX == p.stripSize.width, sourceLocation: sourceLocation)
    #expect(imageColumns == p.pixelImageRect.width, sourceLocation: sourceLocation)
    #expect(abs(nextSourceX - Double(p.source.width)) < 1e-6, sourceLocation: sourceLocation)

    // 照片完整在长卷内、在上下边距内，左右补边对称。
    let img = p.pixelImageRect
    #expect(img.minX >= 0 && img.maxX <= p.stripSize.width, sourceLocation: sourceLocation)
    #expect(img.minY >= p.verticalMargin && img.maxY <= p.tile.height - p.verticalMargin, sourceLocation: sourceLocation)
    #expect(p.pixelPadding.left == p.pixelPadding.right, sourceLocation: sourceLocation)
    #expect(img.minY == p.tile.height - img.maxY, sourceLocation: sourceLocation)
    #expect(p.exactImageRect.width < 2 || abs(Double(img.width) - p.exactImageRect.width) <= 1, sourceLocation: sourceLocation)
    #expect(p.exactImageRect.height < 2 || abs(Double(img.height) - p.exactImageRect.height) <= 1, sourceLocation: sourceLocation)

    // 封面独立 Fit。
    expectFitInvariants(p.cover)
}

@Suite("全景切片")
struct PanoramaLayoutTests {
    // MARK: 验收算例（§5.3 数值表、§13.4）

    @Test("AC-01：3:1 → IG，4 张，无补边")
    func ac01() throws {
        let p = try PanoramaLayout(tile: instagram, source: PixelSize(width: 3000, height: 1000))
        #expect(p.slideCount == 4)
        #expect(p.stripSize == PixelSize(width: 4320, height: 1440))
        #expect(p.exactImageRect == Rect(x: 0, y: 0, width: 4320, height: 1440))
        #expect(p.pixelImageRect == PixelRect(x: 0, y: 0, width: 4320, height: 1440))
        #expect(p.pixelPadding == (0, 0))
        #expect(p.slices.allSatisfy { $0.backgroundLeft == 0 && $0.backgroundRight == 0 })
        #expect(p.warnings.isEmpty)
        // 封面：完整原图 Fit，宽 960。
        #expect(p.cover.pixelRect == PixelRect(x: 60, y: 560, width: 960, height: 320))
        expectSeamless(p)
    }

    @Test("AC-02：65:24 → IG，4 张，长卷 4320，图宽 3900，左右各 210")
    func ac02() throws {
        let p = try PanoramaLayout(tile: instagram, source: PixelSize(width: 6500, height: 2400))
        #expect(p.slideCount == 4)
        #expect(p.stripSize.width == 4320)
        #expect(abs(p.exactImageRect.width - 3900) < 1e-9)
        #expect(p.pixelImageRect == PixelRect(x: 210, y: 0, width: 3900, height: 1440))
        #expect(p.pixelPadding == (210, 210))
        #expect(p.slices.map(\.backgroundLeft) == [210, 0, 0, 0])
        #expect(p.slices.map(\.backgroundRight) == [0, 0, 0, 210])
        #expect(p.warnings.isEmpty)
        expectSeamless(p)
    }

    @Test("AC-03：65:24 → XHS，3 张，补边约 157.5，统一栅格化")
    func ac03() throws {
        let p = try PanoramaLayout(tile: xiaohongshu, source: PixelSize(width: 6500, height: 2400))
        #expect(p.slideCount == 3)
        #expect(p.stripSize == PixelSize(width: 3240, height: 1080))
        #expect(abs(p.exactImageRect.width - 2925) < 1e-9)
        #expect(abs(p.exactPadding.left - 157.5) < 1e-9 && abs(p.exactPadding.right - 157.5) < 1e-9)
        // 2925 与 3240 奇偶不同：取 2924，左右各 158，对称。
        #expect(p.pixelImageRect == PixelRect(x: 158, y: 0, width: 2924, height: 1080))
        #expect(p.pixelPadding == (158, 158))
        expectSeamless(p)
    }

    @Test("3:1 → XHS，3 张，无补边")
    func threeToOneXHS() throws {
        let p = try PanoramaLayout(tile: xiaohongshu, source: PixelSize(width: 3000, height: 1000))
        #expect(p.slideCount == 3)
        #expect(p.pixelImageRect == PixelRect(x: 0, y: 0, width: 3240, height: 1080))
        expectSeamless(p)
    }

    // MARK: 整数边界

    @Test("比例恰为整数张时不多算一张", arguments: [instagram, xiaohongshu, douyin])
    func exactIntegerBoundary(tile: PixelSize) throws {
        // sw / sh = N·W / H，整数精确成立；浮点计算可能略大于 N。
        for n in 2...12 {
            for k in 1...300 {
                let sh = tile.height * k
                let sw = n * tile.width * k
                let p = try PanoramaLayout(tile: tile, source: PixelSize(width: sw, height: sh))
                #expect(p.automaticSlideCount == n, "\(sw)×\(sh) on \(tile)")
                #expect(p.pixelImageRect.width == n * tile.width)
            }
        }
    }

    @Test("略大于 / 略小于整数边界")
    func nearBoundary() throws {
        // 浮点噪声量级的超出（< 容差）仍算 4 张。
        let tiny = try PanoramaLayout(tile: instagram, source: PixelSize(width: 300_000_001, height: 100_000_000))
        #expect(tiny.automaticSlideCount == 4)
        #expect(tiny.pixelImageRect.width == 4320)
        expectSeamless(tiny)
        // 真实超出 1.44 px → 5 张。
        let over = try PanoramaLayout(tile: instagram, source: PixelSize(width: 3001, height: 1000))
        #expect(over.automaticSlideCount == 5)
        expectSeamless(over)
        // 略小 → 4 张，两端补少量底色。
        let under = try PanoramaLayout(tile: instagram, source: PixelSize(width: 2999, height: 1000))
        #expect(under.automaticSlideCount == 4)
        #expect(under.pixelPadding.left == 1)
        expectSeamless(under)
    }

    // MARK: 手动张数（D-11）

    @Test("手动改多：只在两端补更多底色")
    func manualMore() throws {
        let p = try PanoramaLayout(tile: instagram, source: PixelSize(width: 3000, height: 1000), slideCount: .manual(6))
        #expect(p.slideCount == 6)
        #expect(p.pixelImageRect == PixelRect(x: 1080, y: 0, width: 4320, height: 1440))
        #expect(p.slices.first?.imageRect == nil && p.slices.first?.backgroundLeft == 1080)
        #expect(p.slices.last?.imageRect == nil && p.slices.last?.backgroundRight == 1080)
        #expect(p.warnings == [.increasedSlideCount(automatic: 4, requested: 6)])
        expectSeamless(p)

        let q = try PanoramaLayout(tile: instagram, source: PixelSize(width: 6500, height: 2400), slideCount: .manual(5))
        #expect(q.pixelPadding == (750, 750))
        expectSeamless(q)
    }

    @Test("手动改少：整体缩小到 N·W 宽，上下补底色并提示")
    func manualFewer() throws {
        let p = try PanoramaLayout(tile: instagram, source: PixelSize(width: 3000, height: 1000), slideCount: .manual(3))
        #expect(p.stripSize.width == 3240)
        #expect(p.pixelImageRect == PixelRect(x: 0, y: 180, width: 3240, height: 1080))
        guard case .reducedSlideCount(let auto, let req, let factor) = p.warnings.first else {
            Issue.record("缺少改少提示"); return
        }
        #expect(auto == 4 && req == 3 && abs(factor - 0.75) < 1e-12)
        expectSeamless(p)

        let one = try PanoramaLayout(tile: xiaohongshu, source: PixelSize(width: 6500, height: 2400), slideCount: .manual(1))
        #expect(one.pixelImageRect.width == 1080)
        expectSeamless(one)
    }

    // MARK: 上下边距 v（D-10）

    @Test("上下边距：渲染高度 H − 2v，张数随之重算")
    func verticalMargin() throws {
        let p = try PanoramaLayout(tile: instagram, source: PixelSize(width: 3000, height: 1000), verticalMargin: 120)
        #expect(p.automaticSlideCount == 4)
        #expect(p.pixelImageRect == PixelRect(x: 360, y: 120, width: 3600, height: 1200))
        expectSeamless(p)

        // v = 180 → 渲染 3240×1080，恰好 3 张。
        let q = try PanoramaLayout(tile: instagram, source: PixelSize(width: 3000, height: 1000), verticalMargin: 180)
        #expect(q.automaticSlideCount == 3)
        #expect(q.pixelImageRect == PixelRect(x: 0, y: 180, width: 3240, height: 1080))
        expectSeamless(q)

        let r = try PanoramaLayout(tile: instagram, source: PixelSize(width: 6500, height: 2400), verticalMargin: 100)
        #expect(r.pixelImageRect.minY == 100 && r.pixelImageRect.height == 1240)
        expectSeamless(r)

        // v 与改少同时生效：照片仍不越过 v。
        let s = try PanoramaLayout(tile: instagram, source: PixelSize(width: 3000, height: 1000), verticalMargin: 100, slideCount: .manual(2))
        #expect(s.pixelImageRect.height == 720 && s.pixelImageRect.minY == 360)
        expectSeamless(s)
    }

    @Test("非法上下边距与张数")
    func invalid() {
        #expect(throws: GeometryError.invalidVerticalMargin(720)) {
            try PanoramaLayout(tile: instagram, source: PixelSize(width: 3000, height: 1000), verticalMargin: 720)
        }
        #expect(throws: GeometryError.invalidSlideCount(0)) {
            try PanoramaLayout(tile: instagram, source: PixelSize(width: 3000, height: 1000), slideCount: .manual(0))
        }
    }

    // MARK: 警告

    @Test("超过平台轮播上限（含封面）")
    func carouselLimit() throws {
        let ok = try PanoramaLayout(tile: instagram, source: PixelSize(width: 3000, height: 1000), maxCarouselItems: 5)
        #expect(ok.warnings.isEmpty)
        let tooMany = try PanoramaLayout(tile: instagram, source: PixelSize(width: 3000, height: 1000), maxCarouselItems: 4)
        #expect(tooMany.warnings == [.exceedsCarouselLimit(totalItems: 5, limit: 4)])
        let extreme = try PanoramaLayout(tile: instagram, source: PixelSize(width: 20000, height: 2000), maxCarouselItems: 10)
        #expect(extreme.slideCount == 14)
        #expect(extreme.warnings.contains(.exceedsCarouselLimit(totalItems: 15, limit: 10)))
        expectSeamless(extreme)
    }

    @Test("竖图、方图、放得进一张：提示但仍可计算")
    func unsuitable() throws {
        let portrait = try PanoramaLayout(tile: instagram, source: PixelSize(width: 4000, height: 6000))
        #expect(portrait.warnings.first?.code == "panorama.not_landscape")
        expectSeamless(portrait)

        let square = try PanoramaLayout(tile: xiaohongshu, source: PixelSize(width: 3000, height: 3000))
        #expect(square.warnings == [.notLandscape(aspectRatio: 1)])
        #expect(square.slideCount == 1)
        expectSeamless(square)

        let single = try PanoramaLayout(tile: xiaohongshu, source: PixelSize(width: 2000, height: 1000), verticalMargin: 300)
        #expect(single.warnings == [.fitsSingleSlide])
        expectSeamless(single)
    }

    @Test("EXIF 方向影响全景判断")
    func orientation() throws {
        let rotated = SourceImage(storedSize: PixelSize(width: 1000, height: 3000), orientation: .left)
        let p = try PanoramaLayout(tile: instagram, source: rotated)
        #expect(p.slideCount == 4 && p.warnings.isEmpty)
    }

    @Test("大量比例 × 平台 × 边距 × 张数：无缝不变量恒成立")
    func sweep() throws {
        for tile in [instagram, xiaohongshu, douyin, PixelSize(width: 1081, height: 1351)] {
            for v in [0, 1, 37, 200] {
                for (sw, sh) in [(3000, 1000), (6500, 2400), (12345, 1001), (99991, 7), (5, 3), (1000, 1000), (1000, 4000)] {
                    let source = PixelSize(width: sw, height: sh)
                    for count in [SlideCount.automatic, .manual(1), .manual(2), .manual(7)] {
                        let p = try PanoramaLayout(tile: tile, source: source, verticalMargin: v, slideCount: count)
                        expectSeamless(p)
                    }
                }
            }
        }
    }
}
