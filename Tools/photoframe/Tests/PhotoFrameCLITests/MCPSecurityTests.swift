import Darwin
import Foundation
import MCP
import PhotoFrameApplication
@testable import PhotoFrameCLI
import Testing

// §11.4 安全规则与 AC-07：目录白名单、符号链接逃逸、`..`、硬链接、覆盖授权、资源上限、错误信息不泄露路径。

@Suite("MCP 安全规则")
struct MCPSecurityTests {
    /// 拒绝，且错误信息（结构化内容和 text）里没有白名单以外的路径。
    func expectRefused(_ reply: ToolReply, _ code: String, hiding secret: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(reply.isError && !reply.ok, sourceLocation: sourceLocation)
        #expect(reply.code == code, "\(reply.text)", sourceLocation: sourceLocation)
        #expect(!reply.text.contains(secret), "泄露了路径：\(reply.text)", sourceLocation: sourceLocation)
    }

    @Test("没有配置目录时拒绝所有文件访问")
    func noRoots() async throws {
        let h = try await MCPHarness.start(read: [], write: [])
        defer { Task { await h.stop() } }
        let url = try h.photo("in/A.jpg")
        let read = try await h.call("inspect_image", ["path": .string(url.path)])
        #expect(read.code == "mcp.no_read_access")
        let write = try await h.call("validate_export", exportArguments([url], output: h.outputs))
        #expect(write.code == "mcp.no_write_access")
        // 不碰文件的工具照常可用
        #expect(try await h.call("list_presets").ok)
    }

