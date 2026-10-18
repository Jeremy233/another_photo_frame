import Darwin
import Foundation
@testable import PhotoFrameCLI
import Testing

/// 子进程运行 `photoframe mcp serve`，通过真实的 stdin / stdout 走一遍：
/// initialize → tools/list → list_presets → create_export_job → get_job_status → 文件落盘 → 关闭 stdin 后退出。
@Suite("MCP 可执行文件", .enabled(if: photoframeExecutable != nil, "需要 swift test 构建出的 photoframe"))
struct MCPProcessTests {
    @Test("stdio 端到端：导出文件落盘，stdout 只有协议消息，日志在 stderr")
    func endToEnd() throws {
        let box = try Sandbox()
        let root = URL(filePath: MCPAccessPolicy.realPath(box.root.path)!, directoryHint: .isDirectory)
        let photo = URL(filePath: MCPAccessPolicy.realPath(try box.photo("in/Badlands.jpg", width: 900, height: 300).path)!)
        let out = root.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let client = try StdioClient(
            arguments: ["mcp", "serve", "--allow-read", root.appending(path: "in").path, "--allow-write", out.path],
            library: root.appending(path: "Library"))
        defer { client.kill() }

        let initialize = try client.request("initialize", [
            "protocolVersion": "2025-11-25", "capabilities": [String: Any](), "clientInfo": ["name": "e2e", "version": "1"],
        ])
        let serverInfo = initialize["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "photoframe")
        #expect(initialize["protocolVersion"] as? String == "2025-11-25")
        try client.notify("notifications/initialized")

        let tools = try client.request("tools/list", [:])
        #expect((tools["tools"] as? [Any])?.count == MCPToolName.allCases.count)

        let presets = try client.callTool("list_presets", [:])
        #expect((presets["presets"] as? [Any])?.count == 6)

        let created = try client.callTool("create_export_job", [
            "images": [photo.path], "presets": ["instagram-panorama"], "outputDirectory": out.path,
        ])
        #expect(created["ok"] as? Bool == true, "\(created)")
        let jobs = created["jobs"] as? [[String: Any]] ?? []
        let jobId = try #require(jobs.first?["jobId"] as? String)

        var job: [String: Any] = [:]
        for _ in 0..<600 {
            let status = try client.callTool("get_job_status", ["jobId": jobId])
            job = status["job"] as? [String: Any] ?? [:]
            let state = job["status"] as? String ?? ""
            if ["completed", "failed", "canceled"].contains(state) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(job["status"] as? String == "completed", "\(job)")
        let outputs = job["outputs"] as? [[String: Any]] ?? []
        #expect(outputs.count > 1)
        let cover = out.appending(path: "Instagram/Badlands_Panorama/00_Cover.jpg")
        #expect(outputs.first?["path"] as? String == cover.path)
        #expect(imageInfo(cover).width == 1080)
        #expect(imageInfo(cover).profile == "sRGB IEC61966-2.1")

        let refused = try client.callTool("inspect_image", ["path": "/etc/passwd"])
        #expect((refused["error"] as? [String: Any])?["code"] as? String == "mcp.path_not_allowed")

        let status = try client.close()
        #expect(status == 0)
        #expect(client.stderr.contains("stdio 已就绪"))
        #expect(client.stderr.contains("客户端已断开"))
        #expect(client.nonProtocolLines.isEmpty, "stdout 里有非协议内容：\(client.nonProtocolLines)")
        #expect(!box.tree(out).contains { $0.contains(".photoframe-staging/") })
    }

    @Test("没有 --allow-read / --allow-write 时照常启动，但拒绝文件访问；目录不存在时启动失败")
    func roots() throws {
        let box = try Sandbox()
        let client = try StdioClient(arguments: ["mcp", "serve"], library: box.root.appending(path: "Library"))
        defer { client.kill() }
        _ = try client.request("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "e2e", "version": "1"],
        ])
        let reply = try client.callTool("inspect_image", ["path": box.root.appending(path: "x.jpg").path])
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "mcp.no_read_access")
        #expect(try client.close() == 0)

        let bad = try runProcess(["mcp", "serve", "--allow-read", "/no/such/dir"], in: box.root)
        #expect(bad.status == 2)
        #expect(bad.stdout.isEmpty)
        #expect(bad.stderr.contains("mcp.invalid_root"))
    }
}

