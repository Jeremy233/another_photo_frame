import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameMacModel
import PhotoFrameRendering
import PhotoFrameStorage
import UniformTypeIdentifiers

// 界面上的中文名称。

extension WorkbenchMode {
    var title: String {
        switch self {
        case .current: "当前"
        case .active: "活跃"
        case .completed: "已完成"
        }
    }
}

extension SidebarTab {
    var title: String {
        switch self {
        case .presets: "预设"
        case .locations: "位置"
        case .assets: "素材"
        }
    }
}

extension InspectorTab {
    var title: String {
        switch self {
        case .canvas: "画布"
        case .panorama: "全景"
        case .layers: "装饰"
        case .output: "输出"
        }
    }
}

extension CatalogPresetOrigin {
    var groupTitle: String {
        switch self {
        case .builtIn: "内置"
        case .user: "用户保存"
        case .imported: "导入"
        case .file: "文件"
        }
    }
}

extension AssetCategory {
    var title: String {
        switch self {
        case .signature: "签名"
        case .watermark: "水印"
        case .cameraBadge: "相机图标"
        }
    }
}

extension OverlayAnchor {
    var title: String {
        switch name {
        case "topLeft": "左上"
        case "top": "上"
        case "topRight": "右上"
        case "left": "左"
        case "center": "中"
        case "right": "右"
        case "bottomLeft": "左下"
        case "bottom": "下"
        default: "右下"
        }
    }
}

/// 任务状态的文字（参照 Compressor：等待 / 处理中 / 成功）。状态列只用这里的文字。
extension JobStatus {
    var title: String {
        switch self {
        case .queued: "等待"
        case .validating: "校验"
        case .decoding: "解码"
        case .rendering: "渲染"
        case .encoding: "编码"
        case .writing: "写入"
        case .completed: "成功"
        case .failed: "失败"
        case .canceled: "已取消"
        }
    }
}

extension JobRecord {
    /// 状态列：执行中的阶段写成「处理中 · 渲染」。
    var statusTitle: String {
        switch status {
        case .queued, .completed, .failed, .canceled: status.title
        default: "处理中 · \(status.title)"
        }
    }
}

extension SourceColorOverride {
    /// 与后端警告、源图的 ICC 一行同一个名字。
    var title: String { displayName }
}

/// 源图右栏「EXIF」里各项的中文名和顺序。值来自图层文字可用的 EXIF 字段，悬停时显示对应的文字模板占位符。
enum ExifLabels {
    static let order: [(key: String, title: String)] = [
        ("camera", "相机"), ("make", "品牌"), ("model", "型号"), ("lens", "镜头"), ("focalLength", "焦距"),
        ("focalLength35", "等效焦距"), ("aperture", "光圈"), ("shutter", "快门"), ("iso", "ISO"), ("date", "拍摄日期"),
    ]

    /// 按固定顺序排好的（名字、占位符、值）；不认识的键排在后面，原样显示。
    static func rows(_ metadata: [String: String]) -> [(title: String, key: String, value: String)] {
        let known = order.compactMap { entry in metadata[entry.key].map { (entry.title, entry.key, $0) } }
        let others = metadata.keys.filter { key in !order.contains { $0.key == key } }.sorted().map { ($0, $0, metadata[$0] ?? "") }
        return known + others
    }
}

extension SourceInspection {
    /// EXIF 方向（1…8）的说法。
    var orientationTitle: String {
        switch orientation {
        case 1: "正常"
        case 2: "水平翻转"
        case 3: "旋转 180°"
        case 4: "垂直翻转"
        case 5: "水平翻转后逆时针旋转 90°"
        case 6: "顺时针旋转 90°"
        case 7: "水平翻转后顺时针旋转 90°"
        case 8: "逆时针旋转 90°"
        default: "\(orientation)"
        }
    }
}

extension SourceInspection.HDR {
    /// HDR 的形式（D-62）。
    var kindTitle: String {
        switch kind {
        case "gainMap": "增益图"
        case "gainMapTIFF": "TIFF 增益图"
        case "transferFunction": "PQ / HLG"
        case "floatLinear": "浮点线性"
        default: kind
        }
    }
}

extension JobOutputRole {
    var shortTitle: String {
        switch self {
        case .cover: "封面"
        case .slide(let p): "\(p)"
        }
    }
}

extension PixelSize {
    var text: String { "\(width) × \(height)" }
}

enum FileTypes {
    static let images: [UTType] = [.jpeg, .png, .tiff]
    static let preset = UTType(filenameExtension: "photoframe") ?? .zip
    static let assets: [UTType] = [.png, .svg]
}

extension TextStyle.FontWeight {
    var title: String {
        switch self {
        case .ultraLight: "极细"
        case .thin: "纤细"
        case .light: "细"
        case .regular: "常规"
        case .medium: "中等"
        case .semibold: "中粗"
        case .bold: "粗"
        case .heavy: "特粗"
        case .black: "黑"
        }
    }
}

/// ImageIO 给出的色彩空间名（`kCGColorSpaceDisplayP3` 之类）换成给人看的名字，与「按此解释」的选项同名；嵌入的 ICC 描述原样显示。
enum ColorProfileName {
    static func display(_ name: String) -> String {
        guard name.hasPrefix("kCGColorSpace") else { return name }
        let known = [
            "kCGColorSpaceSRGB": "sRGB", "kCGColorSpaceDisplayP3": "Display P3", "kCGColorSpaceAdobeRGB1998": "Adobe RGB",
            "kCGColorSpaceROMMRGB": "ProPhoto RGB", "kCGColorSpaceITUR_2020": "Rec. 2020", "kCGColorSpaceGenericGrayGamma2_2": "灰度",
        ]
        return known[name] ?? String(name.dropFirst("kCGColorSpace".count))
    }
}
