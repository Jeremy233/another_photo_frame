import Foundation
import Testing
import PhotoFrameCore
@testable import PhotoFrameStorage

private func rejection(_ body: () throws(LibraryError) -> ValidatedAsset) -> String? {
    do {
        _ = try body()
        return nil
    } catch {
        return error.code
    }
}

@Suite("素材校验：PNG")
struct PNGValidationTests {
    @Test("正常 PNG：读出尺寸，内容原样保存")
    func valid() throws {
        let data = makePNG(width: 40, height: 12)
        let v = try AssetValidator.validate(data, fileExtension: "PNG")
        #expect(v.format == .png)
        #expect(v.pixelSize == PixelSize(width: 40, height: 12))
        #expect(v.data == data)
        #expect(v.warnings.isEmpty)
    }

    @Test("手工拼出的最小 PNG（灰度、索引色、隔行）能通过")
    func handBuilt() throws {
        // 2×2 灰度 8 位：每行 1 字节过滤类型 + 2 字节像素。
        let gray = PNGBuilder.png([PNGBuilder.ihdr(width: 2, height: 2, colorType: 0), PNGBuilder.chunk("IDAT", PNGBuilder.zlib(Data(count: 6)))])
        #expect(try AssetValidator.validate(gray, format: .png).pixelSize == PixelSize(width: 2, height: 2))

        // 单边正好 16384 px（D-85 上限）可以导入。
        let wide = PNGBuilder.png([PNGBuilder.ihdr(width: 16384, height: 1), PNGBuilder.chunk("IDAT", PNGBuilder.zlib(Data(count: 1 + 16384 * 4)))])
        #expect(try AssetValidator.validate(wide, format: .png).pixelSize == PixelSize(width: 16384, height: 1))

        // 索引色缺调色板 → 拒绝。
        let noPalette = PNGBuilder.png([PNGBuilder.ihdr(width: 2, height: 2, colorType: 3), PNGBuilder.chunk("IDAT", PNGBuilder.zlib(Data(count: 6)))])
        #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(noPalette, format: .png) } == "asset.corrupted")

        // Adam7 隔行 3×3 RGBA：按 7 个子图计算的解压大小。
        let size = AssetValidator.inflatedSize(width: 3, height: 3, bitsPerPixel: 32, interlaced: true)
        var ihdr = PNGBuilder.ihdr(width: 3, height: 3)
        ihdr = PNGBuilder.chunk("IHDR", PNGBuilder.be32(3) + PNGBuilder.be32(3) + [8, 6, 0, 0, 1])
        let interlaced = PNGBuilder.png([ihdr, PNGBuilder.chunk("IDAT", PNGBuilder.zlib(Data(count: size)))])
        #expect(try AssetValidator.validate(interlaced, format: .png).pixelSize == PixelSize(width: 3, height: 3))
    }

