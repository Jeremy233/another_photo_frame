import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import PhotoFrameCore

/// 照片在一页上的来源：几何全部来自 PhotoFrameCore（FitLayout / CropLayout / PanoramaLayout），这里不重算。
enum PhotoPlacement {
    /// 源图显示坐标中的 `region` 缩放到 `rect.size`，放在页面的 `rect`（Fit、封面、比例裁切）。
    case region(Rect, rect: PixelRect)
    /// 全景切片：整张照片在长卷中栅格化一次（`strip` = `pixelImageRect`），本页取 `[kW, (k+1)W)`。
    case strip(PixelRect, sliceOriginX: Int)
    /// 整张都是底色的切片。
    case none
}

/// 一页的合成参数。
struct PagePlan {
    var role: OutputRole
    var canvas: PixelSize
    var background: PresetColor
    var photo: PhotoPlacement
    /// 图层（已按 zIndex 排序）及其在本页的像素矩形。
    var overlays: [(layer: OverlayLayer, rect: PixelRect)]
}

/// 照片缩放与页面合成（§6.3 Layout / Composite 两段，§6.4）。全部在工作空间（D-03）里完成。
struct PageComposer {
    /// 把源图中的一块区域缩放成 `target` 像素，extent = (0, 0, target)。
    ///
    /// 做法沿用色彩 PoC：先 `clampedToExtent`，再 Lanczos，最后裁回整数尺寸。照片边缘是硬边，
    /// 透明区不会卷进滤波核，照片内沿不振铃（PoC 坑 7）。x、y 两个方向按 D-22 的像素尺寸分别缩放。
    static func scaledPhoto(_ image: CIImage, region: Rect, displaySize: PixelSize, target: PixelSize) -> CIImage {
        let e = image.extent
        let fx = e.width / Double(displaySize.width), fy = e.height / Double(displaySize.height)
        // 显示坐标（左上原点）→ 解码图（左下原点）
        let rx = region.minX * fx, rw = region.width * fx
        let rh = region.height * fy, ry = e.height - (region.minY + region.height) * fy
        var img = image.clampedToExtent()
        if rx != 0 || ry != 0 { img = img.transformed(by: CGAffineTransform(translationX: -rx, y: -ry)) }
        let sx = Double(target.width) / rw, sy = Double(target.height) / rh
        if abs(sx - 1) > 1e-12 || abs(sy - 1) > 1e-12 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = img
            f.scale = Float(sy)
            f.aspectRatio = Float(sx / sy)
            img = f.outputImage!
        }
        return img.cropped(to: CGRect(x: 0, y: 0, width: target.width, height: target.height))
    }

    /// 只作用于照片图层的 HDR → SDR（§6.7 第 2、3 条：背景、水印、文字不参与 tone map）。
    static func toneMapped(_ photo: CIImage, sourceHeadroom: Double) -> CIImage {
        let f = CIFilter.toneMapHeadroom()
        f.inputImage = photo
        f.sourceHeadroom = Float(sourceHeadroom)
        f.targetHeadroom = 1
        return f.outputImage!.cropped(to: photo.extent)
    }

    /// 页面坐标（左上原点）的矩形 → CI 坐标（左下原点）的平移量。
    static func ciOrigin(_ rect: PixelRect, canvasHeight: Int) -> CGPoint {
        CGPoint(x: rect.x, y: canvasHeight - rect.y - rect.height)
    }

    /// 合成一页。`photo` 是已经缩放好的照片（`.region` 时尺寸 = rect，`.strip` 时尺寸 = 长卷中的照片矩形）。
    static func compose(
        plan: PagePlan, photo: CIImage?, overlays: [String: CIImage], background: CIColor
    ) -> CIImage {
        let pageRect = CGRect(x: 0, y: 0, width: plan.canvas.width, height: plan.canvas.height)
        var page = CIImage(color: background).cropped(to: pageRect)
        if let photo {
            switch plan.photo {
            case .region(_, let rect):
                let o = ciOrigin(rect, canvasHeight: plan.canvas.height)
                page = photo.transformed(by: CGAffineTransform(translationX: o.x, y: o.y)).composited(over: page)
            case .strip(let strip, let sliceX):
                // 整数平移：所有切片取自同一个全局栅格，接缝两侧逐像素一致（§5.3 第 4、6 条）。
                let o = ciOrigin(PixelRect(x: strip.x - sliceX, y: strip.y, width: strip.width, height: strip.height),
                                 canvasHeight: plan.canvas.height)
                page = photo.transformed(by: CGAffineTransform(translationX: o.x, y: o.y))
                    .cropped(to: pageRect).composited(over: page)
            case .none:
                break
            }
        }
        for (layer, rect) in plan.overlays {
            guard let content = overlays[layer.layerId] else { continue }
            let o = ciOrigin(rect, canvasHeight: plan.canvas.height)
            var placed = content.transformed(by: CGAffineTransform(translationX: o.x, y: o.y))
            if layer.opacity < 1 {
                // CI 的颜色滤镜在非预乘值上运算，只缩放 alpha 即可（测试验证线性光混合结果）。
                let a = CGFloat(max(0, layer.opacity))
                let m = CIFilter.colorMatrix()
                m.inputImage = placed
                m.aVector = CIVector(x: 0, y: 0, z: 0, w: a)
                placed = m.outputImage!
            }
            page = placed.composited(over: page)
        }
        return page.cropped(to: pageRect)
    }
}
