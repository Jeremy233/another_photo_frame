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
        case .layers: "图层"
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

extension LayerTemplate {
    var title: String {
        switch self {
        case .watermark: "水印"
        case .signature: "签名"
        case .cameraBadge: "相机图标"
        case .exifText: "EXIF 文字"
        case .text: "文字"
        }
    }
}

extension OverlayLayer.LayerType {
    var title: String {
        switch self {
        case .text: "文字"
        case .asset: "素材"
        case .metadataText: "EXIF 文字"
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

extension JobStatus {
    var title: String {
        switch self {
        case .queued: "排队中"
        case .validating: "校验"
        case .decoding: "解码"
        case .rendering: "渲染"
        case .encoding: "编码"
        case .writing: "写入"
        case .completed: "已完成"
        case .failed: "失败"
        case .canceled: "已取消"
        }
    }
}

extension SourceColorOverride {
    var title: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        case .adobeRGB: "Adobe RGB"
        case .proPhoto: "ProPhoto RGB"
        case .rec2020: "Rec. 2020"
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
