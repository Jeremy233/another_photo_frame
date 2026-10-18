import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PhotoFrameCore
import Testing
@testable import PhotoFrameRendering

/// 源图解码：TIFF 结构解析（单个坏标签、BigTIFF）、「最大化兼容性」TIFF 还原、输入颜色决策、峰值估计、
/// ICC 重建、EXIF 文字。所有图片都由代码合成。
@Suite("源图解码")
struct DecodeTests {
    static let romm = CGColorSpace(name: CGColorSpace.rommrgb)!.copyICCData()! as Data
    static let rec2020 = CGColorSpace(name: CGColorSpace.itur_2020)!.copyICCData()! as Data

    static func decode(_ url: URL, override: SourceColorOverride? = nil, long: Int = 64) throws -> DecodedSource {
        try SourceDecoder(context: PhotoFrameRenderer().context)
            .decode(url, neededSize: PixelSize(width: long, height: long), override: override)
    }

    /// 解码结果在工作空间里的 RGBAf 像素。
    static func pixels(_ image: CIImage?) throws -> [Float] {
        let image = try #require(image)
        let e = image.extent
        var px = [Float](repeating: 0, count: Int(e.width) * Int(e.height) * 4)
        px.withUnsafeMutableBytes { buf in
            WorkingColor.makeContext().render(image, toBitmap: buf.baseAddress!, rowBytes: Int(e.width) * 16, bounds: e,
                                              format: .RGBAf, colorSpace: WorkingColor.space)
        }
        return px
    }

