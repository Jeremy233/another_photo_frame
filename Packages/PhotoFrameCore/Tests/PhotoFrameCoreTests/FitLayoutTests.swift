import Testing
@testable import PhotoFrameCore

let instagram = PixelSize(width: 1080, height: 1440)
let xiaohongshu = PixelSize(width: 1080, height: 1080)
let douyin = PixelSize(width: 1080, height: 1920)

/// 检查 Fit 的通用不变量：留白 ≥ m、对称、尺寸与精确值差 ≤ 1 px、至少一边贴住内框。
func expectFitInvariants(_ fit: FitLayout, sourceLocation: SourceLocation = #_sourceLocation) {
    let m = fit.margins
    #expect(m.minimum >= fit.minimumMargin, sourceLocation: sourceLocation)
    #expect(m.left == m.right, sourceLocation: sourceLocation)
    #expect(m.top == m.bottom, sourceLocation: sourceLocation)
    // 精确值不足 2 px 的退化情况会被抬到最小 1 或 2 px，其余情况误差 ≤ 1 px。
    #expect(fit.exactRect.width < 2 || abs(Double(fit.pixelRect.width) - fit.exactRect.width) <= 1, sourceLocation: sourceLocation)
    #expect(fit.exactRect.height < 2 || abs(Double(fit.pixelRect.height) - fit.exactRect.height) <= 1, sourceLocation: sourceLocation)
    #expect(m.left == fit.minimumMargin || m.top == fit.minimumMargin, sourceLocation: sourceLocation)
    // 变换把源图四角映射到像素矩形四角。
    let br = fit.transform.apply(Point(x: Double(fit.source.width), y: Double(fit.source.height)))
    #expect(abs(br.x - Double(fit.pixelRect.maxX)) < 1e-6, sourceLocation: sourceLocation)
    #expect(abs(br.y - Double(fit.pixelRect.maxY)) < 1e-6, sourceLocation: sourceLocation)
}

@Suite("Fit 布局")
struct FitLayoutTests {
    @Test("横图放入 IG：宽度贴边，上下多余留白")
    func landscapeInInstagram() throws {
        let fit = try FitLayout(canvas: instagram, minimumMargin: 60, source: PixelSize(width: 6000, height: 4000))
        #expect(fit.pixelRect == PixelRect(x: 60, y: 400, width: 960, height: 640))
        #expect(fit.margins == PixelInsets(top: 400, left: 60, bottom: 400, right: 60))
        expectFitInvariants(fit)
    }

    @Test("竖图放入 IG：高度贴边")
    func portraitInInstagram() throws {
        let fit = try FitLayout(canvas: instagram, minimumMargin: 60, source: PixelSize(width: 4000, height: 6000))
        // 可用 960×1320，scale = min(0.24, 0.22) = 0.22 → 880×1320。
        #expect(fit.pixelRect == PixelRect(x: 100, y: 60, width: 880, height: 1320))
        expectFitInvariants(fit)
    }

    @Test("方图放入 1:1：四边恰好 m")
    func squareInSquare() throws {
        let fit = try FitLayout(canvas: xiaohongshu, minimumMargin: 60, source: PixelSize(width: 5000, height: 5000))
        #expect(fit.pixelRect == PixelRect(x: 60, y: 60, width: 960, height: 960))
        expectFitInvariants(fit)
    }

    @Test("65:24 全景封面：非贴边方向的半像素按同奇偶吸附")
    func panoramaCover() throws {
        let fit = try FitLayout(canvas: instagram, minimumMargin: 60, source: PixelSize(width: 6500, height: 2400))
        // 精确高 960 × 24/65 = 354.46… → 与 1440 同奇偶最近的是 354。
        #expect(fit.exactRect.height > 354 && fit.exactRect.height < 355)
        #expect(fit.pixelRect == PixelRect(x: 60, y: 543, width: 960, height: 354))
        expectFitInvariants(fit)
    }

    @Test("奇数画布尺寸也保持对称")
    func oddCanvas() throws {
        let fit = try FitLayout(canvas: PixelSize(width: 1001, height: 777), minimumMargin: 33, source: PixelSize(width: 3000, height: 2000))
        expectFitInvariants(fit)
        #expect(fit.pixelRect.width % 2 == 1)
    }

    @Test("EXIF 方向 6 交换宽高")
    func orientation() throws {
        let source = SourceImage(storedSize: PixelSize(width: 6000, height: 4000), orientation: .right)
        #expect(source.displaySize == PixelSize(width: 4000, height: 6000))
        let fit = try FitLayout(canvas: instagram, minimumMargin: 60, source: source)
        #expect(fit.pixelRect.height == 1320)
        for o in ExifOrientation.allCases {
            let s = SourceImage(storedSize: PixelSize(width: 3, height: 2), orientation: o)
            #expect(s.displaySize.width == (o.rawValue >= 5 ? 2 : 3))
        }
    }