/// 空闲的服务器不占 CPU（SDK 自带的 stdio 传输每 10 ms 轮询一次）；客户端不再读输出时不被 SIGPIPE 杀掉。
@Suite("MCP 可执行文件：stdio", .enabled(if: photoframeExecutable != nil, "需要 swift test 构建出的 photoframe"))
struct MCPStdioTests {
    @Test("空闲时几乎不用 CPU、不被定时唤醒；不把 stdin / stdout 改成非阻塞")
    func idle() throws {
        let box = try Sandbox()
        let client = try StdioClient(arguments: ["mcp", "serve"], library: box.root.appending(path: "Library"), probeStdio: true)
        defer { client.kill() }
        _ = try client.request("initialize", [
            "protocolVersion": "2025-11-25", "capabilities": [String: Any](), "clientInfo": ["name": "e2e", "version": "1"],
        ])
        try client.notify("notifications/initialized")
        let modes = client.nonBlockingStdio()
        #expect(!modes.stdin && !modes.stdout, "stdin / stdout 被设成了非阻塞（O_NONBLOCK 记在共用的文件描述上，退出后还在）")

        Thread.sleep(forTimeInterval: 0.5)
        let before = try client.usage()
        Thread.sleep(forTimeInterval: 2)
        let after = try client.usage()
        // 以前：约 8 ms CPU、140 多次唤醒（每 10 ms 一次）；现在都接近 0。
        #expect(after.cpu - before.cpu < 0.004, "空闲 2 秒用了 \(after.cpu - before.cpu) 秒 CPU")
        #expect(after.wakeups - before.wakeups < 40, "空闲 2 秒被唤醒 \(after.wakeups - before.wakeups) 次")
        #expect(try client.close() == 0)
    }

    @Test("客户端不再读 stdout / stderr：写入失败但进程不被 SIGPIPE 杀掉，stdin 结束后正常退出")
    func clientStopsReading() throws {
        let box = try Sandbox()
        let client = try StdioClient(arguments: ["mcp", "serve"], library: box.root.appending(path: "Library"))
        defer { client.kill() }
        _ = try client.request("initialize", [
            "protocolVersion": "2025-11-25", "capabilities": [String: Any](), "clientInfo": ["name": "e2e", "version": "1"],
        ])
        client.stopReading()
        try client.post("tools/call", ["name": "list_presets", "arguments": [String: Any]()])
        Thread.sleep(forTimeInterval: 0.5)  // 服务器写回复（EPIPE）
        let end = try client.finish()
        #expect(end.reason == .exit && end.status == 0, "退出：\(end.reason == .exit ? "exit" : "signal") \(end.status)")
    }
}

