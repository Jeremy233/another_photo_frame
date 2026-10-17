import CoreGraphics
import Foundation
import ImageIO
import PhotoFrameCore
import PhotoFrameStorage
import Testing
import UniformTypeIdentifiers
@testable import PhotoFrameRendering

/// Golden 对照（§13.2）：黄金结果记录尺寸、排版坐标、颜色采样、背景 RGB、元数据策略与警告列表，
/// 而不是编码后的字节（跨系统版本编码器会变）。像素采样按容差比较。
///
/// 更新黄金文件：`PHOTOFRAME_RECORD_GOLDEN=1 swift test --filter Golden`，然后检查 `Golden/*.json` 的 diff。
///
/// 基准系统（D-68）：黄金文件以用户本机（macOS 27）为标定基准，`recordedOn` 记录录制时的系统版本。
/// 当前系统的主版本号与 `recordedOn` 相同时严格比较，差异使测试失败；主版本号不同（例如 CI 的 macOS 26）时
/// 只把差异打印出来，不让测试失败。`PHOTOFRAME_GOLDEN_STRICT=1` 强制严格比较。不要在其他系统版本上重录。
@Suite("Golden")
struct GoldenTests {
    struct Manifest: Codable, Equatable {
        struct Sample: Codable, Equatable {
            var at: [Int]
            var rgb: [Int]
        }

        struct Output: Codable, Equatable {
            var file: String
            var page: Int
            var size: [Int]
            var photoRect: [Int]?
            var layers: [String: [Int]]
            var dynamicRange: String
            var profile: String
            var hasExif: Bool
            var hasGPS: Bool
            var samples: [Sample]
        }

        var scenario: String
        /// 录制时的系统版本，例如 `macOS 27.0.1`。
        var recordedOn: String
        var preset: String
        var hdrKind: String
        var sdrMethod: String
        var sourceProfileOrigin: String
        var displaySize: [Int]
        var warnings: [String]
        var outputs: [Output]
    }

    static let goldenDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")
    static let tolerance = 3

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// 与录制系统主版本相同，或环境变量要求时，严格比较。
    static func isStrict(recordedOn: String) -> Bool {
        if ProcessInfo.processInfo.environment["PHOTOFRAME_GOLDEN_STRICT"] == "1" { return true }
        let major = { (s: String) in s.split(separator: " ").last?.split(separator: ".").first.map(String.init) }
        return major(recordedOn) == major(systemVersion)
    }

    static func builtIn(_ name: String) throws -> ExportPreset {
        let all = BuiltInPresets.all(catalog: try PlatformCatalogStore.builtIn())
        return try #require(all.first { $0.name == name })
    }

