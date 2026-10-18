import Foundation
import MCP
import PhotoFrameApplication
@testable import PhotoFrameCLI
import PhotoFrameStorage
import Testing

// MCP 测试：进程内的 MCP 客户端通过 SDK 的内存传输连到 PhotoFrameMCPServer。
// 目录：in/（允许读取）、out/（允许写入）、outside/（都不允许），全在系统临时目录里；图片都是代码合成的。

/// 工具调用的结果。
struct ToolReply {
    var result: CallTool.Result

    var object: [String: Value] { result.structuredContent?.objectValue ?? [:] }
    var ok: Bool { object["ok"]?.boolValue == true }
    var isError: Bool { result.isError == true }
    var code: String? { object["error"]?.objectValue?["code"]?.stringValue }
    /// text 内容（与 structuredContent 同一份 JSON）。
    var text: String {
        result.content.compactMap { item -> String? in
            if case .text(let t, _, _) = item { return t }
            return nil
        }.joined()
    }
    var images: Int {
        result.content.filter { item in
            if case .image = item { return true }
            return false
        }.count
    }

    subscript(key: String) -> Value? { object[key] }
}

final class MCPHarness: Sendable {
    let sandbox: Sandbox
    let inputs: URL
    let outputs: URL
    let outside: URL
    let service: any PhotoFrameService
    let photoframe: PhotoFrameMCPServer
    let server: Server
    let client: Client

    private init(sandbox: Sandbox, inputs: URL, outputs: URL, outside: URL, service: any PhotoFrameService,
                 photoframe: PhotoFrameMCPServer, server: Server, client: Client) {
        self.sandbox = sandbox
        self.inputs = inputs
        self.outputs = outputs
        self.outside = outside
        self.service = service
        self.photoframe = photoframe
        self.server = server
        self.client = client
    }

    /// `read` / `write` 为 nil 时分别是 `inputName`、`outputName` 目录（默认 in/、out/）；传空数组表示没有配置。
    /// `wrap` 可以把服务包一层（例如卡住 `submit`）。
    static func start(
        limits: MCPLimits = MCPLimits(), read: [String]? = nil, write: [String]? = nil, renderer: (any JobRenderer)? = nil,
        inputName: String = "in", outputName: String = "out",
        wrap: (@Sendable (any PhotoFrameService) -> any PhotoFrameService)? = nil
    ) async throws -> MCPHarness {
        let sandbox = try Sandbox()
        let root = URL(filePath: MCPAccessPolicy.realPath(sandbox.root.path)!, directoryHint: .isDirectory)
        let inputs = root.appending(path: inputName, directoryHint: .isDirectory)
        let outputs = root.appending(path: outputName, directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        for dir in [inputs, outputs, outside] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

        let options = LocalPhotoFrameService.Options(maxConcurrentJobs: 2, libraryRoot: root.appending(path: "Library"))
        var service: any PhotoFrameService = if let renderer {
            try serviceFactory(renderer: renderer)(options)
        } else {
            try LocalPhotoFrameService.makeDefault(options)
        }
        if let wrap { service = wrap(service) }
        let policy = try MCPAccessPolicy(readRoots: read ?? [inputs.path], writeRoots: write ?? [outputs.path], limits: limits)
        let photoframe = PhotoFrameMCPServer(service: service, policy: policy)
        let server = await photoframe.makeServer()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "PhotoFrameCLITests", version: "1")
        try await client.connect(transport: clientTransport)
        return MCPHarness(sandbox: sandbox, inputs: inputs, outputs: outputs, outside: outside, service: service,
                          photoframe: photoframe, server: server, client: client)
    }

    func stop() async {
        await client.disconnect()
        await server.stop()
        await photoframe.shutdown()
    }

    func call(_ name: String, _ arguments: [String: Value] = [:]) async throws -> ToolReply {
        let context = try await client.send(CallTool.request(.init(name: name, arguments: arguments)))
        return ToolReply(result: try await context.value)
    }

    /// 不经过 MCP 传输，直接在服务器上调用工具（并发测试用）。
    func direct(_ name: MCPToolName, _ arguments: [String: Value]) async -> ToolReply {
        ToolReply(result: await photoframe.call(name, arguments))
    }

    /// 合成一张照片，`relative` 相对于测试目录（例如 `in/a.jpg`、`outside/secret.jpg`），返回真实路径。
    @discardableResult
    func photo(_ relative: String, width: Int = 300, height: Int = 200) throws -> URL {
        let url = try sandbox.photo(relative, width: width, height: height)
        return URL(filePath: MCPAccessPolicy.realPath(url.path)!)
    }

    /// 轮询到任务结束。
    func waitForJob(_ jobId: String) async throws -> [String: Value] {
        for _ in 0..<1200 {
            let reply = try await call("get_job_status", ["jobId": .string(jobId)])
            let job = reply["job"]?.objectValue ?? [:]
            let status = job["status"]?.stringValue ?? ""
            if ["completed", "failed", "canceled"].contains(status) { return job }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TestFailure("任务 \(jobId) 60 秒内没有结束")
    }
}

extension Value {
    static func strings(_ items: [String]) -> Value { .array(items.map { .string($0) }) }

    /// 从 JSON 文本构造（避免在测试里写大段嵌套字面量）。
    static func json(_ text: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(text.utf8))
    }
}

/// 导出参数。
func exportArguments(_ images: [URL], preset: String = "instagram-standard", output: URL, overwrite: Bool = false) -> [String: Value] {
    var args: [String: Value] = [:]
    args["images"] = .strings(images.map(\.path))
    args["presets"] = .strings([preset])
    args["outputDirectory"] = .string(output.path)
    if overwrite { args["overwrite"] = .bool(true) }
    return args
}
