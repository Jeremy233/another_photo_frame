import CoreImage
import Darwin
import Foundation
import PhotoFrameCore
@testable import PhotoFrameRendering
import Testing

/// D-129：不在内置磁盘上的源图先复制到本机再解码。
@Suite("源图暂存到本机")
struct SourceStagingTests {
    /// 不管源图在哪个卷上都复制（在内置磁盘的临时目录里测试复制、复用、校验）。
    static func forced(_ root: URL, byteLimit: Int64 = 2 << 30, available: Int64? = nil) -> SourceStaging {
        SourceStaging(root: root, byteLimit: byteLimit, needsStaging: { _ in true }, availableBytes: { _ in available })
    }

    static func never(_ root: URL) -> SourceStaging {
        SourceStaging(root: root, needsStaging: { _ in false })
    }

    /// 把 fixture 复制到临时目录（源图会被改权限、改内容）。
    static func source(_ name: String, in dir: URL, as newName: String? = nil) throws -> URL {
        let url = dir.appendingPathComponent(newName ?? name)
        try FileManager.default.copyItem(at: Fixtures.url(name), to: url)
        return url
    }

    static func render(_ renderer: PhotoFrameRenderer, _ source: URL, _ preset: ExportPreset) async throws -> (RenderResult, [Data]) {
        let out = try makeTempDirectory()
        let result = try await renderer.render(job: RenderJob(sourceURL: source, preset: preset, outputDirectory: out))
        return (result, try result.outputs.map { try Data(contentsOf: $0.fileURL) })
    }

    static let cases: [(String, ExportPreset)] = [
        ("chart_srgb.jpg", makePreset(output: OutputSettings(format: .jpeg))),
        ("chart_srgb_16.tif", makePreset(panorama: PanoramaSettings(enabled: true), output: OutputSettings(format: .jpeg))),
        ("chart_noicc.png", makePreset()),
        ("hdr_gainmap.jpg", makePreset(output: OutputSettings(format: .jpeg, dynamicRange: .hdr))),
        ("hdr_float_linear2020.tif", makePreset(output: OutputSettings(format: .jpeg, dynamicRange: .hdr))),
    ]

    @Test("从本机副本解码，导出的文件与直接读逐字节相同")
    func stagedOutputIsByteIdentical() async throws {
        let dir = try makeTempDirectory()
        let staging = Self.forced(dir.appendingPathComponent("staging"))
        let staged = PhotoFrameRenderer(staging: staging)
        let direct = PhotoFrameRenderer(staging: Self.never(dir.appendingPathComponent("unused")))
        for (name, preset) in Self.cases {
            let src = try Self.source(name, in: dir)
            let (a, bytesA) = try await Self.render(staged, src, preset)
            let (b, bytesB) = try await Self.render(direct, src, preset)
            #expect(a.diagnostics.transformSteps.contains { $0.contains("D-129") }, "\(name)")
            #expect(!b.diagnostics.transformSteps.contains { $0.contains("D-129") }, "\(name)")
            #expect(a.outputs.map(\.dynamicRange) == b.outputs.map(\.dynamicRange), "\(name)")
            #expect(bytesA == bytesB, "\(name) 的输出不同")
        }
        #expect(staging.copyCount == Self.cases.count)
    }

    @Test("同一版本的源图只复制一次；之后（包括 CI 对 gain map 的第二次读取）只读副本，不再读原文件")
    func copyIsReused() throws {
        let dir = try makeTempDirectory()
        let src = try Self.source("hdr_gainmap.jpg", in: dir)
        let staging = Self.forced(dir.appendingPathComponent("staging"))
        let decoder = SourceDecoder(context: WorkingColor.makeContext(), staging: staging)
        let first = try decoder.decode(src, neededSize: PixelSize(width: 480, height: 320), override: nil)
        #expect(first.hdrKind == .gainMap)
        #expect(staging.copyCount == 1)

        // 原文件读不了了（文件属性还能读）：HDR 版本由 CI 按需展开，读的必须是副本；再次解码直接用副本。
        #expect(chmod(src.path, 0) == 0)
        defer { chmod(src.path, 0o644) }
        #expect(throws: (any Error).self) { try Data(contentsOf: src) }
        let hdr = try #require(first.hdr)
        let e = hdr.extent
        var px = [Float](repeating: 0, count: Int(e.width) * Int(e.height) * 4)
        px.withUnsafeMutableBytes { buf in
            WorkingColor.makeContext().render(hdr, toBitmap: buf.baseAddress!, rowBytes: Int(e.width) * 16, bounds: e,
                                              format: .RGBAf, colorSpace: WorkingColor.space)
        }
        let peak = stride(from: 1, to: px.count, by: 4).map { px[$0] }.max() ?? 0
        #expect(peak > 4, "高光仍按 gain map 展开：峰值 \(peak)")
        let again = try decoder.decode(src, neededSize: PixelSize(width: 960, height: 640), override: .displayP3)
        #expect(again.hdrKind == .gainMap)
        #expect(staging.copyCount == 1)
    }

