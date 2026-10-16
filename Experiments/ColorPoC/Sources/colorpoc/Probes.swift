import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

// MARK: - 8. 隐式转换探针：每个框架在哪一步碰了颜色

func runProbes(_ env: Env, _ R: Results) throws {
    R.line("## 8. 隐式转换探针（P1–P11）")
    R.line()
    let fx = env.fixtures
    let ws0 = WorkingSpace.all[0]
    let p = Pipeline(ws0)

    // P1 ImageIO 解码：像素是否原样（无转换），颜色空间只是附带的标签
    R.line("### P1 ImageIO 解码是否改动像素")
    R.line()
    var rows: [[String]] = []
    let cases: [(String, FImage, Double)] = [
        ("chart_prophoto_16.tif", Chart.render(Chart.patches) { Spaces.prophoto.encoded(fromXYZ: $0) }, 65535),
        ("chart_p3_16.tif", Chart.render(Chart.patches) { Spaces.displayP3.encoded(fromXYZ: $0) }, 65535),
        ("chart_adobergb.jpg", Chart.render(Chart.patches) { Spaces.adobeRGB.encoded(fromXYZ: $0) }, 255),
        ("watermark_alpha.png", Watermark.render(), 255),
        ("hdr_float_linear2020.tif", HDRScene.render { Spaces.linear2020.fromXYZ * $0 }, 1),
        ("hdr_pq2020_203nit.png", HDRScene.render { xyz in
            let l = Spaces.linear2020.fromXYZ * xyz
            return V3(PQ.encode(nits: l.x * 203), PQ.encode(nits: l.y * 203), PQ.encode(nits: l.z * 203)) }, 65535),
    ]
    for (file, expected, scale) in cases {
        let (_, raw, info) = decodeRaw(fx.url(file))!
        var maxDiff = 0.0, maxVal: Float = 0
        for i in 0..<raw.px.count {
            if i % 4 == 3 && file != "watermark_alpha.png" { continue }
            // 透明像素：直通 alpha PNG 中 RGB 无意义，ImageIO 可能按预乘返回
            maxDiff = max(maxDiff, Double(abs(raw.px[i] - expected.px[i])) * scale)
            maxVal = max(maxVal, raw.px[i])
        }
        rows.append([file, "\(info.bitsPerComponent)\(info.isFloat ? " float" : "")", info.alpha, info.colorSpace,
                     scale == 1 ? f4(maxDiff) : f2(maxDiff), f2(Double(maxVal))])
    }
    R.table(["文件", "解码位深", "alpha", "CGImage 颜色空间", "与写入值最大差（码值；float 为绝对值）", "最大分量值"], rows)

    // P2 无 ICC 的识别
    R.line("### P2 无 ICC 文件在各层的表现")
    R.line()
    rows = []
    for file in ["chart_noicc.png", "chart_noicc.jpg", "chart_srgb.jpg"] {
        let i = fileInfo(fx.url(file))!
        let ci = CIImage(contentsOf: fx.url(file))!
        rows.append([file, i.profileName ?? "nil", i.decodedColorSpace, csName(ci.colorSpace), colorTag(fx.url(file))])
    }
    R.table(["文件", "ImageIO ProfileName", "解码 CGImage 颜色空间", "CIImage.colorSpace", "文件内颜色描述"], rows)

    // P3 降采样解码（D-18）：缩略图 API 会不会顺手把颜色/位深改掉
    R.line("### P3 降采样解码（CGImageSourceCreateThumbnailAtIndex，max 480）")
    R.line()
    rows = []
    for file in ["chart_prophoto_16.tif", "chart_p3.jpg", "hdr_float_linear2020.tif", "hdr_pq2020_203nit.png", "hdr_gainmap.jpg"] {
        let src = CGImageSourceCreateWithURL(fx.url(file) as CFURL, nil)!
        for (label, opts) in [("默认", [:] as [CFString: Any]),
                              ("ShouldAllowFloat", [kCGImageSourceShouldAllowFloat: true]),
                              ("DecodeToHDR", [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR])] {
            var o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 480]
            o.merge(opts) { $1 }
            guard let t = CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary) else { rows.append([file, label, "失败", "", ""]); continue }
            let (f, info) = readRaw(t)
            rows.append([file, label, "\(t.width)×\(t.height)", "\(info.bitsPerComponent)\(info.isFloat ? " float" : "")", info.colorSpace,
                         f2(Double(f.px.enumerated().filter { $0.offset % 4 != 3 }.map(\.element).max() ?? 0))])
        }
    }
    R.table(["文件", "选项", "尺寸", "位深", "颜色空间", "最大分量"], rows)

    // P4 背景色的几种写法
    R.line("### P4 背景色 #FAFAF8 的几种构造方式 → 8-bit sRGB PNG")
    R.line()
    rows = []
    let canvas = CGRect(x: 0, y: 0, width: 8, height: 8)
    let c = (250.0 / 255, 250.0 / 255, 248.0 / 255)
    let variants: [(String, CIColor)] = [
        ("CIColor(red:green:blue:)（未指定空间）", CIColor(red: c.0, green: c.1, blue: c.2)),
        ("CIColor(..., colorSpace: sRGB)", CIColor(red: c.0, green: c.1, blue: c.2, colorSpace: sRGB)!),
        ("CIColor(cgColor: CGColor(srgbRed:...))", CIColor(cgColor: CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))),
        ("错误：把 250/255 当 Display P3", CIColor(red: c.0, green: c.1, blue: c.2, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)!),
        ("错误：把 250/255 当线性值", CIColor(red: c.0, green: c.1, blue: c.2, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!),
    ]
    for ws in WorkingSpace.all {
        let pw = Pipeline(ws)
        for (label, color) in variants {
            let img = CIImage(color: color).cropped(to: canvas)
            let url = env.out.appendingPathComponent("probes/bg_\(ws.id)_\(rows.count).png")
            try pw.writePNG(img, to: url)
            let px = decodeRaw(url)!.1[4, 4]
            rows.append([ws.id, label, csName(color.colorSpace), "(\(code8(px.x)),\(code8(px.y)),\(code8(px.z)))"])
        }
    }
    R.table(["工作空间", "写法", "CIColor.colorSpace", "输出 PNG 像素"], rows)

    // P5 关闭 CI 色彩管理：证明转换是 CI 在渲染时做的
    R.line("### P5 Core Image 是否是唯一做 ICC 转换的组件")
    R.line()
    rows = []
    let noCM = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    for file in ["chart_prophoto_16.tif", "chart_adobergb_16.tif", "chart_srgb_16.tif"] {
        let img = CIImage(contentsOf: fx.url(file))!
        var on = FImage(w: Chart.w, h: Chart.h), off = FImage(w: Chart.w, h: Chart.h)
        var bytes = [UInt8](repeating: 0, count: Chart.w * Chart.h * 4)
        for (ctx, target) in [(p.ctx, 0), (noCM, 1)] {
            ctx.render(img, toBitmap: &bytes, rowBytes: Chart.w * 4, bounds: img.extent, format: .RGBA8, colorSpace: target == 0 ? sRGB : nil)
            var f = FImage(w: Chart.w, h: Chart.h)
            for i in 0..<bytes.count { f.px[i] = Float(bytes[i]) / 255 }
            if target == 0 { on = f } else { off = f }
        }
        let ident = Placement(canvas: CGSize(width: Chart.w, height: Chart.h), origin: .zero, scale: 1, size: CGSize(width: Chart.w, height: Chart.h))
        rows.append([file, f2(Stats(chartDeltaE(on, patches: Chart.patches, placement: ident)).median),
                     f2(Stats(chartDeltaE(off, patches: Chart.patches, placement: ident)).median)])
    }
    R.table(["输入", "CI 色彩管理开（→sRGB）ΔE 中位", "CI 色彩管理关（原值直出）ΔE 中位"], rows)

    // P6 ImageIO 编码：给它非 sRGB 的 CGImage，会不会替你转换
    R.line("### P6 ImageIO 编码器对颜色空间的处理")
    R.line()
    rows = []
    let wide = p.load(fx.url("wide_prophoto_16.tif"))
    let chart = p.load(fx.url("chart_prophoto_16.tif"))
    let encCases: [(String, CIImage, CIFormat, CGColorSpace, UTType)] = [
        ("色卡 → CGImage RGBA8 Display P3 → JPEG", chart, .RGBA8, CGColorSpace(name: CGColorSpace.displayP3)!, .jpeg),
        ("色卡 → CGImage RGBAh extendedLinearSRGB → JPEG", chart, .RGBAh, ws0.cg, .jpeg),
        ("色卡 → CGImage RGBAh extendedLinearSRGB → PNG", chart, .RGBAh, ws0.cg, .png),
        ("广色域 → CGImage RGBAh extendedLinearSRGB → PNG", wide, .RGBAh, ws0.cg, .png),
        ("广色域 → CGImage RGBAh extendedLinearSRGB → TIFF", wide, .RGBAh, ws0.cg, .tiff),
    ]
    for (label, img, fmt, cs, type) in encCases {
        let cg = p.ctx.createCGImage(img, from: img.extent, format: fmt, colorSpace: cs)!
        let url = env.out.appendingPathComponent("probes/encode_\(rows.count).\(type.preferredFilenameExtension!)")
        try writeImage(cg, to: url, type: type, properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        let info = fileInfo(url)!
        let (_, raw, rinfo) = decodeRaw(url)!
        let negatives = raw.px.enumerated().filter { $0.offset % 4 != 3 && $0.element < 0 }.count
        let over = raw.px.enumerated().filter { $0.offset % 4 != 3 && $0.element > 1 }.count
        // 读回后经 CI 转到 sRGB 的色卡 ΔE（只对色卡）
        var de = "–"
        if img === chart {
            let back = p.renderRGBA8(CIImage(contentsOf: url)!, rect: CGRect(x: 0, y: 0, width: Chart.w, height: Chart.h))
            let ident = Placement(canvas: .zero, origin: .zero, scale: 1, size: .zero)
            de = f2(Stats(chartDeltaE(back, patches: Chart.patches, placement: ident)).median)
        }
        rows.append([label, info.profileName ?? "nil", "\(rinfo.bitsPerComponent)\(rinfo.isFloat ? " float" : "")", rinfo.colorSpace,
                     "\(negatives)", "\(over)", de])
    }
    R.table(["写出方式", "文件 ICC", "文件位深", "读回颜色空间", "负值分量数", ">1 分量数", "读回→sRGB ΔE 中位"], rows)

    // P7 Core Graphics 画图时的转换与截断
    R.line("### P7 Core Graphics：把 ProPhoto 广色域图画进不同上下文")
    R.line()
    rows = []
    let wideCG = decodeRaw(fx.url("wide_prophoto_16.tif"))!.0
    let patches = WideChart.patches(in: Spaces.prophoto)
    for (label, space, half, math) in [
        ("extendedLinearSRGB half", CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, true, Spaces.linearSRGB),
        ("linearSRGB（非 extended）half", CGColorSpace(name: CGColorSpace.linearSRGB)!, true, Spaces.linearSRGB),
        ("extendedLinearITUR_2020 half", CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!, true, Spaces.linear2020),
        ("linearITUR_2020（非 extended）half", CGColorSpace(name: CGColorSpace.linearITUR_2020)!, true, Spaces.linear2020),
    ] as [(String, CGColorSpace, Bool, RGBSpace)] {
        let f = cgDraw(wideCG, into: space, half: half)
        let wsTmp = WorkingSpace(id: label, cg: space, math: math)
        let cc = clipCount(f, expected: expectedPatchValue(patches, ws: wsTmp, placement: nil, inset: 2), region: (0..<Chart.w, 0..<Chart.h))
        rows.append([label, "\(cc.expectedOutOfRange)", "\(cc.clipped)", f4(cc.maxErrInRange)])
    }
    R.table(["CGContext 颜色空间", "需 extended 像素", "被截断", "域内最大误差"], rows)

    // P8 ColorSync（经 CGColor 转换）与参考数学一致性
    R.line("### P8 ColorSync（CGColor.converted）与参考数学的一致性")
    R.line()
    rows = []
    for v in FixtureSet.iccVariants {
        let cs = CGColorSpace(name: v.cg)!
        var des: [Double] = []
        for patch in Chart.patches {
            let e = v.space.encoded(fromXYZ: patch.xyz)
            let col = CGColor(colorSpace: cs, components: [e.x, e.y, e.z, 1])!
            let conv = col.converted(to: sRGB, intent: .relativeColorimetric, options: nil)!.components!
            des.append(deltaE(srgb: V3(conv[0], conv[1], conv[2]), srgb: Spaces.srgb.encoded(fromXYZ: patch.xyz)))
        }
        let s = Stats(des)
        rows.append([v.id, f3(s.median), f3(s.max)])
    }
    let oog = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.rommrgb)!, components: [0, 1, 0, 1])!
    let toExt = oog.converted(to: extSRGB, intent: .relativeColorimetric, options: nil)!.components!
    let toStd = oog.converted(to: sRGB, intent: .relativeColorimetric, options: nil)!.components!
    let refExt = Spaces.srgb.encoded(fromXYZ: Spaces.prophoto.xyz(fromEncoded: V3(0, 1, 0)))
    R.table(["ICC", "ΔE 中位", "ΔE max"], rows)
    R.line("ProPhoto 纯绿 (0,1,0) → extendedSRGB = (\(toExt.prefix(3).map { f3(Double($0)) }.joined(separator: ", ")))，参考 (\(f3(refExt.x)), \(f3(refExt.y)), \(f3(refExt.z)))；→ sRGB = (\(toStd.prefix(3).map { f3(Double($0)) }.joined(separator: ", ")))")
    R.line()

    // P9 默认写出的元数据
    R.line("### P9 输出文件默认带了哪些元数据块")
    R.line()
    rows = []
    for (label, url) in [("CI writeJPEGRepresentation", env.outURL(ws0.id, "chart/chart_srgb.jpg")),
                         ("CI writePNGRepresentation", env.outURL(ws0.id, "chart/chart_srgb.png")),
                         ("CI JPEG + hdrImage（gain map）", env.outURL(ws0.id, "hdr/hdr_pq2020_203nit_hdr_gainmap_CI.jpg")),
                         ("ImageIO CGImageDestination JPEG", fx.url("chart_srgb.jpg"))] {
        guard let i = fileInfo(url) else { rows.append([label, "（先跑 chart/hdr）", ""]); continue }
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as? [CFString: Any] ?? [:]
        let exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any])?.keys.map { $0 as String }.sorted().joined(separator: ",") ?? "–"
        let tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",") ?? "–"
        rows.append([label, i.metadataDictionaries.joined(separator: " "), exif, tiff, colorTag(url)])
    }
    // 让 JPEG 真正嵌入 sRGB ICC 的写法：用 ICC 数据重建一个"非命名"的 CGColorSpace
    let iccSRGB = CGColorSpace(iccData: sRGB.copyICCData()!)!
    let chartImg = p.load(fx.url("chart_srgb_16.tif"))
    let viaICC = env.out.appendingPathComponent("probes/jpeg_icc_from_data_CI.jpg")
    try p.ctx.writeJPEGRepresentation(of: chartImg, to: viaICC, colorSpace: iccSRGB,
                                      options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0])
    rows.append(["CI JPEG，colorSpace = CGColorSpace(iccData: sRGB ICC)", fileInfo(viaICC)!.metadataDictionaries.joined(separator: " "), "", "",
                 colorTag(viaICC)])
    let viaICC2 = env.out.appendingPathComponent("probes/jpeg_icc_from_data_ImageIO.jpg")
    try writeImage(p.ctx.createCGImage(chartImg, from: chartImg.extent, format: .RGBA8, colorSpace: iccSRGB)!, to: viaICC2, type: .jpeg,
                   properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
    rows.append(["ImageIO JPEG，CGImage 颜色空间 = CGColorSpace(iccData: sRGB ICC)", fileInfo(viaICC2)!.metadataDictionaries.joined(separator: " "), "", "",
                 colorTag(viaICC2)])
    R.table(["写出方式", "元数据字典", "EXIF 键", "TIFF 字段", "文件内颜色描述"], rows)

    // P10 ImageIO 写 ISO gain map 的输入要求
    try probeGainMapEncode(env, R)
    // P11 HDR→SDR 的几种 tone map
    try probeToneMap(env, R)
}

