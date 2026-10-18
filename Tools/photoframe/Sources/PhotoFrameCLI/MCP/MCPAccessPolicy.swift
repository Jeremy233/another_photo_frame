import Darwin
import Foundation
import PhotoFrameApplication

/// MCP 的文件访问白名单与资源上限（§11.4 安全规则、§12.2）。
///
/// - 允许读取的输入目录、允许写入的输出目录由用户在 MCP 客户端配置里显式给出（`--allow-read` / `--allow-write`
///   或环境变量）；没有配置时拒绝所有文件访问。
/// - 只接受绝对路径；含 `.`、`..` 段、控制字符的路径直接拒绝。
/// - 先按字面判断是否在白名单内（不在就不碰文件系统，不泄露文件是否存在），再解析符号链接，解析后的真实路径
///   也必须在白名单内（拒绝符号链接逃逸）。
/// - 输入必须是普通文件且只有一个硬链接（硬链接可能指向白名单外的文件，无法判断另一端在哪）。
public struct MCPAccessPolicy: Sendable {
    /// 一个白名单目录：用户写的形式和解析符号链接后的真实路径（例如 `/tmp` → `/private/tmp`）。
    struct Root: Sendable {
        var given: String
        var real: String
    }

    let readRoots: [Root]
    let writeRoots: [Root]
    public let limits: MCPLimits

    /// 根目录必须是已存在的目录，不能是 `/`。
    public init(readRoots: [String], writeRoots: [String], limits: MCPLimits = MCPLimits()) throws(ApplicationError) {
        func root(_ text: String, _ option: String) throws(ApplicationError) -> Root {
            let expanded = (text as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw ApplicationError(code: "mcp.invalid_root", message: "\(option) 需要绝对路径：\(text)")
            }
            let given = URL(filePath: expanded).standardizedFileURL.path
            guard let real = Self.realPath(given), Self.isDirectory(real) else {
                throw ApplicationError(code: "mcp.invalid_root", message: "\(option) 不是已存在的目录：\(text)")
            }
            guard real != "/", given != "/" else {
                throw ApplicationError(code: "mcp.invalid_root", message: "\(option) 不能是根目录 /")
            }
            return Root(given: given, real: real)
        }
        self.readRoots = try readRoots.map { (t) throws(ApplicationError) in try root(t, "--allow-read") }
        self.writeRoots = try writeRoots.map { (t) throws(ApplicationError) in try root(t, "--allow-write") }
        self.limits = limits
    }

    public var readDirectories: [String] { readRoots.map(\.real) }
    public var writeDirectories: [String] { writeRoots.map(\.real) }

    // MARK: - 输入

    /// 检查一个输入文件，返回解析后的真实路径（之后只用这个路径访问）。
    func inputFile(_ text: String, argument: String) throws(ApplicationError) -> URL {
        guard !readRoots.isEmpty else { throw .noAccess(read: true) }
        let lexical = try Self.lexicalPath(text, argument: argument)
        guard Self.lexicallyContains(readRoots, lexical) else { throw .notAllowed(argument, read: true) }
        guard let real = Self.realPath(lexical) else {
            // 不存在时也按真实路径判断：最深的已存在祖先（经目录链接可能在白名单外）不在白名单内就与「存在但在外面」报同样的错，
            // 不泄露白名单以外的文件是否存在。
            guard let existing = Self.existingAncestor(lexical), Self.contains(readRoots, existing.real, real: true) else {
                throw .notAllowed(argument, read: true)
            }
            throw ApplicationError(code: "source.not_found", message: "找不到文件：\(lexical)")
        }
        guard Self.contains(readRoots, real, real: true) else { throw .notAllowed(argument, read: true) }
        var st = stat()
        guard lstat(real, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw ApplicationError(code: "source.not_regular_file", message: "\(argument) 不是普通文件")
        }
        guard st.st_nlink == 1 else {
            throw ApplicationError(code: "mcp.hard_link_refused", message: "\(argument) 有多个硬链接，拒绝读取",
                                   hint: "硬链接可能指向允许目录以外的文件；请复制一份普通文件再用")
        }
        guard Int64(st.st_size) <= limits.maxInputBytes else {
            throw ApplicationError(code: "mcp.file_too_large",
                                   message: "\(argument) 超过单文件上限 \(limits.maxInputBytes / 1_048_576) MiB",
                                   hint: "在 MCP 客户端配置里调大 --max-input-mb")
        }
        return URL(filePath: real)
    }

