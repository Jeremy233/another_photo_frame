import CoreGraphics
import Foundation
import PhotoFrameStorage

/// 受限 SVG（D-09）：只解析基本图形与路径，禁止脚本、外部引用与远程资源。
///
/// - 支持：`svg`、`g`、`path`、`rect`、`circle`、`ellipse`、`line`、`polyline`、`polygon`；
///   属性 `fill`、`stroke`、`stroke-width`、`opacity`、`fill-opacity`、`stroke-opacity`、`fill-rule`、
///   `stroke-linecap`、`stroke-linejoin`、`stroke-miterlimit`、`color`（供 currentColor）、`display: none`、`visibility`、
///   `transform`（translate / scale / rotate / matrix）、`style` 里的同名声明。
///   嵌套的 `svg` 按 `g` 画（x / y / width / height / viewBox 忽略并警告）。
/// - 元素规则和上限只有一份（D-87）：`AssetValidator.SVGPolicy`（PhotoFrameStorage，素材导入时用同一套）与
///   `AssetImportLimits.default`（D-85）。
/// - 拒绝整个文件：DOCTYPE / ENTITY、`SVGPolicy.renderingForbiddenElements`（脚本、外部内容、样式表、链接）、
///   任何 `href`、`on*` 事件属性、`url(`、`javascript:`、`data:` 取值，元素数或嵌套超过上限。
///   导入比这里更严（D-87）：还拒绝动画元素和处理指令；这里动画元素跳过，处理指令忽略。
/// - 忽略：`SVGPolicy.ignoredElements`；其他不支持的元素连同子树跳过并警告（例如渐变、文字、滤镜）。
/// 颜色按 sRGB 解释：几个命名色、`#RGB` / `#RGBA` / `#RRGGBB` / `#RRGGBBAA`、`rgb()`（数字或百分比）。
struct RestrictedSVG {
    enum Command {
        case fill(CGPath, CGColor, evenOdd: Bool)
        case stroke(CGPath, CGColor, width: CGFloat, cap: CGLineCap, join: CGLineJoin, miterLimit: CGFloat)
    }

    /// viewBox（没有时为 0, 0, width, height）。
    var viewBox: CGRect
    /// 内容的像素尺寸（width / height 属性，缺省取 viewBox 尺寸）。
    var size: CGSize
    var commands: [Command]
    var warnings: [String]

    typealias Policy = AssetValidator.SVGPolicy
    static let limits = AssetImportLimits.default

    static func parse(_ data: Data) throws(RenderError) -> RestrictedSVG {
        guard data.count <= limits.maxSVGBytes else { throw reject("文件超过 \(limits.maxSVGBytes >> 20) MiB") }
        // 与素材导入相同：查整个文件、不分大小写。按字节找（String.contains 查 8 MiB 要约 200 ms，每次预览都会解析）。
        // UTF-16 等编码在这里查不到，由 Builder 的 ENTITY 回调拦下。
        let lower = Data(String(decoding: data, as: UTF8.self).lowercased().utf8)
        if lower.range(of: Data("<!doctype".utf8)) != nil || lower.range(of: Data("<!entity".utf8)) != nil {
            throw reject("不允许 DOCTYPE / ENTITY 声明")
        }
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let error = delegate.error { throw error }
        guard ok else { throw reject("XML 解析失败：\(parser.parserError?.localizedDescription ?? "未知错误")") }
        guard let root = delegate.root else { throw reject("没有 <svg> 根元素") }
        return RestrictedSVG(viewBox: root.viewBox, size: root.size, commands: delegate.commands, warnings: delegate.warnings)
    }

    static func reject(_ why: String) -> RenderError {
        RenderError(code: "render.svg_rejected", message: "SVG 素材不符合受限格式：\(why)",
                    hint: "只支持基本图形与路径：请导出为不含脚本、外部引用和文字的 SVG，或改用 PNG")
    }