    @Test("不信任扩展名：内容不是 PNG 时拒绝")
    func typeMismatch() {
        let svgData = svg()
        #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(svgData, fileExtension: "png") } == "asset.type_mismatch")
        let jpegish = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0, count: 64))
        #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(jpegish, fileExtension: "png") } == "asset.type_mismatch")
        #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(makePNG(), fileExtension: "svg") } == "asset.type_mismatch")
    }

    @Test("不支持的类型")
    func unsupported() {
        for ext in ["gif", "jpg", "heic", "pdf", ""] {
            #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(makePNG(), fileExtension: ext) } == "asset.unsupported_type")
        }
    }

    @Test("默认上限（D-85）")
    func defaultLimits() {
        let d = AssetImportLimits.default
        #expect(d.maxPNGBytes == 64 << 20 && d.maxSVGBytes == 8 << 20)
        #expect(d.maxDimension == 16384 && d.maxPixelCount == 64 << 20)
        #expect(d.maxSVGElements == 50_000 && d.maxSVGDepth == 64)
    }

    @Test("文件超过大小上限")
    func tooLarge() {
        var limits = AssetImportLimits.default
        limits.maxPNGBytes = 64
        #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(makePNG(), format: .png, limits: limits) } == "asset.too_large")
    }

    @Test("IHDR 谎报超大尺寸：不解压就拒绝")
    func hugeDimensions() {
        let tiny = PNGBuilder.zlib(Data(count: 10))
        for (w, h) in [(100_000, 10), (10, 100_000), (16_385, 1), (16_384, 16_384), (8193, 8193), (0, 10)] as [(UInt32, UInt32)] {
            let data = PNGBuilder.png([PNGBuilder.ihdr(width: w, height: h), PNGBuilder.chunk("IDAT", tiny)])
            #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(data, format: .png) } == "asset.invalid_dimensions")
        }
    }

    @Test("压缩炸弹：解压后比 IHDR 声明的大")
    func decompressionBomb() {
        // 声明 4×4 RGBA（应解出 4 × 17 = 68 字节），实际塞进 8 MiB 的零。
        let bomb = PNGBuilder.zlib(Data(count: 8 << 20))
        #expect(bomb.count < 64 << 10)
        let data = PNGBuilder.png([PNGBuilder.ihdr(width: 4, height: 4), PNGBuilder.chunk("IDAT", bomb)])
        #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(data, format: .png) } == "asset.corrupted")
    }

    @Test("图像数据不足：解压后比声明的小")
    func shortImageData() {
        let data = PNGBuilder.png([PNGBuilder.ihdr(width: 64, height: 64), PNGBuilder.chunk("IDAT", PNGBuilder.zlib(Data(count: 100)))])
        #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(data, format: .png) } == "asset.corrupted")
    }

    @Test("截断、改坏一个字节、缺 IHDR、坏 zlib 头")
    func corrupted() {
        let good = makePNG()
        let truncated = good.prefix(good.count / 2)
        var flipped = good
        flipped[good.count / 2] ^= 0xFF
        let noHeader = Data(AssetValidator.pngSignature + PNGBuilder.chunk("IDAT", PNGBuilder.zlib(Data(count: 4))) + PNGBuilder.chunk("IEND", []))
        let badZlib = PNGBuilder.png([PNGBuilder.ihdr(width: 1, height: 1), PNGBuilder.chunk("IDAT", [0x12, 0x34, 1, 2, 3, 4, 5, 6])])
        for data in [Data(truncated), flipped, noHeader, badZlib] {
            #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(data, format: .png) } == "asset.corrupted")
        }
    }

    @Test("动画 PNG 拒绝")
    func animated() {
        let actl = PNGBuilder.chunk("acTL", PNGBuilder.be32(2) + PNGBuilder.be32(0))
        let data = PNGBuilder.png([PNGBuilder.ihdr(width: 1, height: 1), actl, PNGBuilder.chunk("IDAT", PNGBuilder.zlib(Data(count: 5)))])
        #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(data, format: .png) } == "asset.unsupported_type")
    }

    @Test("IEND 之后的多余数据（例如拼接的 ZIP）被去掉")
    func trailingData() throws {
        let good = makePNG()
        let polyglot = good + Data("PK\u{03}\u{04}secret".utf8)
        let v = try AssetValidator.validate(polyglot, format: .png)
        #expect(v.data == good)
        #expect(v.warnings.count == 1)
    }

    @Test("zlib 流分在多个 IDAT 里（前面夹着别的数据块）：能通过；任何一块 CRC 不对都拒绝")
    func multipleIDAT() throws {
        // 4×3 RGBA：每行 1 字节过滤类型（0）+ 16 字节像素。
        let raw = Data((0..<3).flatMap { row in [UInt8(0)] + (0..<16).map { UInt8(row * 16 + $0) } })
        let z = PNGBuilder.zlib(raw)
        // 第一块只有 zlib 头的 1 个字节。
        let parts = [Array(z[0..<1]), Array(z[1..<6]), Array(z[6...])]
        let text = PNGBuilder.chunk("tEXt", Array("Comment\u{0}hi".utf8))
        let chunks = [PNGBuilder.ihdr(width: 4, height: 3), text] + parts.map { PNGBuilder.chunk("IDAT", $0) }
        let data = PNGBuilder.png(chunks)
        let v = try AssetValidator.validate(data, format: .png)
        #expect(v.pixelSize == PixelSize(width: 4, height: 3))
        #expect(v.data == data && v.warnings.isEmpty)

        // 多余数据照样去掉；传入的是下标不从 0 开始的切片时，结果相同，存下的数据从 0 开始编号。
        let padded = Data([1, 2, 3]) + data + Data("tail".utf8)
        let slice = padded[3...]
        let s = try AssetValidator.validate(slice, format: .png)
        #expect(s.data == data && s.data.startIndex == 0)
        #expect(s.warnings == ["已去掉 IEND 之后 4 字节的多余数据"])

        // 改坏中间那块 IDAT（chunks[3]）CRC 的最后一个字节。
        var broken = data
        broken[8 + chunks[0...3].reduce(0) { $0 + $1.count } - 1] ^= 0xFF
        do {
            _ = try AssetValidator.validate(broken, format: .png)
            Issue.record("应拒绝")
        } catch {
            #expect(error.code == "asset.corrupted")
            #expect(error.message == "素材文件已损坏：数据块 IDAT 校验和不符")
        }
    }
}

