import Foundation
import Security

/// 库目录的布局与文件操作。
///
/// ```text
/// <root>/                         见 LibraryLocation（App Group 容器或 ~/Library/Application Support/AnotherPhotoFrame/）
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
///
/// 根目录（D-78，D-124 修改）。GUI、CLI、MCP 都调用 ``defaultRoot()``，按同一套规则落到同一个库：
/// 1. 环境变量 `PHOTOFRAME_LIBRARY`（非空）；
/// 2. 进程带本 App Group 的 entitlement（已签名的 GUI）：系统给出的 App Group 容器；
/// 3. `~/Library/Group Containers/<App Group ID>/` 已经存在（签名的 GUI 建过）：用它；
/// 4. 否则 `~/Library/Application Support/AnotherPhotoFrame/`。
///
/// 未签名的进程没有 App Group entitlement，macOS 不允许它在 Group Containers 下建目录（Operation not permitted），
/// 所以不能只看 `containerURL(forSecurityApplicationGroupIdentifier:)`：它对未签名进程也会返回路径。
/// 也可以用 `LocalLibrary(root:)` 指定任意目录（测试、自定义位置）。
public enum LibraryLocation {
    public static let directoryName = "AnotherPhotoFrame"
    public static let environmentVariable = "PHOTOFRAME_LIBRARY"

    /// App Group ID。占位值：真实值依赖开发者 Team ID，签名时一并确定。
    public static let appGroupIdentifier = "group.org.anotherphotoframe"

    /// 本进程的库根目录（规则见类型说明）。
    public static func defaultRoot(appGroupIdentifier: String = appGroupIdentifier) -> URL {
        let entitled = hasAppGroupEntitlement(appGroupIdentifier)
            ? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) : nil
        return resolveRoot(
            environment: ProcessInfo.processInfo.environment, entitledContainer: entitled,
            home: userHomeDirectory(), appGroupIdentifier: appGroupIdentifier)
    }

    /// ``defaultRoot(appGroupIdentifier:)`` 的规则本身（可测试）。`entitledContainer` 是带 entitlement 时系统给出的容器。
    public static func resolveRoot(
        environment: [String: String], entitledContainer: URL?, home: URL, appGroupIdentifier: String = appGroupIdentifier,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) -> URL {
        if let path = environment[environmentVariable], !path.isEmpty {
            return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        if let entitledContainer { return root(inGroupContainer: entitledContainer) }
        let container = groupContainerPath(appGroupIdentifier: appGroupIdentifier, home: home)
        if fileExists(container) { return root(inGroupContainer: container) }
        return home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// 进程是否带 `com.apple.security.application-groups` entitlement 且包含这个 App Group。
    static func hasAppGroupEntitlement(_ identifier: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(identifier) == true
    }

    /// `<home>/Library/Group Containers/<appGroupIdentifier>`。
    public static func groupContainerPath(appGroupIdentifier: String, home: URL) -> URL {
        home.appending(path: "Library/Group Containers", directoryHint: .isDirectory)
            .appending(path: appGroupIdentifier, directoryHint: .isDirectory)
    }

    /// 容器内的库目录：`<container>/Library/Application Support/AnotherPhotoFrame/`。
    public static func root(inGroupContainer container: URL) -> URL {
        container.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// 真实主目录：沙盒进程里 `NSHomeDirectory()` 指向自己的容器，所以从用户数据库读。
    static func userHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(filePath: String(cString: dir), directoryHint: .isDirectory)
        }
        return URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    }
}

enum LibraryFiles {
    /// 原子写：同目录临时文件 → fsync → rename。失败时原文件保持不变。
    ///
    /// 临时文件名长度固定（`.pf-<UUID>.tmp`），不随目标文件名变长：目标文件名接近 255 个字符时也能写入。
    static func atomicWrite(_ data: Data, to url: URL) throws(LibraryError) {
        let dir = url.deletingLastPathComponent()
        try ensureDirectory(dir)
        let tmp = dir.appending(path: ".pf-\(UUID().uuidString).tmp")
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
        // URL 会缓存资源值（各个副本共用一份）：长期持有的 URL（例如 AssetBindingStore.fileURL）在文件被替换后
        // 仍会得到旧的类型和大小。每次先清掉缓存再查。
        var url = url
        url.removeAllCachedResourceValues()
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

    /// 写入前检查大小：超过读取上限（``read(_:maxBytes:)`` 的 `maxBytes`）的文件写进去也读不回来，所以不写。
    static func checkWritable(_ data: Data, name: String, maxBytes: Int) throws(LibraryError) {
        guard data.count <= maxBytes else {
            throw .io("写入 \(name) 失败：\(data.count) 字节，超过上限 \(maxBytes) 字节")
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
