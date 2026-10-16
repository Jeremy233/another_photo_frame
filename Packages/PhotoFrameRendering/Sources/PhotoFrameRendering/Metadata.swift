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

    /// 替换模板中的 `{name}`；缺失的占位符替换为空，并返回它们的名字。
    static func fill(_ template: String, values: [String: String]) -> (text: String, missing: [String]) {
        var out = "", missing: [String] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let key = String(rest[rest.index(after: open)..<close])
            if let value = values[key] { out += value } else { missing.append(key) }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return (out, missing)
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

/// 输出元数据策略（§6.8、§12.3、D-06）：默认全部不写出；「保留拍摄参数」「保留 GPS」两个独立开关。
///
/// 从不复制：MakerNote、序列号、机主姓名、用户注释、缩略图、XMP / IPTC、Orientation（输出像素已校正方向）。
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
    static func properties(from source: [CFString: Any], policy: OutputSettings.Metadata) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        if policy.keepShootingInfo {
            let exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let e = Dictionary(uniqueKeysWithValues: shootingExifKeys.compactMap { k in exif[k].map { (k, $0) } })
            let t = Dictionary(uniqueKeysWithValues: shootingTIFFKeys.compactMap { k in tiff[k].map { (k, $0) } })
            if !e.isEmpty { out[kCGImagePropertyExifDictionary] = e }
            if !t.isEmpty { out[kCGImagePropertyTIFFDictionary] = t }
        }
        if policy.keepGps, let gps = source[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty {
            out[kCGImagePropertyGPSDictionary] = gps
        }
        return out
    }
}
