import ArgumentParser
import PhotoFrameRendering

/// `--assume-profile`：没有 ICC 的源图按什么色彩空间解释（D-04、D-75）。源图自带 ICC 时忽略，并警告 `source.override_ignored`。
/// 与 GUI 右栏「按此解释」的五个选项一一对应，GUI 里这样设置的任务都能用 CLI / MCP 复现。
enum AssumedProfile: String, CaseIterable, ExpressibleByArgument {
    case srgb
    case displayP3 = "display-p3"
    case adobeRGB = "adobe-rgb"
    case proPhotoRGB = "prophoto-rgb"
    case rec2020

    var override: SourceColorOverride {
        switch self {
        case .srgb: .sRGB
        case .displayP3: .displayP3
        case .adobeRGB: .adobeRGB
        case .proPhotoRGB: .proPhoto
        case .rec2020: .rec2020
        }
    }

    /// 用法和错误信息里列出的取值。
    static let valueList = allCases.map(\.rawValue).joined(separator: "|")

    static let help = ArgumentHelp(
        "没有 ICC 的源图按这个色彩空间解释（默认按 sRGB 并警告）。源图自带 ICC 时忽略并警告。",
        valueName: valueList)
}
