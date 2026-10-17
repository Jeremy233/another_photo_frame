import CoreGraphics
import Foundation
import ImageIO

/// 预览「原图」的解码与缓存。
///
/// 摄影原图动辄几十 MB、四五千万像素，每次切换都重新解码会明显卡顿。这里分三档：
/// - `quick`：先给一张小图（有内嵌缩略图就直接用，否则按 512 px 解码，JPEG 可以按比例缩小解码，很快）；
/// - `screen`：后台解码长边不超过 3072 px 的清晰版本，好了替换；
/// - `full`：放大到超出清晰版本的像素时才按需解码全分辨率，此时 100% 才是真实像素。
/// SDR 预览不按 HDR 解码；HDR 才请求 HDR 解码（增益图）。
/// 解码结果按 URL、档位、动态范围放进内存缓存，按最近使用淘汰，总量不超过 `byteLimit`；全分辨率只留一张。
@MainActor
final class OriginalImageStore {
    static let shared = OriginalImageStore()

    enum Tier: Hashable, Sendable {
        case quick, screen, full

        /// 长边上限；nil 为全分辨率。
        var maxPixelSize: Int? {
            switch self {
            case .quick: 512
            case .screen: 3072
            case .full: nil
            }
        }
    }

    struct Key: Hashable, Sendable {
        var url: URL
        var tier: Tier
        var hdr: Bool
    }

    /// 原图尺寸（已按 EXIF 方向转正）。
    struct Info: Sendable {
        var pixelSize: CGSize
    }

    var byteLimit: Int
    private(set) var cachedBytes = 0
    private var entries: [Key: (image: CGImage, bytes: Int)] = [:]
    /// 最近使用的在后面。
    private var order: [Key] = []
    private var infos: [URL: Info] = [:]
    private var loading: [Key: Task<CGImage?, Never>] = [:]
    /// 实际解码次数（测试用）。
    private(set) var decodeCount = 0

    init(byteLimit: Int = 600 << 20) {
        self.byteLimit = byteLimit
    }

    func cached(_ key: Key) -> CGImage? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.image
    }

    /// 已缓存的最清晰的一档（全分辨率 > 清晰版 > 快图）。
    func best(url: URL, hdr: Bool) -> (image: CGImage, tier: Tier)? {
        for tier in [Tier.full, .screen, .quick] {
            if let image = cached(Key(url: url, tier: tier, hdr: hdr)) { return (image, tier) }
        }
        return nil
    }

    func info(_ url: URL) -> Info? {
        if let info = infos[url] { return info }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let info = Info(pixelSize: orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h))
        infos[url] = info
        return info
    }

    /// 解码（同一张同一档只解码一次，正在解码时等它完成）。
    func load(_ key: Key) async -> CGImage? {
        if let image = cached(key) { return image }
        if let task = loading[key] { return await task.value }
        decodeCount += 1
        let task = Task.detached(priority: key.tier == .quick ? .userInitiated : .utility) { Self.decode(key) }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image { insert(image, for: key) }
        return image
    }

    nonisolated static func decode(_ key: Key) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(key.url as CFURL, nil) else { return nil }
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        if key.hdr { options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR }
        switch key.tier {
        case .quick:
            // 有内嵌缩略图就直接用（不按 HDR 解码，只是占位）。
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = Tier.quick.maxPixelSize!
            options[kCGImageSourceDecodeRequest] = nil
        case .screen:
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = Tier.screen.maxPixelSize!
        case .full:
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                options[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
            }
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func insert(_ image: CGImage, for key: Key) {
        if key.tier == .full {
            // 全分辨率很大：只留最新的一张。
            for other in order where other.tier == .full && other != key { remove(other) }
        }
        remove(key)
        let bytes = image.bytesPerRow * image.height
        entries[key] = (image, bytes)
        order.append(key)
        cachedBytes += bytes
        while cachedBytes > byteLimit, let oldest = order.first, oldest != key { remove(oldest) }
    }

    private func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        cachedBytes -= entry.bytes
        order.removeAll { $0 == key }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// 不再需要全分辨率时（缩回适合窗口）释放它。
    func releaseFull(url: URL) {
        for key in order where key.url == url && key.tier == .full { remove(key) }
    }

    func removeAll() {
        entries = [:]
        order = []
        cachedBytes = 0
    }
}