    @Test("复制途中源图被改：抛出 render.source_changed，不留下半个副本；文件不再变化后可以重新复制")
    func modifiedDuringCopy() throws {
        let dir = try makeTempDirectory()
        let src = try Self.source("chart_srgb_16.tif", in: dir)
        let root = dir.appendingPathComponent("staging")
        let staging = Self.forced(root)
        staging.chunkSize = 64 << 10
        staging.afterChunk = { copied in
            guard copied == 64 << 10, let handle = try? FileHandle(forWritingTo: src) else { return }
            handle.seekToEndOfFile()
            handle.write(Data([0]))
            try? handle.close()
        }
        let decoder = SourceDecoder(context: WorkingColor.makeContext(), staging: staging)
        do {
            _ = try decoder.decode(src, neededSize: PixelSize(width: 100, height: 100), override: nil)
            Issue.record("应当失败")
        } catch {
            #expect(error.code == "render.source_changed")
            #expect(error.message.contains("chart_srgb_16.tif"), "\(error.message)")
            #expect(error.hint != nil)
        }
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { !$0.hasSuffix(".lock") && $0.contains(".") }
        #expect(leftovers.isEmpty, "\(leftovers)")
        #expect(staging.usage.count == 0)

        staging.afterChunk = nil
        let source = try decoder.decode(src, neededSize: PixelSize(width: 100, height: 100), override: nil)
        #expect(source.stagedCopy != nil)
    }

    @Test("副本总量超过上限：删掉最久没用、没有在用的副本；在用的不删")
    func evictsLeastRecentlyUsedUnusedCopies() throws {
        let dir = try makeTempDirectory()
        let names = ["a", "b", "c"].map { "\($0).tif" }
        let sources = try names.map { try Self.source("chart_srgb_16.tif", in: dir, as: $0) }
        let size = Int64(try Data(contentsOf: sources[0]).count)
        let staging = Self.forced(dir.appendingPathComponent("staging"), byteLimit: size * 5 / 2)

        var a = try staging.localCopy(of: sources[0])
        var b = try staging.localCopy(of: sources[1])
        let bFile = try #require(b?.url)
        b = nil
        #expect(staging.usage.count == 2)
        // 复制 c 要腾出空间：a 还在用，删最久没用的 b。
        let c = try staging.localCopy(of: sources[2])
        #expect(staging.usage.count == 2)
        #expect(!FileManager.default.fileExists(atPath: bFile.path))
        #expect(FileManager.default.fileExists(atPath: try #require(a?.url).path))

        // a 不用了，再要 b：b 重新复制，删掉 a（c 还在用）。
        let aFile = try #require(a?.url)
        a = nil
        let b2 = try staging.localCopy(of: sources[1])
        #expect(staging.copyCount == 4)
        #expect(!FileManager.default.fileExists(atPath: aFile.path))
        #expect(FileManager.default.fileExists(atPath: try #require(c?.url).path))
        #expect(FileManager.default.fileExists(atPath: try #require(b2?.url).path))
        #expect(staging.usage.bytes <= size * 5 / 2)
    }

    @Test("本机空间不够：不复制，照旧直接读原文件")
    func fallsBackWhenLocalSpaceIsShort() throws {
        let dir = try makeTempDirectory()
        let src = try Self.source("hdr_gainmap.jpg", in: dir)
        let staging = Self.forced(dir.appendingPathComponent("staging"), available: 100 << 20)
        let source = try SourceDecoder(context: WorkingColor.makeContext(), staging: staging)
            .decode(src, neededSize: PixelSize(width: 480, height: 320), override: nil)
        #expect(source.stagedCopy == nil)
        #expect(source.hdrKind == .gainMap)
        #expect(staging.copyCount == 0)
        #expect(!source.transformSteps.contains { $0.contains("D-129") })
    }