    static func write(_ data: Data, _ name: String) throws -> URL {
        let url = try makeTempDirectory().appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func count(_ source: DecodedSource, _ code: String) -> Int { source.warnings.filter { $0.code == code }.count }

    // MARK: - 合成 TIFF

    /// 16 位 RGB 测试图（值随位置变化）。
    static func rgb16(_ x: Int, _ y: Int) -> [Int] { [(x * 4111 + y * 97) % 65536, (y * 7919 + x * 13) % 65536, (x * y * 331 + 1000) % 65536] }

    /// 16 位 RGB、未压缩、单条带的经典 TIFF 或 BigTIFF。`extra` 是额外的 IFD0 目录项（可以故意写坏）。
    static func rgbTIFF(width: Int = 16, height: Int = 8, little: Bool = true, big: Bool = false, icc: Data?,
                        extra: [(Int, Int, TIFFBuilder.Value)] = []) -> Data {
        var t = TIFFBuilder(little: little, big: big)
        var px = Data()
        for y in 0..<height { for x in 0..<width { for v in rgb16(x, y) { px += t.uint(v, 2) } } }
        let pxOffset = t.append(px)
        var entries: [(Int, Int, TIFFBuilder.Value)] = [
            (256, 4, .ints([width])), (257, 4, .ints([height])), (258, 3, .ints([16, 16, 16])), (259, 3, .ints([1])),
            (262, 3, .ints([2])), (273, 4, .ints([pxOffset])), (277, 3, .ints([3])), (278, 4, .ints([height])),
            (279, 4, .ints([px.count])), (284, 3, .ints([1])),
        ]
        if let icc { entries.append((34675, 7, .at(offset: t.append(icc), count: icc.count))) }
        let ifd0 = t.appendIFD(entries + extra)
        return t.finish(firstIFD: ifd0)
    }

    /// ISO 21496-1 二进制元数据（Lightroom 前缀 4 字节）。每个通道 (min, max, gamma, baseOffset, alternateOffset)，log2 值。
    static func gainMapMetadata(_ channels: [(Double, Double, Double, Double, Double)]) -> Data {
        var meta = Data([0, 0, 0, 0])
        meta += Data([0, 0, 0, 0, channels.count == 3 ? 0xC0 : 0x40])
        func ratio(_ v: Double) {
            meta += Data.be32(Int(UInt32(bitPattern: Int32((v * 10000).rounded()))))
            meta += Data.be32(10000)
        }
        ratio(0); ratio(2)
        for c in channels { ratio(c.0); ratio(c.1); ratio(c.2); ratio(c.3); ratio(c.4) }
        return meta
    }

    struct CompatOptions {
        var width = 12, height = 10
        var little = true
        var baseBits = 16
        var gainBits = 8
        var gainChannels = 3
        var gainWidth: Int? = nil, gainHeight: Int? = nil
        var gainCompression = 1
        var icc: Data? = DecodeTests.rec2020
        var metadata = DecodeTests.gainMapMetadata([(0, 2, 1, 1.0 / 64, 1.0 / 64), (-0.5, 2.5, 0.77, 0.01, 0.02), (0.25, 1.5, 1.3, 0, 0)])
        var extraIFD0: [(Int, Int, TIFFBuilder.Value)] = []
        var extraSub: [(Int, Int, TIFFBuilder.Value)] = []
        /// 把 SubIFD 的 52557 指到文件之外。
        var metadataOutOfBounds = false
        /// 替换 IFD0 的 330（SubIFDs）目录项。
        var subIFDs: TIFFBuilder.Value? = nil
    }

    /// 结构与 Lightroom「最大化兼容性」TIFF 相同：IFD0 = RGB 底图，SubIFD = gain map（Photometric 52553 + 52557）。
    static func compatTIFF(_ o: CompatOptions = CompatOptions()) -> Data {
        var t = TIFFBuilder(little: o.little)
        func samples(_ bits: Int, _ values: [Int]) -> Data {
            values.reduce(Data()) { $0 + (bits == 8 ? Data([UInt8($1 >> 8)]) : t.uint($1, 2)) }
        }
        var base = Data()
        for y in 0..<o.height { for x in 0..<o.width { base += samples(o.baseBits, rgb16(x, y)) } }
        let gw = o.gainWidth ?? o.width, gh = o.gainHeight ?? o.height
        var gain = Data()
        for y in 0..<gh {
            for x in 0..<gw {
                let v = [(x * 9001 + y * 31) % 65536, (y * 6007 + x * 101) % 65536, (x * y * 977 + 5) % 65536]
                gain += samples(o.gainBits, Array(v.prefix(o.gainChannels)))
            }
        }
        let baseOffset = t.append(base), gainOffset = t.append(gain)
        let metaOffset = o.metadataOutOfBounds ? 0x7FFF_0000 : t.append(o.metadata)
        let sub = t.appendIFD([
            (254, 4, .ints([1])), (256, 4, .ints([gw])), (257, 4, .ints([gh])),
            (258, 3, .ints(Array(repeating: o.gainBits, count: o.gainChannels))), (259, 3, .ints([o.gainCompression])),
            (262, 3, .ints([52553])), (273, 4, .ints([gainOffset])), (277, 3, .ints([o.gainChannels])), (278, 4, .ints([gh])),
            (279, 4, .ints([gain.count])), (284, 3, .ints([1])), (52557, 7, .at(offset: metaOffset, count: o.metadata.count)),
        ] + o.extraSub)
        var ifd0: [(Int, Int, TIFFBuilder.Value)] = [
            (254, 4, .ints([0])), (256, 4, .ints([o.width])), (257, 4, .ints([o.height])),
            (258, 3, .ints([o.baseBits, o.baseBits, o.baseBits])), (259, 3, .ints([1])), (262, 3, .ints([2])),
            (273, 4, .ints([baseOffset])), (277, 3, .ints([3])), (278, 4, .ints([o.height])), (279, 4, .ints([base.count])),
            (284, 3, .ints([1])), (330, 4, o.subIFDs ?? .ints([sub])),
        ]
        if let icc = o.icc { ifd0.append((34675, 7, .at(offset: t.append(icc), count: icc.count))) }
        let first = t.appendIFD(ifd0 + o.extraIFD0)
        return t.finish(firstIFD: first)
    }

    // MARK: - TIFF 目录：单个坏标签不影响其他标签

    @Test("私有标签越界：只跳过它，嵌入的 ICC 仍然有效，不警告也不改标为 sRGB")
    func outOfBoundsPrivateTag() throws {
        let clean = try Self.write(Self.rgbTIFF(icc: Self.romm), "clean.tif")
        for extra in [(65000, 7, TIFFBuilder.Value.at(offset: 0x7FFF_0000, count: 100)),   // 截断的私有标签
                      (37724, 7, TIFFBuilder.Value.at(offset: 64, count: 300_000_000))] {  // 数量 ≥ 2^28 且越界
            let data = Self.rgbTIFF(icc: Self.romm, extra: [extra])
            #expect(SourceFileFormat.hasEmbeddedColorDescription(data, format: .tiff), "标签 \(extra.0)")
            let ifd0 = try #require(try TIFFFile(data).ifd0)
            #expect(ifd0.tags[34675] != nil && ifd0.tags[extra.0] == nil && ifd0.invalidTags == [extra.0])
        }
        // ImageIO 能读的那份（越界的截断标签）完整解码：与没有坏标签的同一张图逐像素相同。
        let url = try Self.write(Self.rgbTIFF(icc: Self.romm, extra: [(65000, 7, .at(offset: 0x7FFF_0000, count: 100))]), "bad.tif")
        let source = try Self.decode(url)
        #expect(source.hasEmbeddedProfile)
        #expect(source.sourceProfileOrigin == "embedded")
        #expect(source.sourceProfile == WorkingColor.describe(CGColorSpace(name: CGColorSpace.rommrgb)))
        #expect(Self.count(source, "source.profile_missing") == 0)
        #expect(try Self.pixels(source.sdr) == Self.pixels(Self.decode(clean).sdr))
    }

    @Test("Photoshop 分层 TIFF：37724 数量 ≥ 2^28 但在文件范围内，ICC 照常生效")
    func hugeLayerTagInBounds() throws {
        // 稀疏文件：37724 指向文件末尾 256 MiB 的空洞，不占磁盘空间。
        let count = (1 << 28) + 16, layerOffset = 1 << 16
        let data = Self.rgbTIFF(icc: Self.romm, extra: [(37724, 7, .at(offset: layerOffset, count: count))])
        #expect(data.count < layerOffset)
        let url = try Self.write(data, "layered.tif")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(layerOffset + count))
        try handle.close()

        let mapped = try Data(contentsOf: url, options: .mappedIfSafe)
        #expect(SourceFileFormat.hasEmbeddedColorDescription(mapped, format: .tiff))
        let source = try Self.decode(url)
        #expect(source.hasEmbeddedProfile)
        #expect(source.sourceProfileOrigin == "embedded")
        #expect(source.sourceProfile == WorkingColor.describe(CGColorSpace(name: CGColorSpace.rommrgb)))
        #expect(source.warnings.isEmpty)
        #expect(source.hdrKind == .none)
        let clean = try Self.write(Self.rgbTIFF(icc: Self.romm), "clean.tif")
        #expect(try Self.pixels(source.sdr) == Self.pixels(Self.decode(clean).sdr))
    }