    @Test("白名单以外的输入、相对路径、..、控制字符")
    func inputOutsideRoots() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let secret = try h.photo("outside/secret.jpg")
        expectRefused(try await h.call("inspect_image", ["path": .string(secret.path)]), "mcp.path_not_allowed", hiding: secret.path)
        expectRefused(try await h.call("inspect_image", ["path": .string("/etc/passwd")]), "mcp.path_not_allowed", hiding: "/etc/passwd")
        let dotdot = h.inputs.path + "/../outside/secret.jpg"
        expectRefused(try await h.call("inspect_image", ["path": .string(dotdot)]), "mcp.invalid_path", hiding: "outside")
        expectRefused(try await h.call("inspect_image", ["path": .string("in/A.jpg")]), "mcp.invalid_path", hiding: "secret")
        expectRefused(try await h.call("inspect_image", ["path": .string(h.inputs.path + "/a\u{0}b.jpg")]), "mcp.invalid_path", hiding: "secret")
        // 前缀相同但不是子目录：in-evil 不在 in 里
        let sibling = try h.photo("in-evil/x.jpg")
        expectRefused(try await h.call("inspect_image", ["path": .string(sibling.path)]), "mcp.path_not_allowed", hiding: sibling.path)
        // 导出时同样检查每一张源图
        let export = try await h.call("create_export_job", exportArguments([secret], output: h.outputs))
        expectRefused(export, "mcp.path_not_allowed", hiding: secret.path)
    }

    @Test("符号链接逃逸：文件链接、目录链接都按真实路径判断")
    func symlinkEscape() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let secret = try h.photo("outside/secret.jpg")
        let fileLink = h.inputs.appending(path: "link.jpg")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: secret)
        expectRefused(try await h.call("inspect_image", ["path": .string(fileLink.path)]), "mcp.path_not_allowed", hiding: secret.path)

        let dirLink = h.inputs.appending(path: "dir")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: h.outside)
        let viaDir = dirLink.appending(path: "secret.jpg").path
        expectRefused(try await h.call("inspect_image", ["path": .string(viaDir)]), "mcp.path_not_allowed", hiding: h.outside.path)

        // 链接指向白名单内部的文件可以用
        let inside = try h.photo("in/real.jpg")
        let innerLink = h.inputs.appending(path: "alias.jpg")
        try FileManager.default.createSymbolicLink(at: innerLink, withDestinationURL: inside)
        let ok = try await h.call("inspect_image", ["path": .string(innerLink.path)])
        #expect(ok.ok)
        #expect(MCPAccessPolicy.realPath(ok["image"]?.objectValue?["path"]?.stringValue ?? "") == inside.path)
    }

    @Test("输出目录：白名单以外、符号链接逃逸、悬空链接、作品目录的上级是链接")
    func outputEscape() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let url = try h.photo("in/Badlands.jpg")
        expectRefused(try await h.call("validate_export", exportArguments([url], output: h.outside)),
                      "mcp.path_not_allowed", hiding: h.outside.path)

        let escape = h.outputs.appending(path: "escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: h.outside)
        expectRefused(try await h.call("create_export_job", exportArguments([url], output: escape.appending(path: "x"))),
                      "mcp.path_not_allowed", hiding: h.outside.path)

        let dangling = h.outputs.appending(path: "dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: h.outside.path + "/missing")
        expectRefused(try await h.call("validate_export", exportArguments([url], output: dangling)),
                      "mcp.path_not_allowed", hiding: h.outside.path)

        // 输出根目录本身在白名单内，但平台子目录 Instagram 是指向外面的链接
        let root = h.outputs.appending(path: "root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Instagram"), withDestinationURL: h.outside)
        let validation = try await h.call("validate_export", exportArguments([url], output: root))
        #expect(validation.ok && validation["valid"]?.boolValue == false)
        #expect(!validation.text.contains(h.outside.path))
        let created = try await h.call("create_export_job", exportArguments([url], output: root))
        expectRefused(created, "mcp.path_not_allowed", hiding: h.outside.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.outside.path).isEmpty)
    }

    @Test("硬链接的输入拒绝读取")
    func hardLink() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let secret = try h.photo("outside/secret.jpg")
        let linked = h.inputs.appending(path: "hard.jpg")
        #expect(Darwin.link(secret.path, linked.path) == 0)
        expectRefused(try await h.call("inspect_image", ["path": .string(linked.path)]), "mcp.hard_link_refused", hiding: secret.path)
    }

    @Test("覆盖必须显式请求，且同样受白名单约束")
    func overwriteAuthorization() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let url = try h.photo("in/Badlands.jpg")
        let first = try await h.call("create_export_job", exportArguments([url], output: h.outputs))
        _ = try await h.waitForJob(first["jobs"]?.arrayValue?.first?.objectValue?["jobId"]?.stringValue ?? "")
        let cover = h.outputs.appending(path: "Instagram/Badlands_Standard/00_Cover.jpg")
        let before = try FileManager.default.attributesOfItem(atPath: cover.path)[.modificationDate] as? Date

        // 不给 overwrite：预计写到 _v2，原目录不动
        let plain = try await h.call("validate_export", exportArguments([url], output: h.outputs))
        let planned = plain["jobs"]?.arrayValue?.first?.objectValue?["directory"]?.stringValue ?? ""
        #expect(planned.hasSuffix("Badlands_Standard_v2"))

        // 不是本软件发布的目录：即使给了 overwrite 也拒绝（D-49）
        let foreign = h.outputs.appending(path: "Instagram/Other_Standard")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: foreign.appending(path: "notes.txt"))
        let other = try h.photo("in/Other.jpg")
        let refused = try await h.call("create_export_job", exportArguments([other], output: h.outputs, overwrite: true))
        #expect(refused.code == "export.overwrite_refused")
        #expect(FileManager.default.fileExists(atPath: foreign.appending(path: "notes.txt").path))

        // 覆盖白名单以外的目录：在检查覆盖之前就被拒绝
        let outsideTarget = try await h.call("create_export_job", exportArguments([url], output: h.outside, overwrite: true))
        expectRefused(outsideTarget, "mcp.path_not_allowed", hiding: h.outside.path)

        let after = try FileManager.default.attributesOfItem(atPath: cover.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test("上限：单文件大小、预览尺寸与页数、内联字节、队列长度、输出总量")
    func limits() async throws {
        var limits = MCPLimits()
        limits.maxInputBytes = 4096
        limits.maxPreviewEdge = 400
        limits.maxPreviewPages = 2
        limits.maxInlinePreviewBytes = 64
        let h = try await MCPHarness.start(limits: limits)
        defer { Task { await h.stop() } }
        let big = try h.photo("in/Big.jpg", width: 1200, height: 800)
        expectRefused(try await h.call("inspect_image", ["path": .string(big.path)]), "mcp.file_too_large", hiding: "outside")

        let h2 = try await MCPHarness.start(limits: limits)
        defer { Task { await h2.stop() } }
        let small = try h2.photo("in/Small.jpg", width: 60, height: 40)
        var args: [String: Value] = ["image": .string(small.path), "preset": .string("instagram-standard"), "maxEdge": .int(800)]
        #expect(try await h2.call("preview_export", args).code == "mcp.limit_exceeded")
        args["maxEdge"] = .int(100)
        args["pages"] = .array([.int(0), .int(1), .int(2)])
        #expect(try await h2.call("preview_export", args).code == "mcp.limit_exceeded")
        args["pages"] = nil
        let inline = try await h2.call("preview_export", args)
        #expect(inline.code == "mcp.limit_exceeded")
        args["outputDirectory"] = .string(h2.outputs.path)
        #expect(try await h2.call("preview_export", args).ok)

        var queue = MCPLimits()
        queue.maxActiveJobs = 1
        let h3 = try await MCPHarness.start(limits: queue, renderer: HoldingRenderer())
        defer { Task { await h3.stop() } }
        let a = try h3.photo("in/A.jpg")
        let b = try h3.photo("in/B.jpg")
        let both = try await h3.call("create_export_job", exportArguments([a, b], output: h3.outputs))
        #expect(both.code == "mcp.queue_full", "\(both.text)")
        let one = try await h3.call("create_export_job", exportArguments([a], output: h3.outputs))
        #expect(one.ok, "\(one.text)")
        let more = try await h3.call("create_export_job", exportArguments([b], output: h3.outputs))
        #expect(more.code == "mcp.queue_full", "\(more.text)")

        var quota = MCPLimits()
        quota.maxOutputBytes = 1
        let h4 = try await MCPHarness.start(limits: quota)
        defer { Task { await h4.stop() } }
        let c = try h4.photo("in/C.jpg")
        let first = try await h4.call("create_export_job", exportArguments([c], output: h4.outputs))
        _ = try await h4.waitForJob(first["jobs"]?.arrayValue?.first?.objectValue?["jobId"]?.stringValue ?? "")
        #expect(try await h4.call("create_export_job", exportArguments([c], output: h4.outputs)).code == "mcp.output_quota_exceeded")
    }

    @Test("错误信息去掉白名单以外的路径")
    func redaction() throws {
        let sandbox = try Sandbox()
        let root = MCPAccessPolicy.realPath(sandbox.root.path)!
        let policy = try MCPAccessPolicy(readRoots: [root], writeRoots: [])
        #expect(policy.redact("找不到源文件：/Users/someone/Pictures/a.jpg") == "找不到源文件：<路径已隐藏>")
        #expect(policy.redact("输出目录不可用：\(root)/x（权限）") == "输出目录不可用：\(root)/x（权限）")
        #expect(policy.redact("\(root)/../../etc/passwd") == "<路径已隐藏>")
        #expect(policy.redact("见 photoframe://access 资源") == "见 photoframe://access 资源")
        #expect(policy.redact("file:///etc/hosts") == "<路径已隐藏>")
        #expect(policy.redact("standard/panorama 与 1/250s") == "standard/panorama 与 1/250s")
    }

    @Test("错误信息过滤：白名单目录含空格或括号、白名单内的名字含空格、白名单外含空格的路径")
    func redactionAwkwardNames() throws {
        let sandbox = try Sandbox()
        let root = MCPAccessPolicy.realPath(sandbox.root.path)!
        let spaced = root + "/Social Exports"
        let paren = root + "/Photos (2024)"
        let plain = root + "/in"
        for dir in [spaced, paren, plain] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let policy = try MCPAccessPolicy(readRoots: [plain, paren], writeRoots: [spaced])

        // 白名单内的路径原样保留：目录本身含空格、括号，或之后的名字含空格、括号
        for text in [
            spaced, "\"\(spaced)\"", "\(spaced)/Instagram/Badlands_Standard/00_Cover.jpg",
            "已替换之前导出的 \(spaced)/Instagram/Badlands_Standard", "输出目录不可用：\(spaced)（权限）",
            paren, "找不到文件：\(paren)/a.jpg", "\(paren)/Trip (2024)/a.jpg",
            "\(spaced)/a b.jpg", "\(plain)/My Photo.jpg", "\(plain)/My Photos/a b.jpg", "\(plain)/Trip (2024)/IMG (1).jpg（权限）",
            "拒绝覆盖 \(spaced)/Instagram/a_Standard：其中含有源文件 \(plain)/a b.jpg",
        ] {
            #expect(policy.redact(text) == text)
        }
        // 白名单外含空格的路径整条隐藏（以前只隐藏第一个空格之前的部分）
        #expect(policy.redact("找不到源文件：/Users/someone/My Pictures/a b.jpg") == "找不到源文件：<路径已隐藏>")
        #expect(policy.redact("/Users/someone/Trip (2024)/a.jpg（权限）") == "<路径已隐藏>（权限）")
        // 与白名单目录只是前缀相同的旁边的目录、用 .. 走出去的路径：不显示
        #expect(policy.redact("\(spaced) 2/x.jpg") == "<路径已隐藏>")
        #expect(policy.redact("\(spaced)abc/x.jpg") == "<路径已隐藏>")
        #expect(policy.redact("\(plain) 2/x.jpg") == "<路径已隐藏>")
        #expect(policy.redact("\(paren)(1)/x.jpg") == "<路径已隐藏>")
        #expect(policy.redact("\(spaced)/../secret/x y.jpg") == "<路径已隐藏>")
        // 白名单内的路径之后的另一个路径单独判断
        #expect(policy.redact("\(spaced)/a b.jpg 和 /etc/x y") == "\(spaced)/a b.jpg 和 <路径已隐藏>")
    }

    @Test("白名单目录含空格和括号时，工具结果和 photoframe://access 里的路径照常显示")
    func awkwardRootsEndToEnd() async throws {
        let h = try await MCPHarness.start(inputName: "My Photos", outputName: "Social Exports (2024)")
        defer { Task { await h.stop() } }
        let url = try h.photo("My Photos/Bad lands.jpg")
        // 服务返回的路径可能是 /var/… 形式（/private/var 的另一种写法），按真实路径比较。
        let inspected = try await h.call("inspect_image", ["path": .string(url.path)])
        #expect(MCPAccessPolicy.realPath(inspected["image"]?.objectValue?["path"]?.stringValue ?? "") == url.path, "\(inspected.text)")

        let validated = try await h.call("validate_export", exportArguments([url], output: h.outputs))
        let job = validated["jobs"]?.arrayValue?.first?.objectValue ?? [:]
        #expect(MCPAccessPolicy.realPath(job["source"]?.stringValue ?? "") == url.path, "\(validated.text)")
        let directory = job["directory"]?.stringValue ?? ""
        #expect(directory.hasPrefix("/") && directory.hasSuffix("/Social Exports (2024)/Instagram/Bad lands_Standard"), "\(validated.text)")
        #expect(!validated.text.contains(MCPAccessPolicy.hiddenPath), "\(validated.text)")

        let created = try await h.call("create_export_job", exportArguments([url], output: h.outputs))
        let done = try await h.waitForJob(created["jobs"]?.arrayValue?.first?.objectValue?["jobId"]?.stringValue ?? "")
        let cover = done["outputs"]?.arrayValue?.first?.objectValue?["path"]?.stringValue ?? ""
        #expect(MCPAccessPolicy.realPath(cover) == h.outputs.appending(path: "Instagram/Bad lands_Standard/00_Cover.jpg").path, "\(done)")

        let access = try await h.client.readResource(uri: MCPResources.access)
        let accessText = access.first?.text ?? ""
        let json = try JSONDecoder().decode(Value.self, from: Data(accessText.utf8)).objectValue ?? [:]
        #expect(json["readDirectories"]?.arrayValue?.first?.stringValue == h.inputs.path)
        #expect(json["writeDirectories"]?.arrayValue?.first?.stringValue == h.outputs.path)
        #expect(!accessText.contains(MCPAccessPolicy.hiddenPath))
    }

    @Test("输出目录下的 .photoframe-staging 经链接指向白名单外：拒绝，外面的东西不写也不清理")
    func stagingSymlink() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        let url = try h.photo("in/Badlands.jpg")
        // 外面有一个看起来像残留临时目录的旧目录（UUID 名字、超过 24 小时）
        let stale = h.outside.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: stale.path)
        try FileManager.default.createSymbolicLink(at: h.outputs.appending(path: ".photoframe-staging"), withDestinationURL: h.outside)

        expectRefused(try await h.call("validate_export", exportArguments([url], output: h.outputs)),
                      "mcp.path_not_allowed", hiding: h.outside.path)
        expectRefused(try await h.call("create_export_job", exportArguments([url], output: h.outputs)),
                      "mcp.path_not_allowed", hiding: h.outside.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.outside.path) == [stale.lastPathComponent])
        #expect(try await h.call("get_job_status")["jobs"]?.arrayValue?.isEmpty == true)

        // 悬空的链接同样拒绝；指向白名单内部的链接可以用
        let sub = h.outputs.appending(path: "sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: sub.appending(path: ".photoframe-staging").path,
                                                   withDestinationPath: h.outside.path + "/missing")
        expectRefused(try await h.call("validate_export", exportArguments([url], output: sub)), "mcp.path_not_allowed", hiding: h.outside.path)
        let inner = h.outputs.appending(path: "inner")
        try FileManager.default.createDirectory(at: h.outputs.appending(path: "elsewhere"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: inner.appending(path: ".photoframe-staging"),
                                                   withDestinationURL: h.outputs.appending(path: "elsewhere"))
        let allowed = try await h.call("validate_export", exportArguments([url], output: inner))
        #expect(allowed.ok && allowed["valid"]?.boolValue == true, "\(allowed.text)")
    }

    @Test("不存在的输入经目录链接指向白名单外：与存在时报同样的错，不泄露外面的文件是否存在")
    func missingInputViaDirectoryLink() async throws {
        let h = try await MCPHarness.start()
        defer { Task { await h.stop() } }
        try h.photo("outside/secret.jpg")
        let dirLink = h.inputs.appending(path: "dir")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: h.outside)
        for name in ["secret.jpg", "missing.jpg", "sub/missing.jpg"] {
            let path = dirLink.appending(path: name)
            expectRefused(try await h.call("inspect_image", ["path": .string(path.path)]), "mcp.path_not_allowed", hiding: h.outside.path)
            expectRefused(try await h.call("validate_export", exportArguments([path], output: h.outputs)),
                          "mcp.path_not_allowed", hiding: h.outside.path)
        }
        // 悬空的文件链接：不知道指向哪里，同样拒绝
        let dangling = h.inputs.appending(path: "dangling.jpg")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: h.outside.path + "/missing.jpg")
        expectRefused(try await h.call("inspect_image", ["path": .string(dangling.path)]), "mcp.path_not_allowed", hiding: h.outside.path)
        // 白名单内真的不存在：照常 source.not_found
        let missing = try await h.call("inspect_image", ["path": .string(h.inputs.appending(path: "nope/missing.jpg").path)])
        #expect(missing.code == "source.not_found")
    }

    @Test("白名单目录本身必须存在且不能是 /")
    func invalidRoots() throws {
        #expect(throws: ApplicationError.self) { try MCPAccessPolicy(readRoots: ["/"], writeRoots: []) }
        #expect(throws: ApplicationError.self) { try MCPAccessPolicy(readRoots: ["relative/dir"], writeRoots: []) }
        #expect(throws: ApplicationError.self) { try MCPAccessPolicy(readRoots: [], writeRoots: ["/no/such/dir-\(UUID())"]) }
    }
}
