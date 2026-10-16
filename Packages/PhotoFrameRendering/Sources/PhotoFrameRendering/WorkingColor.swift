import CoreGraphics
import CoreImage
import Foundation
import PhotoFrameCore

/// 颜色空间与 Core Image 上下文（D-03：extended linear Rec.2020 + RGBAh）。
enum WorkingColor {
    /// 工作空间。所有中间结果都在这里，全程 extended，不在 [0, 1] 截断。
    static let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let format = CIFormat.RGBAh
    static let spaceName = "extendedLinearITUR_2020"
    static let formatName = "RGBAh"

    /// V1 唯一的输出空间（§6.8）。
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let sRGBProfileName = "sRGB IEC61966-2.1"
    /// 显示用预览（`PreviewColorMode.extendedRange`）：与 sRGB 同一编码，但不截断 > 1 与色域外的值。
    static let extendedSRGB = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    /// HDR → SDR 峰值估算用的线性 sRGB（§6.7：「线性 sRGB 分量最大值的 99.95 分位」）。
    static let extendedLinearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// 新建渲染上下文。CI 默认工作空间是 extended linear sRGB，必须显式指定（PoC §6 第 5 条）。
    /// 不缓存中间结果：任务之间不共享大图缓冲，内存只取决于当前任务。
    static func makeContext() -> CIContext {
        CIContext(options: [
            .workingColorSpace: space,
            .workingFormat: NSNumber(value: format.rawValue),
            .cacheIntermediates: false,
            .name: "PhotoFrameRendering",
        ])
    }

    /// 预设颜色（`#RRGGBB`，sRGB 编码，§6.5）→ CIColor。CI 在渲染时把它转进工作空间。
    static func ciColor(_ color: PresetColor) throws(RenderError) -> CIColor {
        let (r, g, b) = try rgb8(color)
        return CIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, colorSpace: sRGB)!
    }

    static func cgColor(_ color: PresetColor) throws(RenderError) -> CGColor {
        let (r, g, b) = try rgb8(color)
        return CGColor(colorSpace: sRGB, components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1])!
    }

    static func rgb8(_ color: PresetColor) throws(RenderError) -> (Int, Int, Int) {
        guard color.colorSpace == "sRGB" else {
            throw RenderError(code: "render.unsupported_color_space", message: "目前只支持 sRGB 颜色：\(color.colorSpace)")
        }
        guard color.isValidHex, let v = Int(color.hex.dropFirst(), radix: 16) else {
            throw RenderError(code: "render.invalid_color", message: "颜色格式应为 #RRGGBB：\(color.hex)")
        }
        return (v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF)
    }

    /// 输入色彩空间覆盖（D-04）对应的颜色空间。
    static func space(for override: SourceColorOverride) -> CGColorSpace {
        switch override {
        case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
        case .adobeRGB: CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        case .proPhoto: CGColorSpace(name: CGColorSpace.rommrgb)!
        case .rec2020: CGColorSpace(name: CGColorSpace.itur_2020)!
        }
    }

    static func describe(_ space: CGColorSpace?) -> String {
        guard let space else { return "未知" }
        if let name = space.name { return name as String }
        if let data = space.copyICCData() as Data?, let desc = ICCProfile(data)?.descriptionText { return desc }
        return "\(space.model)"
    }
}