    static func manifest(_ scenario: String, preset: ExportPreset, result: RenderResult) throws -> Manifest {
        let sdr: String = switch result.diagnostics.sdrMethod {
        case .none: "none"
        case .sourceRendition: "sourceRendition"
        case .toneMapHeadroom(let s, let t): String(format: "toneMapHeadroom(%.1f→%.0f)", s, t)
        }
        let outputs = try result.outputs.map { out -> Manifest.Output in
            let img = try readSRGB8(out.fileURL)
            let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out.fileURL as CFURL, nil)!, 0, nil)
                as! [CFString: Any]
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            var points = [(2, 2), (img.width - 3, img.height - 3)]
            if let r = out.photoRect {
                for fy in [0.25, 0.5, 0.75] {
                    for fx in [0.1, 0.5, 0.9] {
                        points.append((r.x + Int(Double(r.width) * fx), r.y + Int(Double(r.height) * fy)))
                    }
                }
            }
            return Manifest.Output(
                file: out.fileURL.lastPathComponent, page: out.role.page,
                size: [out.pixelSize.width, out.pixelSize.height],
                photoRect: out.photoRect.map { [$0.x, $0.y, $0.width, $0.height] },
                layers: Dictionary(uniqueKeysWithValues: out.layers.map { ($0.layerId, [$0.rect.x, $0.rect.y, $0.rect.width, $0.rect.height]) }),
                dynamicRange: out.dynamicRange.rawValue, profile: out.colorProfile,
                hasExif: exif[kCGImagePropertyExifFNumber] != nil
                    || (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] != nil,
                hasGPS: props[kCGImagePropertyGPSDictionary] != nil,
                samples: points.map { p in let c = img[p.0, p.1]; return Manifest.Sample(at: [p.0, p.1], rgb: [c.0, c.1, c.2]) })
        }
        return Manifest(
            scenario: scenario, recordedOn: Self.systemVersion, preset: preset.name, hdrKind: result.diagnostics.hdrKind.rawValue, sdrMethod: sdr,
            sourceProfileOrigin: result.diagnostics.sourceProfileOrigin,
            displaySize: [result.diagnostics.displaySize.width, result.diagnostics.displaySize.height],
            warnings: result.warnings.map(\.code).sorted(), outputs: outputs)
    }

    static func check(_ scenario: String, source: URL, preset: ExportPreset, assets: [String: RenderAsset] = [:]) async throws {
        let result = try await render(source, preset, assets: assets)
        let actual = try manifest(scenario, preset: preset, result: result)
        let url = goldenDirectory.appendingPathComponent("\(scenario).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if ProcessInfo.processInfo.environment["PHOTOFRAME_RECORD_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: goldenDirectory, withIntermediateDirectories: true)
            try encoder.encode(actual).write(to: url)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            Issue.record("缺少黄金文件 \(url.lastPathComponent)；用 PHOTOFRAME_RECORD_GOLDEN=1 生成")
            return
        }
        let expected = try JSONDecoder().decode(Manifest.self, from: data)
        var differences: [String] = []
        // 结构字段逐项相等；像素采样按容差。
        var a = actual, e = expected
        a.recordedOn = ""; e.recordedOn = ""
        for i in a.outputs.indices { a.outputs[i].samples = [] }
        for i in e.outputs.indices { e.outputs[i].samples = [] }
        if a != e {
            differences.append("结构不同：\n  当前 \(String(decoding: try encoder.encode(a), as: UTF8.self))")
        }
        for (o, (ao, eo)) in zip(actual.outputs, expected.outputs).enumerated() {
            if ao.samples.map(\.at) != eo.samples.map(\.at) { differences.append("输出 \(o) 采样点不同") }
            for (s, x) in zip(ao.samples, eo.samples) {
                let diff = zip(s.rgb, x.rgb).map { abs($0 - $1) }.max() ?? 0
                if diff > tolerance { differences.append("输出 \(o) 采样 \(s.at)：\(s.rgb) vs 黄金 \(x.rgb)") }
            }
        }
        guard !differences.isEmpty else { return }
        if isStrict(recordedOn: expected.recordedOn) {
            for d in differences { Issue.record("\(scenario)：\(d)") }
        } else {
            print("[golden 仅报告] \(scenario)：黄金文件录制于 \(expected.recordedOn)，当前 \(systemVersion)，"
                  + "差异不计为失败（D-68）")
            for d in differences { print("  - \(d)") }
        }
    }

    @Test("Instagram Standard：16 位 sRGB 色卡")
    func instagramStandard() async throws {
        try await Self.check("instagram-standard-chart16", source: Fixtures.url("chart_srgb_16.tif"),
                             preset: try Self.builtIn("Instagram Standard"))
    }

    @Test("XHS Panorama：65:24 合成全景（AC-03）")
    func xhsPanorama() async throws {
        let dir = try makeTempDirectory()
        let src = dir.appendingPathComponent("pano.png")
        try writeGradientPhoto(width: 6500, height: 2400, to: src)
        try await Self.check("xhs-panorama-65x24", source: src, preset: try Self.builtIn("XHS Panorama"))
    }

    @Test("Douyin Standard：EXIF 方向 6")
    func douyinOrientation() async throws {
        try await Self.check("douyin-standard-orientation6", source: Fixtures.url("orientation_6.jpg"),
                             preset: try Self.builtIn("Douyin Standard"))
    }

    @Test("Instagram Standard：PQ HDR 源输出 SDR（tone map）")
    func hdrToneMap() async throws {
        // 内置预设是 auto（D-125），HDR 源会输出 HDR；这里固定为 SDR，检查 tone map。
        var preset = try Self.builtIn("Instagram Standard")
        preset.output.dynamicRange = .sdr
        try await Self.check("instagram-standard-pq", source: Fixtures.url("hdr_pq2020_203nit.png"), preset: preset)
    }

    @Test("无 ICC 源 + 水印与文字图层的位置")
    func noProfileWithLayers() async throws {
        var preset = try Self.builtIn("Instagram Standard")
        preset.output = OutputSettings(format: .png)
        preset.layers = [
            OverlayLayer(layerId: "wm", type: .asset, anchor: .bottomRight, offset: OverlayOffset(x: 0, y: 16),
                         maxBoundsPx: PixelSize(width: 200, height: 80), slotId: "wm"),
            OverlayLayer(layerId: "signature", type: .text, anchor: .bottomLeft, offset: OverlayOffset(x: 0, y: 16),
                         sizePx: PixelSize(width: 400, height: 30),
                         text: TextStyle(content: "AnotherPhotoFrame", fontSizePx: 18)),
        ]
        preset.assetSlots = [AssetSlot(slotId: "wm")]
        try await Self.check("instagram-standard-noicc-layers", source: Fixtures.url("chart_noicc.png"), preset: preset,
                             assets: ["wm": RenderAsset(fileURL: Fixtures.url("watermark_alpha.png"), format: .png)])
    }
}