    @Test("BigTIFF：自己找到 IFD0 的 34675，按嵌入的 ICC 解码", arguments: [true, false])
    func bigTIFFProfile(_ little: Bool) throws {
        let data = Self.rgbTIFF(little: little, big: true, icc: Self.romm)
        #expect(try SourceFileFormat.sniff(data) == .tiff)
        #expect(SourceFileFormat.hasEmbeddedColorDescription(data, format: .tiff))
        #expect(!SourceFileFormat.hasEmbeddedColorDescription(Self.rgbTIFF(little: little, big: true, icc: nil), format: .tiff))
        // 34675 越界只跳过它；目录表越界时整个 IFD0 无效。
        let oob = Self.rgbTIFF(little: little, big: true, icc: nil, extra: [(34675, 7, .at(offset: 1 << 40, count: 600))])
        #expect(!SourceFileFormat.hasEmbeddedColorDescription(oob, format: .tiff))
        #expect(!SourceFileFormat.hasEmbeddedColorDescription(data.prefix(data.count - 30), format: .tiff))
        // gain map TIFF 仍只支持经典 TIFF。
        #expect(try GainMapTIFF.detect(data) == nil)

        let source = try Self.decode(try Self.write(data, "big.tif"))
        #expect(source.hasEmbeddedProfile)
        #expect(source.sourceProfileOrigin == "embedded")
        #expect(source.sourceProfile == WorkingColor.describe(CGColorSpace(name: CGColorSpace.rommrgb)))
        #expect(Self.count(source, "source.profile_missing") == 0)
        let classic = try Self.decode(try Self.write(Self.rgbTIFF(little: little, icc: Self.romm), "classic.tif"))
        #expect(try Self.pixels(source.sdr) == Self.pixels(classic.sdr))
    }