    // MARK: - 输出

    /// 检查一个输出目录（可以还不存在），返回解析后的路径：最深的已存在祖先换成真实路径，其余各段原样接上。
    func outputDirectory(_ text: String, argument: String) throws(ApplicationError) -> URL {
        guard !writeRoots.isEmpty else { throw .noAccess(read: false) }
        let lexical = try Self.lexicalPath(text, argument: argument)
        guard Self.lexicallyContains(writeRoots, lexical) else { throw .notAllowed(argument, read: false) }
        let resolved = try writablePath(lexical, argument: argument)
        if let real = Self.realPath(resolved.path), !Self.isDirectory(real) {
            throw ApplicationError(code: "job.destination_invalid", message: "\(argument) 不是目录")
        }
        return resolved
    }

    /// 已经过白名单的输出路径（例如校验阶段推算出的作品目录）在写入前再查一次：已存在的部分不能是指向白名单外的符号链接。
    func checkWritable(_ url: URL, argument: String) throws(ApplicationError) {
        _ = try writablePath(url.standardizedFileURL.path, argument: argument)
    }

    private func writablePath(_ lexical: String, argument: String) throws(ApplicationError) -> URL {
        guard let existing = Self.existingAncestor(lexical), Self.contains(writeRoots, existing.real, real: true) else {
            throw .notAllowed(argument, read: false)
        }
        return existing.missing.reduce(URL(filePath: existing.real, directoryHint: .isDirectory)) {
            $0.appending(path: $1, directoryHint: .isDirectory)
        }
    }

    /// 最深的已存在祖先的真实路径，以及其后还不存在的各段。路径上有悬空的符号链接时为 nil：
    /// 它不存在但占着名字，不能当成「还没创建」，也不知道指向哪里。
    private static func existingAncestor(_ lexical: String) -> (real: String, missing: [String])? {
        var existing = lexical
        var missing: [String] = []
        while true {
            if let real = realPath(existing) { return (real, missing) }
            var st = stat()
            if lstat(existing, &st) == 0 || existing == "/" { return nil }
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
    }

    // MARK: - 错误信息里的路径

    /// 把字符串里白名单以外的绝对路径换成占位符（错误信息、警告都经过这里，§11.4「返回安全错误」）。
    /// `photoframe://…` 这类 URI 保留；`file:` URL 按路径处理。
    ///
    /// 路径在哪里结束只能估计（目录名、文件名可以含空格和括号）：
    /// - 以白名单目录（用户写的形式或真实路径，长的优先）开头、后面是结尾、`/` 或标点时，整个目录都算在路径里，即使它含空格或括号；
    /// - 之后用空格隔开、含 `/` 的词也算在路径里（`<目录>/My Photos/a.jpg`），遇到中文标点、引号、换行或新的绝对路径为止；
    /// - 整条路径在白名单内才原样保留；否则连同后面直到标点为止的词一起隐藏（宁可多藏，不能少藏）。
    func redact(_ text: String) -> String {
        guard text.contains("/") else { return text }
        let ns = text as NSString
        let roots = redactionRoots
        var out = ""
        var last = 0
        for match in Self.pathPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let start = match.range.location
            guard start >= last else {
                // 已经并入前一个路径。续接只在空白或标点处结束，不会只并入半个；万一如此，剩下的部分按隐藏处理。
                if NSMaxRange(match.range) > last {
                    out += Self.hiddenPath
                    last = NSMaxRange(match.range)
                }
                continue
            }
            out += ns.substring(with: NSRange(location: last, length: start - last))
            let token = ns.substring(with: match.range)
            if match.range(at: 1).location != NSNotFound {
                if token.lowercased().hasPrefix("file:") {
                    out += isVisible(URL(string: token)?.path ?? token) ? token : Self.hiddenPath
                } else {
                    out += token
                }
                last = NSMaxRange(match.range)
                continue
            }
            let base = Self.rootEnd(in: text, ns, at: start, roots: roots) ?? NSMaxRange(match.range)
            let (pathEnd, wordsEnd) = Self.continuation(in: text, ns, after: base)
            let path = ns.substring(with: NSRange(location: start, length: pathEnd - start))
            if isVisible(ns.substring(with: NSRange(location: start, length: base - start))), isVisible(path) {
                out += path
                last = pathEnd
            } else {
                out += Self.hiddenPath
                last = wordsEnd
            }
        }
        return out + ns.substring(from: last)
    }

