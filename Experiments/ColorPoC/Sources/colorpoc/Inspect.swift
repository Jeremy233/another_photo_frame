import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd

// MARK: - inspect：检查用户导出的样本是否符合测试要求（不写任何文件）

func inspect(_ urls: [URL]) {
    let exts = Set(["jpg", "jpeg", "tif", "tiff", "png"])
    var files: [URL] = []
    for u in urls {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
            files += (FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
                .filter { exts.contains($0.pathExtension.lowercased()) }
        } else { files.append(u) }
    }
    let ctx = CIContext(options: [.workingColorSpace: WorkingSpace.all[2].cg, .workingFormat: CIFormat.RGBAh.rawValue])
    for url in files.sorted(by: { $0.path < $1.path }) {
        print("== \(url.lastPathComponent)  (\(String(format: "%.1f", Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1e6)) MB)")
        guard let info = fileInfo(url) else { print("   ImageIO 无法读取"); continue }
        print("   格式 \(info.type)  \(info.width)×\(info.height)  位深 \(info.depth ?? 0)\(info.isFloat == true ? " float" : "")  alpha \(info.hasAlpha ?? false)  EXIF 方向 \(info.orientation ?? 1)")
        print("   ICC: ProfileName=\(info.profileName ?? "nil")  文件内=\(colorTag(url))  解码 CGImage=\(info.decodedColorSpace)")
        if let sub = info.jpegSubsampling { print("   JPEG 采样 \(sub)") }
        print("   元数据块 \(info.metadataDictionaries.joined(separator: " "))")
        if let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.range(of: "c2pa".data(using: .ascii)!) != nil {
            print("   含 Content Credentials（C2PA）数据")
        }
        // gain map
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            for (label, key) in [("ISO 21496-1", kCGImageAuxiliaryDataTypeISOGainMap), ("Apple", kCGImageAuxiliaryDataTypeHDRGainMap)] {
                guard let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, key) as? [String: Any] else { continue }
                let desc = aux[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any] ?? [:]
                let fmt = (desc["PixelFormat"] as? UInt32).map { f in String(bytes: [24, 16, 8, 0].map { UInt8((f >> $0) & 0xff) }, encoding: .ascii) ?? "?" } ?? "?"
                var meta: [String] = []
                if let m = aux[kCGImageAuxiliaryDataInfoMetadata as String] {
                    for t in (CGImageMetadataCopyTags(m as! CGImageMetadata) as? [CGImageMetadataTag]) ?? [] {
                        let n = CGImageMetadataTagCopyName(t)! as String
                        if ["BaseHeadroom", "AlternateHeadroom", "HDRCapacityMax", "HDRCapacityMin", "BaseRenditionIsHDR", "Version"].contains(n) {
                            meta.append("\(n)=\(CGImageMetadataTagCopyValue(t)!)")
                        }
                    }
                }
                print("   gain map（\(label)）\(desc["Width"] ?? "?")×\(desc["Height"] ?? "?") \(fmt)  \(meta.joined(separator: " "))")
            }
        }
        // HDR 展开后的统计（降采样到长边 1500 后在 extended linear Rec.2020 中统计）
        guard let hdr = CIImage(contentsOf: url, options: [.expandToHDR: true, .applyOrientationProperty: true]) else { continue }
        let e = hdr.extent
        let s = min(1, 1500 / max(e.width, e.height))
        let small = hdr.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let r = small.extent.integral
        let w = Int(r.width), h = Int(r.height)
        var f = FImage(w: w, h: h)
        f.px.withUnsafeMutableBytes { ctx.render(small, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: WorkingSpace.all[2].cg) }
        var over = 0, maxY = 0.0, negS = 0, negP3 = 0, neg2020 = 0
        var ys: [Double] = []
        for y in 0..<h {
            for x in 0..<w {
                let v = f.rgb(x, y)
                let xyz = Spaces.linear2020.toXYZ * v
                ys.append(xyz.y); maxY = max(maxY, xyz.y)
                if xyz.y > 1.001 { over += 1 }
                if (Spaces.linearSRGB.fromXYZ * xyz).min() < -1e-3 { negS += 1 }
                if (Spaces.linearP3.fromXYZ * xyz).min() < -1e-3 { negP3 += 1 }
                if v.min() < -1e-3 { neg2020 += 1 }
            }
        }
        let st = Stats(ys), n = Double(w * h)
        print("   展开后：CIImage 空间 \(csName(hdr.colorSpace))  contentHeadroom \(f2(Double(hdr.contentHeadroom)))")
        print("   亮度 Y：中位 \(f3(st.median))  P95 \(f3(st.p95))  最大 \(f2(maxY))  >1（高于 SDR 白）像素 \(String(format: "%.2f%%", 100 * Double(over) / n))")
        print("   超出色域（有负分量）：sRGB \(String(format: "%.2f%%", 100 * Double(negS) / n))  P3 \(String(format: "%.2f%%", 100 * Double(negP3) / n))  Rec.2020 \(String(format: "%.2f%%", 100 * Double(neg2020) / n))")
    }
}

// MARK: - compare：两张图（都按 SDR 读取，不展开 gain map）缩到长边 1200 后在 sRGB 8-bit 下比较 ΔE2000

func compareSDR(_ a: URL, _ b: URL) {
    let p = Pipeline(WorkingSpace.all[2])
    func render(_ u: URL) -> FImage {
        let img = p.load(u, expandHDR: false)
        let e = img.extent
        let s = 1200 / max(e.width, e.height)
        let rect = CGRect(x: 0, y: 0, width: (e.width * s).rounded(), height: (e.height * s).rounded())
        let small = p.scaled(img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).clampedToExtent(), by: s).cropped(to: rect)
        return p.renderRGBA8(small, rect: rect)
    }
    let fa = render(a), fb = render(b)
    guard fa.w == fb.w, fa.h == fb.h else { print("尺寸不同：\(fa.w)×\(fa.h) vs \(fb.w)×\(fb.h)"); return }
    var de: [Double] = [], dl: [Double] = []
    for y in 0..<fa.h { for x in 0..<fa.w {
        let la = lab(fromXYZ: Spaces.srgb.xyz(fromEncoded: fa.rgb(x, y))), lb = lab(fromXYZ: Spaces.srgb.xyz(fromEncoded: fb.rgb(x, y)))
        de.append(deltaE2000(la, lb)); dl.append(la.x - lb.x)
    } }
    let s = Stats(de), l = Stats(dl)
    print("\(a.lastPathComponent) vs \(b.lastPathComponent)：ΔE 中位 \(f2(s.median)) / P95 \(f2(s.p95)) / max \(f2(s.max))；ΔL* 中位 \(f2(l.median))")
}
