import ArgumentParser
import Darwin
import Foundation
import MCP
import PhotoFrameApplication
import System

/// `photoframe mcp …`
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp", abstract: "本地 MCP 服务器（给 AI 客户端用）。", subcommands: [ServeCommand.self])

    /// `photoframe mcp serve --allow-read <目录>… --allow-write <目录>…`（§11.3、§11.4）
    struct ServeCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "serve",
            abstract: "以 stdio 运行 MCP 服务器，由 AI 客户端启动。",
            discussion: """
                stdout 只写 MCP 协议消息，日志写 stderr。不联网，不读取任何 token。
                只能读取 --allow-read、写入 --allow-write 指定的目录（也可用环境变量 PHOTOFRAME_MCP_ALLOW_READ /
                PHOTOFRAME_MCP_ALLOW_WRITE，多个目录用 : 分隔）；都没有配置时拒绝所有文件访问。
                客户端关闭连接（stdin 结束）或收到 SIGINT / SIGTERM 时，取消本服务器创建的未完成任务后退出。
                """)

        @Option(name: .customLong("allow-read"), help: ArgumentHelp("允许读取源图的目录（含子目录）。可重复。", valueName: "目录"))
        var allowRead: [String] = []

        @Option(name: .customLong("allow-write"), help: ArgumentHelp("允许写入导出和预览的目录（含子目录）。可重复。", valueName: "目录"))
        var allowWrite: [String] = []

        @Option(name: .customLong("max-input-mb"), help: ArgumentHelp("单个输入文件上限（MiB），默认 2048。", valueName: "n"))
        var maxInputMB: Int?

        @Option(name: .customLong("max-preview-edge"), help: ArgumentHelp("预览长边上限（像素），默认 2048。", valueName: "px"))
        var maxPreviewEdge: Int?

        @Option(name: .customLong("max-active-jobs"), help: ArgumentHelp("同时未结束的导出任务上限，默认 16。", valueName: "n"))
        var maxActiveJobs: Int?

        @Option(name: .customLong("max-output-mb"), help: ArgumentHelp("本次会话写出的文件总量上限（MiB），默认 20480。", valueName: "n"))
        var maxOutputMB: Int?

        @Option(name: .long, help: ArgumentHelp("同时执行的任务数（默认按 CPU 核数，D-53）。", valueName: "n"))
        var jobs: Int?

        func validate() throws {
            for value in [maxInputMB, maxPreviewEdge, maxActiveJobs, maxOutputMB, jobs] {
                if let value, value < 1 { throw ValidationError("上限和 --jobs 应为正整数。") }
            }
        }

        var limits: MCPLimits {
            var limits = MCPLimits()
            if let maxInputMB { limits.maxInputBytes = Int64(maxInputMB) << 20 }
            if let maxPreviewEdge { limits.maxPreviewEdge = maxPreviewEdge }
            if let maxActiveJobs { limits.maxActiveJobs = maxActiveJobs }
            if let maxOutputMB { limits.maxOutputBytes = Int64(maxOutputMB) << 20 }
            return limits
        }

        func run() async throws {
            let ctx = CommandContext(command: "mcp serve", json: false)
            let env = ctx.env
            func directories(_ given: [String], _ variable: String) -> [String] {
                given + (env.variables[variable] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
            }
            let policy: MCPAccessPolicy
            do {
                policy = try MCPAccessPolicy(
                    readRoots: directories(allowRead, "PHOTOFRAME_MCP_ALLOW_READ"),
                    writeRoots: directories(allowWrite, "PHOTOFRAME_MCP_ALLOW_WRITE"), limits: limits)
            } catch {
                throw ctx.fail(error, status: .usage)
            }
            let service = try ctx.makeService(.init(maxConcurrentJobs: jobs))
            let photoframe = PhotoFrameMCPServer(service: service, policy: policy)

            func describe(_ dirs: [String]) -> String { dirs.isEmpty ? "（未配置，拒绝）" : dirs.joined(separator: ", ") }
            ctx.log("photoframe MCP \(PhotoFrameCLI.version)（协议 \(MCP.Version.latest)）：stdio 已就绪")
            ctx.log("允许读取：\(describe(policy.readDirectories))")
            ctx.log("允许写入：\(describe(policy.writeDirectories))")

            let server = await photoframe.makeServer()
            env.interrupts.onInterrupt { Task { await server.stop() } }
            // 客户端不再读 stdout / stderr 时，写入返回 EPIPE（发送失败），而不是被 SIGPIPE 直接杀掉：
            // 这样 stdin 结束后照常取消本服务器的任务、清理临时目录。
            signal(SIGPIPE, SIG_IGN)
            do {
                try await server.start(transport: MCPStdioTransport(output: Self.protocolOutput()))
            } catch {
                throw ctx.fail(ApplicationError(code: "mcp.transport", message: "无法启动 stdio：\(error)"), status: .internalError)
            }
            await server.waitUntilCompleted()
            await server.stop()
            await photoframe.shutdown()
            ctx.log(env.interrupts.isTriggered ? "已中断：未完成的任务已取消。" : "客户端已断开，退出。")
            if env.interrupts.isTriggered { throw CLIExit(status: .interrupted) }
        }

        /// 协议消息专用的 stdout：复制一份原来的 stdout 给传输层，再把 fd 1 指向 stderr，
        /// 这样任何意外写到 stdout 的内容（库里的 print 等）都进 stderr，不会破坏协议。
        static func protocolOutput() -> FileDescriptor {
            let fd = dup(STDOUT_FILENO)
            guard fd >= 0 else { return .standardOutput }
            dup2(STDERR_FILENO, STDOUT_FILENO)
            return FileDescriptor(rawValue: fd)
        }
    }
}
