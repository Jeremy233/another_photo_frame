import Foundation
import PhotoFrameApplication
import Synchronization

/// 一路文本输出（stdout 或 stderr）。测试里换成内存缓冲。
public final class TextSink: Sendable {
    private let writer: @Sendable (String) -> Void

    public init(_ writer: @escaping @Sendable (String) -> Void) {
        self.writer = writer
    }

    public func write(_ text: String) { writer(text) }
    public func line(_ text: String = "") { writer(text + "\n") }

    // 用会抛错的写入：`mcp serve` 忽略 SIGPIPE，读端关闭时这里得到 EPIPE（丢掉这次输出），而不是 Objective-C 异常。
    public static let standardOutput = TextSink { try? FileHandle.standardOutput.write(contentsOf: Data($0.utf8)) }
    public static let standardError = TextSink { try? FileHandle.standardError.write(contentsOf: Data($0.utf8)) }
}

/// 中断（Ctrl-C）通知。可执行文件把 SIGINT / SIGTERM 接到 `trigger()`；测试直接调用。
public final class InterruptMonitor: Sendable {
    private struct State {
        var triggered = false
        var handlers: [@Sendable () -> Void] = []
    }

    private let state = Mutex(State())

    public init() {}

    public var isTriggered: Bool { state.withLock { $0.triggered } }

    /// 是否有命令登记了中断处理。没有时可执行文件直接退出。
    public var hasHandlers: Bool { state.withLock { !$0.handlers.isEmpty } }

    /// 第一次调用时执行已登记的处理；之后的调用不再重复。
    public func trigger() {
        let handlers = state.withLock { s -> [@Sendable () -> Void] in
            guard !s.triggered else { return [] }
            s.triggered = true
            return s.handlers
        }
        for handler in handlers { handler() }
    }

    /// 登记处理；已经中断过时立即执行。
    public func onInterrupt(_ handler: @escaping @Sendable () -> Void) {
        let fired = state.withLock { s -> Bool in
            if !s.triggered { s.handlers.append(handler) }
            return s.triggered
        }
        if fired { handler() }
    }
}

/// 命令运行环境：输出、当前目录、中断、服务。可执行文件用 ``standard``，测试注入自己的。
public struct CLIEnvironment: Sendable {
    public typealias ServiceFactory = @Sendable (LocalPhotoFrameService.Options) throws(ApplicationError) -> any PhotoFrameService

    public var stdout: TextSink
    public var stderr: TextSink
    public var currentDirectory: URL
    public var interrupts: InterruptMonitor
    /// 本地库（预设库、素材库、绑定）的根目录；nil 按 `LibraryLocation.defaultRoot()` 的规则选（D-78、D-124）。
    /// 可执行文件从环境变量 `PHOTOFRAME_LIBRARY` 取；测试指向临时目录。
    public var libraryRoot: URL?
    /// 进程环境变量（`mcp serve` 读 `PHOTOFRAME_MCP_ALLOW_READ` / `PHOTOFRAME_MCP_ALLOW_WRITE`）。测试里默认为空。
    public var variables: [String: String]
    public var makeService: ServiceFactory

    public init(
        stdout: TextSink, stderr: TextSink, currentDirectory: URL, interrupts: InterruptMonitor = InterruptMonitor(),
        libraryRoot: URL? = nil, variables: [String: String] = [:],
        makeService: @escaping ServiceFactory = { options throws(ApplicationError) in try LocalPhotoFrameService.makeDefault(options) }
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.currentDirectory = currentDirectory
        self.interrupts = interrupts
        self.libraryRoot = libraryRoot
        self.variables = variables
        self.makeService = makeService
    }

    public static let standard = CLIEnvironment(
        stdout: .standardOutput, stderr: .standardError,
        currentDirectory: URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
        libraryRoot: ProcessInfo.processInfo.environment["PHOTOFRAME_LIBRARY"].flatMap { $0.isEmpty ? nil : URL(filePath: ($0 as NSString).expandingTildeInPath, directoryHint: .isDirectory) },
        variables: ProcessInfo.processInfo.environment)

    @TaskLocal public static var current: CLIEnvironment = .standard

    /// 命令行里的路径：展开 `~`，相对路径按当前目录解析。
    public func resolvePath(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(filePath: expanded) : currentDirectory.appending(path: expanded)
        return url.standardizedFileURL
    }
}
