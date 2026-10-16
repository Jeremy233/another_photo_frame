import Foundation
import ImageIO
import PhotoFrameCore

/// `metadataText` 模板的占位符（§7.1、§7.2）。取值规则由渲染层定义：
///
/// | 占位符 | 来源 | 示例 |
/// |---|---|---|
/// | `{camera}` | TIFF Make + Model（Model 已含品牌时不重复） | `NIKON Z 8` |
/// | `{make}` / `{model}` | TIFF Make / Model | `NIKON CORPORATION` |
/// | `{lens}` | EXIF LensModel | `NIKKOR Z 24-120mm f/4 S` |
/// | `{focalLength}` | EXIF FocalLength | `35mm` |
/// | `{focalLength35}` | EXIF FocalLenIn35mmFilm | `35mm` |
/// | `{aperture}` | EXIF FNumber | `f/8` |
/// | `{shutter}` | EXIF ExposureTime | `1/250s`、`2s` |
/// | `{iso}` | EXIF ISOSpeedRatings | `ISO 100` |
/// | `{date}` | EXIF DateTimeOriginal | `2026-10-16` |
///
/// `RenderJob.metadataOverrides` 里的同名值优先（胶片扫描可人工指定）。
enum MetadataText {
    static func values(from properties: [CFString: Any]) -> [String: String] {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var v: [String: String] = [:]
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let make, !make.isEmpty { v["make"] = make }
        if let model, !model.isEmpty { v["model"] = model }
        switch (make, model) {
        case (let m?, let n?):
            let brand = m.split(separator: " ").first.map(String.init) ?? m
            v["camera"] = n.lowercased().hasPrefix(brand.lowercased()) ? n : "\(brand) \(n)"
        case (nil, let n?): v["camera"] = n
        case (let m?, nil): v["camera"] = m
        default: break
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty { v["lens"] = lens }
        if let f = number(exif[kCGImagePropertyExifFocalLength]) { v["focalLength"] = "\(trim(f))mm" }
        if let f = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]) { v["focalLength35"] = "\(trim(f))mm" }
        if let n = number(exif[kCGImagePropertyExifFNumber]) { v["aperture"] = "f/\(trim(n))" }
        if let t = number(exif[kCGImagePropertyExifExposureTime]), t > 0 {
            v["shutter"] = t >= 1 ? "\(trim(t))s" : "1/\(Int((1 / t).rounded()))s"
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first.flatMap(number) {
            v["iso"] = "ISO \(Int(iso))"
        }
        if let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String, d.count >= 10 {
            v["date"] = String(d.prefix(10)).replacingOccurrences(of: ":", with: "-")
        }
        return v
    }

    /// 填写模板（D-64）。缺失的占位符连同它旁边多余的分隔符一起去掉，不留下「35mm ·  · 1/250s」。
    ///
    /// 规则（逐行处理，`\n` 分行）：
    /// - 一行切成「前缀 + 占位符 + 分隔符 + 占位符 … + 后缀」，分隔符是两个占位符之间的文字。
    /// - 有值的占位符按原顺序拼接，每个值前面用它自己左侧的分隔符；第一个有值的不带分隔符。
    ///   例：`{a} · {b} · {c}` 缺 b → `A · C`；缺 a → `B · C`。
    /// - 前缀跟随第一个占位符、后缀跟随最后一个占位符：对应的值缺失时一起去掉。
    ///   例：`Shot on {camera} ({lens})` 缺 lens → `Shot on Z 8`。
    /// - 一个值都没有的行整行去掉。没有占位符的行原样保留。
    /// - 全部行都去掉后结果为空字符串，调用方不画这个图层（仍给警告）。
    static func fill(_ template: String, values: [String: String]) -> (text: String, missing: [String]) {
        var missing: [String] = []
        var lines: [String] = []
        for line in template.components(separatedBy: "\n") {
            var literals: [String] = []   // literals[i] 在第 i 个占位符之前；最后一个是后缀
            var keys: [String] = []
            var rest = Substring(line)
            while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                literals.append(String(rest[..<open]))
                keys.append(String(rest[rest.index(after: open)..<close]))
                rest = rest[rest.index(after: close)...]
            }
            literals.append(String(rest))
            guard !keys.isEmpty else { lines.append(line); continue }
            var body = ""
            var any = false
            for (i, key) in keys.enumerated() {
                guard let value = values[key], !value.isEmpty else { missing.append(key); continue }
                if any { body += literals[i] }
                body += value
                any = true
            }
            guard any else { continue }
            let present = { (k: String) in !(values[k] ?? "").isEmpty }
            let prefix = present(keys[0]) ? literals[0] : ""
            let suffix = present(keys[keys.count - 1]) ? literals[keys.count] : ""
            lines.append(prefix + body + suffix)
        }
        return (lines.joined(separator: "\n"), missing)
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: n.doubleValue
        case let d as Double: d
        case let s as String: Double(s)
        default: nil
        }
    }

    private static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", (v * 10).rounded() / 10)
    }
}