    @Test("gain map 用到的标签损坏时与以前一样不当作 gain map；无关标签损坏不影响检测")
    func gainMapDetectionWithBadTags() throws {
        var unrelated = CompatOptions()
        unrelated.extraIFD0 = [(65000, 7, .at(offset: 0x7FFF_0000, count: 100))]
        unrelated.extraSub = [(65001, 7, .at(offset: 0x7FFF_0000, count: 100))]
        #expect(try GainMapTIFF.detect(Self.compatTIFF(unrelated)) != nil)
        let ok = try Self.decode(try Self.write(Self.compatTIFF(unrelated), "unrelated.tif"))
        #expect(ok.hdrKind == .gainMapTIFF)
        #expect(ok.warnings.isEmpty)

        // 以前整个 IFD 失败的情形照旧：SubIFD 的 52557 越界 → 跳过这个 SubIFD，按普通 SDR 读入、不警告；
        // IFD0 的 330 越界或数量 ≥ 2^28（在文件范围内）→ 不是 gain map TIFF。
        var badMeta = CompatOptions()
        badMeta.metadataOutOfBounds = true
        #expect(try GainMapTIFF.detect(Self.compatTIFF(badMeta)) == nil)
        let source = try Self.decode(try Self.write(Self.compatTIFF(badMeta), "bad52557.tif"))
        #expect(source.hdrKind == .none)
        #expect(source.warnings.isEmpty, "\(source.warnings)")
        var badSub = CompatOptions()
        badSub.subIFDs = .at(offset: 0x7FFF_0000, count: 2)
        #expect(try GainMapTIFF.detect(Self.compatTIFF(badSub)) == nil)
        // 数量 ≥ 2^28 但在文件范围内（稀疏文件，不占磁盘）：以前整个 IFD0 失败，现在也不去逐个读 2^28 个 SubIFD。
        badSub.subIFDs = .at(offset: 8, count: 1 << 28)
        let url = try Self.write(Self.compatTIFF(badSub), "hugeSubIFDs.tif")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(8 + 4 * (1 << 28)))
        try handle.close()
        let mapped = try Data(contentsOf: url, options: .mappedIfSafe)
        #expect(try TIFFFile(mapped).ifd0?.invalidTags == [330])
        #expect(try GainMapTIFF.detect(mapped) == nil)
    }

    // MARK: - 「最大化兼容性」TIFF 还原

    /// 原来的逐采样还原（每个采样读一次、按 ISO 21496-1 公式逐通道计算），用来核对查表版本逐位相同。
    static func referenceReconstruct(_ gm: GainMapTIFF, step: Int, linearize: (Float, Int) -> Float) throws -> (sdr: Data, hdr: Data) {
        let base = try gm.file.raster(gm.base), gain = try gm.file.raster(gm.gainMap)
        let m = gm.metadata
        func apply(_ b: SIMD3<Float>, _ g: SIMD3<Float>) -> SIMD3<Float> {
            var out = SIMD3<Float>()
            for c in 0..<3 {
                let i = m.multiChannel ? c : 0
                let e = pow(Double(max(g[i], 0)), 1 / m.gamma[i])
                let logBoost = m.gainMapMin[i] + (m.gainMapMax[i] - m.gainMapMin[i]) * e
                out[c] = Float((Double(b[c]) + m.baseOffset[i]) * pow(2, logBoost) - m.alternateOffset[i])
            }
            return out
        }
        let w = base.width / step, h = base.height / step
        var sdr = [Float16](repeating: 0, count: w * h * 4), hdr = sdr
        for y in 0..<h {
            for x in 0..<w {
                var s = SIMD3<Float>(), v = SIMD3<Float>()
                for dy in 0..<step {
                    for dx in 0..<step {
                        let sx = x * step + dx, sy = y * step + dy
                        let b = SIMD3(linearize(base.read(sx, sy, 0), 0), linearize(base.read(sx, sy, 1), 1), linearize(base.read(sx, sy, 2), 2))
                        let gx = min(sx * gain.width / base.width, gain.width - 1), gy = min(sy * gain.height / base.height, gain.height - 1)
                        let g = gain.channels == 1
                            ? SIMD3(repeating: gain.read(gx, gy, 0))
                            : SIMD3(gain.read(gx, gy, 0), gain.read(gx, gy, 1), gain.read(gx, gy, 2))
                        s += b
                        v += apply(b, g)
                    }
                }
                let i = (y * w + x) * 4
                s /= Float(step * step); v /= Float(step * step)
                sdr[i] = Float16(s.x); sdr[i + 1] = Float16(s.y); sdr[i + 2] = Float16(s.z); sdr[i + 3] = 1
                hdr[i] = Float16(v.x); hdr[i + 1] = Float16(v.y); hdr[i + 2] = Float16(v.z); hdr[i + 3] = 1
            }
        }
        return (sdr.withUnsafeBytes { Data($0) }, hdr.withUnsafeBytes { Data($0) })
    }

    /// (底图位深, gain map 位深, gain map 通道数, 小端, step)
    static let reconstructCases: [(Int, Int, Int, Bool, Int)] = [
        (16, 8, 3, true, 1), (16, 16, 3, true, 2), (8, 8, 1, true, 1), (8, 16, 3, false, 3), (16, 16, 1, false, 2), (16, 8, 3, false, 1),
    ]

    @Test("gain map 还原：8 / 16 位按码值查表，与逐采样计算逐位相同", arguments: reconstructCases)
    func reconstructMatchesPerSample(_ c: (Int, Int, Int, Bool, Int)) throws {
        for singleChannelMetadata in [false, true] {
            var o = CompatOptions()
            (o.baseBits, o.gainBits, o.gainChannels, o.little) = (c.0, c.1, c.2, c.3)
            if c.2 == 1 { (o.gainWidth, o.gainHeight) = (5, 4) }   // 低分辨率 gain map
            if singleChannelMetadata { o.metadata = Self.gainMapMetadata([(-0.25, 2.25, 0.8, 0.002, 0.003)]) }
            let gm = try #require(try GainMapTIFF.detect(Self.compatTIFF(o)))
            let trc = try #require(ICCProfile(Self.rec2020)?.trcFunctions)
            let linearize: @Sendable (Float, Int) -> Float = { v, ch in trc[ch](v) }
            let r = try gm.reconstruct(step: c.4, linearize: linearize)
            let ref = try Self.referenceReconstruct(gm, step: c.4, linearize: linearize)
            #expect(r.width == 12 / c.4 && r.height == 10 / c.4)
            #expect(r.sdr == ref.sdr, "SDR \(c) 单通道元数据 \(singleChannelMetadata)")
            #expect(r.hdr == ref.hdr, "HDR \(c) 单通道元数据 \(singleChannelMetadata)")
        }
    }

    @Test("gain map 读不出来（SubIFD 压缩）时按 SDR 读入：警告不重复", arguments: [false, true])
    func compressedGainMapWarningsOnce(_ withOverride: Bool) throws {
        var o = CompatOptions()
        o.gainCompression = 5
        o.icc = withOverride ? Self.rec2020 : nil
        let source = try Self.decode(try Self.write(Self.compatTIFF(o), "lzw.tif"), override: withOverride ? .displayP3 : nil)
        #expect(source.hdrKind == .none)
        #expect(Self.count(source, "source.hdr_not_read") == 1)
        if withOverride {
            // 有 ICC 时覆盖被忽略：只警告一次，来源仍是嵌入的 ICC。
            #expect(Self.count(source, "source.override_ignored") == 1)
            #expect(Self.count(source, "source.profile_missing") == 0)
            #expect(source.sourceProfileOrigin == "embedded")
        } else {
            #expect(Self.count(source, "source.profile_missing") == 1)
            #expect(Self.count(source, "source.override_ignored") == 0)
            #expect(source.sourceProfileOrigin == "assumedSRGB")
        }
        #expect(source.warnings.count == 2, "\(source.warnings)")
    }

    // MARK: - 输入颜色决策

    @Test("Rec. 2020 覆盖与嵌入 itur_2020 ICC 的同一像素解码相同（坑 20 改写同样适用）")
    func rec2020OverrideRewritesTRC() throws {
        let untagged = try Self.write(Self.rgbTIFF(width: 256, height: 1, icc: nil), "untagged.tif")
        let tagged = try Self.write(Self.rgbTIFF(width: 256, height: 1, icc: Self.rec2020), "tagged.tif")
        let overridden = try Self.decode(untagged, override: .rec2020, long: 256)
        let embedded = try Self.decode(tagged, long: 256)
        #expect(overridden.sourceProfileOrigin == "override")
        #expect(overridden.transformSteps.contains { $0.contains("坑 20") })
        #expect(embedded.transformSteps.contains { $0.contains("坑 20") })
        let a = try Self.pixels(overridden.sdr), b = try Self.pixels(embedded.sdr)
        #expect(a == b)
        // 线性值按 ICC 的曲线本身（不是 γ2.4）。
        let p = try #require(ICCProfile(Self.rec2020)?.bt709FamilyParametricTRC)
        for x in [40, 128, 200] {
            let code = Self.rgb16(x, 0)[0]
            let expected = ICCProfile.evaluateType3(p, Double(code) / 65535)
            #expect(abs(Double(a[x * 4]) / expected - 1) < 0.01, "x = \(x)：\(a[x * 4]) vs \(expected)")
        }
        // 其他覆盖的 ICC 不是这种曲线，不改写。
        for other in [SourceColorOverride.sRGB, .displayP3, .adobeRGB, .proPhoto] {
            let s = try Self.decode(untagged, override: other, long: 256)
            #expect(!s.transformSteps.contains { $0.contains("坑 20") }, "\(other)")
        }
    }

    /// 8 位灰度、没有 ICC 的 TIFF。
    static func grayTIFF() -> Data {
        var t = TIFFBuilder()
        let w = 16, h = 8
        let px = t.append(Data((0..<(w * h)).map { UInt8($0 * 2 % 256) }))
        let ifd0 = t.appendIFD([
            (256, 4, .ints([w])), (257, 4, .ints([h])), (258, 3, .ints([8])), (259, 3, .ints([1])), (262, 3, .ints([1])),
            (273, 4, .ints([px])), (277, 3, .ints([1])), (278, 4, .ints([h])), (279, 4, .ints([w * h])), (284, 3, .ints([1])),
        ])
        return t.finish(firstIFD: ifd0)
    }

    @Test("没有颜色描述的灰度图：有无覆盖都报缺 ICC，来源 assumedSRGB，描述写灰度空间本身，像素不变")
    func untaggedGrayDiagnostics() throws {
        let url = try Self.write(Self.grayTIFF(), "gray.tif")
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let space = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil)?.colorSpace)
        #expect(space.model == .monochrome)

        let plain = try Self.decode(url)
        #expect(plain.sourceProfileOrigin == "assumedSRGB")
        #expect(plain.sourceProfile == WorkingColor.describe(space))
        #expect(plain.sourceProfile != "sRGB IEC61966-2.1")
        #expect(plain.warnings.map(\.code) == ["source.profile_missing"])

        let overridden = try Self.decode(url, override: .displayP3)
        #expect(overridden.sourceProfileOrigin == "assumedSRGB")
        #expect(overridden.sourceProfile == WorkingColor.describe(space))
        #expect(overridden.warnings.map(\.code) == ["source.override_ignored", "source.profile_missing"])
        #expect(try Self.pixels(overridden.sdr) == Self.pixels(plain.sdr))
    }

    // MARK: - 峰值估计

    /// 原来的写法：整个数组排序后取第 index 个。
    static func sortedPeak(_ image: CIImage, context: CIContext) -> Double {
        let e = image.extent
        let s = min(1, 1024 / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let r = CGRect(x: 0, y: 0, width: max(1, (e.width * s).rounded(.down)), height: max(1, (e.height * s).rounded(.down)))
        let w = Int(r.width), h = Int(r.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            context.render(small, toBitmap: buf.baseAddress!, rowBytes: w * 16, bounds: r, format: .RGBAf,
                           colorSpace: WorkingColor.extendedLinearSRGB)
        }
        let maxima = (0..<(w * h)).map { max(px[4 * $0], px[4 * $0 + 1], px[4 * $0 + 2]) }.sorted()
        return max(1, Double(maxima[min(maxima.count - 1, Int((Double(maxima.count - 1) * 0.9995).rounded()))]))
    }

    static let peakSizes: [(Int, Int)] = [(1, 1), (7, 5), (300, 200), (1500, 900), (2048, 3)]

    @Test("画面峰值：选择算法与整体排序取同一个值", arguments: peakSizes)
    func peakMatchesSort(_ size: (Int, Int)) throws {
        let (w, h) = size
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(w * 31 + h)
        func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) }
        let patterns: [(Int) -> Float] = [
            { _ in (rnd() * 64).rounded() / 8 },                  // 0…8，大量重复值
            { _ in rnd() < 0.999 ? rnd() * 0.9 : 1 + rnd() * 5 },  // 绝大多数 < 1，少量高光
            { i in Float(i % 97) / 12 },                           // 周期，升序段
            { i in Float(w * h - i) / Float(w * h) * 6 },          // 降序
            { _ in 3 },                                            // 全部相同
        ]
        let decoder = SourceDecoder(context: PhotoFrameRenderer().context)
        for (k, pattern) in patterns.enumerated() {
            var px = [Float](repeating: 1, count: w * h * 4)
            for i in 0..<(w * h) { for c in 0..<3 { px[i * 4 + c] = pattern(i) } }
            let image = CIImage(bitmapData: px.withUnsafeBytes { Data($0) }, bytesPerRow: w * 16, size: CGSize(width: w, height: h),
                                format: .RGBAf, colorSpace: WorkingColor.extendedLinearSRGB)
            #expect(decoder.estimatePeak(image) == Self.sortedPeak(image, context: decoder.context), "\(size) 模式 \(k)")
        }
    }

    // MARK: - ICC

    @Test("ICC 标签签名含非 ASCII 字节：原样写回，坑 20 改写仍然生效")
    func iccNonASCIISignature() throws {
        let original = try #require(ICCProfile(Self.rec2020))
        let cprt = try #require(original.tags.firstIndex { $0.signature == "cprt" })
        var modified = Self.rec2020
        modified[132 + 12 * cprt] = 0xA9
        let icc = try #require(ICCProfile(modified))
        let p = try #require(icc.bt709FamilyParametricTRC)
        let rebuilt = icc.replacingTRC(samples: ICCProfile.sampledCurve(p))
        // 与 ASCII 版本的重建结果只差这一个字节（标签表没有错位）。
        var expected = original.replacingTRC(samples: ICCProfile.sampledCurve(p))
        expected[132 + 12 * cprt] = 0xA9
        #expect(rebuilt == expected)
        #expect(CGColorSpace(iccData: rebuilt as CFData) != nil)
        #expect(ICCProfile(rebuilt)?.tags.map(\.rawSignature) == icc.tags.map(\.rawSignature))

        // 端到端：带这份 ICC 的 16 位 TIFF 仍然按曲线本身解码，与 ASCII 版本相同。
        let a = try Self.decode(try Self.write(Self.rgbTIFF(width: 64, height: 2, icc: modified), "a9.tif"))
        let b = try Self.decode(try Self.write(Self.rgbTIFF(width: 64, height: 2, icc: Self.rec2020), "ascii.tif"))
        #expect(a.transformSteps.contains { $0.contains("坑 20") })
        #expect(try Self.pixels(a.sdr) == Self.pixels(b.sdr))
    }

    // MARK: - EXIF 文字

    static func exif(_ values: [CFString: Any]) -> [String: String] {
        MetadataText.values(from: [kCGImagePropertyExifDictionary: values])
    }

    static let shutterCases: [(Double, String)] = [
        (0.004, "1/250s"), (0.000125, "1/8000s"), (1 / 3.0, "1/3s"), (0.3, "1/3s"), (1 / 6.0, "1/6s"), (0.08, "1/13s"),
        (2, "2s"), (1, "1s"), (1.3, "1.3s"), (0.5, "1/2s"),
        (10 / 13.0, "1/1.3s"), (0.8, "1/1.3s"), (0.625, "1/1.6s"), (0.4, "1/2.5s"), (1 / 1.5, "1/1.5s"), (1 / 3.5, "1/3.5s"),
    ]

    @Test("快门：整数倒数和 1/6 档以内照旧；其他保留一位小数", arguments: shutterCases)
    func shutterText(_ c: (Double, String)) {
        #expect(Self.exif([kCGImagePropertyExifExposureTime: c.0])["shutter"] == c.1)
    }

    static let apertureCases: [(Double, String)] = [(0.95, "f/0.95"), (0.7, "f/0.7"), (1.4, "f/1.4"), (8, "f/8"), (5.6, "f/5.6"), (1, "f/1")]

    @Test("光圈：小于 1 时保留两位小数", arguments: apertureCases)
    func apertureText(_ c: (Double, String)) {
        #expect(Self.exif([kCGImagePropertyExifFNumber: c.0])["aperture"] == c.1)
    }

    @Test("ISO：ISOSpeedRatings 封顶 65535 时改用 RecommendedExposureIndex / ISOSpeed")
    func isoText() {
        let ratings = kCGImagePropertyExifISOSpeedRatings, rei = kCGImagePropertyExifRecommendedExposureIndex
        #expect(Self.exif([ratings: [65535], rei: 102400])["iso"] == "ISO 102400")
        #expect(Self.exif([ratings: [65535], kCGImagePropertyExifISOSpeed: 204800])["iso"] == "ISO 204800")
        #expect(Self.exif([ratings: [65535]])["iso"] == "ISO 65535")
        #expect(Self.exif([ratings: [100], rei: 102400])["iso"] == "ISO 100")
        #expect(Self.exif([rei: 102400])["iso"] == nil)
    }

    @Test("损坏的 EXIF 数值（inf、NaN、极大、极小）不让进程崩溃")
    func absurdNumbers() {
        let keys = [kCGImagePropertyExifExposureTime, kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm,
                    kCGImagePropertyExifFNumber]
        for value: Any in [Double.infinity, Double.nan, 1e30, 1e-19, 5e-324, "inf", "nan", "1e300"] {
            for key in keys { _ = Self.exif([key: value]) }
            _ = Self.exif([kCGImagePropertyExifISOSpeedRatings: [value]])
            _ = Self.exif([kCGImagePropertyExifISOSpeedRatings: [65535], kCGImagePropertyExifRecommendedExposureIndex: value])
        }
        #expect(Self.exif([kCGImagePropertyExifFocalLength: Double.infinity])["focalLength"] == nil)
        #expect(Self.exif([kCGImagePropertyExifFocalLength: Double.nan])["focalLength"] == nil)
        #expect(Self.exif([kCGImagePropertyExifExposureTime: 1e-19])["shutter"] == "1/1e+19s")
        #expect(Self.exif([kCGImagePropertyExifFocalLength: 35.0])["focalLength"] == "35mm")
    }
}

