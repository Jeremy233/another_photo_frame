import CryptoKit
import Darwin
import Foundation
import PhotoFrameCore
import Synchronization

/// 本次执行独占的临时目录（§9.2、§12.2）：
///
/// ```text
/// <输出根目录>/.photoframe-staging/<attemptId>/
///     render/        渲染器写文件的地方
///     <作品名>/      校验后按最终文件名组装，再整个目录原子改名到目的地
/// ```
///
/// 放在输出根目录下，保证与目的地同卷，`rename` 才是原子的。
public struct StagingArea: Hashable, Sendable {
    public var attemptId: AttemptID
    /// `.photoframe-staging`
    public var stagingRoot: URL
    /// `.photoframe-staging/<attemptId>`
    public var directory: URL
    public var renderDirectory: URL { directory.appending(path: "render", directoryHint: .isDirectory) }
    /// 组装作品目录的地方，发布时整个改名到目的地。
    var assemblyDirectory: URL { directory.appending(path: "work", directoryHint: .isDirectory) }
    /// 覆盖时挪开的旧作品目录。
    var replacedDirectory: URL { directory.appending(path: "replaced", directoryHint: .isDirectory) }
}

/// 先写临时目录、校验、再原子发布（§9.2、§12.2）。
///
/// - 整个作品目录一次改名发布，目的地要么没有这个目录，要么是完整的成品，不会出现半成品。
/// - 改名用 `renamex_np(RENAME_EXCL)`：默认（``ConflictPolicy/versionSuffix``）目标已存在时改用下一个版本号；
///   两个任务同时发布同名作品也不会互相覆盖。显式选择 ``ConflictPolicy/overwrite`` 时，
///   只替换本软件之前发布的作品目录，步骤见 `replacePublished`。
/// - 只接受临时目录里的普通文件；符号链接、硬链接（可能指向原图）、目录都拒绝，原图永远不会被移动或改写。
/// - 清理只删除本次执行自己的 `<attemptId>` 目录。
public struct AtomicExporter: Sendable {
    public static let stagingDirectoryName = ".photoframe-staging"

    public var verifier: any OutputVerifier
    /// 互斥改名；测试用来模拟中途失败。
    var renameOperation: RenameOperation = .exclusive

    public init(verifier: any OutputVerifier = SignatureOutputVerifier()) {
        self.verifier = verifier
    }

    public static func stagingRoot(for destinationRoot: URL) -> URL {
        destinationRoot.appending(path: stagingDirectoryName, directoryHint: .isDirectory)
    }

    public func makeStaging(destinationRoot: URL, attemptId: AttemptID) throws(ApplicationError) -> StagingArea {
        let root = Self.stagingRoot(for: destinationRoot)
        let area = StagingArea(
            attemptId: attemptId, stagingRoot: root,
            directory: root.appending(path: attemptId.description, directoryHint: .isDirectory))
        do {
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            throw .stagingFailed(error.localizedDescription)
        }
        // 清理时会 rmdir 空的 `.photoframe-staging`。本进程内用锁与创建互斥；
        // 别的进程（GUI 与 CLI 同时导出到同一目录）仍可能在两级 mkdir 之间删掉它，
        // 这时 mkdir 报 ENOENT（APFS 上正在删除的目录也可能报 EINVAL），从头再来。
        let paths = [root.path, area.directory.path, area.renderDirectory.path]
        let lastError: Int32 = Self.stagingLock.withLock { _ in
            var lastError: Int32 = 0
            for _ in 0..<8 {
                lastError = 0
                for path in paths {
                    let code = path.withCString { mkdir($0, 0o755) == 0 ? 0 : errno }
                    if code != 0 && code != EEXIST {
                        lastError = code
                        break
                    }
                }
                guard lastError == ENOENT || lastError == EINVAL else { break }
            }
            return lastError
        }
        guard lastError == 0 else { throw .stagingFailed(String(cString: strerror(lastError))) }
        return area
    }

    /// 删除本次执行的临时目录；`.photoframe-staging` 空了也一并删除（不空说明有别的任务在用，保留）。
    public func discard(_ area: StagingArea) {
        try? FileManager.default.removeItem(at: area.directory)
        Self.stagingLock.withLock { _ in _ = rmdir(area.stagingRoot.path) }
    }

