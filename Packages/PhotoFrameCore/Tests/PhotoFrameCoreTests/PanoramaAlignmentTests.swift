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
        // 向下取整：差不超过 2R 像素。
        #expect(abs(p.pixelPadding.right - v) <= 8)
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