    @Test("启动时清理残留：原来的进程已退出的目录删掉，还在运行的进程（锁着）和刚建的目录不删；退出时删掉自己的目录")
    func sweepsLeftovers() throws {
        let dir = try makeTempDirectory()
        let root = dir.appendingPathComponent("staging")
        let src = try Self.source("chart_srgb.jpg", in: dir)
        let live = Self.forced(root)
        let liveCopy = try #require(try live.localCopy(of: src))
        let liveDirectory = liveCopy.url.deletingLastPathComponent()

        func makeDirectory(_ name: String, lock: Bool, old: Bool) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("copy.jpg"))
            if lock { FileManager.default.createFile(atPath: url.appendingPathComponent(".lock").path, contents: nil) }
            if old { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: url.path) }
            return url
        }
        let crashed = try makeDirectory("99999-crashed", lock: true, old: false)
        let oldTemporary = try makeDirectory("99998-old.tmp", lock: true, old: true)
        let newTemporary = try makeDirectory("99997-new.tmp", lock: false, old: false)
        let oldUnlocked = try makeDirectory("99996-nolock", lock: false, old: true)
        let newUnlocked = try makeDirectory("99995-nolock", lock: false, old: false)

        let sweeper = Self.forced(root)
        sweeper.sweepLeftovers()
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        #expect(!exists(crashed))
        #expect(!exists(oldTemporary))
        #expect(exists(newTemporary))
        #expect(!exists(oldUnlocked))
        #expect(exists(newUnlocked))
        #expect(exists(liveDirectory), "还在运行的进程的目录不删")
        #expect(exists(liveCopy.url))

        live.removeAll()
        #expect(!exists(liveDirectory))
    }

    // MARK: - 真实的磁盘映像

    @Test("磁盘映像上的源图：判定为不在内置磁盘、复制后解码，输出与内置磁盘上的同一文件逐字节相同；复制途中卸载映像时报错而不崩溃",
          .timeLimit(.minutes(2)))
    func diskImage() async throws {
        let dir = try makeTempDirectory()
        guard let image = DiskImage(in: dir) else {
            // 不能挂载磁盘映像的环境（例如受限的 CI）：跳过，其余测试覆盖复制本身。
            print("[跳过] hdiutil 无法挂载磁盘映像")
            return
        }
        defer { image.detach() }
        var onImage: [URL] = []
        for (name, _) in Self.cases {
            let url = image.mountPoint.appendingPathComponent(name)
            try FileManager.default.copyItem(at: Fixtures.url(name), to: url)
            onImage.append(url)
        }
        #expect(SourceStaging.isOffInternalDisk(onImage[0]))

        let staging = SourceStaging(root: dir.appendingPathComponent("staging"))
        let staged = PhotoFrameRenderer(staging: staging)
        let direct = PhotoFrameRenderer(staging: Self.never(dir.appendingPathComponent("unused")))
        for ((name, preset), url) in zip(Self.cases, onImage) {
            let (a, bytesA) = try await Self.render(staged, url, preset)
            let (_, bytesB) = try await Self.render(direct, Fixtures.url(name), preset)
            #expect(a.diagnostics.transformSteps.contains { $0.contains("D-129") }, "\(name)")
            #expect(bytesA == bytesB, "\(name) 的输出不同")
        }

        // 复制到一半时强制卸载映像（相当于拔掉移动硬盘、NAS 断开）。
        let big = image.mountPoint.appendingPathComponent("big.tif")
        try FileManager.default.copyItem(at: Fixtures.url("hdr_float_linear2020.tif"), to: big)
        let unplugging = SourceStaging(root: dir.appendingPathComponent("staging2"))
        unplugging.chunkSize = 64 << 10
        unplugging.afterChunk = { copied in if copied == 64 << 10 { image.detach(force: true) } }
        do {
            _ = try SourceDecoder(context: WorkingColor.makeContext(), staging: unplugging)
                .decode(big, neededSize: PixelSize(width: 100, height: 100), override: nil)
            Issue.record("应当失败")
        } catch {
            #expect(["render.source_read_failed", "render.source_changed"].contains(error.code), "\(error)")
        }
        #expect(unplugging.usage.count == 0)
    }
}

/// 用 hdiutil 建一个小的 APFS 磁盘映像并挂载（不在 Finder 里显示）。
final class DiskImage: @unchecked Sendable {
    let mountPoint: URL
    private let lock = NSLock()
    private var attached = true

    init?(in dir: URL) {
        let file = dir.appendingPathComponent("staging-test.dmg")
        mountPoint = dir.appendingPathComponent("mnt", isDirectory: true)
        guard Self.hdiutil(["create", "-size", "32m", "-fs", "APFS", "-volname", "PFStagingTest", file.path, "-quiet"]),
              Self.hdiutil(["attach", file.path, "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, "-quiet"])
        else { return nil }
    }

    func detach(force: Bool = false) {
        lock.withLock {
            guard attached else { return }
            attached = !Self.hdiutil(["detach", mountPoint.path, "-quiet"] + (force ? ["-force"] : []))
        }
    }

    deinit { detach(force: true) }

    @discardableResult
    static func hdiutil(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
