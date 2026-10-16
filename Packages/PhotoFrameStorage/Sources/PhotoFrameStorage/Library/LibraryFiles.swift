import Foundation

/// 库目录的布局与文件操作。
///
/// ```text
/// <root>/                         默认 ~/Library/Application Support/AnotherPhotoFrame/
/// ├── Presets/<presetId>.json     每个用户预设一个文件（LibraryPresetFile）
/// ├── Assets/<assetId>/           每个素材一个目录
/// │   ├── asset.json              元信息（AssetInfo）
/// │   └── content.png | content.svg
/// ├── Assets/.staging/            导入中的素材，完成后整个目录改名到位
/// ├── bindings.json               预设本地绑定 + 用户默认绑定
/// └── .lock                       读改写 bindings.json 时的跨进程锁
/// ```
///
/// 每个条目单独一个文件，任何一个损坏只影响它自己。所有写入都是「写临时文件 → fsync → rename」，
/// 进程中途崩溃只会留下以 `.` 开头的临时文件，读取时忽略。
public enum LibraryLocation {
    public static let directoryName = "AnotherPhotoFrame"

    /// 默认根目录：`~/Library/Application Support/AnotherPhotoFrame/`。
    /// 沙盒进程里 Application Support 会落在自己的容器内。
    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: directoryName, directoryHint: .isDirectory)
    }
}

enum LibraryFiles {
    /// 原子写：同目录临时文件 → fsync → rename。失败时原文件保持不变。
    static func atomicWrite(_ data: Data, to url: URL) throws(LibraryError) {
        let dir = url.deletingLastPathComponent()
        try ensureDirectory(dir)
        let tmp = dir.appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: tmp)
            try handle.synchronize()
            try handle.close()
            guard rename(tmp.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw .io("写入 \(url.lastPathComponent) 失败：\(describe(error))")
        }
    }

    /// POSIX rename：同一卷内原子替换（文件）或移动（目录，目标必须不存在或为空目录）。
    static func move(_ from: URL, to: URL, what: String) throws(LibraryError) {
        guard Darwin.rename(from.path, to.path) == 0 else {
            throw .io("\(what)失败：\(String(cString: strerror(errno)))")
        }
    }

    static func ensureDirectory(_ url: URL) throws(LibraryError) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw .io("无法创建目录 \(url.lastPathComponent)：\(describe(error))")
        }
    }

    /// 目录中的普通文件（不跟随符号链接，跳过 `.` 开头的临时文件）。
    static func regularFiles(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { isRegularFile($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return v?.isRegularFile == true && v?.isSymbolicLink != true
    }

    static func isDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isSymbolicLink != true
    }

    /// 读取普通文件；超过 `maxBytes` 时不读入内存。
    static func read(_ url: URL, maxBytes: Int) throws(LibraryError) -> Data {
        guard isRegularFile(url) else { throw .io("\(url.lastPathComponent) 不是普通文件") }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maxBytes else { throw LibraryError.io("\(url.lastPathComponent) 超过 \(maxBytes) 字节") }
            return try Data(contentsOf: url)
        } catch let e as LibraryError {
            throw e
        } catch {
            throw .io("读取 \(url.lastPathComponent) 失败：\(describe(error))")
        }
    }

    /// 在跨进程文件锁（flock）内执行。同一进程内的不同线程也互斥（各自打开文件描述符）。
    static func withLock<T>(_ lockFile: URL, _ body: () throws(LibraryError) -> T) throws(LibraryError) -> T {
        try ensureDirectory(lockFile.deletingLastPathComponent())
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .io("无法打开锁文件：\(String(cString: strerror(errno)))") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw .io("加锁失败：\(String(cString: strerror(errno)))") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    static func describe(_ error: any Error) -> String {
        // 只给出错误原因，不带 NSError 里的完整路径。
        if let e = error as? POSIXError { return String(cString: strerror(e.code.rawValue)) }
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return "\(ns.domain) \(ns.code)"
    }

    /// 当前时间，取整到秒：存盘用 ISO 8601（不带小数秒），读回来要和内存里的值相等。
    static func now() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
