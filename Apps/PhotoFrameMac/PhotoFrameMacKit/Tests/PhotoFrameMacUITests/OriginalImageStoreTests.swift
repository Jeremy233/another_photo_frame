import CoreGraphics
import Foundation
import ImageIO
@testable import PhotoFrameMacUI
import Testing
import UniformTypeIdentifiers

@MainActor @Suite struct OriginalImageStoreTests {
    /// 合成一张 width × height 的 JPEG（可选 EXIF 方向）。
    static func jpeg(_ name: String, width: Int, height: Int, orientation: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)-\(name).jpg")
        try write(to: url, width: width, height: height, orientation: orientation)
        return url
    }

    static func write(to url: URL, width: Int, height: Int, orientation: Int = 1) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test func changedFileIsDecodedAgain() async throws {
        let url = try Self.jpeg("changed", width: 1200, height: 800)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OriginalImageStore()
        let info = try #require(store.reloadInfo(url))
        #expect(info.pixelSize == CGSize(width: 1200, height: 800))
        _ = await store.load(.init(url: url, tier: .quick, hdr: false, modified: info.modified))
        #expect(store.decodeCount == 1)

        // 同一个文件换了内容：下次加载时按修改时间发现，重新读尺寸、重新解码。
        try Self.write(to: url, width: 900, height: 600)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        let changed = try #require(store.reloadInfo(url))
        #expect(changed.pixelSize == CGSize(width: 900, height: 600) && changed.modified != info.modified)
        #expect(store.best(url: url, hdr: false, modified: changed.modified) == nil)
        _ = await store.load(.init(url: url, tier: .quick, hdr: false, modified: changed.modified))
        #expect(store.decodeCount == 2)
    }

    @Test func fullDecodeNoLongerNeededIsNotCached() async throws {
        let url = try Self.jpeg("full", width: 4000, height: 3000)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OriginalImageStore()
        let key = OriginalImageStore.Key(url: url, tier: .full, hdr: false)
        // 请求它的视图已经不需要了（任务被取消）：几百 MB 的全分辨率不放进缓存。
        let request = Task { await store.load(key) }
        request.cancel()
        #expect(await request.value == nil)
        #expect(store.cached(key) == nil)
        #expect(await store.load(key) != nil)
        #expect(store.cached(key) != nil)
    }

    @Test func retainKeepsOnlyOriginalsStillInTheBatch() async throws {
        let a = try Self.jpeg("a", width: 600, height: 400)
        let b = try Self.jpeg("b", width: 600, height: 400)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let store = OriginalImageStore()
        _ = await store.load(.init(url: a, tier: .quick, hdr: false))
        _ = await store.load(.init(url: b, tier: .quick, hdr: false))
        store.retain(urls: [b])
        #expect(store.cached(.init(url: a, tier: .quick, hdr: false)) == nil)
        #expect(store.cached(.init(url: b, tier: .quick, hdr: false)) != nil)
    }

    @Test func fullResolutionThresholdHasHysteresis() {
        let size = CGSize(width: 8000, height: 6000)
        // 还不知道这块画布的比例：不要全分辨率。
        #expect(!OriginalImageStore.needsFull(pixelSize: size, scale: nil, showingFull: false))
        // 清晰版本（3072 px）够用时不要，放大到不够时要。
        #expect(!OriginalImageStore.needsFull(pixelSize: size, scale: 0.3, showingFull: false))
        #expect(OriginalImageStore.needsFull(pixelSize: size, scale: 0.5, showingFull: false))
        // 已经在显示全分辨率：缩到阈值的 3/4（2304 px）以下才释放。
        #expect(OriginalImageStore.needsFull(pixelSize: size, scale: 0.35, showingFull: true))
        #expect(!OriginalImageStore.needsFull(pixelSize: size, scale: 0.25, showingFull: true))
        // 原图不比清晰版本大：从来不需要。
        #expect(!OriginalImageStore.needsFull(pixelSize: CGSize(width: 3000, height: 2000), scale: 4, showingFull: false))
    }

    @Test func tiersAndCache() async throws {
        let url = try Self.jpeg("tiers", width: 4000, height: 3000)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OriginalImageStore()
        #expect(store.info(url)?.pixelSize == CGSize(width: 4000, height: 3000))

        let quick = try #require(await store.load(.init(url: url, tier: .quick, hdr: false)))
        #expect(max(quick.width, quick.height) <= 512)
        let screen = try #require(await store.load(.init(url: url, tier: .screen, hdr: false)))
        #expect(max(screen.width, screen.height) == 3072)
        let full = try #require(await store.load(.init(url: url, tier: .full, hdr: false)))
        #expect(full.width == 4000 && full.height == 3000)   // 100% 是真实像素
        #expect(store.decodeCount == 3)

        // 看过的图直接从缓存取，不再解码；最清晰的一档优先。
        _ = await store.load(.init(url: url, tier: .screen, hdr: false))
        #expect(store.decodeCount == 3)
        #expect(store.best(url: url, hdr: false)?.tier == .full)
        // SDR 和 HDR 分开缓存（SDR 不按 HDR 解码）。
        #expect(store.best(url: url, hdr: true) == nil)

        store.releaseFull(url: url)
        #expect(store.best(url: url, hdr: false)?.tier == .screen)
    }

    @Test func onlyOneFullImageAndByteLimit() async throws {
        let a = try Self.jpeg("a", width: 1200, height: 800)
        let b = try Self.jpeg("b", width: 1200, height: 800)
        defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
        let store = OriginalImageStore()
        _ = await store.load(.init(url: a, tier: .full, hdr: false))
        _ = await store.load(.init(url: b, tier: .full, hdr: false))
        #expect(store.cached(.init(url: a, tier: .full, hdr: false)) == nil)
        #expect(store.cached(.init(url: b, tier: .full, hdr: false)) != nil)

        // 超过字节上限时淘汰最久没用的。
        let small = OriginalImageStore(byteLimit: 1200 * 800 * 4 + 100)
        _ = await small.load(.init(url: a, tier: .screen, hdr: false))
        _ = await small.load(.init(url: b, tier: .screen, hdr: false))
        #expect(small.cached(.init(url: a, tier: .screen, hdr: false)) == nil)
        #expect(small.cached(.init(url: b, tier: .screen, hdr: false)) != nil)
        #expect(small.cachedBytes <= small.byteLimit)
    }

    @Test func orientationIsApplied() throws {
        let url = try Self.jpeg("rotated", width: 1200, height: 800, orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(OriginalImageStore().info(url)?.pixelSize == CGSize(width: 800, height: 1200))
    }

    @Test func minimapMath() {
        // 内容 1000 × 800 pt（四周留白 16），可见区域 400 × 300，滚到 (216, 116)。
        let visible = Minimap.visibleRect(offset: CGPoint(x: 216, y: 116), container: CGSize(width: 400, height: 300),
                                          contentSize: CGSize(width: 1000, height: 800), padding: 16)
        #expect(visible == CGRect(x: 200, y: 100, width: 400, height: 300))
        // 点内容中心：可见区域居中；点到边缘：限制在可滚动范围内。
        let scroll = CGSize(width: 1032, height: 832), container = CGSize(width: 400, height: 300)
        #expect(Minimap.offset(centering: CGPoint(x: 500, y: 400), scrollContent: scroll, container: container, padding: 16) == CGPoint(x: 316, y: 266))
        #expect(Minimap.offset(centering: .zero, scrollContent: scroll, container: container, padding: 16) == .zero)
        #expect(Minimap.offset(centering: CGPoint(x: 5000, y: 5000), scrollContent: scroll, container: container, padding: 16) == CGPoint(x: 632, y: 532))
    }
}