    /// 把 viewBox 等比放进 `box`（xMidYMid meet），画进左下原点的 CG 上下文。
    func draw(in ctx: CGContext, box: CGRect) {
        guard viewBox.width > 0, viewBox.height > 0 else { return }
        let s = min(box.width / viewBox.width, box.height / viewBox.height)
        let dx = box.minX + (box.width - viewBox.width * s) / 2
        let dyTop = (box.height - viewBox.height * s) / 2
        ctx.saveGState()
        // SVG 是 y 向下：先翻转到左上原点。
        ctx.translateBy(x: 0, y: box.maxY - dyTop)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: dx, y: 0)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -viewBox.minX, y: -viewBox.minY)
        for command in commands {
            switch command {
            case .fill(let path, let color, let evenOdd):
                ctx.addPath(path)
                ctx.setFillColor(color)
                ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
            case .stroke(let path, let color, let width, let cap, let join, let miterLimit):
                ctx.addPath(path)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(width)
                ctx.setLineCap(cap)
                ctx.setLineJoin(join)
                ctx.setMiterLimit(miterLimit)
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    // MARK: - 解析

    /// sRGB 编码值与 alpha（只有 `#RRGGBBAA` / `#RGBA` 的 alpha 不是 1）。
    typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

    struct Style {
        var fill: RGBA? = (0, 0, 0, 1)
        var stroke: RGBA?
        /// `color`（继承，初始黑色），只给 currentColor 用。不认识的取值记在 `unknownColor`，用到时再警告。
        var color: RGBA = (0, 0, 0, 1)
        var unknownColor: String?
        var strokeWidth = 1.0
        /// 祖先与自身 opacity 的乘积。已乘进下面两项；子元素显式给出 fill-opacity / stroke-opacity 时要再乘上。
        var groupOpacity = 1.0
        var fillOpacity = 1.0
        var strokeOpacity = 1.0
        var evenOdd = false
        var cap = CGLineCap.butt
        var join = CGLineJoin.miter
        /// SVG 默认 4（CG 默认 10，尖角会拉出长刺）。
        var miterLimit = 4.0
        /// visibility（继承）：hidden / collapse 的图形不画，子元素可以用 visible 重新显示。
        var visible = true
        var transform = CGAffineTransform.identity
    }

    struct Root {
        var viewBox: CGRect
        var size: CGSize
    }

    final class Builder: NSObject, XMLParserDelegate {
        var root: Root?
        var commands: [Command] = []
        var warnings: [String] = []
        var error: RenderError?
        var stack: [Style] = []
        /// > 0 时处于被跳过的子树中。
        var skipDepth = 0
        var elementCount = 0
        var depth = 0

        func fail(_ parser: XMLParser, _ why: String) {
            if error == nil { error = RestrictedSVG.reject(why) }
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            elementCount += 1
            depth += 1
            let limits = RestrictedSVG.limits
            guard elementCount <= limits.maxSVGElements else { return fail(parser, "元素超过 \(limits.maxSVGElements) 个") }
            guard depth <= limits.maxSVGDepth else { return fail(parser, "嵌套超过 \(limits.maxSVGDepth) 层") }
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if RestrictedSVG.Policy.renderingForbiddenElements.contains(local) { return fail(parser, "不允许 <\(local)>") }
            for (key, value) in attributes {
                let k = key.lowercased()
                if k.hasSuffix("href") { return fail(parser, "不允许外部引用（\(key)）") }
                if k.hasPrefix("on") { return fail(parser, "不允许事件属性（\(key)）") }
                let v = value.lowercased()
                if v.contains("url(") || v.contains("javascript:") || v.contains("data:") {
                    return fail(parser, "不允许引用（\(key)=\(value.prefix(40))）")
                }
            }
            if skipDepth > 0 { skipDepth += 1; return }
            if RestrictedSVG.Policy.ignoredElements.contains(local) { skipDepth = 1; return }

            let props = properties(attributes)
            if root == nil {
                guard local == "svg" else { return fail(parser, "根元素不是 <svg>") }
                root = makeRoot(attributes)
                if hidden(props) { skipDepth = 1; return }
                stack = [apply(props, to: Style())]
                return
            }
            // display: none 的子树整个不画；只是隐藏，不算不支持，不警告。
            if hidden(props) { skipDepth = 1; return }
            guard RestrictedSVG.Policy.containerElements.contains(local) || RestrictedSVG.Policy.shapeElements.contains(local) else {
                warnings.append("跳过不支持的元素 <\(local)>")
                skipDepth = 1
                return
            }
            if local == "svg" {
                let viewport = ["x", "y", "width", "height", "viewBox"].filter { attributes[$0] != nil }
                if !viewport.isEmpty { warnings.append("忽略嵌套 <svg> 的 \(viewport.joined(separator: " / "))，按 <g> 绘制") }
            }
            let style = apply(props, to: stack.last ?? Style())
            stack.append(style)
            if RestrictedSVG.Policy.shapeElements.contains(local), style.visible {
                guard let path = shape(local, attributes) else {
                    warnings.append("<\(local)> 的几何参数无效，已跳过")
                    return
                }
                emit(path, style)
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            depth -= 1
            if skipDepth > 0 { skipDepth -= 1; return }
            if !stack.isEmpty { stack.removeLast() }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            if error == nil { error = RestrictedSVG.reject("XML 解析失败：\(parseError.localizedDescription)") }
        }

        // 文本检查之外再拦一次（例如 UTF-16 文件里的 DOCTYPE），在实体展开之前中止。
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            fail(parser, "不允许 DOCTYPE / ENTITY 声明")
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            fail(parser, "不允许 DOCTYPE / ENTITY 声明")
        }

        func makeRoot(_ a: [String: String]) -> Root {
            let w = a["width"].flatMap(length), h = a["height"].flatMap(length)
            var box: CGRect?
            if let vb = a["viewBox"].map(numbers), vb.count == 4, vb[2] > 0, vb[3] > 0 {
                box = CGRect(x: vb[0], y: vb[1], width: vb[2], height: vb[3])
            }
            let viewBox = box ?? CGRect(x: 0, y: 0, width: w ?? 0, height: h ?? 0)
            var size = CGSize(width: w ?? viewBox.width, height: h ?? viewBox.height)
            if w == nil, let h, viewBox.height > 0 { size.width = h * viewBox.width / viewBox.height }
            if h == nil, let w, viewBox.width > 0 { size.height = w * viewBox.height / viewBox.width }
            return Root(viewBox: viewBox, size: size)
        }

        func emit(_ path: CGPath, _ s: Style) {
            var p = s.transform
            guard let transformed = path.copy(using: &p) else { return }
            if let f = s.fill, s.fillOpacity * f.a > 0 {
                commands.append(.fill(transformed, color(f, alpha: s.fillOpacity * f.a), evenOdd: s.evenOdd))
            }
            if let k = s.stroke, s.strokeWidth > 0, s.strokeOpacity * k.a > 0 {
                // 线宽随变换缩放（取两个方向缩放的几何平均）。
                let scale = sqrt(abs(s.transform.a * s.transform.d - s.transform.b * s.transform.c))
                commands.append(.stroke(transformed, color(k, alpha: s.strokeOpacity * k.a),
                                        width: s.strokeWidth * scale, cap: s.cap, join: s.join, miterLimit: s.miterLimit))
            }
        }

        func color(_ c: RGBA, alpha: Double) -> CGColor {
            CGColor(colorSpace: WorkingColor.sRGB, components: [c.r, c.g, c.b, min(max(alpha, 0), 1)])!
        }

        /// 属性加上 `style` 里的声明（声明优先）。
        func properties(_ attributes: [String: String]) -> [String: String] {
            var props = attributes
            if let style = attributes["style"] {
                for decl in style.split(separator: ";") {
                    let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2 { props[kv[0]] = kv[1] }
                }
            }
            return props
        }

        /// display 不继承，但 none 时整个子树都不画。
        func hidden(_ props: [String: String]) -> Bool {
            props["display"]?.trimmingCharacters(in: .whitespaces).lowercased() == "none"
        }

        func apply(_ props: [String: String], to parent: Style) -> Style {
            var s = parent
            // color 本身不画东西：不认识的取值先沿用上级，等 currentColor 用到时再警告。
            if let v = props["color"] {
                let t = v.trimmingCharacters(in: .whitespaces).lowercased()
                if let c = RestrictedSVG.parseColor(t) {
                    s.color = c
                    s.unknownColor = nil
                } else if t != "inherit", t != "currentcolor" {
                    s.unknownColor = v
                }
            }
            if let v = props["fill"] { s.fill = paint(v, inherited: parent.fill, style: s) }
            if let v = props["stroke"] { s.stroke = paint(v, inherited: parent.stroke, style: s) }
            if let v = props["stroke-width"].flatMap(length) { s.strokeWidth = v }
            if let v = props["stroke-miterlimit"].flatMap(Double.init), v >= 1, v.isFinite { s.miterLimit = v }
            // 显式的 fill-opacity / stroke-opacity 也要乘上祖先的 opacity。
            if let v = props["fill-opacity"].flatMap(Double.init) { s.fillOpacity = v * parent.groupOpacity }
            if let v = props["stroke-opacity"].flatMap(Double.init) { s.strokeOpacity = v * parent.groupOpacity }
            if let v = props["fill-rule"] { s.evenOdd = v == "evenodd" }
            if let v = props["stroke-linecap"] { s.cap = v == "round" ? .round : v == "square" ? .square : .butt }
            if let v = props["stroke-linejoin"] { s.join = v == "round" ? .round : v == "bevel" ? .bevel : .miter }
            switch props["visibility"]?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "hidden", "collapse": s.visible = false
            case "visible": s.visible = true
            default: break
            }
            let own = props["opacity"].flatMap(Double.init) ?? 1
            s.fillOpacity *= own
            s.strokeOpacity *= own
            s.groupOpacity *= own
            if let t = props["transform"] { s.transform = transform(t).concatenating(parent.transform) }
            return s
        }

        /// fill / stroke：`inherit` 取上级的值，`currentColor` 取本元素的 color。
        func paint(_ v: String, inherited: RGBA?, style s: Style) -> RGBA? {
            let t = v.trimmingCharacters(in: .whitespaces).lowercased()
            switch t {
            case "none", "transparent": return nil
            case "inherit": return inherited
            case "currentcolor":
                if let bad = s.unknownColor { warnings.append("不认识的颜色 \(bad)，沿用上级颜色") }
                return s.color
            default:
                if let c = RestrictedSVG.parseColor(t) { return c }
                warnings.append("不认识的颜色 \(v)，沿用上级颜色")
                return inherited
            }
        }

        func transform(_ v: String) -> CGAffineTransform {
            var result = CGAffineTransform.identity
            let scanner = v.replacingOccurrences(of: ")", with: ")|").split(separator: "|")
            for part in scanner {
                let pieces = part.split(separator: "(", maxSplits: 1)
                guard pieces.count == 2 else { continue }
                let name = pieces[0].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n"))
                let n = numbers(String(pieces[1].dropLast()))
                var t = CGAffineTransform.identity
                switch (name, n.count) {
                case ("translate", 1): t = CGAffineTransform(translationX: n[0], y: 0)
                case ("translate", 2): t = CGAffineTransform(translationX: n[0], y: n[1])
                case ("scale", 1): t = CGAffineTransform(scaleX: n[0], y: n[0])
                case ("scale", 2): t = CGAffineTransform(scaleX: n[0], y: n[1])
                case ("rotate", 1): t = CGAffineTransform(rotationAngle: n[0] * .pi / 180)
                case ("rotate", 3):
                    t = CGAffineTransform(translationX: n[1], y: n[2]).rotated(by: n[0] * .pi / 180)
                        .translatedBy(x: -n[1], y: -n[2])
                case ("matrix", 6): t = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
                default: warnings.append("忽略不支持的变换 \(name)")
                }
                // SVG 列表从左到右嵌套：后面的先作用于点。
                result = t.concatenating(result)
            }
            return result
        }

        func shape(_ name: String, _ a: [String: String]) -> CGPath? {
            func num(_ k: String) -> Double { a[k].flatMap(length) ?? 0 }
            let path = CGMutablePath()
            switch name {
            case "rect":
                let w = num("width"), h = num("height")
                guard w > 0, h > 0 else { return nil }
                var rx = a["rx"].flatMap(length), ry = a["ry"].flatMap(length)
                if rx == nil { rx = ry }
                if ry == nil { ry = rx }
                let r = CGRect(x: num("x"), y: num("y"), width: w, height: h)
                if let rx, let ry, rx > 0, ry > 0 {
                    path.addRoundedRect(in: r, cornerWidth: min(rx, w / 2), cornerHeight: min(ry, h / 2))
                } else {
                    path.addRect(r)
                }
            case "circle":
                let r = num("r")
                guard r > 0 else { return nil }
                path.addEllipse(in: CGRect(x: num("cx") - r, y: num("cy") - r, width: 2 * r, height: 2 * r))
            case "ellipse":
                let rx = num("rx"), ry = num("ry")
                guard rx > 0, ry > 0 else { return nil }
                path.addEllipse(in: CGRect(x: num("cx") - rx, y: num("cy") - ry, width: 2 * rx, height: 2 * ry))
            case "line":
                path.move(to: CGPoint(x: num("x1"), y: num("y1")))
                path.addLine(to: CGPoint(x: num("x2"), y: num("y2")))
            case "polyline", "polygon":
                let n = numbers(a["points"] ?? "")
                guard n.count >= 4 else { return nil }
                path.move(to: CGPoint(x: n[0], y: n[1]))
                for i in stride(from: 2, to: n.count - 1, by: 2) { path.addLine(to: CGPoint(x: n[i], y: n[i + 1])) }
                if name == "polygon" { path.closeSubpath() }
            case "path":
                guard let d = a["d"], let p = PathData.parse(d) else { return nil }
                return p
            default:
                return nil
            }
            return path
        }
    }

    /// 数字列表（逗号或空白分隔，支持 `1.5.5`、`1-2`、指数）。
    static func numbers(_ s: String) -> [Double] {
        var scanner = PathData.Scanner(Array(s.utf8))
        var out: [Double] = []
        while let v = scanner.number() { out.append(v) }
        return out
    }

    /// 长度：只接受无单位或 px 的有限值（`inf`、`nan`、`1e400` 都不算）。
    static func length(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let body = t.hasSuffix("px") ? String(t.dropLast(2)) : t
        guard let v = Double(body), v.isFinite else { return nil }
        return v
    }

    /// 颜色（已去空白、转小写）。不认识或格式不对时返回 nil。
    static func parseColor(_ t: String) -> RGBA? {
        switch t {
        case "black": return (0, 0, 0, 1)
        case "white": return (1, 1, 1, 1)
        case "red": return (1, 0, 0, 1)
        case "green": return (0, 128.0 / 255, 0, 1)
        case "blue": return (0, 0, 1, 1)
        case "gray", "grey": return (128.0 / 255, 128.0 / 255, 128.0 / 255, 1)
        case "transparent": return (0, 0, 0, 0)
        default: break
        }
        if t.hasPrefix("#") {
            let hex = t.dropFirst()
            let digits = hex.count == 3 || hex.count == 4 ? hex.map { "\($0)\($0)" }.joined() : String(hex)
            if digits.count == 6, let n = Int(digits, radix: 16) {
                return (Double(n >> 16 & 255) / 255, Double(n >> 8 & 255) / 255, Double(n & 255) / 255, 1)
            }
            // 8 位：最后两位是 alpha。
            if digits.count == 8, digits.allSatisfy(\.isHexDigit), let n = Int(digits, radix: 16) {
                return (Double(n >> 24 & 255) / 255, Double(n >> 16 & 255) / 255, Double(n >> 8 & 255) / 255,
                        Double(n & 255) / 255)
            }
            return nil
        }
        if t.hasPrefix("rgb(") {
            // 分量是 0…255 的数字或百分比。
            var s = PathData.Scanner(Array(t.dropFirst(4).dropLast().utf8))
            var c: [Double] = []
            while let v = s.number() {
                if s.i < s.b.count, s.b[s.i] == 0x25 { s.i += 1; c.append(v / 100) } else { c.append(v / 255) }
            }
            return c.count == 3 ? (c[0], c[1], c[2], 1) : nil
        }
        return nil
    }
}

