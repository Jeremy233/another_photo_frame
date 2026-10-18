import Darwin
import Foundation

/// 互斥改名：目标已存在时失败。返回 0 或 errno。
struct RenameOperation: Sendable {
    var rename: @Sendable (_ from: URL, _ to: URL) -> Int32

    static let exclusive = RenameOperation { from, to in
        from.path.withCString { f in
            to.path.withCString { t in
                if renamex_np(f, t, UInt32(RENAME_EXCL)) == 0 { return 0 }
                let code = errno
                // exFAT 等卷不支持 RENAME_EXCL（ENOTSUP），改用普通 rename 并自己挡住已存在的目标。
                return code == ENOTSUP ? renameUnlessExists(f, t) : code
            }
        }
    }

    /// 不支持 `RENAME_EXCL` 的卷上的互斥改名：目标已存在（包括悬空的符号链接）时返回 EEXIST。
    /// 普通 `rename` 只会替换空目录；要发布的作品目录和挪开的旧目录都不是空的，两个任务同时发布同名目录时
    /// 后到的仍然得到 EEXIST（ENOTEMPTY），不会互相覆盖。
    static func renameUnlessExists(_ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>) -> Int32 {
        var st = stat()
        if lstat(to, &st) == 0 { return EEXIST }
        guard errno == ENOENT else { return errno }
        if Darwin.rename(from, to) == 0 { return 0 }
        let code = errno
        return code == ENOTEMPTY || code == ENOTDIR || code == EISDIR ? EEXIST : code
    }
}

extension AtomicExporter {
    /// 发布时写在作品目录上的扩展属性，标记「这是本软件发布的」。覆盖只认带这个标记的目录。
    /// 用扩展属性而不是文件，作品目录里只有要上传的图片（D-54）。
    public static let publishedMarkerAttribute = "org.anotherphotoframe.published"

    static func markAsPublished(_ directory: URL, jobId: JobID) throws(ApplicationError) {
        let value = Array(jobId.description.utf8)
        let result = directory.path.withCString { path in
            value.withUnsafeBytes { setxattr(path, publishedMarkerAttribute, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        }
        guard result == 0 else { throw .stagingFailed("无法写入发布标记：\(String(cString: strerror(errno)))") }
    }

    public static func isPublishedByPhotoFrame(_ directory: URL) -> Bool {
        directory.path.withCString { getxattr($0, publishedMarkerAttribute, nil, 0, 0, XATTR_NOFOLLOW) } > 0
    }

    /// 本软件发布的作品目录里允许出现的文件：`00_Cover.jpg`、`01_Slide.png`…，以及 Finder 的 `.DS_Store`。
    static func isPublishedFileName(_ name: String) -> Bool {
        if name == ".DS_Store" { return true }
        return name.wholeMatch(of: /[0-9]{2,}_(Cover|Slide)\.(jpg|png)/) != nil
    }

    /// ``ConflictPolicy/overwrite``：把组装好的 `assembly` 发布到 `target`。目标不存在时直接发布；
    /// 存在时检查后替换。返回是否替换了旧目录。
    ///
    /// 替换步骤（新目录此时已在临时目录里完整校验过）：
    /// 1. 检查旧目录：是真实目录（不是符号链接）、带本软件的发布标记、只含本软件命名的图片、不含任何任务的源文件；
    /// 2. 把旧目录改名挪进本次执行的临时目录；
    /// 3. 把新目录改名就位；失败则把旧目录改名挪回原处；
    /// 4. 删除挪开的旧目录。
    /// - Parameter keepsReplaced: 旧目录既没能恢复、也没能挪出临时目录时设为 true，调用方清理时要留下它。
    func publishReplacing(
        _ assembly: URL, at target: URL, staging: StagingArea, protectedSources: [URL], keepsReplaced: inout Bool
    ) throws(ApplicationError) -> Bool {
        // 目标还不存在：与默认策略一样互斥改名。期间被别人抢先创建（EEXIST）则走替换。
        let first = renameOperation.rename(assembly, target)
        if first == 0 { return false }
        guard first == EEXIST || first == ENOTEMPTY else { throw .publishFailed(String(cString: strerror(first))) }

        try checkReplaceable(target, protectedSources: protectedSources)

        let aside = staging.replacedDirectory
        let moveAside = renameOperation.rename(target, aside)
        guard moveAside == 0 else { throw .publishFailed("无法挪开旧目录：\(String(cString: strerror(moveAside)))") }

        let moveIn = renameOperation.rename(assembly, target)
        guard moveIn == 0 else {
            let restore = renameOperation.rename(aside, target)
            if restore == 0 {
                throw .publishFailed("新目录无法就位，已恢复旧目录：\(String(cString: strerror(moveIn)))")
            }
            // 恢复也失败：把旧目录留在临时目录外，不让清理删掉它。
            let rescue = target.deletingLastPathComponent()
                .appending(path: "\(target.lastPathComponent).previous-\(staging.attemptId)", directoryHint: .isDirectory)
            let rescued = renameOperation.rename(aside, rescue) == 0
            keepsReplaced = !rescued
            throw .publishFailed("新目录无法就位，旧目录也无法恢复；旧目录\(rescued ? "保留在 \(rescue.path)" : "仍在 \(aside.path)")")
        }
        try? FileManager.default.removeItem(at: aside)
        return true
    }

    /// 覆盖前检查旧目录，任何一项不满足都拒绝（`export.overwrite_refused` / `export.overwrite_contains_source`）。
    func checkReplaceable(_ target: URL, protectedSources: [URL]) throws(ApplicationError) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: target.path),
              attributes[.type] as? FileAttributeType == .typeDirectory
        else { throw .overwriteRefused(target.path, "目标不是目录") }
        guard Self.isPublishedByPhotoFrame(target) else {
            throw .overwriteRefused(target.path, "不是本软件发布的作品目录")
        }

        // 源文件按路径与文件身份（设备 + inode，能识别硬链接）两种方式比对。
        let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var sourceIdentities: Set<FileIdentity> = []
        // 已经不存在的源文件不需要保护。
        for source in protectedSources {
            guard let id = FileIdentity(source) else { continue }
            if source.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(targetPath) {
                throw .overwriteContainsSource(target.path, source.path)
            }
            sourceIdentities.insert(id)
        }

        guard let names = try? fm.contentsOfDirectory(atPath: target.path) else {
            throw .overwriteRefused(target.path, "无法读取目录内容")
        }
        for name in names {
            let entry = target.appending(path: name, directoryHint: .notDirectory)
            if let id = FileIdentity(entry), sourceIdentities.contains(id) {
                throw .overwriteContainsSource(target.path, entry.path)
            }
            let type = (try? fm.attributesOfItem(atPath: entry.path))?[.type] as? FileAttributeType
            guard type == .typeRegular, Self.isPublishedFileName(name) else {
                throw .overwriteRefused(target.path, "目录里有不是本软件输出的项目：\(name)")
            }
        }
    }
}

/// 文件身份：设备号 + inode。不跟随符号链接。
struct FileIdentity: Hashable {
    var device: dev_t
    var inode: ino_t

    init?(_ url: URL) {
        var st = stat()
        guard url.path.withCString({ lstat($0, &st) }) == 0 else { return nil }
        device = st.st_dev
        inode = st.st_ino
    }
}
