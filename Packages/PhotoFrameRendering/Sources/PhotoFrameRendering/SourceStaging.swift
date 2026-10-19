import Darwin
import Foundation
import Synchronization

/// 不在内置磁盘上的源图（NAS、移动硬盘、外接 SSD、磁盘映像……）先按顺序复制到本机缓存目录，再从副本解码（D-129）。
///
/// - 原因：`Data(contentsOf:options: .mappedIfSafe)` 只映射本地、非移动介质卷上的文件（`MNT_LOCAL` 且没有 `MNT_REMOVABLE`），
///   SMB、USB 硬盘、磁盘映像上的源图会整个读进内存，gain map JPEG 还要由 CI 按路径再读一遍整个文件。
///   macOS 没有标成移动介质的外接 SSD 会被映射，解码途中拔掉会 SIGBUS 崩溃。从本机副本读就没有这些问题。
/// - 判定只看卷的属性（URL resource values），不读文件。内置磁盘上的源图照旧直接读，什么都不变。
/// - 复制前后比较源图的大小、修改时间、文件号和所在设备；中途被改或读失败（卷断开）时这个任务失败，给出明确的错误，不会崩溃。
///   SMB 客户端会缓存文件属性，别的电脑在复制期间改了文件不一定能发现。
/// - 本机空间不够（副本之外留不出 1 GB）或本机写不进去时不复制，照旧直接读。
/// - 副本按（路径、大小、修改时间、文件号、设备）复用：预览之后再导出只读一次 NAS。总量超过上限（默认 2 GB）时删掉最久没用、
///   而且没有在用的副本；还有解码结果（``Copy``）引用的副本不删，CI 之后还要按路径读它。
/// - 每个进程一个目录 `<pid>-<UUID>`，里面的 `.lock` 由本进程一直锁着。进程正常退出时删掉自己的目录；
///   崩溃留下的目录由之后启动的进程清理（锁拿得到就说明原来的进程已经不在了）。
final class SourceStaging: @unchecked Sendable {
    /// 所有渲染器共用的一份：`~/Library/Caches/AnotherPhotoFrame/SourceStaging`。
    static let shared = SourceStaging(root: defaultRoot)

