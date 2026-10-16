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

    @Test("文件超过大小上限")
    func tooLarge() {
        var limits = AssetImportLimits.default
        limits.maxPNGBytes = 64
        #expect(rejection { () throws(LibraryError) in try AssetValidator.validate(makePNG(), format: .png, limits: limits) } == "asset.too_large")
    }

    @Test("IHDR 谎报超大尺寸：不解压就拒绝")
    func hugeDimensions() {
        let tiny = PNGBuilder.zlib(Data(count: 10))
        for (w, h) in [(100_000, 10), (10, 100_000), (8192, 8192), (0, 10)] as [(UInt32, UInt32)] {
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
