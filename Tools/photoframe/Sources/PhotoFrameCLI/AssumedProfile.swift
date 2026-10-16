import ArgumentParser
import PhotoFrameRendering

/// `--assume-profile`：没有 ICC 的源图按什么色彩空间解释（D-04）。源图自带 ICC 时忽略，并警告 `source.override_ignored`。
enum AssumedProfile: String, CaseIterable, ExpressibleByArgument {
    case srgb
    case displayP3 = "display-p3"
    case adobeRGB = "adobe-rgb"

    var override: SourceColorOverride {
        switch self {
        case .srgb: .sRGB
        case .displayP3: .displayP3
        case .adobeRGB: .adobeRGB
        }
    }

    static let help = ArgumentHelp(
        "没有 ICC 的源图按这个色彩空间解释（默认按 sRGB 并警告）。源图自带 ICC 时忽略并警告。",
        valueName: "srgb|display-p3|adobe-rgb")
}
