import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PhotoFrameCore
import Testing
import UniformTypeIdentifiers
@testable import PhotoFrameRendering

/// HDR 输入与输出（§6.2、§6.7、§6.9）。fixture 的 HDR 场景：第 0 行中性色块线性亮度
/// 0.05 / 0.18 / 0.5 / 0.75 / 1.0 / 1.5 / 2 / 3 / 4 / 5 / 6 / 8（相对 SDR 白），每块 80 px。
@Suite("HDR")
struct HDRTests {
    static let levels = [0.05, 0.18, 0.5, 0.75, 1.0, 1.5, 2, 3, 4, 5, 6, 8]
    static func chartPreset(_ range: OutputSettings.DynamicRange = .sdr, format: OutputSettings.Format = .png) -> ExportPreset {
        makePreset(width: 960, height: 640, margin: 0, output: OutputSettings(format: format, dynamicRange: range))
    }

    /// 读回 HDR 文件（展开 gain map），返回工作空间里中性色块的线性 Y（G 通道）。
    static func readHDR(_ url: URL, size: PixelSize, points: [(Int, Int)]) throws -> (headroom: Float, values: [Double]) {
        let image = try #require(CIImage(contentsOf: url, options: [.expandToHDR: true]))
        let ctx = WorkingColor.makeContext()
        var px = [Float](repeating: 0, count: size.width * size.height * 4)
        px.withUnsafeMutableBytes { buf in
            ctx.render(image, toBitmap: buf.baseAddress!, rowBytes: size.width * 16,
                       bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height), format: .RGBAf,
                       colorSpace: WorkingColor.space)
        }
        let values = points.map { Double(px[($0.1 * size.width + $0.0) * 4 + 1]) }
        return (image.contentHeadroom, values)
    }

    static let neutralCenters = (0..<12).map { ($0 * 80 + 40, 40) }

    @Test("gain map JPEG：SDR 输出直接用文件自带的 SDR 底图（§6.7 第 1 条）")
    func gainMapSDR() async throws {
        let url = Fixtures.url("hdr_gainmap.jpg")
        let result = try await render(url, Self.chartPreset())
        #expect(result.diagnostics.hdrKind == .gainMap)
        #expect(result.diagnostics.sdrMethod == .sourceRendition)
        #expect((result.diagnostics.sourceHeadroom ?? 0) > 1)
        let out = try readSRGB8(result.outputs[0].fileURL)
        let base = draw8(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!)
        var maxDiff = 0
        for (x, y) in Self.neutralCenters {
            let a = out[x, y], b = base[x, y]
            maxDiff = max(maxDiff, abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
        }
        #expect(maxDiff <= 2)
    }

    @Test("PQ PNG：没有 SDR 版本，按画面峰值 CIToneMapHeadroom，不硬截断（§6.7 第 2、4 条）")
    func pqToneMap() async throws {
        let result = try await render(Fixtures.url("hdr_pq2020_203nit.png"), Self.chartPreset())
        #expect(result.diagnostics.hdrKind == .transferFunction)
        guard case .toneMapHeadroom(let headroom, let target) = result.diagnostics.sdrMethod else {
            Issue.record("应使用 CIToneMapHeadroom"); return
        }
        #expect(target == 1)
        #expect(headroom > 6, "峰值按画面估算（fixture 峰值 8），不是 PQ 默认的 4.93：\(headroom)")
        #expect(result.diagnostics.transformSteps.contains { $0.contains("CIToneMapHeadroom") })
        let out = try readSRGB8(result.outputs[0].fileURL)
        let codes = Self.neutralCenters.map { out[$0.0, $0.1].1 }
        // 1.0 … 6.0 的色块逐级变亮（没有被一起截断到白）。
        for i in 4..<10 { #expect(codes[i] < codes[i + 1], "色块 \(Self.levels[i]) → \(Self.levels[i + 1])：\(codes)") }
    }

    @Test("32 位浮点 TIFF：先转 RGBAh，峰值 > 1 视为 HDR")
    func floatTIFF() async throws {
        let result = try await render(Fixtures.url("hdr_float_linear2020.tif"), Self.chartPreset())
        #expect(result.diagnostics.isFloat)
        #expect(result.diagnostics.hdrKind == .floatLinear)
        #expect(result.diagnostics.transformSteps.contains { $0.contains("RGBAh") })
        let headroom = result.diagnostics.sourceHeadroom ?? 0
        #expect(headroom > 6 && headroom < 12, "\(headroom)")
    }

    @Test("HDR 输出：gain map JPEG，SDR 底图 + 读回保留动态范围，背景不随 headroom 变亮", arguments: ["hdr_gainmap.jpg", "hdr_pq2020_203nit.png"])
    func hdrOutput(_ name: String) async throws {
        // 画布比色卡高 80 px，上下各 40 px 背景。
        let preset = makePreset(width: 960, height: 720, margin: 0,
                                output: OutputSettings(format: .jpeg, dynamicRange: .hdr))
        let result = try await render(Fixtures.url(name), preset)
        let out = result.outputs[0]
        #expect(out.dynamicRange == .hdr)
        #expect((out.hdrHeadroom ?? 0) > 1)
        let data = try Data(contentsOf: out.fileURL)
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil)
        #expect(JPEGSegments.contains(data, marker: 0xE2, prefix: Data("ICC_PROFILE\0".utf8)), "插入 ICC 后 gain map 仍在")

        let points = Self.neutralCenters.map { ($0.0, $0.1 + 40) } + [(10, 10)]
        let back = try Self.readHDR(out.fileURL, size: PixelSize(width: 960, height: 720), points: points)
        let white = back.values[4]
        #expect(abs(white - 1) < 0.08, "1.0 色块读回 \(white)")
        // headroom 以内的级别保持比例（PoC：误差 ≤ 2.3%；JPEG 压缩下放宽到 10%）。
        for i in 5..<12 where Self.levels[i] <= Double(back.headroom) * 0.98 {
            #expect(abs(back.values[i] / white / Self.levels[i] - 1) < 0.1, "\(Self.levels[i])：\(back.values[i] / white)")
        }
        // 背景 #FAFAF8 在 HDR 里仍是参考白附近（线性 G ≈ 0.955），不发光。
        #expect(abs(back.values[12] - 0.955) < 0.03, "背景 \(back.values[12])")

        // SDR 回退底图：背景仍是 #FAFAF8（JPEG 误差 ±2）。
        let sdr = draw8(CGImageSourceCreateImageAtIndex(src, 0, nil)!)
        #expect(close(sdr[10, 10], (250, 250, 248), tolerance: 2))
    }

    @Test("请求 HDR 但源图是 SDR：按 SDR 输出并警告；HDR 不支持 PNG")
    func hdrFallbacks() async throws {
        let sdr = try await render(Fixtures.url("chart_srgb.jpg"), Self.chartPreset(.hdr, format: .jpeg))
        #expect(sdr.outputs[0].dynamicRange == .sdr)
        #expect(sdr.warnings.contains { $0.code == "output.hdr_source_not_hdr" })

        await #expect(throws: RenderError.self) {
            _ = try await render(Fixtures.url("hdr_gainmap.jpg"), Self.chartPreset(.hdr, format: .png))
        }
    }

    @Test("auto（D-125）：HDR 源图 + JPEG 输出 HDR；SDR 源图或 PNG 安静地输出 SDR")
    func autoRange() async throws {
        let hdr = try await render(Fixtures.url("hdr_gainmap.jpg"), Self.chartPreset(.auto, format: .jpeg))
        #expect(hdr.outputs[0].dynamicRange == .hdr)
        let sdr = try await render(Fixtures.url("chart_srgb.jpg"), Self.chartPreset(.auto, format: .jpeg))
        #expect(sdr.outputs[0].dynamicRange == .sdr)
        #expect(!sdr.warnings.contains { $0.code.hasPrefix("output.hdr") })
        let png = try await render(Fixtures.url("hdr_gainmap.jpg"), Self.chartPreset(.auto, format: .png))
        #expect(png.outputs[0].dynamicRange == .sdr)
        #expect(!png.warnings.contains { $0.code.hasPrefix("output.hdr") })
    }

    // MARK: - gain map JPEG：底图的颜色解释改过（D-127）

    /// 底图怎样被改写解释：文件嵌入 itur_2020 ICC（坑 20 改写曲线），或没有 ICC 而用输入色彩空间覆盖。
    struct Reinterpretation: Sendable, CustomTestStringConvertible {
        var name: String
        var embedsRec2020: Bool
        var override: SourceColorOverride?
        var testDescription: String { name }

        static let all = [
            Reinterpretation(name: "嵌入 itur_2020 ICC（坑 20）", embedsRec2020: true, override: nil),
            Reinterpretation(name: "没有 ICC，覆盖为 Rec. 2020", embedsRec2020: false, override: .rec2020),
            Reinterpretation(name: "没有 ICC，覆盖为 Adobe RGB", embedsRec2020: false, override: .adobeRGB),
        ]
    }

    /// 12 个中性色块（线性 Rec. 2020，每块 80 × 160 px）：前 9 块 SDR 与 HDR 相同（gain = 1），后 3 块 SDR 为白、HDR 为 2 / 3 / 4 倍。
    static let reinterpretSDR: [Double] = [0.01, 0.03, 0.06, 0.1, 0.18, 0.3, 0.5, 0.75, 1, 1, 1, 1]
    static let reinterpretHDR: [Double] = [0.01, 0.03, 0.06, 0.1, 0.18, 0.3, 0.5, 0.75, 1, 2, 3, 4]

    /// 用 CI 写一张合成的 gain map JPEG。`embedsRec2020` 为 false 时按 sRGB 写，ImageIO 不嵌 ICC（坑 2），就是「没有 ICC」的源图。
    static func writeGainMapJPEG(to url: URL, embedsRec2020: Bool) throws {
        func chart(_ values: [Double]) -> CIImage {
            values.enumerated().reduce(CIImage.empty()) { image, item in
                let color = CIColor(red: item.element, green: item.element, blue: item.element, alpha: 1, colorSpace: WorkingColor.space)!
                return CIImage(color: color).cropped(to: CGRect(x: item.offset * 80, y: 0, width: 80, height: 160)).composited(over: image)
            }
        }
        let space = CGColorSpace(name: embedsRec2020 ? CGColorSpace.itur_2020 : CGColorSpace.sRGB)!
        try WorkingColor.makeContext().writeJPEGRepresentation(
            of: chart(reinterpretSDR), to: url, colorSpace: space,
            options: [.hdrImage: chart(reinterpretHDR).settingContentHeadroom(4), .hdrGainMapAsRGB: true])
        let data = try Data(contentsOf: url)
        #expect(SourceFileFormat.hasEmbeddedColorDescription(data, format: .jpeg) == embedsRec2020)
    }

    /// 各色块中心在工作空间里的线性 G（图像可以是降采样后的尺寸）。
    static func patchValues(_ image: CIImage) -> [Double] {
        let e = image.extent
        let w = Int(e.width), h = Int(e.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            WorkingColor.makeContext().render(image, toBitmap: buf.baseAddress!, rowBytes: w * 16, bounds: e, format: .RGBAf,
                                              colorSpace: WorkingColor.space)
        }
        return (0..<12).map { i in Double(px[((h / 2) * w + Int((Double(i) + 0.5) * Double(w) / 12)) * 4 + 1]) }
    }

    @Test("gain map JPEG 的底图改写了颜色解释：HDR 版本套用到改写后的底图，暗部和中间调与 SDR 版本一致",
          arguments: Reinterpretation.all, [960, 400])
    func gainMapFollowsReinterpretedBase(_ c: Reinterpretation, decodeLong: Int) throws {
        let url = try makeTempDirectory().appendingPathComponent("gainmap.jpg")
        try Self.writeGainMapJPEG(to: url, embedsRec2020: c.embedsRec2020)
        let source = try SourceDecoder(context: WorkingColor.makeContext())
            .decode(url, neededSize: PixelSize(width: decodeLong / 2, height: decodeLong / 12), override: c.override)
        #expect(source.hdrKind == .gainMap)
        #expect(source.headroom == 4)
        #expect(source.transformSteps.contains { $0.contains("applyingGainMap") }, "\(source.transformSteps)")
        let sdr = Self.patchValues(try #require(source.sdr)), hdr = Self.patchValues(try #require(source.hdr))

        // 前提：按文件原样展开的 HDR 与改写后的 SDR 在暗部明显不同（以前的做法）。
        let asIs = Self.patchValues(try #require(CIImage(contentsOf: url, options: [.expandToHDR: true])))
        #expect(abs(asIs[1] - sdr[1]) > 0.004, "原样展开 \(asIs[1])，SDR \(sdr[1])")

        for i in 0..<9 {
            #expect(abs(hdr[i] - sdr[i]) <= 0.001 + 0.01 * sdr[i], "色块 \(i)：SDR \(sdr[i])，HDR \(hdr[i])")
        }
        // 高光仍按 gain map 展开（底图为白，与解释无关）。
        for i in 9..<12 {
            #expect(abs(hdr[i] / Self.reinterpretHDR[i] - 1) < 0.02, "色块 \(i)：HDR \(hdr[i])")
        }
    }

    @Test("颜色解释没改过的 gain map JPEG 仍按文件原样展开")
    func gainMapAsIsWhenNotReinterpreted() throws {
        let url = try makeTempDirectory().appendingPathComponent("gainmap.jpg")
        try Self.writeGainMapJPEG(to: url, embedsRec2020: false)
        for name in [url, Fixtures.url("hdr_gainmap.jpg")] {
            let source = try SourceDecoder(context: WorkingColor.makeContext()).decode(name, neededSize: PixelSize(width: 480, height: 80), override: nil)
            #expect(source.hdrKind == .gainMap)
            #expect(source.transformSteps.contains { $0.contains("expandToHDR") }, "\(source.transformSteps)")
        }
    }

    @Test("导出 HDR：读回的 HDR 与 SDR 底图在暗部和中间调一致，高光保留", arguments: Reinterpretation.all)
    func hdrExportFollowsReinterpretedBase(_ c: Reinterpretation) async throws {
        let url = try makeTempDirectory().appendingPathComponent("gainmap.jpg")
        try Self.writeGainMapJPEG(to: url, embedsRec2020: c.embedsRec2020)
        let preset = makePreset(width: 960, height: 160, margin: 0, output: OutputSettings(format: .jpeg, dynamicRange: .hdr))
        let result = try await render(url, preset, override: c.override)
        let out = result.outputs[0]
        #expect(out.dynamicRange == .hdr)
        let sdr = Self.patchValues(try #require(CIImage(contentsOf: out.fileURL)))
        let hdr = Self.patchValues(try #require(CIImage(contentsOf: out.fileURL, options: [.expandToHDR: true])))
        // 8 位底图 + 8 位 gain map 的量化误差。
        for i in 0..<9 {
            #expect(abs(hdr[i] - sdr[i]) <= 0.003 + 0.03 * sdr[i], "色块 \(i)：SDR \(sdr[i])，HDR \(hdr[i])")
        }
        for i in 9..<12 {
            #expect(abs(hdr[i] / hdr[8] / Self.reinterpretHDR[i] - 1) < 0.1, "色块 \(i)：HDR \(hdr[i] / hdr[8])")
        }
    }

    // MARK: - 「明确是 HDR」的判定（D-62）

    /// PQ 编码值（ST 2084），nits → 0…1。
    static func pq(nits: Double) -> Double {
        let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128, c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
        let y = pow(nits / 10000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    /// 32 位浮点线性 TIFF（extended linear sRGB），像素值恒为 `value`。
    static func writeFloatTIFF(value: Float, to url: URL) throws {
        let w = 64, h = 32
        var px = [Float](repeating: value, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4 + 3] = 1 }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        let info = CGImageAlphaInfo.last.rawValue | CGBitmapInfo.floatComponents.rawValue | CGImageByteOrderInfo.order32Little.rawValue
        let img = CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16,
                          space: WorkingColor.extendedLinearSRGB, bitmapInfo: CGBitmapInfo(rawValue: info),
                          provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
                          intent: .defaultIntent)!
        try writeImage(img, to: url, type: .tiff)
    }

    @Test("标为 HDR（PQ）但峰值 ≤ SDR 白：仍是 HDR 源，headroom = 1，SDR 不 tone map，HDR 输出改写 SDR 并警告")
    func markedHDRWithoutHeadroom() async throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("pq_dim.png")
        let code = UInt16((Self.pq(nits: 100) * 65535).rounded())   // 100 nits < 203 nits（SDR 白）
        try writeImage(makeImage16(width: 64, height: 32, space: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!) { _, _ in
            (code, code, code)
        }, to: url, type: .png)

        let sdr = try await render(url, makePreset(width: 64, height: 32, margin: 0))
        #expect(sdr.diagnostics.hdrKind == .transferFunction)
        #expect(sdr.diagnostics.sourceHeadroom == 1)
        #expect(sdr.diagnostics.sdrMethod == .none)

        let hdr = try await render(url, makePreset(width: 64, height: 32, margin: 0,
                                                   output: OutputSettings(format: .jpeg, dynamicRange: .hdr)))
        #expect(hdr.outputs[0].dynamicRange == .sdr)
        #expect(hdr.warnings.contains { $0.code == "output.hdr_no_headroom" })
    }

    @Test("没有 HDR 标记：浮点峰值 ≤ 1 按 SDR；浮点峰值 > 1 视为 HDR 数据", arguments: [(Float(0.8), false), (Float(3), true)])
    func floatWithoutMarker(_ c: (Float, Bool)) async throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("float.tif")
        try Self.writeFloatTIFF(value: c.0, to: url)
        let result = try await render(url, makePreset(width: 64, height: 32, margin: 0))
        #expect(result.diagnostics.isFloat)
        #expect(result.diagnostics.hdrKind == (c.1 ? .floatLinear : .none))
        if c.1 { #expect(abs((result.diagnostics.sourceHeadroom ?? 0) - 3) < 0.05) }
    }

    @Test("没有 HDR 标记的 16 位整数 TIFF 按 SDR")
    func integerWithoutMarker() async throws {
        let result = try await render(Fixtures.url("chart_srgb_16.tif"), Self.chartPreset())
        #expect(result.diagnostics.hdrKind == .none)
    }

    // MARK: - Lightroom「最大化兼容性」TIFF（合成）

    /// 写一份结构与 Lightroom 相同的 TIFF：IFD0 = 16 位 sRGB SDR 底图，SubIFD = 8 位 RGB gain map
    /// （Photometric 52553，52557 = 4 字节前缀 + ISO 21496-1 元数据）。左半 gain = 0，右半 gain = 1。
    static func writeGainMapTIFF(to url: URL, width: Int = 64, height: Int = 32, base: UInt16 = 0x8000) throws {
        var meta = Data([0, 0, 0, 0])                // Lightroom 前缀
        meta += Data([0, 0, 0, 0, 0xC0])             // minimum_version, writer_version, flags = 多通道 | 底图空间
        func ratio(_ n: Int32, _ d: UInt32) { meta += Data.be32(Int(UInt32(bitPattern: n))); meta += Data.be32(Int(d)) }
        ratio(0, 1); ratio(2, 1)                     // base / alternate headroom（log2）：0 / 2 → 4×
        for _ in 0..<3 { ratio(0, 1); ratio(2, 1); ratio(1, 1); ratio(1, 64); ratio(1, 64) } // min max gamma offsets

        var file = TIFFWriter()
        let icc = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()! as Data
        var basePixels = Data()
        for _ in 0..<(width * height * 3) { basePixels.append(UInt8(base & 0xFF)); basePixels.append(UInt8(base >> 8)) }
        var gainPixels = Data()
        for _ in 0..<height { for x in 0..<width { gainPixels += Data(repeating: x < width / 2 ? 0 : 255, count: 3) } }
        let baseOffset = file.append(basePixels)
        let gainOffset = file.append(gainPixels)
        let iccOffset = file.append(icc)
        let metaOffset = file.append(meta)
        let sub = file.appendIFD([
            (254, 4, [1]), (256, 4, [width]), (257, 4, [height]), (258, 3, [8, 8, 8]), (259, 3, [1]),
            (262, 3, [52553]), (273, 4, [gainOffset]), (277, 3, [3]), (278, 4, [height]),
            (279, 4, [gainPixels.count]), (284, 3, [1]), (52557, 7, [metaOffset, meta.count]),
        ])
        let ifd0 = file.appendIFD([
            (254, 4, [0]), (256, 4, [width]), (257, 4, [height]), (258, 3, [16, 16, 16]), (259, 3, [1]),
            (262, 3, [2]), (273, 4, [baseOffset]), (277, 3, [3]), (278, 4, [height]),
            (279, 4, [basePixels.count]), (284, 3, [1]), (330, 4, [sub]), (34675, 7, [iccOffset, icc.count]),
        ])
        try file.finish(firstIFD: ifd0).write(to: url)
    }

    @Test("「最大化兼容性」TIFF：SDR 用 IFD0，HDR 从 SubIFD gain map 还原（§6.2）")
    func gainMapTIFF() async throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("compat.tif")
        try Self.writeGainMapTIFF(to: url)

        let preset = makePreset(width: 64, height: 32, margin: 0, output: OutputSettings(format: .jpeg, dynamicRange: .hdr))
        let result = try await render(url, preset)
        #expect(result.diagnostics.hdrKind == .gainMapTIFF)
        #expect(result.diagnostics.sdrMethod == .sourceRendition)
        #expect(abs((result.diagnostics.sourceHeadroom ?? 0) - 4) < 1e-6)
        #expect(!result.warnings.contains { $0.code == "source.hdr_not_read" })

        // SDR 底图：0x8000 / 65535 ≈ 0.5 sRGB 编码 → 8 位 128。
        let src = CGImageSourceCreateWithURL(result.outputs[0].fileURL as CFURL, nil)!
        let sdr = draw8(CGImageSourceCreateImageAtIndex(src, 0, nil)!)
        #expect(close(sdr[8, 16], (128, 128, 128), tolerance: 2))
        #expect(close(sdr[56, 16], (128, 128, 128), tolerance: 2))

        // HDR：右半 = (b + 1/64)·4 − 1/64，左半 = b。
        let back = try Self.readHDR(result.outputs[0].fileURL, size: PixelSize(width: 64, height: 32), points: [(8, 16), (56, 16)])
        let b = ColorMath.srgbToLinear(Double(0x8000) / 65535)
        #expect(abs(back.values[0] / b - 1) < 0.05, "左半 \(back.values[0]) vs \(b)")
        let expected = (b + 1.0 / 64) * 4 - 1.0 / 64
        #expect(abs(back.values[1] / expected - 1) < 0.08, "右半 \(back.values[1]) vs \(expected)")
    }

    @Test("gain map 无法解析时按 SDR 读入并提示「HDR 部分未读取」")
    func gainMapTIFFUnreadable() async throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("broken.tif")
        try Self.writeGainMapTIFF(to: url)
        // 把 52557 元数据的 minimum_version 改成非 0（两种前缀都无法解析）。
        var data = try Data(contentsOf: url)
        let tiff = try TIFFFile(data)
        let sub = try tiff.ifd(at: tiff.ints(tiff.ifd0!, 330)![0])
        let offset = sub.tags[52557]!.valueOffset
        data[offset] = 0xFF; data[offset + 4] = 0xFF
        try data.write(to: url)

        let result = try await render(url, makePreset(width: 64, height: 32, margin: 0))
        #expect(result.warnings.contains { $0.code == "source.hdr_not_read" })
        #expect(result.diagnostics.hdrKind == .none)
    }
}