private func numbers(_ s: String) -> [Double] { RestrictedSVG.numbers(s) }
private func length(_ s: String) -> Double? { RestrictedSVG.length(s) }

/// SVG 路径数据（`d` 属性）。
enum PathData {
    struct Scanner {
        var b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        mutating func skipSeparators() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x2C || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }

        mutating func peekCommand() -> UInt8? {
            skipSeparators()
            guard i < b.count else { return nil }
            let c = b[i]
            return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ? (c == 0x65 || c == 0x45 ? nil : c) : nil
        }

        mutating func number() -> Double? {
            skipSeparators()
            let start = i
            if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
            var digits = false, dot = false
            while i < b.count {
                let c = b[i]
                if c >= 0x30 && c <= 0x39 { digits = true; i += 1 }
                else if c == 0x2E, !dot { dot = true; i += 1 }
                else { break }
            }
            if digits, i < b.count, b[i] == 0x65 || b[i] == 0x45 {
                var j = i + 1
                if j < b.count, b[j] == 0x2B || b[j] == 0x2D { j += 1 }
                if j < b.count, b[j] >= 0x30 && b[j] <= 0x39 {
                    i = j
                    while i < b.count, b[i] >= 0x30 && b[i] <= 0x39 { i += 1 }
                }
            }
            // 溢出成 inf 的（如 1e999）也算无效：后面的几何计算会得到 inf / NaN。
            guard digits, let v = Double(String(decoding: b[start..<i], as: UTF8.self)), v.isFinite else { i = start; return nil }
            return v
        }