/// 用换行分隔的 JSON-RPC 与子进程通信（MCP stdio 传输）。超过 120 秒没有结束的进程会被杀掉，测试不会挂住。
final class StdioClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var buffer = Data()
    private var nextId = 1
    private(set) var nonProtocolLines: [String] = []
    private let errorData = LockedData()
    /// 与子进程的 stdin、stdout 共用打开的文件描述（O_NONBLOCK 记在那上面），用来检查模式。
    private var stdinProbe: Int32 = -1
    private var stdoutProbe: Int32 = -1

    /// `probeStdio`：留一份 stdin、stdout 管道的描述符，之后用 `nonBlockingStdio()` 检查模式（检查前读不到 stdout 的 EOF）。
    init(arguments: [String], library: URL, probeStdio: Bool = false) throws {
        guard let exe = photoframeExecutable else { throw TestFailure("找不到 photoframe 可执行文件") }
        process.executableURL = exe
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PHOTOFRAME_LIBRARY"] = library.path
        environment["PHOTOFRAME_MCP_ALLOW_READ"] = nil
        environment["PHOTOFRAME_MCP_ALLOW_WRITE"] = nil
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let sink = errorData
        errors.fileHandleForReading.readabilityHandler = { handle in sink.append(handle.availableData) }
        if probeStdio {
            stdinProbe = dup(input.fileHandleForReading.fileDescriptor)
            stdoutProbe = dup(output.fileHandleForWriting.fileDescriptor)
        }
        try process.run()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { if process.isRunning { process.terminate() } }
    }

    var stderr: String { errorData.string }

    func notify(_ method: String) throws {
        try send(["jsonrpc": "2.0", "method": method])
    }

    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let id = nextId
        nextId += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            let message = try readMessage()
            guard message["id"] as? Int == id else { continue }
            if let error = message["error"] { throw TestFailure("\(method) 失败：\(error)") }
            return message["result"] as? [String: Any] ?? [:]
        }
    }

    /// 调用工具，返回 structuredContent。
    func callTool(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        let result = try request("tools/call", ["name": name, "arguments": arguments])
        return result["structuredContent"] as? [String: Any] ?? [:]
    }

    /// 子进程的 stdin、stdout 是否是非阻塞的。查完关掉 stdout 那一份（否则这里一直占着写端，读不到 EOF）。
    func nonBlockingStdio() -> (stdin: Bool, stdout: Bool) {
        defer { closeProbes() }
        return (fcntl(stdinProbe, F_GETFL) & O_NONBLOCK != 0, fcntl(stdoutProbe, F_GETFL) & O_NONBLOCK != 0)
    }

    /// 子进程到目前为止用的 CPU 时间（秒）和被中断唤醒的次数。
    func usage() throws -> (cpu: Double, wakeups: UInt64) {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(process.processIdentifier, RUSAGE_INFO_V2, $0) }
        }
        guard status == 0 else { throw TestFailure("proc_pid_rusage 失败：\(errno)") }
        // 时间以 mach_absolute_time 的单位计。
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        return (ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9, info.ri_interrupt_wkups + info.ri_pkg_idle_wkups)
    }

    /// 客户端不再读 stdout / stderr（关掉读端），之后服务器的写入都得到 EPIPE。
    func stopReading() {
        closeProbes()
        errors.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }

    /// 只发请求，不等回复。
    func post(_ method: String, _ params: [String: Any]) throws {
        let id = nextId
        nextId += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    /// 关闭 stdin，等进程结束（`stopReading()` 之后用，不再读输出）。
    func finish() throws -> (reason: Process.TerminationReason, status: Int32) {
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationReason, process.terminationStatus)
    }

    private func closeProbes() {
        for fd in [stdinProbe, stdoutProbe] where fd >= 0 { Darwin.close(fd) }
        (stdinProbe, stdoutProbe) = (-1, -1)
    }

    /// 关闭 stdin（客户端断开），等进程退出。
    func close() throws -> Int32 {
        closeProbes()
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil
        errorData.append(errors.fileHandleForReading.readDataToEndOfFile())
        // 读完剩下的 stdout，检查有没有非协议内容。
        buffer.append(output.fileHandleForReading.readDataToEndOfFile())
        while let line = nextLine() { check(line) }
        return process.terminationStatus
    }

    func kill() {
        closeProbes()
        if process.isRunning { process.terminate() }
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readMessage() throws -> [String: Any] {
        while true {
            if let line = nextLine() {
                if let message = check(line) { return message }
                continue
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw TestFailure("服务器关闭了 stdout。stderr：\(stderr)") }
            buffer.append(chunk)
        }
    }

    private func nextLine() -> Data? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = buffer[buffer.startIndex..<newline]
        buffer = Data(buffer[(newline + 1)...])
        return Data(line)
    }

    @discardableResult
    private func check(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty else { return nil }
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
            nonProtocolLines.append(String(decoding: line, as: UTF8.self))
            return nil
        }
        return message
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