/// 最小的小端 TIFF 写入器，只供测试合成 fixture。
struct TIFFWriter {
    var data = Data([0x49, 0x49, 42, 0, 0, 0, 0, 0])

    mutating func align() { while data.count % 2 != 0 { data.append(0) } }

    mutating func append(_ bytes: Data) -> Int {
        align()
        let offset = data.count
        data += bytes
        return offset
    }

    /// 每项：(标签, 类型, 值)。类型 7（UNDEFINED）的值写 [偏移, 长度]。
    mutating func appendIFD(_ entries: [(Int, Int, [Int])]) -> Int {
        var extra: [(Int, Data)] = []
        align()
        let start = data.count
        var ifd = Data()
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        func le32(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]) }
        let sorted = entries.sorted { $0.0 < $1.0 }
        ifd += le16(sorted.count)
        let tableEnd = start + 2 + sorted.count * 12 + 4
        var cursor = tableEnd
        for (tag, type, values) in sorted {
            ifd += le16(tag) + le16(type)
            if type == 7 {
                ifd += le32(values[1]) + le32(values[0])
                continue
            }
            let size = type == 3 ? 2 : 4
            ifd += le32(values.count)
            let payload = values.reduce(Data()) { $0 + (size == 2 ? le16($1) : le32($1)) }
            if payload.count <= 4 {
                ifd += payload + Data(count: 4 - payload.count)
            } else {
                ifd += le32(cursor)
                extra.append((cursor, payload))
                cursor += payload.count
            }
        }
        ifd += le32(0)
        data += ifd
        for (_, payload) in extra { data += payload }
        return start
    }

    func finish(firstIFD: Int) -> Data {
        var out = data
        out.replaceSubrange(4..<8, with: [UInt8(firstIFD & 0xFF), UInt8(firstIFD >> 8 & 0xFF),
                                          UInt8(firstIFD >> 16 & 0xFF), UInt8(firstIFD >> 24 & 0xFF)])
        return out
    }
}
