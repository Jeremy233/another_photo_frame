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

    init(arguments: [String], library: URL) throws {
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

    /// 关闭 stdin（客户端断开），等进程退出。
    func close() throws -> Int32 {
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