        /// 圆弧标志位可以紧挨着写（`a1 1 0 011 1`）。
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < b.count, b[i] == 0x30 || b[i] == 0x31 else { return nil }
            defer { i += 1 }
            return b[i] == 0x31
        }
    }

    static let maxCommands = 200_000

    static func parse(_ d: String) -> CGPath? {
        var s = Scanner(Array(d.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: UInt8 = 0
        var count = 0
        var command: UInt8?
        while true {
            if let c = s.peekCommand() { command = c; s.i += 1 } else if s.i >= s.b.count { break }
            guard let cmd = command else { return nil }
            count += 1
            guard count <= maxCommands else { return nil }
            let rel = cmd >= 0x61
            func pt() -> CGPoint? {
                guard let x = s.number(), let y = s.number() else { return nil }
                return rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch cmd | 0x20 {
            case 0x6D: // m
                guard let p = pt() else { return path.isEmpty ? nil : path }
                path.move(to: p); current = p; start = p
                command = rel ? 0x6C : 0x4C // 后续坐标对按 lineto
                lastControl = nil
            case 0x6C: // l
                guard let p = pt() else { return nil }
                path.addLine(to: p); current = p; lastControl = nil
            case 0x68: // h
                guard let x = s.number() else { return nil }
                current.x = rel ? current.x + x : x
                path.addLine(to: current); lastControl = nil
            case 0x76: // v
                guard let y = s.number() else { return nil }
                current.y = rel ? current.y + y : y
                path.addLine(to: current); lastControl = nil
            case 0x63: // c
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return nil }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case 0x73: // s
                let c1 = [0x63, 0x73].contains(lastCommand | 0x20) ? reflect(lastControl, current) : current
                guard let c2 = pt(), let p = pt() else { return nil }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case 0x71: // q
                guard let c = pt(), let p = pt() else { return nil }
                path.addQuadCurve(to: p, control: c); current = p; lastControl = c
            case 0x74: // t
                let c = [0x71, 0x74].contains(lastCommand | 0x20) ? reflect(lastControl, current) : current
                guard let p = pt() else { return nil }
                path.addQuadCurve(to: p, control: c); current = p; lastControl = c
            case 0x61: // a
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(),
                      let large = s.flag(), let sweep = s.flag(), let p = pt() else { return nil }
                addArc(path, from: current, to: p, rx: abs(rx), ry: abs(ry), rotation: rot, large: large, sweep: sweep)
                current = p; lastControl = nil
            case 0x7A: // z
                path.closeSubpath(); current = start; lastControl = nil
                command = nil
                lastCommand = cmd
                continue
            default:
                return nil
            }
            lastCommand = cmd
        }
        return path
    }

    static func reflect(_ control: CGPoint?, _ current: CGPoint) -> CGPoint {
        guard let control else { return current }
        return CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
    }

    /// SVG 端点圆弧 → 中心参数化 → 每段 ≤ 90° 的三次贝塞尔（SVG 1.1 附录 F.6）。
    static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rx0: Double, ry ry0: Double,
                       rotation: Double, large: Bool, sweep: Bool) {
        guard p0 != p1 else { return }
        guard rx0 > 0, ry0 > 0 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        var rx = rx0, ry = ry0
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        // 坐标或半径极大时中间量会溢出成 inf / NaN（下面的 Int() 会崩溃）：退化成直线。
        guard rx.isFinite, ry.isFinite, cx.isFinite, cy.isFinite, theta1.isFinite, delta.isFinite else {
            path.addLine(to: p1)
            return
        }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let k = 4.0 / 3 * tan(step / 4)
        func point(_ t: Double) -> (CGPoint, CGPoint) {
            let x = rx * cos(t), y = ry * sin(t)
            let dxt = -rx * sin(t), dyt = ry * cos(t)
            let p = CGPoint(x: cosP * x - sinP * y + cx, y: sinP * x + cosP * y + cy)
            let d = CGPoint(x: cosP * dxt - sinP * dyt, y: sinP * dxt + cosP * dyt)
            return (p, d)
        }
        var t = theta1
        for _ in 0..<segments {
            let (a, da) = point(t), (b, db) = point(t + step)
            path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                          control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t += step
        }
    }
}