/// 文件里实际写了什么颜色描述（PNG: 颜色相关块；JPEG: APP2 ICC_PROFILE；TIFF: ImageIO 读到的 ICC 名）。
func colorTag(_ url: URL) -> String {
    guard let d = try? Data(contentsOf: url) else { return "?" }
    switch url.pathExtension.lowercased() {
    case "png":
        var found: [String] = []
        var i = 8
        while i + 8 <= d.count {
            let len = d[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(bytes: d[i + 4..<i + 8], encoding: .ascii) ?? ""
            if ["iCCP", "sRGB", "gAMA", "cHRM", "cICP"].contains(type) { found.append(type) }
            if type == "IDAT" { break }
            i += 12 + len
        }
        return found.isEmpty ? "无" : found.joined(separator: "+")
    case "jpg", "jpeg":
        return d.range(of: "ICC_PROFILE".data(using: .ascii)!) != nil ? "ICC" : "无 ICC"
    default:
        return fileInfo(url)?.profileName.map { "ICC" + "（\($0)）" } ?? "无"
    }
}

func hasEmbeddedProfile(_ url: URL) -> Bool {
    let t = colorTag(url)
    return t != "无" && t != "无 ICC"
}

func probeGainMapEncode(_ env: Env, _ R: Results) throws {
    R.line("### P10 ImageIO 写 ISO gain map JPEG：输入 CGImage 的要求")
    R.line()
    R.line("源：hdr_float_linear2020.tif（峰值 8.0）。读回用 CIImage(expandToHDR) → extendedLinearSRGB，看 8.0 色块与 1.0 色块。")
    R.line()
    let p = Pipeline(WorkingSpace.all[0])
    let img = p.load(env.fixtures.url("hdr_float_linear2020.tif"))
    var rows: [[String]] = []
    let extP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
    let p3pq = CGColorSpace(name: CGColorSpace.displayP3_PQ)!
    let base = p.ctx.createCGImage(img, from: img.extent, format: .RGBAh, colorSpace: extP3)!
    let variants: [(String, CGImage, [CFString: Any])] = [
        ("extLinearP3 half，headroom 未知", base, [:]),
        ("extLinearP3 half + CGImageCreateCopyWithContentHeadroom(8)", CGImageCreateCopyWithContentHeadroom(8, base)!, [:]),
        ("extLinearP3 half + headroom 8 + BaseColorSpace=sRGB（EncodeRequestOptions 内）", CGImageCreateCopyWithContentHeadroom(8, base)!,
         [kCGImageDestinationEncodeRequestOptions: [kCGImageDestinationEncodeBaseColorSpace: sRGB]]),
        ("extLinearP3 half + headroom 8 + BaseColorSpace=sRGB（顶层）", CGImageCreateCopyWithContentHeadroom(8, base)!,
         [kCGImageDestinationEncodeBaseColorSpace: sRGB]),
        ("ITUR_2100_PQ RGBA16", p.ctx.createCGImage(img, from: img.extent, format: .RGBA16, colorSpace: pq)!, [:]),
        ("DisplayP3_PQ RGBA16", p.ctx.createCGImage(img, from: img.extent, format: .RGBA16, colorSpace: p3pq)!, [:]),
    ]
    for (label, cg, extra) in variants {
        let url = env.out.appendingPathComponent("probes/gainmap_encode_\(rows.count).jpg")
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0,
                                      kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap]
        props.merge(extra) { $1 }
        do {
            try writeImage(cg, to: url, type: .jpeg, properties: props)
            let info = fileInfo(url)!
            let back = p.load(url)
            let f = p.renderFloat(back, rect: back.extent)
            let y = neutralY(f, ws: WorkingSpace.all[0], placement: nil)
            let sdr = p.renderRGBA8(p.load(url, expandHDR: false), rect: back.extent)
            let sdrCodes = HDRScene.patches.prefix(12).map { code8(sdr[Int($0.rect.midX), Int($0.rect.midY)].y) }
            rows.append([label, f2(Double(cg.contentHeadroom)), info.hasISOGainMap ? "✅" : "❌", info.profileName ?? "nil",
                         f2(Double(back.contentHeadroom)), f2(y[4]), f2(y[11]), sdrCodes.map(String.init).joined(separator: " ")])
        } catch {
            rows.append([label, "", "写出失败 \(error)", "", "", "", "", ""])
        }
    }
    R.table(["输入 CGImage", "CGImage headroom", "ISO gain map", "底图 ICC", "读回 headroom", "读回 Y(1.0)", "读回 Y(8.0)", "SDR 底图中性色块码值"], rows)
}

