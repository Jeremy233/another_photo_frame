import Foundation
import PhotoFrameCore

/// 导出目录与文件命名（§9.2）：
///
/// ```text
/// <输出根目录>/<平台>/<作品名>/00_Cover.jpg
///                             01_Slide.jpg
///                             …
/// ```
///
/// 作品名目录已存在时加版本后缀：`Badlands_Panorama_v2`、`_v3`…，永不覆盖。
public struct OutputNaming: Hashable, Sendable, Codable {
    /// 作品名模板。可用占位符：
    /// - `{source}`：源文件名去掉扩展名；
    /// - `{variant}`：开启全景为 `Panorama`，否则 `Standard`（与 D-32 内置预设命名一致）；
    /// - `{preset}`：预设名称；
    /// - `{platform}`：平台目录名。
    ///
    /// 默认 `{source}_{variant}`，同一张源图的 Standard 与 Panorama 输出因此落在不同目录。
    public var workNameTemplate: String

    public static let defaultWorkNameTemplate = "{source}_{variant}"

    public init(workNameTemplate: String = OutputNaming.defaultWorkNameTemplate) {
        self.workNameTemplate = workNameTemplate
    }

    /// 平台 ID → 目录名，与 §9.2 示例一致。
    public static let platformFolderNames: [String: String] = [
        "instagram": "Instagram",
        "xiaohongshu": "Xiaohongshu",
        "douyin": "Douyin",
    ]

    /// 预设没有平台时的目录名。
    public static let genericPlatformFolder = "Custom"

    public static func platformFolderName(for platformId: String?) -> String {
        guard let platformId, !platformId.isEmpty else { return genericPlatformFolder }
        if let known = platformFolderNames[platformId] { return known }
        let clean = sanitize(platformId)
        return clean.prefix(1).uppercased() + clean.dropFirst()
    }

    public func workName(source: PhotoSource, preset: ExportPreset) -> String {
        let values: [String: String] = [
            "source": source.baseName,
            "variant": preset.panorama.enabled ? "Panorama" : "Standard",
            "preset": preset.name,
            "platform": Self.platformFolderName(for: preset.platform),
        ]
        // 单遍替换：源文件名里即使含有 `{variant}` 之类的文字也不会被再次展开。
        var name = ""
        var rest = workNameTemplate[...]
        while let open = rest.firstIndex(of: "{") {
            name += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }
            let key = String(rest[rest.index(after: open)..<close])
            name += values[key] ?? String(rest[open...close])
            rest = rest[rest.index(after: close)...]
        }
        name += rest
        return Self.sanitize(name)
    }

    /// 输出文件名：`00_Cover.jpg`、`01_Slide.jpg`…。序号至少两位；超过 99 项时按总数补位。
    public static func fileName(for role: JobOutputRole, format: OutputSettings.Format, outputCount: Int) -> String {
        let width = max(2, String(max(outputCount - 1, 0)).count)
        let number = String(role.carouselPosition)
        let padded = String(repeating: "0", count: max(0, width - number.count)) + number
        let label = switch role {
        case .cover: "Cover"
        case .slide: "Slide"
        }
        return "\(padded)_\(label).\(fileExtension(for: format))"
    }

    public static func fileExtension(for format: OutputSettings.Format) -> String {
        switch format {
        case .jpeg: "jpg"
        case .png: "png"
        }
    }

    /// 第 `version` 个版本的目录名：1 为原名，2 起加 `_v<n>`。
    public static func versioned(_ name: String, version: Int) -> String {
        version <= 1 ? name : "\(name)_v\(version)"
    }

    /// 版本号上限；超过时报 `export.versions_exhausted`。
    public static let maxVersion = 9999

    /// 把任意字符串变成安全的单段文件名：去掉路径分隔符、冒号、控制字符和首尾空白，
    /// 不以 `.` 开头（避免隐藏文件和 `..`），限制长度；结果为空时用 `Untitled`。
    public static func sanitize(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            if s == "/" || s == ":" || s == "\\" || s.properties.generalCategory == .control
                || s.properties.generalCategory == .format {
                scalars.append("_")
            } else {
                scalars.append(s)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 留出版本后缀的空间；按字符截断，不会切开组合字符。
        if name.count > 120 { name = String(name.prefix(120)) }
        return name.isEmpty ? "Untitled" : name
    }
}