    /// 删除本次执行的临时文件，但留下挪开的旧作品目录（`replaced/`）。
    func discardKeepingReplaced(_ area: StagingArea) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: area.directory.path)) ?? [] where name != area.replacedDirectory.lastPathComponent {
            try? fm.removeItem(at: area.directory.appending(path: name))
        }
    }

    /// 本进程内让「创建临时目录」与「删除空的 `.photoframe-staging`」互斥。
    static let stagingLock = Mutex(())

    /// 校验渲染结果，组装成作品目录并原子发布。成功或失败都会删除临时目录。
    ///
    /// - Parameter isCanceled: 每移动一个文件、以及最终改名前检查；返回 true 时放弃发布并抛出 `CancellationError`。
    ///   最终改名完成后就不能再取消。
    /// - Parameter protectedSources: 队列中所有任务的源文件。覆盖时目标目录里含有其中任何一个就拒绝；
    ///   本任务的源文件总会加进来。
    public func publish(
        _ result: JobRenderResult,
        spec: JobSpec,
        jobId: JobID,
        staging: StagingArea,
        startedAt: Date,
        protectedSources: [URL] = [],
        isCanceled: @Sendable () -> Bool = { false }
    ) throws -> OutputManifest {
        // 覆盖失败、旧目录既没能恢复也没能挪出临时目录时，它还在 `replaced/` 里：只清理别的部分，
        // 留给用户取回（残留的临时目录 24 小时后才由 D-55 清理）。
        var keepsReplaced = false
        defer { keepsReplaced ? discardKeepingReplaced(staging) : discard(staging) }
        let format = spec.preset.output.format
        let outputs = try checkedOutputs(result.outputs, staging: staging, format: format)

        // 组装：按最终文件名移到作品目录。临时目录里用固定的名字，作品名是 `render`、`replaced` 时也不会和
        // 同一目录下的渲染目录、挪开的旧目录撞名；最终改名时才用作品名。
        let workName = spec.destination.naming.workName(source: spec.source, preset: spec.preset)
        let assembly = staging.assemblyDirectory
        do {
            try FileManager.default.createDirectory(at: assembly, withIntermediateDirectories: false)
        } catch {
            throw ApplicationError.stagingFailed(error.localizedDescription)
        }
        var staged: [(output: JobRenderedOutput, name: String, size: Int64, hash: String?)] = []
        let positions = OutputNaming.positionCount(of: outputs.map(\.role))
        for output in outputs {
            if isCanceled() { throw CancellationError() }
            let name = OutputNaming.fileName(for: output.role, format: format, outputCount: positions)
            let target = assembly.appending(path: name, directoryHint: .notDirectory)
            do {
                try FileManager.default.moveItem(at: output.fileURL, to: target)
            } catch {
                throw ApplicationError.stagingFailed(error.localizedDescription)
            }
            let size = Self.fileSize(target) ?? 0
            let hash = spec.destination.computeHashes ? try Self.sha256(of: target) : nil
            staged.append((output, name, size, hash))
        }
        try Self.markAsPublished(assembly, jobId: jobId)

        // 发布：整个作品目录一次改名。
        let platformDir = spec.destination.rootDirectory.appending(
            path: OutputNaming.platformFolderName(for: spec.preset.platform), directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: platformDir, withIntermediateDirectories: true)
        } catch {
            throw ApplicationError.publishFailed(error.localizedDescription)
        }
        if isCanceled() { throw CancellationError() }
        var warnings = result.warnings
        let published: URL
        switch spec.destination.conflictPolicy {
        case .versionSuffix:
            published = try renameExclusive(assembly, into: platformDir, baseName: workName)
        case .overwrite:
            let target = platformDir.appending(path: workName, directoryHint: .isDirectory)
            let replaced = try publishReplacing(
                assembly, at: target, staging: staging, protectedSources: protectedSources + [spec.source.fileURL],
                keepsReplaced: &keepsReplaced)
            published = target
            if replaced {
                warnings.append(ApplicationWarning(code: "export.replaced_previous", message: "已替换之前导出的 \(target.path)"))
            }
        }

        let items = staged.map { s in
            OutputManifestItem(
                role: s.output.role,
                fileURL: published.appending(path: s.name, directoryHint: .notDirectory),
                fileName: s.name,
                pixelSize: s.output.pixelSize,
                colorProfile: s.output.colorProfile,
                fileSizeBytes: s.size,
                sha256: s.hash,
                warnings: s.output.warnings)
        }
        return OutputManifest(
            jobId: jobId, attemptId: staging.attemptId, directory: published, items: items,
            warnings: warnings, startedAt: startedAt, finishedAt: Date())
    }

    /// 检查渲染器返回的输出项，按轮播顺序排列。
    func checkedOutputs(_ outputs: [JobRenderedOutput], staging: StagingArea, format: OutputSettings.Format) throws(ApplicationError) -> [JobRenderedOutput] {
        guard !outputs.isEmpty else { throw .noOutputs() }
        var seen: Set<JobOutputRole> = []
        let renderDir = staging.renderDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for output in outputs {
            if case .slide(let p) = output.role, p < 1 { throw .invalidRole(output.role) }
            guard seen.insert(output.role).inserted else { throw .duplicateRole(output.role) }

            let path = output.fileURL.standardizedFileURL.path
            // 先按字面路径判断，再解析符号链接判断，防止 `render/../../原图` 或指向外部的链接。
            let resolved = output.fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            let literalParent = output.fileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard literalParent.hasPrefix(renderDir), resolved.hasPrefix(renderDir) else {
                throw .outputOutsideStaging(path)
            }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: path)
            } catch {
                throw .outputMissing(path)
            }
            // attributesOfItem 不跟随符号链接，所以链接本身会被识别出来。
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.referenceCount] as? NSNumber)?.intValue ?? 1 == 1
            else { throw .outputNotRegularFile(path) }
            guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0 else { throw .outputEmpty(path) }
            guard output.pixelSize.isPositive else { throw .invalidPixelSize(output.role, output.pixelSize) }
            try verifier.verify(output.fileURL, format: format)
        }
        return outputs.sorted { $0.role < $1.role }
    }

    /// 把 `source` 改名为 `directory/<baseName>`；已存在时依次尝试 `_v2`、`_v3`…。返回最终路径。
    func renameExclusive(_ source: URL, into directory: URL, baseName: String) throws(ApplicationError) -> URL {
        for version in 1...OutputNaming.maxVersion {
            let target = directory.appending(path: OutputNaming.versioned(baseName, version: version), directoryHint: .isDirectory)
            let code = renameOperation.rename(source, target)
            if code == 0 { return target }
            guard code == EEXIST || code == ENOTEMPTY else {
                throw .publishFailed(String(cString: strerror(code)))
            }
        }
        throw .versionsExhausted(baseName)
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func sha256(of url: URL) throws(ApplicationError) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw .outputMissing(url.path) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // 读失败时报错，不把读到一半的内容当成完整文件的 hash。
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch {
                throw .publishFailed("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)")
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