    private func isVisible(_ path: String) -> Bool {
        let standardized = URL(filePath: path).standardizedFileURL.path
        return Self.lexicallyContains(readRoots + writeRoots, standardized)
    }

    /// 白名单目录的两种写法，长的在前（一个目录是另一个加空格的前缀时先匹配长的）。
    private var redactionRoots: [String] {
        Set((readRoots + writeRoots).flatMap { [$0.given, $0.real] }).sorted { $0.utf16.count > $1.utf16.count }
    }

    static let hiddenPath = "<路径已隐藏>"

    /// `start` 处以白名单目录开头、目录后面是结尾、`/` 或标点（不是空白：`<目录> 2/x` 可能是旁边的另一个目录）时，
    /// 返回目录及其后到下一个空白或标点为止的位置；否则为 nil。
    private static func rootEnd(in text: String, _ ns: NSString, at start: Int, roots: [String]) -> Int? {
        for root in roots {
            let found = ns.range(of: root, options: .anchored, range: NSRange(location: start, length: ns.length - start))
            guard found.location != NSNotFound else { continue }
            let end = NSMaxRange(found)
            guard end == ns.length || rootBoundary.contains(ns.character(at: end)) else { continue }
            let run = pathRun.firstMatch(in: text, options: .anchored, range: NSRange(location: end, length: ns.length - end))
            return end + (run?.range.length ?? 0)
        }
        return nil
    }

    /// `base` 之后用空格隔开的词：返回（含 `/` 的最后一个词的结尾，全部词的结尾）。
    private static func continuation(in text: String, _ ns: NSString, after base: Int) -> (path: Int, words: Int) {
        let range = NSRange(location: base, length: ns.length - base)
        guard let match = continuationPattern.firstMatch(in: text, options: [.anchored, .withTransparentBounds], range: range),
              match.range.length > 0 else { return (base, base) }
        let words = NSMaxRange(match.range)
        let slash = ns.range(of: "/", options: .backwards, range: NSRange(location: base, length: words - base))
        guard slash.location != NSNotFound else { return (base, words) }
        let space = ns.rangeOfCharacter(from: .whitespaces, options: [], range: NSRange(location: slash.location, length: words - slash.location))
        return (space.location == NSNotFound ? words : space.location, words)
    }

