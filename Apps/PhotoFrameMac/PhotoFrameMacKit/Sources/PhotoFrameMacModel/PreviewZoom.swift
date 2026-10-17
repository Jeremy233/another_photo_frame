import CoreGraphics
import Foundation

/// 预览缩放（UI 设计文档第 9 节）：适合窗口、100%、手动缩放（菜单档位、⌘+ / ⌘-、触控板捏合）。
/// 比例以屏幕像素计：1 表示一个图像像素对应一个屏幕像素（100%）。
public enum PreviewZoom: Hashable, Sendable {
    /// 整页（或整条长卷）放进预览区。
    case fit
    case scale(Double)

    /// 100%：一个图像像素对应一个屏幕像素。
    public static let actualSize = PreviewZoom.scale(1)
    /// 菜单里的档位，也是 ⌘+ / ⌘- 依次经过的比例。
    public static let steps: [Double] = [0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 8]
    public static let range: ClosedRange<Double> = 0.05...8

    /// 「适合窗口」的比例：内容（以图像像素计）按屏幕像素缩放后完整放进区域（pt），四周留 `padding`。
    public static func fitScale(contentPixels: CGSize, in area: CGSize, displayScale: Double, padding: Double = 16) -> Double {
        guard contentPixels.width > 0, contentPixels.height > 0 else { return 1 }
        let width = max(area.width - 2 * padding, 1) * displayScale
        let height = max(area.height - 2 * padding, 1) * displayScale
        return min(width / contentPixels.width, height / contentPixels.height)
    }
}

extension PreviewModel {
    /// 现在实际用的比例。
    public var effectiveScale: Double {
        switch zoom {
        case .fit: fitScale
        case .scale(let s): s
        }
    }

    /// 菜单标题：适合窗口时也显示实际比例（Compressor 的预览也是直接显示百分比）。
    public var zoomTitle: String {
        let percent = Int((effectiveScale * 100).rounded())
        return zoom == .fit ? "适合窗口 \(percent)%" : "\(percent)%"
    }

    /// ⌘+：到下一个更大的档位。
    public func zoomIn() {
        let current = effectiveScale
        zoom = .scale(PreviewZoom.steps.first { $0 > current * 1.001 } ?? PreviewZoom.steps[PreviewZoom.steps.count - 1])
    }

    /// ⌘-：到下一个更小的档位。
    public func zoomOut() {
        let current = effectiveScale
        zoom = .scale(PreviewZoom.steps.last { $0 < current * 0.999 } ?? PreviewZoom.steps[0])
    }

    /// 触控板捏合：手势开始时的比例 × 手势的倍数。
    public func magnify(from base: Double, by factor: Double) {
        zoom = .scale(min(max(base * factor, PreviewZoom.range.lowerBound), PreviewZoom.range.upperBound))
    }
}
