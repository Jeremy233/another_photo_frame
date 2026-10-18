import CoreGraphics
import Foundation
import ImageIO
import PhotoFrameMacModel

/// 预览「原图」的解码与缓存。
///
/// 摄影原图动辄几十 MB、四五千万像素，每次切换都重新解码会明显卡顿。这里分三档：
/// - `quick`：先给一张小图（有内嵌缩略图就直接用，否则按 512 px 解码，JPEG 可以按比例缩小解码，很快）；
/// - `screen`：后台解码长边不超过 3072 px 的清晰版本，好了替换；
/// - `full`：放大到超出清晰版本的像素时才按需解码全分辨率，此时 100% 才是真实像素。
/// SDR 预览不按 HDR 解码；HDR 才请求 HDR 解码（增益图）。
/// 解码结果按 URL、文件修改时间、档位、动态范围放进内存缓存，按最近使用淘汰，总量不超过 `byteLimit`；全分辨率只留一张。
/// 源图离开批次后丢掉它的缓存（`retain(urls:)`），系统内存紧张时全部清空。
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
        /// 文件的修改时间：文件改了就是新的键，会重新解码。
        var modified: Date?
    }

    /// 原图尺寸（已按 EXIF 方向转正）和读取时文件的修改时间。
    struct Info: Sendable {
        var pixelSize: CGSize
        var modified: Date?
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
    private var memoryWatch: MemoryPressureWatch?

    init(byteLimit: Int = 600 << 20) {
        self.byteLimit = byteLimit
        // 系统内存紧张时全部清空（都可以重新解码）。
        memoryWatch = MemoryPressureWatch { [weak self] in self?.removeAll() }
    }

    func cached(_ key: Key) -> CGImage? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.image
    }

    /// 已缓存的最清晰的一档（全分辨率 > 清晰版 > 快图）。
    func best(url: URL, hdr: Bool, modified: Date? = nil) -> (image: CGImage, tier: Tier)? {
        for tier in [Tier.full, .screen, .quick] {
            if let image = cached(Key(url: url, tier: tier, hdr: hdr, modified: modified)) { return (image, tier) }
        }
        return nil
    }

    /// 原图尺寸和修改时间；第一次用到时读文件头。
    func info(_ url: URL) -> Info? {
        if let info = infos[url] { return info }
        return readInfo(url, modified: Self.modificationDate(url))
    }

    /// 每次加载原图时调用一次（不在 body 里读文件）：修改时间变了就重新读尺寸，旧的解码结果不再用。
    @discardableResult
    func reloadInfo(_ url: URL) -> Info? {
        let modified = Self.modificationDate(url)
        if let info = infos[url], info.modified == modified { return info }
        for key in order where key.url == url { remove(key) }
        return readInfo(url, modified: modified)
    }

    private func readInfo(_ url: URL, modified: Date?) -> Info? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else {
            infos[url] = nil
            return nil
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let info = Info(pixelSize: orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h), modified: modified)
        infos[url] = info
        return info
    }

    nonisolated static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// 解码（同一张同一档只解码一次，正在解码时等它完成）。
    /// 全分辨率很大：请求它的视图已经不需要了（它的任务被取消：缩回、换了图、离开）就不放进缓存。
    func load(_ key: Key) async -> CGImage? {
        if let image = cached(key) { return image }
        let task: Task<CGImage?, Never>
        if let running = loading[key] {
            task = running
        } else {
            decodeCount += 1
            task = Task.detached(priority: key.tier == .quick ? .userInitiated : .utility) { Self.decode(key) }
            loading[key] = task
        }
        let image = await task.value
        if loading[key] == task { loading[key] = nil }
        guard let image else { return nil }
        if key.tier == .full, Task.isCancelled { return nil }
        if entries[key] == nil { insert(image, for: key) }
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

    /// 要不要全分辨率：放大到清晰版本的像素不够用时要。`scale` 是这块画布现在的比例，还不知道时为 nil（不要）。
    /// 已经在显示全分辨率时，缩到阈值的 3/4 以下才不要，免得在阈值附近来回解码、释放几百 MB。
    nonisolated static func needsFull(pixelSize: CGSize, scale: Double?, showingFull: Bool) -> Bool {
        guard let scale, let limit = Tier.screen.maxPixelSize else { return false }
        let longEdge = max(pixelSize.width, pixelSize.height)
        let threshold = Double(limit) * (showingFull ? 0.75 : 1)
        return longEdge > Double(limit) && longEdge * scale > threshold
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

    /// 不再需要全分辨率时（缩回、换了图、离开「原图」）释放它。
    func releaseFull(url: URL) {
        for key in order where key.url == url && key.tier == .full { remove(key) }
    }

    /// 只留下这些原图的缓存（其他源图已经离开批次）。
    func retain(urls: Set<URL>) {
        for key in order where !urls.contains(key.url) { remove(key) }
        infos = infos.filter { urls.contains($0.key) }
    }

    func removeAll() {
        entries = [:]
        order = []
        cachedBytes = 0
    }
}
