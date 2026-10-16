import CoreGraphics
import Foundation
import ImageIO
import PhotoFrameCore
import PhotoFrameStorage
import Testing
import UniformTypeIdentifiers
@testable import PhotoFrameCLI

/// 纯色 PNG 素材（代码合成）。
func writeSolidPNG(_ url: URL, width: Int, height: Int, rgb: (CGFloat, CGFloat, CGFloat)) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: space, components: [rgb.0, rgb.1, rgb.2, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { throw TestFailure("写出 \(url.lastPathComponent) 失败") }
}

/// 解码成 sRGB 8-bit，数满足条件的像素。
func countPixels(_ url: URL, where match: (UInt8, UInt8, UInt8) -> Bool) throws -> Int {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw TestFailure("无法解码 \(url.lastPathComponent)")
    }
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var n = 0
    for i in stride(from: 0, to: bytes.count, by: 4) where match(bytes[i], bytes[i + 1], bytes[i + 2]) { n += 1 }
    return n
}

func isGreen(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { g > 180 && r < 90 && b < 90 }

/// 带一个必需签名槽的预设：签名在照片下方居右，120×40。
func signedPreset(name: String = "Signed Portrait") -> ExportPreset {
    ExportPreset(
        name: name, platform: "instagram",
        canvas: CanvasSettings(width: 1080, height: 1440, background: .defaultBackground, minMarginPx: 60, mode: .fit),
        layers: [OverlayLayer(layerId: "sig", type: .asset, sizePx: PixelSize(width: 120, height: 40), slotId: "signature")],
        assetSlots: [AssetSlot(slotId: "signature", required: true, acceptedFormats: [.png, .svg])])
}

@Suite("preset / asset 命令")
struct LibraryCommandTests {
    @Test("preset：导入（副本 / 替换）、列出、导出、复制、重命名、删除")
    func presetCommands() async throws {
        let box = try Sandbox()
        let preset = signedPreset()
        try PresetPackage.export(preset, to: box.root.appending(path: "Signed.photoframe"))

        let first = await runCLI(["preset", "import", "Signed.photoframe", "--json"], in: box.root)
        #expect(first.status == 0, "\(first.stderr.value)")
        let imported = try #require(try first.stdout.json()["preset"] as? [String: Any])
        #expect(imported["presetId"] as? String == preset.presetId.uuidString)
        #expect(imported["origin"] as? String == "imported" && imported["readOnly"] as? Bool == false)

        let copy = await runCLI(["preset", "import", "Signed.photoframe"], in: box.root)
        #expect(copy.status == 0)
        #expect(copy.stdout.value.contains("Signed Portrait Copy"))
        #expect(copy.stderr.value.contains("副本"))
        let replaced = try await runCLI(["preset", "import", "Signed.photoframe", "--replace", "--json"], in: box.root).stdout.json()
        #expect(replaced["conflictResolution"] as? String == "replace")

        let list = await runCLI(["preset", "list"], in: box.root)
        let slugs = list.stdout.lines.map { String($0.split(separator: " ")[0]) }
        #expect(Array(slugs.prefix(6)) == ["instagram-standard", "instagram-panorama", "xhs-standard", "xhs-panorama", "douyin-standard", "douyin-panorama"])
        #expect(Set(slugs.dropFirst(6)) == ["signed-portrait", "signed-portrait-copy"])
        #expect(list.stdout.lines.last?.contains("imported") == true)

        // 导出：目标是目录时用预设名作文件名；已存在时要 --overwrite。
        try FileManager.default.createDirectory(at: box.root.appending(path: "out"), withIntermediateDirectories: true)
        let exported = await runCLI(["preset", "export", "signed-portrait", "-o", "out"], in: box.root)
        #expect(exported.stdout.lines == [box.root.appending(path: "out/Signed Portrait.photoframe").path])
        let again = await runCLI(["preset", "export", "signed-portrait", "-o", "out", "--json"], in: box.root)
        #expect(again.status == PhotoFrameExitCode.outputUnavailable.rawValue)
        #expect((try again.stdout.json()["error"] as? [String: Any])?["code"] as? String == "preset.export_exists")
        #expect(await runCLI(["preset", "export", "signed-portrait", "-o", "out", "--overwrite"], in: box.root).status == 0)
        #expect(await runCLI(["preset", "export", "xhs-standard", "-o", "out/xhs.photoframe"], in: box.root).status == 0)

        // 分组移动（D-94）。
        let moved = try await runCLI(["preset", "move", "signed-portrait-copy", "--to", "user", "--json"], in: box.root).stdout.json()
        #expect((moved["preset"] as? [String: Any])?["origin"] as? String == "user")
        let back = await runCLI(["preset", "move", "signed-portrait-copy", "--to", "imported"], in: box.root)
        #expect(back.status == 0 && back.stdout.value.contains("Signed Portrait Copy"))
        let builtInMove = await runCLI(["preset", "move", "xhs-standard", "--to", "user", "--json"], in: box.root)
        #expect(builtInMove.status == PhotoFrameExitCode.invalidInput.rawValue)
        #expect((try builtInMove.stdout.json()["error"] as? [String: Any])?["code"] as? String == "library.builtin_read_only")
        #expect(await runCLI(["preset", "move", "signed-portrait-copy", "--to", "builtIn"], in: box.root).status == PhotoFrameExitCode.usage.rawValue)
        #expect(await runCLI(["preset", "move", "Signed.photoframe", "--to", "user"], in: box.root).status == PhotoFrameExitCode.invalidInput.rawValue)

        let dup = await runCLI(["preset", "duplicate", "xhs-standard", "--name", "Square White"], in: box.root)
        #expect(dup.status == 0 && dup.stdout.value.contains("Square White"))
        #expect(await runCLI(["preset", "rename", "square-white", "Square Gray"], in: box.root).status == 0)
        let builtIn = await runCLI(["preset", "delete", "xhs-standard"], in: box.root)
        #expect(builtIn.status == PhotoFrameExitCode.invalidInput.rawValue)
        #expect(builtIn.stderr.value.contains("library.builtin_read_only"))
        #expect(await runCLI(["preset", "delete", "Square Gray"], in: box.root).status == 0)
        let missing = await runCLI(["preset", "delete", "Square Gray"], in: box.root)
        #expect(missing.status == PhotoFrameExitCode.notFound.rawValue)

        // 同名两个预设：按名称引用报歧义，按 ID 可以。
        #expect(await runCLI(["preset", "rename", "signed-portrait-copy", "Signed Portrait"], in: box.root).status == 0)
        let ambiguous = await runCLI(["preset", "export", "signed portrait", "-o", "x.photoframe"], in: box.root)
        #expect(ambiguous.status == PhotoFrameExitCode.invalidInput.rawValue)
        #expect(ambiguous.stderr.value.contains("library.ambiguous_preset"))
        #expect(await runCLI(["preset", "export", preset.presetId.uuidString, "-o", "x.photoframe"], in: box.root).status == 0)
    }

    @Test("asset：导入、列出、重命名、绑定、删除（绑定保留并提示）")
    func assetCommands() async throws {
        let box = try Sandbox()
        try writeSolidPNG(box.root.appending(path: "sig.png"), width: 120, height: 40, rgb: (0, 1, 0))
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>"#.utf8)
            .write(to: box.root.appending(path: "badge.svg"))
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><script/></svg>"#.utf8)
            .write(to: box.root.appending(path: "evil.svg"))

        let png = await runCLI(["asset", "import", "sig.png", "--category", "signature", "--name", "Green Sig"], in: box.root)
        #expect(png.status == 0, "\(png.stderr.value)")
        let pngId = try #require(png.stdout.lines.first)
        let svg = try await runCLI(["asset", "import", "badge.svg", "--category", "camera-badge", "--json"], in: box.root).stdout.json()
        let svgAsset = try #require(svg["asset"] as? [String: Any])
        #expect(svgAsset["format"] as? String == "svg" && svgAsset["category"] as? String == "camera-badge")
        let evil = await runCLI(["asset", "import", "evil.svg", "--category", "watermark"], in: box.root)
        #expect(evil.status == PhotoFrameExitCode.invalidInput.rawValue && evil.stderr.value.contains("asset.svg_rejected"))
        let dupe = await runCLI(["asset", "import", "sig.png", "--category", "signature"], in: box.root)
        #expect(dupe.stderr.value.contains(pngId))

        let list = try await runCLI(["asset", "list", "--category", "signature", "--json"], in: box.root).stdout.json()
        let assets = try #require(list["assets"] as? [[String: Any]])
        #expect(assets.count == 2)
        #expect(assets.allSatisfy { $0["path"] == nil })
        #expect(await runCLI(["asset", "list"], in: box.root).stdout.lines.count == 3)

        #expect(await runCLI(["asset", "rename", "green sig", "Signature"], in: box.root).status == 0)
        // 改分组（D-95）。
        let recat = try await runCLI(["asset", "set-category", "Signature", "watermark", "--json"], in: box.root).stdout.json()
        #expect((recat["asset"] as? [String: Any])?["category"] as? String == "watermark")
        #expect(await runCLI(["asset", "list", "--category", "watermark"], in: box.root).stdout.lines.count == 1)
        #expect(await runCLI(["asset", "set-category", "Signature", "logo"], in: box.root).status == PhotoFrameExitCode.usage.rawValue)
        #expect(await runCLI(["asset", "set-category", "nope", "watermark"], in: box.root).status == PhotoFrameExitCode.notFound.rawValue)
        #expect(await runCLI(["asset", "bind", "Signature", "--slot", "signature"], in: box.root).status == 0)
        let badSlot = await runCLI(["asset", "bind", "Signature", "--slot", "signature", "--preset", "xhs-standard"], in: box.root)
        #expect(badSlot.status == PhotoFrameExitCode.invalidInput.rawValue && badSlot.stderr.value.contains("binding.unknown_slot"))
        let bindings = try await runCLI(["asset", "bindings", "--json"], in: box.root).stdout.json()
        let rows = try #require(bindings["bindings"] as? [[String: Any]])
        #expect(rows.count == 1 && rows[0]["scope"] as? String == "default" && rows[0]["assetId"] as? String == pngId)

        let deleted = await runCLI(["asset", "delete", pngId], in: box.root)
        #expect(deleted.status == 0)
        #expect(deleted.stderr.value.contains("binding.asset_deleted"))
        #expect(await runCLI(["asset", "delete", pngId], in: box.root).status == PhotoFrameExitCode.notFound.rawValue)
        #expect(await runCLI(["asset", "unbind", "--slot", "signature"], in: box.root).status == 0)
        #expect(await runCLI(["asset", "bindings"], in: box.root).stdout.value.isEmpty)
    }

    @Test("端到端：导入素材 → 绑定 → 用带素材槽的预设导出 → 成品里有图层")
    func assetOverlayEndToEnd() async throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 1200, height: 800)
        try writeSolidPNG(box.root.appending(path: "sig.png"), width: 120, height: 40, rgb: (0, 1, 0))
        try PresetPackage.export(signedPreset(), to: box.root.appending(path: "Signed.photoframe"))
        let export = ["export", "Badlands.jpg", "--preset", "signed-portrait", "-o", "Exports"]

        #expect(await runCLI(["preset", "import", "Signed.photoframe"], in: box.root).status == 0)
        let assetId = try #require(await runCLI(["asset", "import", "sig.png", "--category", "signature"], in: box.root).stdout.lines.first)

        // 还没绑定：必需素材缺失，校验阶段就失败，什么都不写。
        let unbound = await runCLI(export, in: box.root)
        #expect(unbound.status == PhotoFrameExitCode.invalidInput.rawValue)
        #expect(unbound.stderr.value.contains("slot.missing_required"))
        #expect(!FileManager.default.fileExists(atPath: box.exports.path))

        // 单任务绑定（--bind）。
        let once = await runCLI(export + ["--bind", "signature=\(assetId)"], in: box.root)
        #expect(once.status == 0, "\(once.stderr.value)")
        let onceFile = URL(filePath: try #require(once.stdout.lines.first))
        #expect(try countPixels(onceFile, where: isGreen) > 120 * 40 * 8 / 10)

        // 预设本地绑定，之后不用 --bind。
        #expect(await runCLI(["asset", "bind", assetId, "--slot", "signature", "--preset", "signed-portrait"], in: box.root).status == 0)
        let bound = await runCLI(export + ["--json"], in: box.root)
        #expect(bound.status == 0, "\(bound.stderr.value)")
        let job = try #require((try bound.stdout.json()["jobs"] as? [[String: Any]])?.first)
        let output = try #require((job["outputs"] as? [[String: Any]])?.first)
        let file = URL(filePath: try #require(output["path"] as? String))
        #expect(output["width"] as? Int == 1080 && output["height"] as? Int == 1440)
        let green = try countPixels(file, where: isGreen)
        #expect(green > 120 * 40 * 8 / 10 && green < 120 * 40 * 12 / 10, "绿色签名应约 4800 像素：\(green)")

        // 对照：没有图层的内置预设导出里没有绿色。
        let plain = await runCLI(["export", "Badlands.jpg", "--preset", "instagram-standard", "-o", "Exports"], in: box.root)
        #expect(try countPixels(URL(filePath: try #require(plain.stdout.lines.first)), where: isGreen) == 0)

        // 预览走同一条管线，同样画出签名。
        let preview = await runCLI(["preview", "Badlands.jpg", "--preset", "signed-portrait", "-o", "p", "--max-edge", "1440"], in: box.root)
        #expect(preview.status == 0)
        #expect(try countPixels(URL(filePath: try #require(preview.stdout.lines.first)), where: isGreen) > 120 * 40 * 8 / 10)
    }
}
