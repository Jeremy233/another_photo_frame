import Testing
@testable import PhotoFrameCore

/// 全景的左右对齐与「自动上下边距」。
struct PanoramaAlignmentTests {
    let tile = PixelSize(width: 1080, height: 1440)
    /// R = 4：不加边距时渲染宽 5760，自动 6 张，两端各补 360。
    let source = PixelSize(width: 6000, height: 1500)

    @Test func centerSplitsPaddingEvenly() throws {
        let p = try PanoramaLayout(tile: tile, source: source)
        #expect(p.pixelPadding.left == 360 && p.pixelPadding.right == 360)
    }

    @Test func leftPutsPhotoFlushAgainstTheStart() throws {
        let p = try PanoramaLayout(tile: tile, source: source, alignment: .left)
        #expect(p.pixelImageRect.x == 0 && p.exactImageRect.x == 0)
        #expect(p.pixelPadding.right == 720)
        #expect(p.slices.first?.backgroundLeft == 0)
    }

    @Test func rightPutsPhotoFlushAgainstTheEnd() throws {
        let p = try PanoramaLayout(tile: tile, source: source, alignment: .right)
        #expect(p.pixelImageRect.maxX == p.stripSize.width)
        #expect(abs(p.exactImageRect.maxX - Double(p.stripSize.width)) < 1e-9)
        #expect(p.pixelPadding.left == 720 && p.slices.last?.backgroundRight == 0)
    }

    @Test func autoMarginEqualsEachEndWhenCentered() throws {
        // N = floor(5760 / 1080) = 5，v = (5760 − 5400) / (2·4 − 2) = 60。
        let v = PanoramaLayout.equalizedVerticalMargin(tile: tile, source: source)
        #expect(v == 60)
        let p = try PanoramaLayout(tile: tile, source: source, verticalMargin: v)
        #expect(p.slideCount == 5)
        #expect(p.pixelPadding.left == 60 && p.pixelPadding.right == 60)
        #expect(p.pixelImageRect.y == 60 && p.tile.height - p.pixelImageRect.maxY == 60)
    }

    @Test func autoMarginEqualsTheOpenEndWhenFlush() throws {
        let v = PanoramaLayout.equalizedVerticalMargin(tile: tile, source: source, alignment: .left)
        let p = try PanoramaLayout(tile: tile, source: source, verticalMargin: v, alignment: .left)
        #expect(p.slideCount == 5 && p.pixelPadding.left == 0)
        // 取整后差不超过 2R 像素。
        #expect(abs(p.pixelPadding.right - v) <= 8)
    }

    @Test func autoMarginRoundsUpWhenRoundingDownOverflows() throws {
        // R = 3.005：v = 7.2 / 4.01 ≈ 1.80。向下取 1 时照片宽 4321.2 > 4 · 1080，会变成 5 张、不加边距。
        let wide = PixelSize(width: 3005, height: 1000)
        let v = PanoramaLayout.equalizedVerticalMargin(tile: tile, source: wide)
        #expect(v == 2)
        #expect(try PanoramaLayout(tile: tile, source: wide, verticalMargin: v).slideCount == 4)
        // 手动张数同理：放不下时渲染会抛出 slideCountBelowMinimum。
        let manual = PanoramaLayout.equalizedVerticalMargin(tile: tile, source: wide, slideCount: .manual(4))
        #expect(manual == 2)
        #expect(try PanoramaLayout(tile: tile, source: wide, verticalMargin: manual, slideCount: .manual(4)).slideCount == 4)
    }

    @Test func autoMarginSolvesEveryWideSource() throws {
        // 有 ≥ 1 px 的解且不超过半高时，自动边距不能退回 0，版式也必须正好是 N 张。
        for width in stride(from: 1500, through: 40000, by: 7) {
            let wide = PixelSize(width: width, height: 1000)
            let r = wide.aspectRatio
            let n = Int(((r * 1440 + PanoramaLayout.defaultSlideCountTolerance) / 1080).rounded(.down))
            for alignment in [PanoramaSettings.Alignment.center, .left] {
                let k: Double = alignment == .center ? 2 : 1
                let exact = (r * 1440 - Double(n) * 1080) / (2 * r - k)
                guard exact >= 1, exact < 700 else { continue }
                let v = PanoramaLayout.equalizedVerticalMargin(tile: tile, source: wide, alignment: alignment)
                #expect(v > 0, "\(width) \(alignment)")
                let p = try PanoramaLayout(tile: tile, source: wide, verticalMargin: v, alignment: alignment)
                #expect(p.slideCount == n, "\(width) \(alignment)")
                let padding = alignment == .center ? p.pixelPadding.left : p.pixelPadding.right
                #expect(Double(abs(padding - v)) <= 2 * r / k + 2, "\(width) \(alignment)")
            }
        }
    }

    @Test func autoMarginFallsBackToZeroWhenUnsolvable() {
        // 竖图、接近方图（v 会超过半高）、手动张数多于能解的张数。
        #expect(PanoramaLayout.equalizedVerticalMargin(tile: tile, source: PixelSize(width: 1000, height: 1500)) == 0)
        #expect(PanoramaLayout.equalizedVerticalMargin(tile: tile, source: PixelSize(width: 1200, height: 1000)) == 0)
        #expect(PanoramaLayout.equalizedVerticalMargin(tile: tile, source: source, slideCount: .manual(6)) == 0)
    }

    @Test func settingsResolveTheMargin() {
        var settings = PanoramaSettings(enabled: true, verticalMarginPx: 33)
        #expect(settings.resolvedVerticalMargin(tile: tile, source: source) == 33)
        settings.autoVerticalMargin = true
        #expect(settings.resolvedVerticalMargin(tile: tile, source: source) == 60)
    }
}