/// 测试用的 TIFF 写入器：经典 TIFF 或 BigTIFF、任意字节序；目录项的值可以指到任意位置（用来写坏标签）。
struct TIFFBuilder {
    enum Value {
        /// 按类型写的整数：放得下就内联，否则写进文件。
        case ints([Int])
        /// 已写入数据（或故意越界）的位置与数量。
        case at(offset: Int, count: Int)
    }

    let little: Bool
    let big: Bool
    private(set) var data: Data

    init(little: Bool = true, big: Bool = false) {
        self.little = little
        self.big = big
        data = Data(little ? [0x49, 0x49] : [0x4D, 0x4D])
        data += big ? uint(43, 2) + uint(8, 2) + uint(0, 2) + uint(0, 8) : uint(42, 2) + uint(0, 4)
    }

    func uint(_ v: Int, _ n: Int) -> Data {
        let bytes = (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
        return Data(little ? bytes : bytes.reversed())
    }

    mutating func append(_ bytes: Data) -> Int {
        while data.count % 2 != 0 { data.append(0) }
        let offset = data.count
        data += bytes
        return offset
    }

    /// 写一个 IFD（按标签排序），返回它的位置。
    mutating func appendIFD(_ entries: [(Int, Int, Value)]) -> Int {
        let sizes = [1: 1, 2: 1, 3: 2, 4: 4, 7: 1, 16: 8]
        let slot = big ? 8 : 4
        var encoded: [(tag: Int, type: Int, count: Int, field: Data)] = []
        for (tag, type, value) in entries.sorted(by: { $0.0 < $1.0 }) {
            switch value {
            case .ints(let values):
                let payload = values.reduce(Data()) { $0 + uint($1, sizes[type]!) }
                let field = payload.count <= slot ? payload + Data(count: slot - payload.count) : uint(append(payload), slot)
                encoded.append((tag, type, values.count, field))
            case .at(let offset, let count):
                encoded.append((tag, type, count, uint(offset, slot)))
            }
        }
        let start = append(Data())
        data += uint(encoded.count, big ? 8 : 2)
        for e in encoded { data += uint(e.tag, 2) + uint(e.type, 2) + uint(e.count, big ? 8 : 4) + e.field }
        data += uint(0, slot)
        return start
    }

    func finish(firstIFD: Int) -> Data {
        var out = data
        out.replaceSubrange(big ? 8..<16 : 4..<8, with: uint(firstIFD, big ? 8 : 4))
        return out
    }
}
