/// EXIF / TIFF Orientation 标签值（1…8）。
public enum ExifOrientation: Int, Sendable, Codable, CaseIterable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8

    /// 5…8 表示图像需旋转 90°，显示宽高与存储宽高互换。
    public var swapsDimensions: Bool { rawValue >= 5 }
}

/// 一张源图的几何信息：文件中存储的像素尺寸加上 EXIF 方向。
///
/// 所有布局计算都使用 `displaySize`（规范 §5.1 中的 S_w × S_h）。
public struct SourceImage: Hashable, Sendable, Codable {
    public var storedSize: PixelSize
    public var orientation: ExifOrientation

    public init(storedSize: PixelSize, orientation: ExifOrientation = .up) {
        self.storedSize = storedSize
        self.orientation = orientation
    }

    /// EXIF 方向校正后的显示尺寸。
    public var displaySize: PixelSize {
        orientation.swapsDimensions
            ? PixelSize(width: storedSize.height, height: storedSize.width)
            : storedSize
    }
}