/// 源文件中的作者与版权（TIFF、IPTC、XMP 三处取第一个非空值）。
struct AuthorInfo: Hashable {
    var author: String?
    var copyright: String?

    /// - Parameter xmp: 源文件的 XMP（`CGImageSourceCopyMetadataAtIndex`），取 `dc:creator`、`dc:rights`。
    init(properties: [CFString: Any], xmp: CGImageMetadata?) {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        func text(_ any: Any?) -> String? {
            let s: String? = switch any {
            case let s as String: s
            case let a as [Any]: a.compactMap { $0 as? String }.first
            default: nil
            }
            return s.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        author = text(tiff[kCGImagePropertyTIFFArtist]) ?? text(iptc[kCGImagePropertyIPTCByline])
            ?? xmp.flatMap { Self.xmpString($0, "dc:creator") }
        copyright = text(tiff[kCGImagePropertyTIFFCopyright]) ?? text(iptc[kCGImagePropertyIPTCCopyrightNotice])
            ?? xmp.flatMap { Self.xmpString($0, "dc:rights") }
    }

    /// XMP 标签的第一个字符串值（数组、语言替代项都取第一项）。
    static func xmpString(_ meta: CGImageMetadata, _ path: String) -> String? {
        guard let tag = CGImageMetadataCopyTagWithPath(meta, nil, path as CFString) else { return nil }
        func first(_ value: CFTypeRef?) -> String? {
            switch value {
            case let s as String: return s.isEmpty ? nil : s
            case let a as [Any]:
                for item in a {
                    let ref = item as CFTypeRef
                    let value = CFGetTypeID(ref) == CGImageMetadataTagGetTypeID()
                        ? CGImageMetadataTagCopyValue(ref as! CGImageMetadataTag) : ref
                    if let s = first(value) { return s }
                }
                return nil
            default: return nil
            }
        }
        return first(CGImageMetadataTagCopyValue(tag))
    }
}

/// 输出元数据策略（§6.8、§12.3、D-06、D-63）：默认全部不写出；「保留拍摄参数」「保留 GPS」
/// 「保留作者和版权」三个独立开关。
///
/// 从不复制：MakerNote、序列号、机主姓名、用户注释、缩略图、Orientation（输出像素已校正方向）。
/// 作者和版权写成 TIFF Artist / Copyright 与 IPTC By-line / CopyrightNotice（ImageIO 会同步到 XMP 的对应字段）。
enum OutputMetadata {
    static var shootingExifKeys: [CFString] { [
        kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifExposureProgram,
        kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
        kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifShutterSpeedValue, kCGImagePropertyExifApertureValue,
        kCGImagePropertyExifExposureBiasValue, kCGImagePropertyExifMaxApertureValue, kCGImagePropertyExifMeteringMode,
        kCGImagePropertyExifFlash, kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm,
        kCGImagePropertyExifLensSpecification, kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel,
        kCGImagePropertyExifWhiteBalance, kCGImagePropertyExifExposureMode,
    ] }
    static var shootingTIFFKeys: [CFString] { [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel] }

    /// 交给 `CGImageDestinationAddImage` 的属性字典（不含编码参数）。
    static func properties(
        from source: [CFString: Any], author: AuthorInfo, policy: OutputSettings.Metadata
    ) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        if policy.keepShootingInfo {
            let exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let e = Dictionary(uniqueKeysWithValues: shootingExifKeys.compactMap { k in exif[k].map { (k, $0) } })
            let t = Dictionary(uniqueKeysWithValues: shootingTIFFKeys.compactMap { k in tiff[k].map { (k, $0) } })
            if !e.isEmpty { out[kCGImagePropertyExifDictionary] = e }
            if !t.isEmpty { out[kCGImagePropertyTIFFDictionary] = t }
        }
        if policy.keepAuthorAndCopyright {
            var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            var iptc: [CFString: Any] = [:]
            if let a = author.author { tiff[kCGImagePropertyTIFFArtist] = a; iptc[kCGImagePropertyIPTCByline] = [a] }
            if let c = author.copyright { tiff[kCGImagePropertyTIFFCopyright] = c; iptc[kCGImagePropertyIPTCCopyrightNotice] = c }
            if !tiff.isEmpty { out[kCGImagePropertyTIFFDictionary] = tiff }
            if !iptc.isEmpty { out[kCGImagePropertyIPTCDictionary] = iptc }
        }
        if policy.keepGps, let gps = source[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty {
            out[kCGImagePropertyGPSDictionary] = gps
        }
        return out
    }
}