@Suite("素材校验：受限 SVG（D-09）")
struct SVGValidationTests {
    @Test("正常 SVG：尺寸取自 viewBox 或 width/height")
    func valid() throws {
        #expect(try AssetValidator.validate(svg(), format: .svg).pixelSize == PixelSize(width: 120, height: 40))
        let sized = svg(attributes: #"width="300px" viewBox="0 0 120 40""#)
        #expect(try AssetValidator.validate(sized, format: .svg).pixelSize == PixelSize(width: 300, height: 100))
        let v = try AssetValidator.validate(svg(#"<title>t</title><g><path d="M0 0L1 1"/></g>"#), format: .svg)
        #expect(v.warnings.isEmpty)
    }

    @Test("渲染时会跳过的元素只警告")
    func unsupportedElementsWarn() throws {
        let v = try AssetValidator.validate(svg(#"<text>hi</text><linearGradient id="g"/><rect width="1" height="1"/>"#), format: .svg)
        #expect(v.warnings.count == 2)
        let empty = try AssetValidator.validate(svg(""), format: .svg)
        #expect(empty.warnings.contains { $0.contains("没有可绘制") })
    }

    @Test("恶意或超限的 SVG 一律拒绝", arguments: [
        svg(#"<script>alert(1)</script>"#),
        svg(#"<rect width="1" height="1" onclick="x()"/>"#),
        svg(#"<image href="https://example.com/a.png"/>"#),
        svg(##"<use xlink:href="#a"/>"##),
        svg(#"<rect width="1" height="1" fill="url(https://example.com/x)"/>"#),
        svg(#"<rect width="1" height="1" style="fill: url(#p)"/>"#),
        svg(#"<path d="M0 0" fill="javascript:alert(1)"/>"#),
        svg(#"<style>rect{fill:red}</style>"#),
        svg(#"<foreignObject><div/></foreignObject>"#),
        svg(#"<a><rect width="1" height="1"/></a>"#),
        svg(#"<animate attributeName="x"/>"#),
        Data(#"<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "aaaaaaaa"><!ENTITY b "&a;&a;&a;&a;">]><svg viewBox="0 0 1 1">&b;</svg>"#.utf8),
        Data(#"<?xml version="1.0"?><!DOCTYPE svg SYSTEM "file:///etc/passwd"><svg viewBox="0 0 1 1"/>"#.utf8),
        Data(#"<?xml version="1.0"?><?xml-stylesheet href="https://example.com/a.css"?><svg viewBox="0 0 1 1"/>"#.utf8),
        Data(#"<svg viewBox="0 0 1 1"><rect"#.utf8),
        Data(#"<html><svg viewBox="0 0 1 1"/></html>"#.utf8),
        svg(attributes: ""),
        svg(attributes: #"width="100%" height="100%""#),
        Data("<svg viewBox=\"0 0 1 1\"/>".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
    ])
    func rejected(data: Data) {
        let code = rejection { () throws(LibraryError) in try AssetValidator.validate(data, format: .svg) }
        #expect(code == "asset.svg_rejected" || code == "asset.type_mismatch", "\(String(decoding: data, as: UTF8.self))")
    }

    @Test("固有尺寸超出 Int 范围（≥ 2^63，含按 viewBox 推算的）：按「过大」拒绝，不崩溃")
    func hugeIntrinsicSize() {
        func message(_ attributes: String) -> String? {
            do {
                _ = try AssetValidator.validate(svg(attributes: attributes), format: .svg)
                return nil
            } catch {
                #expect(error.code == "asset.svg_rejected", "\(attributes)")
                return error.message
            }
        }
        let max = Int.max
        #expect(message(#"width="1e19" height="10""#) == "SVG 素材不符合受限格式：固有尺寸 \(max)×10 过大")
        #expect(message(#"viewBox="0 0 1e19 1""#) == "SVG 素材不符合受限格式：固有尺寸 \(max)×1 过大")
        #expect(message(#"width="5" height="1e300""#) == "SVG 素材不符合受限格式：固有尺寸 5×\(max) 过大")
        #expect(message(#"height="1e19" viewBox="0 0 1 1""#) == "SVG 素材不符合受限格式：固有尺寸 \(max)×\(max) 过大")
        #expect(message(#"width="1e10" viewBox="0 0 1 1e10""#) == "SVG 素材不符合受限格式：固有尺寸 10000000000×\(max) 过大")
        // 2^63 以下的仍按原来的数值报错。
        #expect(message(#"width="1e18" height="10""#) == "SVG 素材不符合受限格式：固有尺寸 1000000000000000000×10 过大")
    }

    @Test("元素数量、嵌套深度、文件大小上限")
    func limits() {
        var limits = AssetImportLimits.default
        limits.maxSVGElements = 50
        let many = svg(String(repeating: #"<rect width="1" height="1"/>"#, count: 60))
        #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(many, format: .svg, limits: limits) } == "asset.svg_rejected")

        let deep = svg(String(repeating: "<g>", count: 100) + String(repeating: "</g>", count: 100))
        #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(deep, format: .svg) } == "asset.svg_rejected")

        limits = .default
        limits.maxSVGBytes = 100
        let big = svg(String(repeating: " ", count: 200))
        #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(big, format: .svg, limits: limits) } == "asset.too_large")
    }
}
