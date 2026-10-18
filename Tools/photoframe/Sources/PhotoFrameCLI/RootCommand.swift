import ArgumentParser
import Foundation
import PhotoFrameApplication

/// `photoframe` 根命令。
public struct RootCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "photoframe",
        abstract: "为社交平台加白边、切全景轮播图，色彩管理正确。",
        discussion: """
            stdout 只输出数据（文件路径或 --json 结果），进度与日志写到 stderr。
            退出码：0 成功，1 内部错误，2 用法错误，3 找不到输入，4 输入无效，5 输出不可用，6 导出任务失败，130 被中断。
            """,
        version: PhotoFrameCLI.version,
        subcommands: [ExportCommand.self, PreviewCommand.self, ImageCommand.self, PresetCommand.self, AssetCommand.self,
                      MCPCommand.self])

    public init() {}
}

public enum PhotoFrameCLI {
    public static let version = "0.9.0"

    /// 解析并运行一条命令，返回退出码。`arguments` 不含程序名。
    public static func run(_ arguments: [String], environment: CLIEnvironment) async -> Int32 {
        await CLIEnvironment.$current.withValue(environment) {
            do {
                var command = try RootCommand.parseAsRoot(arguments)
                if var async = command as? any AsyncParsableCommand {
                    try await async.run()
                } else {
                    try command.run()
                }
                return PhotoFrameExitCode.success.rawValue
            } catch let exit as CLIExit {
                return exit.status.rawValue
            } catch {
                // 帮助与版本：输出到 stdout，退出码 0。其余是参数解析错误：stderr，退出码 2。
                let code = RootCommand.exitCode(for: error)
                let message = RootCommand.fullMessage(for: error)
                if code == .success {
                    if !message.isEmpty { environment.stdout.line(message) }
                    return PhotoFrameExitCode.success.rawValue
                }
                environment.stderr.line(message)
                return PhotoFrameExitCode.usage.rawValue
            }
        }
    }
}

// MARK: - 命令共用

/// 各命令共用的输出与错误处理。
struct CommandContext {
    var command: String
    var json: Bool
    var env: CLIEnvironment { CLIEnvironment.current }

    func makeService(_ options: LocalPhotoFrameService.Options = .init()) throws -> any PhotoFrameService {
        var options = options
        if options.libraryRoot == nil { options.libraryRoot = env.libraryRoot }
        do {
            return try env.makeService(options)
        } catch {
            throw fail(error)
        }
    }

    func log(_ text: String) { env.stderr.line(text) }

    func warn(_ warnings: [ApplicationWarning], prefix: String = "") {
        guard !json else { return }
        for w in warnings { log("warning: \(prefix)[\(w.code)] \(w.message)") }
    }

    /// 报告一个导致命令结束的错误：stderr 写给人看的信息；`--json` 时 stdout 再写一份结构化结果。返回要抛出的退出。
    func fail(_ error: ApplicationError, status: PhotoFrameExitCode? = nil) -> CLIExit {
        let status = status ?? PhotoFrameExitCode(for: error)
        log("error: [\(error.code)] \(error.message)")
        if let hint = error.hint { log("hint: \(hint)") }
        if json {
            env.stdout.line(JSONOutput.encode(Envelope<NoBody>(command: command, exitCode: status, body: nil, error: ErrorJSON(error))))
        }
        return CLIExit(status: status)
    }

    /// 输出成功或部分失败的结果。
    func emit<Body: Encodable>(_ body: Body, status: PhotoFrameExitCode = .success, error: ApplicationError? = nil) {
        env.stdout.line(JSONOutput.encode(Envelope(command: command, exitCode: status, body: body, error: error.map(ErrorJSON.init))))
    }

    /// 把任意错误转成 ApplicationError（服务接口已经是 typed throws，这里只兜底）。
    static func applicationError(_ error: any Error) -> ApplicationError {
        (error as? ApplicationError) ?? ApplicationError(code: "cli.internal", message: String(describing: error))
    }
}

