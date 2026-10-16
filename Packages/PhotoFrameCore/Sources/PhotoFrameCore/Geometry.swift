// 基本几何值。
//
// 坐标约定（规范 §5.1）：原点在左上，x 向右，y 向下。
// 整数类型（PixelSize / PixelRect / PixelInsets）表示最终栅格上的像素边缘坐标；
// 浮点类型（Size / Point / Rect）表示连续的设计坐标，用于说明精确几何与做采样。

/// 整数像素尺寸。
public struct PixelSize: Hashable, Sendable, Codable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// 宽高比 width / height。
    public var aspectRatio: Double { Double(width) / Double(height) }

    public var isPositive: Bool { width > 0 && height > 0 }

    public var description: String { "\(width)×\(height)" }
}

/// 整数像素矩形，`x..<x+width` × `y..<y+height`。
public struct PixelRect: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Int { x }
    public var minY: Int { y }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var size: PixelSize { PixelSize(width: width, height: height) }

    /// 转为连续坐标。
    public var rect: Rect {
        Rect(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
    }

    public var description: String { "(\(x), \(y), \(width)×\(height))" }
}

/// 四边整数间距（留白、补边等）。
public struct PixelInsets: Hashable, Sendable, Codable {
    public var top: Int
    public var left: Int
    public var bottom: Int
    public var right: Int

    public init(top: Int, left: Int, bottom: Int, right: Int) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public var minimum: Int { Swift.min(top, left, bottom, right) }
}

/// 连续坐标下的尺寸。
public struct Size: Hashable, Sendable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// 连续坐标下的点。
public struct Point: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 连续坐标下的矩形。
public struct Rect: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// 只含缩放与平移的仿射变换：`target = source × scale + translation`。
///
/// 把源图显示坐标（已做 EXIF 方向校正）映射到目标画布或切片坐标。
public struct ScaleTranslateTransform: Hashable, Sendable, Codable {
    public var scaleX: Double
    public var scaleY: Double
    public var translateX: Double
    public var translateY: Double

    public init(scaleX: Double, scaleY: Double, translateX: Double, translateY: Double) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.translateX = translateX
        self.translateY = translateY
    }

    public func apply(_ p: Point) -> Point {
        Point(x: p.x * scaleX + translateX, y: p.y * scaleY + translateY)
    }

    /// 目标坐标反算回源图坐标。
    public func invert(_ p: Point) -> Point {
        Point(x: (p.x - translateX) / scaleX, y: (p.y - translateY) / scaleY)
    }

    /// 把目标坐标中的矩形反算为源图坐标中的矩形。
    public func invert(_ r: Rect) -> Rect {
        let a = invert(Point(x: r.minX, y: r.minY))
        let b = invert(Point(x: r.maxX, y: r.maxY))
        return Rect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// 平移后的同一变换（切片从全局长卷坐标换到本地坐标时用）。
    public func translatedBy(x dx: Double, y dy: Double) -> ScaleTranslateTransform {
        ScaleTranslateTransform(
            scaleX: scaleX, scaleY: scaleY,
            translateX: translateX + dx, translateY: translateY + dy)
    }

    /// 由源图尺寸和其在目标中的像素矩形构造。
    static func mapping(source: PixelSize, into rect: PixelRect) -> ScaleTranslateTransform {
        ScaleTranslateTransform(
            scaleX: Double(rect.width) / Double(source.width),
            scaleY: Double(rect.height) / Double(source.height),
            translateX: Double(rect.x),
            translateY: Double(rect.y))
    }
}

/// 宽高比，如 3:4。
public struct AspectRatio: Hashable, Sendable, Codable, CustomStringConvertible {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init(_ size: PixelSize) {
        self.init(width: Double(size.width), height: Double(size.height))
    }

    public var value: Double { width / height }
    public var isValid: Bool { width > 0 && height > 0 && value.isFinite }

    public var description: String { "\(width):\(height)" }
}