    static var defaultRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "AnotherPhotoFrame/SourceStaging", directoryHint: .isDirectory)
    }

    /// 解码结果持有它，副本在它释放之前不会被删除。
    final class Copy: @unchecked Sendable {
        let url: URL
        private let onRelease: () -> Void

        fileprivate init(url: URL, onRelease: @escaping () -> Void) {
            self.url = url
            self.onRelease = onRelease
        }

        deinit { onRelease() }
    }

    /// 识别源文件的同一个版本。
    struct Identity: Hashable {
        var path: String
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int
        var fileNumber: UInt64
        var device: Int32

        init(_ s: stat, path: String) {
            self.path = path
            size = Int64(s.st_size)
            modifiedSeconds = s.st_mtimespec.tv_sec
            modifiedNanoseconds = s.st_mtimespec.tv_nsec
            fileNumber = UInt64(s.st_ino)
            device = s.st_dev
        }

        init?(path: String) {
            var s = stat()
            guard stat(path, &s) == 0, s.st_mode & S_IFMT == S_IFREG else { return nil }
            self.init(s, path: path)
        }

        init?(descriptor fd: Int32, path: String) {
            var s = stat()
            guard fstat(fd, &s) == 0 else { return nil }
            self.init(s, path: path)
        }
    }

    private struct Entry {
        var url: URL
        var bytes: Int64
        var leases: Int
        var lastUse: UInt64
    }

    let root: URL
    let byteLimit: Int64
    /// 副本之外，本机至少还要留出的空间。
    let reserveBytes: Int64
    private let needsStaging: @Sendable (URL) -> Bool
    private let availableBytes: @Sendable (URL) -> Int64?

    // 测试用
    var chunkSize = 8 << 20
    var afterChunk: (@Sendable (Int64) -> Void)?
    private(set) var copyCount = 0

    private let condition = NSCondition()
    private var entries: [Identity: Entry] = [:]
    private var inFlight: Set<Identity> = []
    private var total: Int64 = 0
    private var tick: UInt64 = 0
    private let directoryLock = NSLock()
    private var directory: URL?
    private var lockDescriptor: Int32 = -1

    init(
        root: URL, byteLimit: Int64 = 2 << 30, reserveBytes: Int64 = 1 << 30,
        needsStaging: @escaping @Sendable (URL) -> Bool = SourceStaging.isOffInternalDisk,
        availableBytes: @escaping @Sendable (URL) -> Int64? = SourceStaging.availableCapacity
    ) {
        self.root = root
        self.byteLimit = byteLimit
        self.reserveBytes = reserveBytes
        self.needsStaging = needsStaging
        self.availableBytes = availableBytes
    }

    /// 源图不在本机的内置磁盘上（网络卷、外接或移动介质、磁盘映像）。只读卷的属性，不读文件；读不到属性时按在本机处理（照旧直接读）。
    static func isOffInternalDisk(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey]) else { return false }
        return !(values.volumeIsLocal == true && values.volumeIsInternal == true)
    }

    static func availableCapacity(_ url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    // MARK: - 副本

    /// 需要时返回源图的本机副本（同一版本的源图只复制一次）。源图在内置磁盘上、读不到文件属性、本机空间不够或写不进去时返回 nil，
    /// 调用方照旧直接读原文件。
    func localCopy(of url: URL) throws(RenderError) -> Copy? {
        let resolved = url.resolvingSymlinksInPath()
        guard needsStaging(resolved), let id = Identity(path: resolved.path) else { return nil }
        condition.lock()
        while true {
            if entries[id] != nil {
                let copy = lease(id)
                condition.unlock()
                return copy
            }
            guard inFlight.contains(id) else { break }
            condition.wait()
        }
        inFlight.insert(id)
        evict(toFit: byteLimit - id.size)
        condition.unlock()

        let result: Result<URL?, RenderError>
        do throws(RenderError) {
            result = .success(try copy(resolved, id, reportingAs: url))
        } catch {
            result = .failure(error)
        }

        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        inFlight.remove(id)
        switch result {
        case .failure(let error):
            throw error
        case .success(nil):
            return nil
        case .success(let local?):
            copyCount += 1
            entries[id] = Entry(url: local, bytes: id.size, leases: 0, lastUse: 0)
            total += id.size
            let copy = lease(id)
            evict(toFit: byteLimit)
            return copy
        }
    }

    /// 调用时持有 `condition`。
    private func lease(_ id: Identity) -> Copy {
        tick += 1
        entries[id]!.leases += 1
        entries[id]!.lastUse = tick
        return Copy(url: entries[id]!.url) { [self] in release(id) }
    }

    private func release(_ id: Identity) {
        condition.lock()
        defer { condition.unlock() }
        entries[id]?.leases -= 1
        evict(toFit: byteLimit)
    }

    /// 删掉最久没用、没有在用的副本，直到总量不超过 `limit`。调用时持有 `condition`。
    private func evict(toFit limit: Int64) {
        while total > limit {
            guard let (id, entry) = entries.filter({ $0.value.leases == 0 }).min(by: { $0.value.lastUse < $1.value.lastUse }) else { return }
            try? FileManager.default.removeItem(at: entry.url)
            entries[id] = nil
            total -= entry.bytes
        }
    }

    /// 本机副本的个数和总字节数（测试用）。
    var usage: (count: Int, bytes: Int64) {
        condition.lock()
        defer { condition.unlock() }
        return (entries.count, total)
    }

    /// 按顺序读完源文件，写进本进程的目录。源图读失败或中途变了时抛错；本机这边出问题时返回 nil（照旧直接读）。
    private func copy(_ source: URL, _ id: Identity, reportingAs original: URL) throws(RenderError) -> URL? {
        guard let directory = try? ownDirectory() else { return nil }
        if let free = availableBytes(directory), free < id.size + reserveBytes { return nil }

        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw .sourceReadFailed(original, errno) }
        defer { close(input) }
        // 打开的就是刚才 stat 的那个文件。
        guard Identity(descriptor: input, path: id.path) == id else { throw .sourceChanged(original) }

        let partial = directory.appending(path: UUID().uuidString + ".partial")
        let output = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard output >= 0 else { return nil }
        var kept = false
        defer {
            close(output)
            if !kept { unlink(partial.path) }
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var copied: Int64 = 0
        while true {
            let n = read(input, buffer, chunkSize)
            if n < 0 {
                if errno == EINTR { continue }
                throw .sourceReadFailed(original, errno)
            }
            if n == 0 { break }
            var offset = 0
            while offset < n {
                let w = write(output, buffer + offset, n - offset)
                if w < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                offset += w
            }
            copied += Int64(n)
            afterChunk?(copied)
        }
        // 复制前后：大小、修改时间、文件号、设备都没变，读到的字节数也等于大小。
        guard copied == id.size, Identity(descriptor: input, path: id.path) == id, Identity(path: source.path) == id else {
            throw .sourceChanged(original)
        }
        let ext = original.pathExtension
        let final = directory.appending(path: UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
        guard rename(partial.path, final.path) == 0 else { return nil }
        kept = true
        return final
    }

    // MARK: - 目录

    /// 本进程的目录，第一次用时创建：先用 `.tmp` 名字建好并锁上 `.lock`，再改成正式名字，清理别的目录时不会误删。
    private func ownDirectory() throws -> URL {
        try directoryLock.withLock {
            if let directory { return directory }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let name = "\(getpid())-\(UUID().uuidString)"
            let temporary = root.appending(path: name + ".tmp", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
            let fd = open(temporary.appending(path: ".lock").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if fd >= 0 { close(fd) }
                try? FileManager.default.removeItem(at: temporary)
                throw CocoaError(.fileWriteUnknown)
            }
            let final = root.appending(path: name, directoryHint: .isDirectory)
            guard Darwin.rename(temporary.path, final.path) == 0 else {
                close(fd)
                try? FileManager.default.removeItem(at: temporary)
                throw CocoaError(.fileWriteUnknown)
            }
            lockDescriptor = fd
            directory = final
            Self.removeAtExit(final)
            return final
        }
    }

    /// 删掉本进程的全部副本和目录（退出时、测试用）。还在用的副本由 mmap 和已打开的文件保持可读。
    func removeAll() {
        condition.lock()
        entries = [:]
        total = 0
        condition.unlock()
        directoryLock.withLock {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            if lockDescriptor >= 0 { close(lockDescriptor) }
            directory = nil
            lockDescriptor = -1
        }
    }

    /// 清理已经退出（或崩溃）的进程留下的目录：`.lock` 能锁上就说明原来的进程不在了。
    /// 没改成正式名字的 `.tmp` 目录和没有 `.lock` 的目录超过 `age` 才删。
    func sweepLeftovers(olderThan age: TimeInterval = 3600) {
        let own = directoryLock.withLock { directory?.lastPathComponent }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return }
        for item in items where item.lastPathComponent != own {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let isOld = Date().timeIntervalSince(modified) > age
            if item.pathExtension == "tmp" {
                if isOld { try? FileManager.default.removeItem(at: item) }
                continue
            }
            let fd = open(item.appending(path: ".lock").path, O_RDONLY)
            guard fd >= 0 else {
                if isOld { try? FileManager.default.removeItem(at: item) }
                continue
            }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { try? FileManager.default.removeItem(at: item) }
            close(fd)
        }
    }

    /// 每个进程第一次创建渲染器时，在后台清理一次 ``shared`` 目录下的残留。
    static func sweepSharedLeftoversOnce() {
        _ = sweptAtLaunch
    }

    private static let sweptAtLaunch: Void = {
        DispatchQueue.global(qos: .utility).async { shared.sweepLeftovers() }
    }()

    // MARK: - 退出时清理

    private static let exitDirectories = Mutex<[String]>([])
    private static let exitHook: Void = {
        atexit {
            for path in SourceStaging.exitDirectories.withLock({ $0 }) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }()

    private static func removeAtExit(_ directory: URL) {
        _ = exitHook
        exitDirectories.withLock { $0.append(directory.path) }
    }
}

extension RenderError {
    /// 复制到本机时读源图失败（多半是 NAS 或移动硬盘断开了）。
    static func sourceReadFailed(_ url: URL, _ code: Int32) -> RenderError {
        RenderError(code: "render.source_read_failed",
                    message: "无法读取 \(url.lastPathComponent)：复制到本机时读取中断（\(String(cString: strerror(code)))）",
                    hint: "源图所在的 NAS 或移动硬盘可能已断开，重新连接后再试")
    }

    /// 复制到本机期间源图被改了。
    static func sourceChanged(_ url: URL) -> RenderError {
        RenderError(code: "render.source_changed",
                    message: "\(url.lastPathComponent) 在复制到本机时被修改了（大小、修改时间或文件号与开始时不同）",
                    hint: "等文件写完、不再变化后再试")
    }
}
