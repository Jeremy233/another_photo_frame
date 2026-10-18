import Foundation
import Testing
import PhotoFrameCore
@testable import PhotoFrameStorage

private func code(_ body: () throws(LibraryError) -> Void) -> String? {
    do {
        try body()
        return nil
    } catch {
        return error.code
    }
}

@Suite("素材库")
struct AssetLibraryTests {
    let root = TempRoot()
    var assets: AssetLibrary { root.library().assets }

    @Test("从文件导入：复制进库，源文件删掉后仍可用")
    func importFromFile() throws {
        let source = root.url.appending(path: "incoming/Signature Black.png")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let png = makePNG(width: 50, height: 20)
        try png.write(to: source)

        let result = try assets.importAsset(fileAt: source, category: .signature)
        let info = result.asset
        #expect(info.displayName == "Signature Black")
        #expect(info.format == .png && info.category == .signature)
        #expect(info.pixelSize == PixelSize(width: 50, height: 20))
        #expect(info.byteCount == png.count)
        #expect(info.sha256.count == 64)
        #expect(result.duplicateOf.isEmpty)

        try FileManager.default.removeItem(at: source)
        let url = try #require(assets.contentURL(for: info.assetId))
        #expect(url.path.hasPrefix(assets.directory.path))
        #expect(try Data(contentsOf: url) == png)
        #expect(assets.asset(withId: info.assetId) == info.record)
        // 库里只有素材目录，没有残留的临时文件。
        #expect(root.allFiles().filter { $0.hasPrefix("Assets/") } == [
            "Assets/\(info.assetId.uuidString)/asset.json", "Assets/\(info.assetId.uuidString)/content.png",
        ])
    }

    @Test("元信息不含路径，可以直接给 MCP")
    func metadataHasNoPaths() throws {
        let info = try assets.importAsset(makePNG(), format: .png, category: .watermark, displayName: "wm").asset
        let json = String(decoding: try JSONEncoder().encode(assets.list().assets), as: UTF8.self)
        #expect(!json.contains(root.url.path))
        #expect(!json.contains("/Users/"))
        #expect(json.contains(info.assetId.uuidString))
    }

    @Test("按分组列出、重命名、改分组、删除")
    func manage() throws {
        let a = try assets.importAsset(makePNG(red: 0.1), format: .png, category: .cameraBadge, displayName: "Z8").asset
        let b = try assets.importAsset(svg(), format: .svg, category: .signature, displayName: "b").asset
        let c = try assets.importAsset(makePNG(red: 0.9), format: .png, category: .signature, displayName: "A").asset
        #expect(assets.list().assets.map(\.assetId) == [c.assetId, b.assetId, a.assetId])
        #expect(assets.list(category: .signature).assets.count == 2)
        #expect(assets.list().assets(in: .cameraBadge).map(\.displayName) == ["Z8"])

        let renamed = try assets.rename(a.assetId, to: "Nikon Z8")
        #expect(renamed.displayName == "Nikon Z8" && renamed.importedAt == a.importedAt)
        try assets.setCategory(b.assetId, to: .watermark)
        #expect(assets.list(category: .watermark).assets.map(\.assetId) == [b.assetId])
        #expect(code { () throws(LibraryError) in _ = try assets.rename(a.assetId, to: " ") } == "library.invalid_name")

        try assets.delete(c.assetId)
        #expect(assets.asset(withId: c.assetId) == nil)
        #expect(assets.contentURL(for: c.assetId) == nil)
        #expect(code { () throws(LibraryError) in try assets.delete(c.assetId) } == "asset.not_found")
        #expect(assets.list().assets.count == 2)
        #expect(!root.allFiles().contains { $0.contains(c.assetId.uuidString) })
    }

    @Test("重复导入相同内容：仍然导入，并指出重复")
    func duplicates() throws {
        let png = makePNG()
        let first = try assets.importAsset(png, format: .png, category: .signature, displayName: "a").asset
        let second = try assets.importAsset(png, format: .png, category: .watermark, displayName: "b")
        #expect(second.duplicateOf == [first.assetId])
        #expect(second.asset.assetId != first.assetId)
    }

    @Test("被拒绝的素材不进库", arguments: ["png", "svg"])
    func rejectedLeavesNothing(ext: String) throws {
        let source = root.url.appending(path: "bad.\(ext)")
        try Data(#"<svg><script>alert(1)</script></svg>"#.utf8).write(to: source)
        let c = code { () throws(LibraryError) in _ = try assets.importAsset(fileAt: source, category: .signature) }
        #expect(c == (ext == "png" ? "asset.type_mismatch" : "asset.svg_rejected"))
        #expect(assets.list().assets.isEmpty)
        #expect(!root.allFiles().contains { $0.hasPrefix("Assets/") && !$0.hasPrefix("Assets/.staging") })
    }

    @Test("超大文件读之前就拒绝；不是普通文件拒绝")
    func fileChecks() throws {
        let lib = AssetLibrary(root: root.url, limits: AssetImportLimits(
            maxPNGBytes: 100, maxSVGBytes: 100, maxDimension: 64, maxPixelCount: 4096, maxSVGElements: 10, maxSVGDepth: 4))
        let big = root.url.appending(path: "big.png")
        try makePNG(width: 60, height: 60).write(to: big)
        #expect(code { () throws(LibraryError) in _ = try lib.importAsset(fileAt: big, category: .signature) } == "asset.too_large")
        let dir = root.url.appending(path: "folder.png")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(code { () throws(LibraryError) in _ = try lib.importAsset(fileAt: dir, category: .signature) } == "library.io")
        #expect(code { () throws(LibraryError) in _ = try lib.importAsset(fileAt: root.url.appending(path: "x.gif"), category: .signature) } == "asset.unsupported_type")
    }

    @Test("元信息损坏、内容丢失或被改动的素材：跳过并警告，查不到")
    func damagedAssets() throws {
        let ok = try assets.importAsset(makePNG(red: 0.1), format: .png, category: .signature, displayName: "ok").asset
        let corrupt = try assets.importAsset(makePNG(red: 0.2), format: .png, category: .signature, displayName: "corrupt").asset
        let missing = try assets.importAsset(makePNG(red: 0.3), format: .png, category: .signature, displayName: "missing").asset
        let tampered = try assets.importAsset(svg(), format: .svg, category: .signature, displayName: "tampered").asset

        try Data("{".utf8).write(to: assets.assetDirectory(corrupt.assetId).appending(path: "asset.json"))
        try FileManager.default.removeItem(at: assets.contentFile(missing.assetId, .png))
        try Data(#"<svg viewBox="0 0 1 1"><script/></svg>"#.utf8).write(to: assets.contentFile(tampered.assetId, .svg))
        try FileManager.default.createDirectory(at: assets.directory.appending(path: ".staging/leftover"), withIntermediateDirectories: true)

        let listing = assets.list()
        #expect(listing.assets.map(\.assetId) == [ok.assetId])
        let codes = Dictionary(uniqueKeysWithValues: listing.warnings.map { ($0.item, $0.code) })
        #expect(codes == [
            corrupt.assetId.uuidString: "asset.unreadable_metadata",
            missing.assetId.uuidString: "asset.missing_file",
            tampered.assetId.uuidString: "asset.size_mismatch",
        ])
        for id in [corrupt.assetId, missing.assetId, tampered.assetId] {
            #expect(assets.asset(withId: id) == nil)
            #expect(assets.contentURL(for: id) == nil)
        }
        #expect(code { () throws(LibraryError) in _ = try assets.info(corrupt.assetId) } == "library.unreadable_item")
        // 损坏的也能删除。
        try assets.delete(corrupt.assetId)
        #expect(assets.list().warnings.count == 2)
    }

    @Test("asset.json 会超过读取上限时（SVG 里有大量不同的未支持元素，提示很长）：拒绝导入，什么都不写")
    func oversizedMetadata() throws {
        let body = (0..<20_000).map { "<unsupported\($0)/>" }.joined() + #"<rect width="1" height="1"/>"#
        let data = svg(body)
        #expect(try AssetValidator.validate(data, format: .svg).warnings.count == 20_000)
        do {
            _ = try assets.importAsset(data, format: .svg, category: .signature, displayName: "many")
            Issue.record("应拒绝导入")
        } catch {
            #expect(error.code == "library.io")
            #expect(error.message.hasPrefix("读写文件失败：写入 asset.json 失败："))
            #expect(error.message.hasSuffix("超过上限 \(AssetLibrary.maxMetadataBytes) 字节"))
        }
        let listing = assets.list()
        #expect(listing.assets.isEmpty && listing.warnings.isEmpty)
        #expect(root.allFiles().isEmpty)

        // 提示少一些的同类 SVG 照常导入、能读回来。
        let fewer = svg((0..<100).map { "<unsupported\($0)/>" }.joined() + #"<rect width="1" height="1"/>"#)
        let info = try assets.importAsset(fewer, format: .svg, category: .signature, displayName: "fewer").asset
        #expect(info.importWarnings.count == 100)
        #expect(try assets.info(info.assetId) == info)
    }

    @Test("重新校验已入库的素材")
    func revalidate() throws {
        let info = try assets.importAsset(svg(#"<text>x</text><rect width="1" height="1"/>"#), format: .svg,
                                          category: .watermark, displayName: "w").asset
        #expect(info.importWarnings.count == 1)
        #expect(try assets.revalidate(info.assetId).count == 1)
    }
}