    @Test("大量比例 × 三个平台 × 多种边距：不变量恒成立")
    func sweep() throws {
        let canvases = [instagram, xiaohongshu, douyin, PixelSize(width: 1001, height: 1333)]
        for canvas in canvases {
            for margin in [0, 1, 60, 61, 200] {
                for w in stride(from: 1, through: 9001, by: 237) {
                    for h in [1, 7, 999, 1000, 1001, 4000, 6001] {
                        let fit = try FitLayout(canvas: canvas, minimumMargin: margin, source: PixelSize(width: w, height: h))
                        expectFitInvariants(fit)
                    }
                }
            }
        }
    }

    @Test("非法参数")
    func invalid() {
        #expect(throws: GeometryError.marginTooLarge(margin: 540, canvas: xiaohongshu)) {
            try FitLayout(canvas: xiaohongshu, minimumMargin: 540, source: PixelSize(width: 10, height: 10))
        }
        #expect(throws: GeometryError.invalidSource(PixelSize(width: 0, height: 10))) {
            try FitLayout(canvas: xiaohongshu, minimumMargin: 60, source: PixelSize(width: 0, height: 10))
        }
        #expect(throws: GeometryError.invalidMargin(-1)) {
            try FitLayout(canvas: xiaohongshu, minimumMargin: -1, source: PixelSize(width: 10, height: 10))
        }
    }

    @Test("同奇偶吸附")
    func snapping() {
        #expect(snapSameParity(2925, container: 3240, limit: 3240) == 2924)  // 平局取小
        #expect(snapSameParity(2925.4, container: 3240, limit: 3240) == 2926)
        #expect(snapSameParity(959.9999999, container: 1080, limit: 960) == 960)
        #expect(snapSameParity(960.4, container: 1080, limit: 960) == 960)  // 不越过内框
        #expect(snapSameParity(0.2, container: 1080, limit: 960) == 2)
        #expect(snapSameParity(0.2, container: 1081, limit: 961) == 1)
        #expect(snapSameParity(4.6, container: 1081, limit: 961) == 5)
    }
}

@Suite("比例裁切布局")
struct CropLayoutTests {
    @Test("默认按内框比例居中裁切，结果填满内框")
    func centeredDefault() throws {
        let crop = try CropLayout(canvas: instagram, minimumMargin: 60, source: PixelSize(width: 6000, height: 4000))
        // 内框 960×1320 = 8:11 → 裁切框 2909×4000（2909.09 四舍五入）。
        #expect(crop.cropRect == PixelRect(x: 1546, y: 0, width: 2909, height: 4000))
        #expect(crop.fit.pixelRect == PixelRect(x: 60, y: 60, width: 960, height: 1320))
        // 裁切框左上角映射到照片左上角。
        let corner = crop.transform.apply(Point(x: 1546, y: 0))
        #expect(abs(corner.x - 60) < 1e-9 && abs(corner.y - 60) < 1e-9)
    }

    @Test("指定比例与位置")
    func anchors() throws {
        let source = PixelSize(width: 4000, height: 6000)
        let square = AspectRatio(width: 1, height: 1)
        let top = try CropLayout(canvas: xiaohongshu, minimumMargin: 60, source: source, aspectRatio: square, anchor: Point(x: 0.5, y: 0))
        #expect(top.cropRect == PixelRect(x: 0, y: 0, width: 4000, height: 4000))
        let bottom = try CropLayout(canvas: xiaohongshu, minimumMargin: 60, source: source, aspectRatio: square, anchor: Point(x: 0.5, y: 1))
        #expect(bottom.cropRect == PixelRect(x: 0, y: 2000, width: 4000, height: 4000))
        let center = try CropLayout(canvas: xiaohongshu, minimumMargin: 60, source: source, aspectRatio: square)
        #expect(center.cropRect.y == 1000)
        expectFitInvariants(center.fit)
    }

    @Test("比例相同则不裁切")
    func sameAspect() throws {
        let crop = try CropLayout(canvas: xiaohongshu, minimumMargin: 60, source: PixelSize(width: 3000, height: 3000))
        #expect(crop.cropRect == PixelRect(x: 0, y: 0, width: 3000, height: 3000))
    }

    @Test("非法比例与位置")
    func invalid() {
        #expect(throws: GeometryError.self) {
            try CropLayout(canvas: instagram, minimumMargin: 60, source: PixelSize(width: 10, height: 10), aspectRatio: AspectRatio(width: 0, height: 1))
        }
        #expect(throws: GeometryError.invalidAnchor(Point(x: 1.5, y: 0.5))) {
            try CropLayout(canvas: instagram, minimumMargin: 60, source: PixelSize(width: 10, height: 10), anchor: Point(x: 1.5, y: 0.5))
        }
    }
}