func probeToneMap(_ env: Env, _ R: Results) throws {
    R.line("### P11 HDR → SDR 的几种 tone map（extLinearSRGB，8-bit sRGB 输出）")
    R.line()
    R.line("中性色块线性亮度：\(HDRScene.neutralLevels.map { f2($0) }.joined(separator: " "))。理想的摄影 SDR 版本：0.18 附近基本不动，1.0 以上逐级压缩但互相可分。")
    R.line()
    let p = Pipeline(WorkingSpace.all[0])
    var rows: [[String]] = []
    for file in ["hdr_pq2020_203nit.png", "hdr_float_linear2020.tif"] {
        let url = env.fixtures.url(file)
        let img = p.load(url)
        let hr = img.contentHeadroom > 1 ? img.contentHeadroom : Float(HDRScene.peak)
        var variants: [(String, CIImage)] = [("直接截断", img)]
        let t1 = CIFilter.toneMapHeadroom(); t1.inputImage = img; t1.sourceHeadroom = hr; t1.targetHeadroom = 1
        variants.append(("CIToneMapHeadroom(source=\(f2(Double(hr))))", t1.outputImage!))
        let sys = CIFilter.systemToneMap(); sys.inputImage = img.settingContentHeadroom(hr); sys.displayHeadroom = 1
        variants.append(("CISystemToneMap(displayHeadroom=1)", sys.outputImage!))
        variants.append(("CIImage 选项 .toneMapHDRtoSDR", CIImage(contentsOf: url, options: [.toneMapHDRtoSDR: true])!))
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR] as CFDictionary) {
            variants.append(("ImageIO DecodeToSDR", CIImage(cgImage: cg)))
        }
        for (label, v) in variants {
            let out = p.renderRGBA8(v, rect: CGRect(x: 0, y: 0, width: HDRScene.w, height: HDRScene.h))
            let codes = HDRScene.patches.prefix(12).map { code8(out[Int($0.rect.midX), Int($0.rect.midY)].y) }
            let ident = Placement(canvas: .zero, origin: .zero, scale: 1, size: .zero)
            let de = Stats(chartDeltaE(out, patches: Array(HDRScene.patches[24..<48]), placement: ident, inset: 8, stride: 4))
            rows.append([file, label, codes.map(String.init).joined(separator: " "), "\(Set(codes[4...]).count)/8", f2(de.median)])
        }
    }
    R.table(["输入", "方法", "中性色块码值（0.05 … 8.0）", "≥1.0 的 8 级可分辨数", "SDR 色卡 ΔE 中位（相对未压缩）"], rows)
}
