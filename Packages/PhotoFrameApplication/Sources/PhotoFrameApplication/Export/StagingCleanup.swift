import Darwin
import Foundation

extension AtomicExporter {
    /// 残留临时目录多久算过期（D-55）。
    public static let staleStagingAge: TimeInterval = 24 * 60 * 60

    /// 清理进程崩溃等原因残留的临时目录（D-55）。
    ///
    /// 只删除 `.photoframe-staging` 下名字是 AttemptID（UUID）、且目录树里最新的修改时间早于 `olderThan` 的子目录；
    /// 其他文件、符号链接、正在执行的 Attempt 都不碰。之后 `.photoframe-staging` 空了就删除它。
    /// 返回删除的目录。
    @discardableResult
    public static func removeStaleStaging(
        in destinationRoot: URL,
        olderThan age: TimeInterval = staleStagingAge,
        now: Date = Date(),
        excluding active: Set<AttemptID> = []
    ) -> [URL] {
        let root = stagingRoot(for: destinationRoot)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let cutoff = now.addingTimeInterval(-age)
        var removed: [URL] = []
        for name in names.sorted() {
            guard let attempt = AttemptID(name), !active.contains(attempt) else { continue }
            let dir = root.appending(path: name, directoryHint: .isDirectory)
            guard (try? fm.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType == .typeDirectory,
                  let newest = newestModification(in: dir), newest < cutoff
            else { continue }
            if (try? fm.removeItem(at: dir)) != nil { removed.append(dir) }
        }
        stagingLock.withLock { _ in _ = rmdir(root.path) }
        return removed
    }

    /// 目录本身及其中所有项目（不跟随符号链接）里最新的修改时间。
    static func newestModification(in directory: URL) -> Date? {
        let fm = FileManager.default
        guard var newest = (try? fm.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date else { return nil }
        if let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: []) {
            for case let url as URL in e {
                if let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, date > newest {
                    newest = date
                }
            }
        }
        return newest
    }
}
