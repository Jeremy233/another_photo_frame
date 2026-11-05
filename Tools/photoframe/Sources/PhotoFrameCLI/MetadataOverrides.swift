import ArgumentParser
import Foundation

/// 手填的元数据（D-135）：胶卷、相机品牌、相机型号、光圈、快门、ISO。优先于源图的 EXIF，给没有 EXIF 的胶片扫描用；
/// 作用于本次命令 / 工具调用的每张源图，与 GUI 右栏「胶卷、相机与参数」相同。
///
/// CLI `export` / `preview` 的选项和 MCP 的 `metadata` 参数共用这些字段，值原样放进请求的 `metadataOverrides`
/// （只写数字的光圈、快门、ISO 由渲染层补单位）；空的不传，留空就用 EXIF。
enum MetadataField: String, CaseIterable {
    case film, make, model, aperture, shutter, iso

    /// CLI 选项的说明，也是 MCP `metadata` 各字段的说明。
    var help: String {
        switch self {
        case .film: "手填的胶卷（如 Kodak Portra 400，内置胶卷按名称匹配，也可以自己写），{film} 和胶卷图层用它。"
        case .make: "手填的相机品牌，优先于 EXIF 的 Make；品牌 logo 和 {brand} 按它认品牌。"
        case .model: "手填的相机型号，优先于 EXIF 的 Model。"
        case .aperture: "手填的光圈，优先于 EXIF；只写数字时补成 f/…（8 → f/8）。"
        case .shutter: "手填的快门，优先于 EXIF；只写数字时补上 s（1/250 → 1/250s）。"
        case .iso: "手填的 ISO，优先于 EXIF；只写数字时补成 ISO …（400 → ISO 400）。"
        }
    }

    /// 去掉没填的（空的或只有空白的），其余原样保留。
    static func overrides(_ values: [MetadataField: String?]) -> [String: String] {
        var out: [String: String] = [:]
        for (field, value) in values {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            out[field.rawValue] = value
        }
        return out
    }
}

/// `export` / `preview` 的手填元数据选项（D-135）。
struct MetadataOptions: ParsableArguments {
    /// 命令说明里的一段。
    static let discussion = "--film、--camera-make、--camera-model、--aperture、--shutter、--iso：手填元数据，优先于源图的 EXIF，用于没有 EXIF 的胶片扫描（D-135）。"

    @Option(name: .long, help: ArgumentHelp(MetadataField.film.help, valueName: "名称"))
    var film: String?

    @Option(name: .customLong("camera-make"), help: ArgumentHelp(MetadataField.make.help, valueName: "文字"))
    var cameraMake: String?

    @Option(name: .customLong("camera-model"), help: ArgumentHelp(MetadataField.model.help, valueName: "文字"))
    var cameraModel: String?

    @Option(name: .long, help: ArgumentHelp(MetadataField.aperture.help, valueName: "值"))
    var aperture: String?

    @Option(name: .long, help: ArgumentHelp(MetadataField.shutter.help, valueName: "值"))
    var shutter: String?

    @Option(name: .long, help: ArgumentHelp(MetadataField.iso.help, valueName: "值"))
    var iso: String?

    /// 请求的 `metadataOverrides`：只有填了的字段。
    var overrides: [String: String] {
        MetadataField.overrides([
            .film: film, .make: cameraMake, .model: cameraModel, .aperture: aperture, .shutter: shutter, .iso: iso,
        ])
    }
}
