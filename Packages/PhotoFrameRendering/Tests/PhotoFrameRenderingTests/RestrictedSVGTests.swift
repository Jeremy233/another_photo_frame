import CoreGraphics
import Foundation
import Testing
@testable import PhotoFrameRendering

/// 受限 SVG 解析的边界情况：直接检查解析出的绘制命令与警告（D-09）。
@Suite("受限 SVG")
struct RestrictedSVGTests {
    static func parse(_ source: String) throws -> RestrictedSVG { try RestrictedSVG.parse(Data(source.utf8)) }

    /// viewBox 100×100 的根元素包住 `body`。
    static func svg(_ body: String, root: String = "") -> String {
        #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" "# + root + ">" + body + "</svg>"
    }

    static func path(_ c: RestrictedSVG.Command) -> CGPath {
        switch c {
        case .fill(let p, _, _), .stroke(let p, _, _, _, _, _): p
        }
    }

    /// sRGB r、g、b、alpha。
    static func rgba(_ c: RestrictedSVG.Command) -> [Double] {
        switch c {
        case .fill(_, let color, _), .stroke(_, let color, _, _, _, _): (color.components ?? []).map(Double.init)
        }
    }

    static func miterLimit(_ c: RestrictedSVG.Command) -> CGFloat? {
        if case .stroke(_, _, _, _, _, let limit) = c { limit } else { nil }
    }

    static func elements(_ p: CGPath) -> [(type: CGPathElementType, points: [CGPoint])] {
        var out: [(type: CGPathElementType, points: [CGPoint])] = []
        p.applyWithBlock { e in
            let n = switch e.pointee.type {
            case .moveToPoint, .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            default: 0
            }
            out.append((e.pointee.type, (0..<n).map { e.pointee.points[$0] }))
        }
        return out
    }

