import Darwin
import Foundation
import ImageIO
import PhotoFrameCore
import Synchronization

/// 源图文件本身：在不在、是不是同一张照片、移动或改名后去了哪里（参照 Lightroom Classic 处理缺失原图的做法）。
///
/// 这里的每个函数都可能碰到网络卷：卷断开后 stat、读文件头、解析书签都可能很久不返回，
/// 所以都在主线程之外执行，并且有时限（``bounded(_:default:_:)``），超时按读不到处理。
enum SourceFiles {
    /// 一次检查最多等多久。
    static let defaultTimeout: Duration = .seconds(3)

    /// 正在等待的 stat（路径）。卡住的 stat 停不下来，同一个路径不再叠加新的，直接当作还读不到。
    private static let pendingStats = Mutex<Set<String>>([])

    enum Probe: Sendable {
        case present, absent
        /// stat 超时（或同一路径的上一次还卡着）：所在的卷多半断开了。
        case unreachable
    }

    /// 文件在不在：只 stat，不读内容。
    static func probe(_ url: URL, timeout: Duration = defaultTimeout) async -> Probe {
        let path = url.path
        guard pendingStats.withLock({ $0.insert(path).inserted }) else { return .unreachable }
        return await bounded(timeout, default: .unreachable) {
            defer { _ = pendingStats.withLock { $0.remove(path) } }
            var info = stat()
            return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG ? .present : .absent
        }
    }

    static func exists(_ url: URL, timeout: Duration = defaultTimeout) async -> Bool {
        await probe(url, timeout: timeout) == .present
    }

    /// 一批文件在不在。按卷分组，每个卷最多同时 stat `width` 个；某个卷有 stat 超时，这个卷剩下的不再 stat，
    /// 都当作读不到（断开的 NAS 上每个 stat 都会卡住，不能一个个等，也不能占满线程）。
    static func probe(_ urls: [URL], timeout: Duration = defaultTimeout, width: Int = 8) async -> [URL: Probe] {
        var result: [URL: Probe] = [:]
        let volumes = Dictionary(grouping: urls, by: volume)
        await withTaskGroup(of: [URL: Probe].self) { group in
            for files in volumes.values {
                group.addTask {
                    var found: [URL: Probe] = [:]
                    for start in stride(from: 0, to: files.count, by: width) {
                        let chunk = files[start..<min(start + width, files.count)]
                        await withTaskGroup(of: (URL, Probe).self) { inner in
                            for url in chunk { inner.addTask { (url, await probe(url, timeout: timeout)) } }
                            for await (url, state) in inner { found[url] = state }
                        }
                        if chunk.contains(where: { found[$0] == .unreachable }) {
                            for url in files[min(start + width, files.count)...] { found[url] = .unreachable }
                            break
                        }
                    }
                    return found
                }
            }
            for await found in group { result.merge(found) { first, _ in first } }
        }
        return result
    }

    /// 文件所在的卷：`/Volumes/<名字>`，其余都算启动卷。只看路径，不访问文件系统。
    static func volume(_ url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? "/Volumes/\(parts[2])" : "/"
    }

    /// 读文件头得到的识别信息（不解码像素）；读不到或超时为 nil。
    static func fingerprint(_ url: URL, timeout: Duration = defaultTimeout) async -> SourceFingerprint? {
        await bounded(timeout, default: nil) { SourceFingerprint(contentsOf: url) }
    }

    /// 文件的书签（不带安全范围：应用没有沙盒）。文件移动、改名后可以用它找到新位置。
    static func bookmark(_ url: URL, timeout: Duration = defaultTimeout) async -> Data? {
        await bounded(timeout, default: nil) { try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
    }

    /// 用书签找文件现在的位置。不弹窗、不装载卷（`withoutUI`、`withoutMounting`）；找不到或超时为 nil。
    static func resolve(_ bookmark: Data, timeout: Duration = defaultTimeout) async -> URL? {
        await bounded(timeout, default: nil) {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                     bookmarkDataIsStale: &stale)
            else { return nil }
            return url.standardizedFileURL
        }
    }

    /// 在后台线程执行 `body`，最多等 `timeout`；超时返回 `value`（`body` 卡住的线程留着，返回后结果丢掉）。
    static func bounded<T: Sendable>(_ timeout: Duration, default value: T, _ body: @escaping @Sendable () -> T) async -> T {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let pending = Mutex<CheckedContinuation<T, Never>?>(continuation)
            let finish = { @Sendable (result: T) in pending.withLock { $0.take() }?.resume(returning: result) }
            DispatchQueue.global(qos: .utility).async { finish(body()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { finish(value) }
        }
    }
}

/// 判断两个文件是不是同一张照片用的信息：像素尺寸、EXIF 拍摄时间、相机厂商和型号（与 Lightroom 重新链接时核对的相同）。
public struct SourceFingerprint: Hashable, Sendable {
    /// 存储的像素尺寸（方向校正前）。
    public var pixelSize: PixelSize?
    /// EXIF DateTimeOriginal（带亚秒时加上亚秒）。
    public var captureTime: String?
    public var make: String?
    public var model: String?

    public init(pixelSize: PixelSize?, captureTime: String?, make: String?, model: String?) {
        self.pixelSize = pixelSize
        self.captureTime = captureTime
        self.make = make
        self.model = model
    }

    /// 只读文件头。
    init?(contentsOf url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        func text(_ value: Any?) -> String? {
            guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
                  !string.isEmpty else { return nil }
            return string
        }
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = PixelSize(width: w, height: h)
        }
        captureTime = text(exif[kCGImagePropertyExifDateTimeOriginal]).map { time in
            text(exif[kCGImagePropertyExifSubsecTimeOriginal]).map { "\(time).\($0)" } ?? time
        }
        make = text(tiff[kCGImagePropertyTIFFMake])
        model = text(tiff[kCGImagePropertyTIFFModel])
    }

    /// 与另一个文件不同的地方，按固定顺序。都相同时为空。
    public func differences(to other: SourceFingerprint) -> [RelinkDifference] {
        var result: [RelinkDifference] = []
        func compare(_ field: String, _ old: String?, _ new: String?) {
            if old != new { result.append(RelinkDifference(field: field, old: old ?? "无", new: new ?? "无")) }
        }
        compare("像素尺寸", pixelSize.map { "\($0.width) × \($0.height)" }, other.pixelSize.map { "\($0.width) × \($0.height)" })
        compare("拍摄时间", captureTime, other.captureTime)
        compare("相机厂商", make, other.make)
        compare("相机型号", model, other.model)
        return result
    }
}

/// 重新链接时新文件与原来不同的一项。
public struct RelinkDifference: Hashable, Sendable {
    /// 「像素尺寸」「拍摄时间」「相机厂商」「相机型号」。
    public var field: String
    public var old: String
    public var new: String

    /// 「像素尺寸：原来 6000 × 4000，现在 5998 × 4000」。
    public var text: String { "\(field)：原来 \(old)，现在 \(new)" }
}
