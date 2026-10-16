import Foundation
import Testing
import PhotoFrameCore
@testable import PhotoFrameStorage

/// 期望导入抛出某个 ZIP 层错误码；预览也必须同样拒绝。
func expectArchiveError(_ data: Data, _ code: String, limits: ArchiveLimits = .presetPackage,
                        sourceLocation: SourceLocation = #_sourceLocation) {
    for attempt in ["import", "preview"] {
        do {
            if attempt == "import" {
                _ = try PresetPackage.importPreset(data, options: .init(limits: limits))
            } else {
                _ = try PresetPackage.preview(data, options: .init(limits: limits))
            }
            Issue.record("\(attempt) 应抛出 \(code)", sourceLocation: sourceLocation)
        } catch {
            #expect(error.code == code, "\(attempt): \(error.message)", sourceLocation: sourceLocation)
        }
    }
}

func zip(_ entries: [ZipWriter.Entry], declaredCount: UInt16? = nil) -> Data {
    var w = ZipWriter()
    for e in entries { w.add(e) }
    w.declaredEntryCountOverride = declaredCount
    return w.finish()
}

let validManifest = Data(manifestJSON(makePreset()).utf8)

@Suite("恶意或损坏的 ZIP")
struct MaliciousArchiveTests {
    @Test("不是 ZIP、空文件、被截断")
    func notZip() {
        expectArchiveError(Data(), "archive.not_zip")
        expectArchiveError(Data("{\"schemaVersion\": 1}".utf8), "archive.not_zip")
        expectArchiveError(Data(repeating: 0x50, count: 4096), "archive.not_zip")
        let good = try! PresetPackage.export(makePreset())
        expectArchiveError(good.prefix(good.count - 5), "archive.not_zip")
        // 中央目录被截掉一半：EOCD 指向越界位置。
        var broken = good
        broken.replaceSubrange((broken.count - 6)..<(broken.count - 2), with: [0xFF, 0xFF, 0x00, 0x00])
        expectArchiveError(broken, "archive.corrupted")
    }

    @Test("压缩包本身过大")
    func archiveTooLarge() {
        let limits = ArchiveLimits(maxArchiveBytes: 100, maxEntryCount: 32, maxTotalUncompressedBytes: 1 << 20, maxEntryUncompressedBytes: 1 << 20)
        expectArchiveError(try! PresetPackage.export(makePreset()), "archive.too_large", limits: limits)
    }

    @Test("条目数量超过上限，包括谎报的条目数")
    func tooManyEntries() {
        let many = [ZipWriter.Entry(name: "manifest.json", data: validManifest)]
            + (0..<40).map { ZipWriter.Entry(name: "f\($0)", data: Data([1])) }
        expectArchiveError(zip(many), "archive.too_many_entries")
        expectArchiveError(zip([ZipWriter.Entry(name: "manifest.json", data: validManifest)], declaredCount: 60000),
                           "archive.too_many_entries")
    }

    @Test("路径穿越与其他不安全的路径", arguments: [
        "../manifest.json", "/etc/passwd", "a/../../b", "assets/../../x", "a\\..\\b", "C:/x", "a//b",
        "./manifest.json", "a/./b", "nul\u{0}byte", "new\nline", "..", "",
    ])
    func unsafePaths(name: String) {
        let data = zip([
            ZipWriter.Entry(name: "manifest.json", data: validManifest),
            ZipWriter.Entry(name: name, data: Data([1])),
        ])
        expectArchiveError(data, "archive.unsafe_path")
    }

    @Test("符号链接")
    func symlink() {
        let data = zip([
            ZipWriter.Entry(name: "manifest.json", data: validManifest),
            ZipWriter.Entry(name: "link", data: Data("/etc/passwd".utf8), unixMode: 0o120777),
        ])
        expectArchiveError(data, "archive.symbolic_link")
    }

    @Test("重复条目：完全同名、仅大小写不同、Unicode 规范化后相同")
    func duplicateEntries() {
        expectArchiveError(zip([
            ZipWriter.Entry(name: "manifest.json", data: validManifest),
            ZipWriter.Entry(name: "manifest.json", data: Data("{}".utf8)),
        ]), "archive.duplicate_entry")
        expectArchiveError(zip([
            ZipWriter.Entry(name: "manifest.json", data: validManifest),
            ZipWriter.Entry(name: "MANIFEST.json", data: Data("{}".utf8)),
        ]), "archive.duplicate_entry")
        expectArchiveError(zip([
            ZipWriter.Entry(name: "manifest.json", data: validManifest),
            ZipWriter.Entry(name: "caf\u{E9}", data: Data([1])),
            ZipWriter.Entry(name: "cafe\u{301}", data: Data([2])),
        ]), "archive.duplicate_entry")
    }

    @Test("ZIP 炸弹：声明的大小超过单条上限")
    func declaredEntryTooLarge() {
        let zeros = Data(count: 2 << 20)  // 2 MiB 的 0，压缩后只有几 KB
        let data = zip([ZipWriter.Entry(name: "manifest.json", data: zeros)])
        #expect(data.count < 64 << 10)
        expectArchiveError(data, "archive.entry_too_large")
    }

    @Test("ZIP 炸弹：谎报解压大小，实际解出更多")
    func lyingSize() {
        let zeros = Data(count: 50 << 20)  // 50 MiB
        let data = zip([ZipWriter.Entry(name: "manifest.json", data: zeros, uncompressedSizeOverride: 100)])
        expectArchiveError(data, "archive.size_mismatch")
    }

    @Test("解压后总大小超过上限")
    func totalTooLarge() {
        let chunk = Data(count: 1 << 20)
        let entries = [ZipWriter.Entry(name: "manifest.json", data: validManifest)]
            + (0..<9).map { ZipWriter.Entry(name: "pad\($0)", data: chunk) }
        expectArchiveError(zip(entries), "archive.total_size_too_large")
    }

    @Test("CRC 不符、加密、未知压缩方式、本地头文件名不一致")
    func otherCorruption() {
        expectArchiveError(zip([ZipWriter.Entry(name: "manifest.json", data: validManifest, crc32Override: 0xDEAD_BEEF)]),
                           "archive.checksum_mismatch")
        expectArchiveError(zip([ZipWriter.Entry(name: "manifest.json", data: validManifest, flagsOverride: 1)]),
                           "archive.unsupported_feature")
        expectArchiveError(zip([ZipWriter.Entry(name: "manifest.json", data: validManifest, compress: false, methodOverride: 12)]),
                           "archive.unsupported_feature")
        expectArchiveError(zip([ZipWriter.Entry(name: "manifest.json", data: validManifest, localNameOverride: "manifest.jsoX")]),
                           "archive.corrupted")
    }

    @Test("缺少 manifest.json，或 manifest 不在根目录")
    func missingManifest() {
        expectArchiveError(zip([ZipWriter.Entry(name: "readme.txt", data: Data([1]))]), "package.missing_manifest")
        expectArchiveError(zip([ZipWriter.Entry(name: "sub/manifest.json", data: validManifest)]), "package.missing_manifest")
        expectArchiveError(zip([]), "package.missing_manifest")
    }
}