    static func near(_ a: [Double], _ b: [Double], tolerance: Double = 1e-9) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    static func near(_ a: CGPoint, _ b: CGPoint, tolerance: Double = 1e-9) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    /// 画进透明的 RGBA8 位图（与 viewBox 同尺寸），按 SVG 坐标（左上原点）取 alpha。
    static func alpha(of svg: RestrictedSVG, width: Int, height: Int) -> (Int, Int) -> UInt8 {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        svg.draw(in: ctx, box: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return { x, y in bytes[(y * width + x) * 4 + 3] }
    }

    // MARK: - 数值溢出

    @Test("圆弧中间量溢出（有限的 1e160）不崩溃，退化成到终点的直线")
    func arcOverflowDegradesToLine() throws {
        let parsed = try Self.parse(Self.svg(#"<path d="M0 0 A1 1 0 0 1 1e160 0"/>"#))
        #expect(parsed.warnings.isEmpty)
        try #require(parsed.commands.count == 1)
        let e = Self.elements(Self.path(parsed.commands[0]))
        #expect(e.map { $0.type } == [.moveToPoint, .addLineToPoint])
        #expect(e.last?.points == [CGPoint(x: 1e160, y: 0)])
        _ = Self.alpha(of: parsed, width: 10, height: 10) // 画出来也不崩溃
    }

    @Test("非有限数字（1e999）按无效处理：整条路径跳过并警告", arguments: [
        "M0 0 A1e999 1 0 0 1 10 5",
        "M0 0 a5 5 1e999 0 1 10 5",
    ])
    func nonFiniteArcNumbers(_ d: String) throws {
        let parsed = try Self.parse(Self.svg(#"<path d=""# + d + #""/>"#))
        #expect(parsed.commands.isEmpty)
        #expect(parsed.warnings == ["<path> 的几何参数无效，已跳过"])
    }

    @Test("长度与数字列表不接受 inf、nan、1e400")
    func nonFiniteLengths() throws {
        for s in ["inf", "nan", "1e400", "1e400px", "-infinity"] { #expect(RestrictedSVG.length(s) == nil, "\(s)") }
        #expect(RestrictedSVG.length(" 12.5px ") == 12.5)
        #expect(RestrictedSVG.numbers("1 2e3 1e999 4") == [1, 2000])
        let parsed = try Self.parse(#"""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20" width="inf" height="1e400">
              <rect width="1e400" height="5"/>
              <rect width="5" height="5" stroke="red" stroke-width="nan"/>
            </svg>
            """#)
        #expect(parsed.size == CGSize(width: 40, height: 20))
        #expect(parsed.warnings == ["<rect> 的几何参数无效，已跳过"])
        // 无效的 stroke-width 被忽略，沿用默认 1。
        let last = try #require(parsed.commands.last)
        if case .stroke(_, _, let width, _, _, _) = last { #expect(width == 1) } else { Issue.record("没有描边") }
    }

    @Test("正常圆弧不受影响：半径不足时按比例放大，仍是 90° 一段的贝塞尔")
    func normalArcUnchanged() throws {
        // (0,0) → (20,0) 的半圆，圆心 (10,0)，sweep = 1 经过 (10,-10)；半径 1 不够，按规则放大到 10。
        let k = 4.0 / 3 * tan(Double.pi / 8) * 10
        let expected: [[CGPoint]] = [
            [CGPoint(x: 0, y: 0)],
            [CGPoint(x: 0, y: -k), CGPoint(x: 10 - k, y: -10), CGPoint(x: 10, y: -10)],
            [CGPoint(x: 10 + k, y: -10), CGPoint(x: 20, y: -k), CGPoint(x: 20, y: 0)],
        ]
        for d in ["M0 0 A10 10 0 0 1 20 0", "M0 0 A1 1 0 0 1 20 0"] {
            let parsed = try Self.parse(Self.svg(#"<path d=""# + d + #""/>"#))
            try #require(parsed.commands.count == 1)
            let e = Self.elements(Self.path(parsed.commands[0]))
            #expect(e.map { $0.type } == [.moveToPoint, .addCurveToPoint, .addCurveToPoint])
            for (got, want) in zip(e.map { $0.points }, expected) {
                #expect(got.count == want.count && zip(got, want).allSatisfy { Self.near($0, $1) }, "\(d)：\(got) ≠ \(want)")
            }
        }
        // 旋转的椭圆弧：仍是曲线，终点落在 (80, 60)。
        let rotated = try Self.parse(Self.svg(#"<path d="M10 10 A20 30 15 0 1 80 60"/>"#))
        let e = Self.elements(Self.path(rotated.commands[0]))
        #expect(e.dropFirst().allSatisfy { $0.type == .addCurveToPoint })
        #expect(Self.near(e.last!.points.last!, CGPoint(x: 80, y: 60)))
    }

    // MARK: - currentColor

    @Test("currentColor 取 color（初始黑色）：fill=none stroke=currentColor 的线条图标画出黑色描边")
    func currentColorDefaultsToBlack() throws {
        // Feather / Lucide / Tabler 风格的图标。
        let parsed = try Self.parse(#"""
            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none"
                 stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M3 7h4l2-3h6l2 3h4v13H3z"/>
              <circle cx="12" cy="13" r="4"/>
            </svg>
            """#)
        #expect(parsed.warnings.isEmpty)
        #expect(parsed.commands.count == 2)
        for c in parsed.commands {
            guard case .stroke(_, _, let width, let cap, let join, _) = c else { Issue.record("应该只有描边"); continue }
            #expect(Self.rgba(c) == [0, 0, 0, 1])
            #expect(width == 2 && cap == .round && join == .round)
        }
    }

    @Test("currentColor 跟随继承的 color（属性或 style），不取上级的 fill；inherit 仍取上级")
    func currentColorFollowsColor() throws {
        let parsed = try Self.parse(##"""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" color="#ff0000">
              <g fill="#00ff00">
                <rect width="5" height="5" fill="currentColor"/>
                <rect width="5" height="5" style="color: #0000ff; fill: currentColor"/>
                <rect width="5" height="5" fill="inherit"/>
              </g>
            </svg>
            """##)
        #expect(parsed.warnings.isEmpty)
        #expect(parsed.commands.map(Self.rgba) == [[1, 0, 0, 1], [0, 0, 1, 1], [0, 1, 0, 1]])
    }

    @Test("不认识的 color 只在 currentColor 用到时警告")
    func unknownColorWarnsOnUse() throws {
        let unused = try Self.parse(Self.svg(#"<rect width="5" height="5" fill="red"/>"#, root: #"color="orange""#))
        #expect(unused.warnings.isEmpty)
        let used = try Self.parse(Self.svg(#"<rect width="5" height="5" fill="currentColor"/>"#, root: #"color="orange""#))
        #expect(used.warnings == ["不认识的颜色 orange，沿用上级颜色"])
        #expect(used.commands.map(Self.rgba) == [[0, 0, 0, 1]])
    }

    // MARK: - display / visibility

    @Test("display: none 的子树不画，也不警告", arguments: [
        #"display="none""#,
        #"style="display:none""#,
        #"style="fill:red; display : none""#,
    ])
    func displayNone(_ hiding: String) throws {
        // 例如 Inkscape 隐藏的图层：<g inkscape:groupmode="layer" style="display:none">。
        let parsed = try Self.parse(Self.svg(
            "<g " + hiding + #"><rect width="50" height="50"/><text>hidden</text></g>"#
                + "<text " + hiding + ">hidden</text>"
                + #"<rect x="60" width="10" height="10"/>"#))
        #expect(parsed.warnings.isEmpty)
        #expect(parsed.commands.map { Self.path($0).boundingBox } == [CGRect(x: 60, y: 0, width: 10, height: 10)])
        let hiddenRoot = try Self.parse(Self.svg(#"<rect width="5" height="5"/>"#, root: hiding))
        #expect(hiddenRoot.commands.isEmpty && hiddenRoot.warnings.isEmpty)
    }

    @Test("visibility: hidden / collapse 的图形不画，子元素 visible 重新显示", arguments: [
        #"visibility="hidden""#,
        #"visibility="collapse""#,
        #"style="visibility:hidden""#,
    ])
    func visibilityHidden(_ hiding: String) throws {
        let parsed = try Self.parse(Self.svg(
            "<g " + hiding + #"><rect width="50" height="50"/><rect x="60" width="10" height="10" visibility="visible"/></g>"#))
        #expect(parsed.warnings.isEmpty)
        #expect(parsed.commands.map { Self.path($0).boundingBox } == [CGRect(x: 60, y: 0, width: 10, height: 10)])
    }

    // MARK: - 不透明度

    @Test("组 opacity 与子元素显式的 fill-opacity / stroke-opacity 相乘")
    func groupOpacityMultipliesExplicitOpacity() throws {
        let parsed = try Self.parse(Self.svg(#"""
            <g opacity="0.5">
              <rect width="5" height="5" fill="red" fill-opacity="0.8" stroke="blue" stroke-opacity="0.6"/>
              <rect width="5" height="5" fill="red"/>
              <g style="fill-opacity:0.5"><rect width="5" height="5" opacity="0.5"/></g>
            </g>
            """#))
        #expect(Self.near(parsed.commands.map { Self.rgba($0)[3] }, [0.4, 0.3, 0.5, 0.125]))
    }

    // MARK: - DOCTYPE / ENTITY

    @Test("DOCTYPE / ENTITY 写在 4 KiB 之后也拒绝（不分大小写）")
    func doctypeAfterLongProlog() throws {
        let comment = "<!--" + String(repeating: "x", count: 5000) + "-->"
        for doctype in [#"<!DOCTYPE svg [<!ENTITY e "40">]>"#, "<!doctype svg>"] {
            let source = #"<?xml version="1.0"?>"# + comment + doctype
                + #"<svg xmlns="http://www.w3.org/2000/svg" width="&e;" height="1"><rect width="1" height="1"/></svg>"#
            let error = #expect(throws: RenderError.self) { _ = try RestrictedSVG.parse(Data(source.utf8)) }
            #expect(error?.code == "render.svg_rejected")
            #expect(error?.message.contains("DOCTYPE / ENTITY") == true, "\(String(describing: error))")
        }
    }

    @Test("文本检查查不到的编码（UTF-16）里的 ENTITY 声明由解析回调拒绝")
    func entityDeclarationInUTF16() throws {
        let hostile = #"<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE svg [<!ENTITY e "40">]>"#
            + #"<svg xmlns="http://www.w3.org/2000/svg" width="&e;" height="1"><rect width="1" height="1"/></svg>"#
        let error = #expect(throws: RenderError.self) { _ = try RestrictedSVG.parse(hostile.data(using: .utf16)!) }
        #expect(error?.code == "render.svg_rejected")
        #expect(error?.message.contains("DOCTYPE / ENTITY") == true, "\(String(describing: error))")
        // 同样的编码、没有 DOCTYPE 时照常解析。
        let plain = #"<?xml version="1.0" encoding="UTF-16"?><svg xmlns="http://www.w3.org/2000/svg" width="40" height="1"><rect width="1" height="1"/></svg>"#
        #expect(try RestrictedSVG.parse(plain.data(using: .utf16)!).commands.count == 1)
    }

    // MARK: - 颜色

    @Test("#RRGGBBAA / #RGBA 的 alpha 乘进不透明度，rgb() 支持百分比")
    func hexAlphaAndPercentRGB() throws {
        let parsed = try Self.parse(Self.svg(##"""
            <rect width="5" height="5" fill="#FF000080"/>
            <rect width="5" height="5" fill="#00f8" fill-opacity="0.5"/>
            <rect width="5" height="5" fill="rgb(100%, 0%, 50%)"/>
            <rect width="5" height="5" fill="none" stroke="#0000ff40"/>
            """##))
        #expect(parsed.warnings.isEmpty)
        let c = parsed.commands.map(Self.rgba)
        try #require(c.count == 4)
        #expect(Self.near(c[0], [1, 0, 0, 128.0 / 255]))
        #expect(Self.near(c[1], [0, 0, 1, 0.5 * 136 / 255]))
        #expect(Self.near(c[2], [1, 0, 0.5, 1]))
        #expect(Self.near(c[3], [0, 0, 1, 64.0 / 255]))
    }

    @Test("格式不对的颜色警告并沿用上级颜色", arguments: ["#12345", "#ggg", "#1234567g", "rgb(1, 2)"])
    func malformedColorsWarn(_ value: String) throws {
        let parsed = try Self.parse(Self.svg(#"<g fill="red"><rect width="5" height="5" fill=""# + value + #""/></g>"#))
        #expect(parsed.warnings == ["不认识的颜色 \(value)，沿用上级颜色"])
        #expect(parsed.commands.map(Self.rgba) == [[1, 0, 0, 1]])
    }

    // MARK: - stroke-miterlimit

    @Test("stroke-miterlimit 默认 4（CG 默认是 10），属性或 style 指定后继承；小于 1 无效")
    func miterLimitParsed() throws {
        let parsed = try Self.parse(Self.svg(#"""
            <path d="M0 0 L10 10" stroke="red"/>
            <g stroke-miterlimit="10"><path d="M0 0 L10 10" stroke="red"/></g>
            <path d="M0 0 L10 10" style="stroke:red; stroke-miterlimit:2.5"/>
            <path d="M0 0 L10 10" stroke="red" stroke-miterlimit="0.5"/>
            """#, root: #"fill="none""#))
        #expect(parsed.commands.compactMap(Self.miterLimit) == [4, 10, 2.5, 4])
    }

    @Test("尖角超过 miterlimit 时画成斜角，不拉出长刺")
    func miterLimitApplied() throws {
        // 顶角约 20°：斜接长度 / 线宽 ≈ 5.8，介于 SVG 默认 4 和 CG 默认 10 之间；斜接尖端在顶点 (50, 40) 上方约 29。
        func tip(_ extra: String) throws -> UInt8 {
            let source = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 130"><polyline points="35.9,120 50,40 64.1,120" fill="none" stroke="black" stroke-width="10" "#
                + extra + "/></svg>"
            let alpha = Self.alpha(of: try Self.parse(source), width: 100, height: 130)
            #expect(alpha(50, 45) > 200) // 线条本身
            return alpha(50, 25)
        }
        #expect(try tip("") == 0)
        #expect(try tip(#"stroke-miterlimit="10""#) > 200)
    }

    // MARK: - 嵌套 svg

    @Test("嵌套 <svg> 的视口属性被忽略时警告，绘制仍与 <g> 相同")
    func nestedSVGViewportWarns() throws {
        let nested = try Self.parse(Self.svg(#"<svg x="10" width="50" viewBox="0 0 10 10"><rect width="5" height="5"/></svg>"#))
        #expect(nested.warnings == ["忽略嵌套 <svg> 的 x / width / viewBox，按 <g> 绘制"])
        let group = try Self.parse(Self.svg(#"<g><rect width="5" height="5"/></g>"#))
        #expect(nested.commands.map { Self.path($0).boundingBox } == group.commands.map { Self.path($0).boundingBox })
        let plain = try Self.parse(Self.svg(#"<svg><rect width="5" height="5"/></svg>"#))
        #expect(plain.warnings.isEmpty)
    }
}