    /// 第 1 组是 `scheme://…` 形式的 URI；否则是以 `/` 开头、前面不是字母数字的一串非空白字符（遇到常见的中英文标点结束）。
    private static let pathPattern = try! NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z0-9+.-]*:/+[^\s"'，。；、：（）()<>\[\]{}]*)|(?<![\p{L}\p{N}_.~-])/[^\s"'，。；、：（）()<>\[\]{}]*"#)

    /// 与 `pathPattern` 相同的「一串非空白、非标点字符」。
    private static let pathRun = try! NSRegularExpression(pattern: #"[^\s"'，。；、：（）()<>\[\]{}]*"#)

    /// 白名单目录后面可以是什么（不含空白）。
    private static let rootBoundary = Set(#"/"'，。；、：（）()<>[]{}"#.utf16)

    /// 续接的词：用空格或制表符隔开，遇到换行、中文标点、引号、尖括号停下（都是 `pathPattern` 的分隔符，续接不会只并入半个路径）。
    /// 词里可以有括号；`/` 前面必须是字母、数字、`_.~-` 或右括号（`Trip (2024)/a.jpg`），否则是新的路径或 URI，整个词都不算。
    private static let continuationPattern = try! NSRegularExpression(
        pattern: #"(?:[\t\p{Zs}]*(?:[^\s"'，。；、：（）<>/]|(?<=[\p{L}\p{N}_.~)\]}-])/)+(?=[\s"'，。；、：（）<>]|$))*"#)

    // MARK: - 工具

    private static func lexicalPath(_ text: String, argument: String) throws(ApplicationError) -> String {
        let invalid = { (why: String) in ApplicationError(code: "mcp.invalid_path", message: "\(argument) \(why)") }
        guard !text.isEmpty, text.utf8.count <= Int(PATH_MAX) else { throw invalid("为空或过长") }
        guard !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { throw invalid("含控制字符") }
        let expanded = (text as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw invalid("必须是绝对路径") }
        let parts = expanded.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == ".." || $0 == "." }) else { throw invalid("不能包含 . 或 .. 段") }
        return "/" + parts.joined(separator: "/")
    }

    /// 按字面判断（用户写的形式或真实路径都算），只用来决定要不要碰文件系统；之后还要检查真实路径。
    private static func lexicallyContains(_ roots: [Root], _ path: String) -> Bool {
        contains(roots, path, real: false) || contains(roots, path, real: true)
    }

    private static func contains(_ roots: [Root], _ path: String, real: Bool) -> Bool {
        roots.contains { root in
            let base = real ? root.real : root.given
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    /// 解析全部符号链接；路径不存在时为 nil。
    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}

/// MCP 服务器的资源上限（§11.4：单文件尺寸、处理队列、预览内存、输出总量）。都可以用 `mcp serve` 的参数调整。
public struct MCPLimits: Sendable {
    /// 单个输入文件的字节上限。D-18 不限制像素尺寸，这里只防止误传超大文件。
    public var maxInputBytes: Int64 = 2 << 30
    /// 预览页长边上限（像素）。
    public var maxPreviewEdge = 2048
    /// 一次预览的页数上限。
    public var maxPreviewPages = 12
    /// 内联返回给客户端的预览 PNG 总字节上限。
    public var maxInlinePreviewBytes = 8 << 20
    /// 同时未结束（排队或执行中）的导出任务上限。
    public var maxActiveJobs = 16
    /// 本次会话写出的文件总量上限（导出成品 + 预览文件）。
    public var maxOutputBytes: Int64 = 20 << 30

    public init() {}
}

extension ApplicationError {
    static func noAccess(read: Bool) -> Self {
        read
            ? Self(code: "mcp.no_read_access", message: "没有配置允许读取的目录，拒绝读取文件",
                   hint: "在 MCP 客户端配置里给 photoframe mcp serve 加 --allow-read <目录>")
            : Self(code: "mcp.no_write_access", message: "没有配置允许写入的目录，拒绝写文件",
                   hint: "在 MCP 客户端配置里给 photoframe mcp serve 加 --allow-write <目录>")
    }

    static func notAllowed(_ argument: String, read: Bool) -> Self {
        Self(code: "mcp.path_not_allowed",
             message: "\(argument) 不在允许\(read ? "读取" : "写入")的目录内（或经符号链接指向目录外）",
             hint: "用 photoframe://access 资源查看允许的目录")
    }
}
