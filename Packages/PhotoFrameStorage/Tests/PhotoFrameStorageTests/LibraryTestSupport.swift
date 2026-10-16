import CoreGraphics
import Foundation
import ImageIO
import PhotoFrameCore
@testable import PhotoFrameStorage

// 测试素材全部在代码里生成，不使用任何真实照片或个人素材。

/// 每个测试一个临时根目录，用完删除。
final class TempRoot {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appending(path: "PhotoFrameStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // 恢复可能被测试改成只读的目录权限，再删除。
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in e { chmod(item.path, 0o755) }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func library() -> LocalLibrary { LocalLibrary(root: url, platforms: testCatalog) }

    /// 目录下所有文件（含隐藏文件）的相对路径。
    func allFiles() -> [String] {
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        var out: [String] = []
        while let item = e?.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(String(item.resolvingSymlinksInPath().path.dropFirst(url.path.count + 1)))
            }
        }
        return out.sorted()
    }
}

let testCatalog = try! PlatformCatalogStore.builtIn()

func samplePreset(name: String = "My Landscape", id: UUID = UUID(), slots: [AssetSlot]? = nil) -> ExportPreset {
    ExportPreset(
        presetId: id,
        name: name,
        platform: "instagram",
        canvas: CanvasSettings(width: 1080, height: 1440),
        layers: [
            OverlayLayer(layerId: "badge", type: .cameraBadge, slotId: "camera.badge"),
            OverlayLayer(layerId: "sig", type: .asset, slotId: "signature"),
        ],
        assetSlots: slots ?? [
            AssetSlot(slotId: "camera.badge", required: false, label: "相机线稿"),
            AssetSlot(slotId: "signature", required: true, acceptedFormats: [.png, .svg]),
        ])
}

// MARK: - 生成 PNG

/// 用 CoreGraphics 画一个纯色 PNG。
func makePNG(width: Int = 32, height: Int = 16, red: CGFloat = 0.2) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: red, green: 0.4, blue: 0.6, alpha: 0.8)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(dest))
    return out as Data
}

/// 手工拼 PNG：用来构造尺寸谎报、压缩炸弹、动画等恶意文件。CRC 都是正确的。
enum PNGBuilder {
    static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        let crc = CRC32.checksum(Data(typeBytes + body))
        return be32(UInt32(body.count)) + typeBytes + body + be32(crc)
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    static func ihdr(width: UInt32, height: UInt32, bitDepth: UInt8 = 8, colorType: UInt8 = 6) -> [UInt8] {
        chunk("IHDR", be32(width) + be32(height) + [bitDepth, colorType, 0, 0, 0])
    }

    /// zlib 包装（头 + raw deflate + 假 Adler-32）。
    static func zlib(_ raw: Data) -> [UInt8] {
        // 太小压不动时用一个 stored 块（BFINAL=1, BTYPE=00）。
        let deflate = Deflate.compress(raw).map { [UInt8]($0) } ?? {
            let n = UInt16(raw.count)
            return [0x01, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8(~n >> 8)] + [UInt8](raw)
        }()
        return [0x78, 0x9C] + deflate + [0, 0, 0, 0]
    }

    static func png(_ chunks: [[UInt8]]) -> Data {
        Data(AssetValidator.pngSignature + chunks.flatMap { $0 } + chunk("IEND", []))
    }
}

// MARK: - 生成 SVG

func svg(_ body: String = ##"<rect x="0" y="0" width="10" height="10" fill="#000"/>"##,
         attributes: String = #"viewBox="0 0 120 40""#) -> Data {
    Data(#"<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" \#(attributes)>\#(body)</svg>"#.utf8)
}
