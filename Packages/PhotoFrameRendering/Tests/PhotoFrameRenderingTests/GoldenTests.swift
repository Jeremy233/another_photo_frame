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
            scenario: scenario, preset: preset.name, hdrKind: result.diagnostics.hdrKind.rawValue, sdrMethod: sdr,
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
        // 结构字段逐项相等；像素采样按容差。
        var a = actual, e = expected
        for i in a.outputs.indices { a.outputs[i].samples = [] }
        for i in e.outputs.indices { e.outputs[i].samples = [] }
        #expect(a == e, "\(scenario) 结构与黄金文件不同")
        for (o, (ao, eo)) in zip(actual.outputs, expected.outputs).enumerated() {
            #expect(ao.samples.map(\.at) == eo.samples.map(\.at))
            for (s, x) in zip(ao.samples, eo.samples) {
                let diff = zip(s.rgb, x.rgb).map { abs($0 - $1) }.max() ?? 0
                #expect(diff <= tolerance, "\(scenario) 输出 \(o) 采样 \(s.at)：\(s.rgb) vs 黄金 \(x.rgb)")
            }
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
        try await Self.check("instagram-standard-pq", source: Fixtures.url("hdr_pq2020_203nit.png"),
                             preset: try Self.builtIn("Instagram Standard"))
    }

    @Test("无 ICC 源 + 水印与 EXIF 文字图层的位置")
    func noProfileWithLayers() async throws {
        var preset = try Self.builtIn("Instagram Standard")
        preset.output = OutputSettings(format: .png)
        preset.layers = [
            OverlayLayer(layerId: "wm", type: .asset, anchor: .bottomRight, offset: OverlayOffset(x: 0, y: 16),
                         maxBoundsPx: PixelSize(width: 200, height: 80), slotId: "wm"),
            OverlayLayer(layerId: "exif", type: .metadataText, anchor: .bottomLeft, offset: OverlayOffset(x: 0, y: 16),
                         sizePx: PixelSize(width: 400, height: 30),
                         text: TextStyle(template: "{camera} · {aperture}", fontSizePx: 18)),
        ]
        preset.assetSlots = [AssetSlot(slotId: "wm")]
        try await Self.check("instagram-standard-noicc-layers", source: Fixtures.url("chart_noicc.png"), preset: preset,
                             assets: ["wm": RenderAsset(fileURL: Fixtures.url("watermark_alpha.png"), format: .png)])
    }
}
