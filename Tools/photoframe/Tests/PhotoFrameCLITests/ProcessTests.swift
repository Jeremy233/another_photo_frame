import Foundation
import Testing
@testable import PhotoFrameCLI

/// 以子进程运行真正的 `photoframe` 可执行文件：检查 stdout / stderr 分离、退出码和信号处理。
@Suite("可执行文件", .enabled(if: photoframeExecutable != nil, "需要 swift test 构建出的 photoframe"))
struct ProcessTests {
    @Test("导出：stdout 只有文件路径，进度在 stderr，退出码 0")
    func export() throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 2400, height: 800)
        let result = try runProcess(["export", "Badlands.jpg", "--preset", "instagram-panorama", "-o", "Exports"], in: box.root)
        #expect(result.status == 0, "\(result.stderr)")
        // 子进程的当前目录是 /private/var/…，比较前统一解析符号链接。
        let lines = result.stdout.split(separator: "\n").map { URL(filePath: String($0)).resolvingSymlinksInPath().path }
        #expect(lines.first == box.exports.appending(path: "Instagram/Badlands_Panorama/00_Cover.jpg").resolvingSymlinksInPath().path)
        #expect(lines.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        #expect(result.stderr.contains(": rendering"))
    }

    @Test("--json：stdout 是一个完整的 JSON 文档")
    func json() throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 1200, height: 800)
        let result = try runProcess(["export", "Badlands.jpg", "--preset", "xhs-standard", "-o", "Exports", "--json"], in: box.root)
        #expect(result.status == 0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(json["ok"] as? Bool == true)
        #expect(result.stderr.contains("completed"))
    }

    @Test("退出码：用法错误 2、找不到输入 3")
    func exitCodes() throws {
        let box = try Sandbox()
        #expect(try runProcess(["export", "x.jpg"], in: box.root).status == 2)
        let missing = try runProcess(["export", "x.jpg", "--preset", "xhs-standard", "-o", "Exports"], in: box.root)
        #expect(missing.status == 3)
        #expect(missing.stdout.isEmpty)
        #expect(missing.stderr.contains("source.not_found"))
    }

    @Test("单独复制出来的可执行文件（旁边没有资源包）：各个命令和 MCP 服务器都能运行（D-126）")
    func loneExecutable() throws {
        let box = try Sandbox()
        try box.photo("Badlands.jpg", width: 1200, height: 800)
        // 只复制可执行文件本身；构建目录里它旁边可能还有旧版本留下的 .bundle，这里不带。
        let bin = box.root.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let lone = bin.appending(path: "photoframe")
        try FileManager.default.copyItem(at: try #require(photoframeExecutable), to: lone)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path) == ["photoframe"])

        for arguments in [
            ["preset", "list", "--json"],
            ["image", "inspect", "Badlands.jpg", "--json"],
            ["export", "Badlands.jpg", "--preset", "xhs-standard", "-o", "Exports", "--json"],
            ["preview", "Badlands.jpg", "--preset", "douyin-standard", "-o", "Preview"],
        ] {
            let result = try runProcess(arguments, in: box.root, executable: lone)
            #expect(result.status == 0, "\(arguments)：\(result.stderr)")
        }
        #expect(FileManager.default.fileExists(atPath: box.exports.appending(path: "Xiaohongshu/Badlands_Standard/00_Cover.jpg").path),
                "\(box.tree())")

        let client = try StdioClient(arguments: ["mcp", "serve"], library: box.root.appending(path: "Library"), executable: lone)
        defer { client.kill() }
        _ = try client.request("initialize", [
            "protocolVersion": "2025-11-25", "capabilities": [String: Any](), "clientInfo": ["name": "e2e", "version": "1"],
        ])
        try client.notify("notifications/initialized")
        #expect((try client.callTool("list_presets", [:])["presets"] as? [Any])?.count == 6)
        #expect(try client.close() == 0)
    }

    @Test("磁盘映像（相当于移动硬盘）上的源图：复制到本机缓存后导出，进程退出时删掉本进程的副本目录（D-129）", .timeLimit(.minutes(2)))
    func stagedSourceIsRemovedAtExit() throws {
        let box = try Sandbox()
        let image = box.root.appending(path: "volume.dmg")
        let mount = box.root.appending(path: "mnt", directoryHint: .isDirectory)
        guard hdiutil(["create", "-size", "32m", "-fs", "APFS", "-volname", "PFStagingCLI", image.path, "-quiet"]),
              hdiutil(["attach", image.path, "-nobrowse", "-noautoopen", "-mountpoint", mount.path, "-quiet"])
        else {
            print("[跳过] hdiutil 无法挂载磁盘映像")
            return
        }
        defer { hdiutil(["detach", mount.path, "-force", "-quiet"]) }
        let photo = try box.photo("Badlands.jpg", width: 1200, height: 800)
        try FileManager.default.copyItem(at: photo, to: mount.appending(path: "Badlands.jpg"))

        let pid = Locked<Int32>(0)
        let result = try runProcess(
            ["export", mount.appending(path: "Badlands.jpg").path, "--preset", "xhs-standard", "-o", "Exports", "--json"], in: box.root
        ) { process, _ in pid.value = process.processIdentifier }
        #expect(result.status == 0, "\(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: box.exports.appending(path: "Xiaohongshu/Badlands_Standard/00_Cover.jpg").path))
        let staging = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "AnotherPhotoFrame/SourceStaging")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        #expect(!left.contains { $0.hasPrefix("\(pid.value)-") }, "\(left)")
    }

    @Test("SIGINT：取消任务并清理临时目录，退出码 130；已发布的作品目录都是完整的")
    func sigint() throws {
        let box = try Sandbox()
        // 足够大的合成图，让任务在收到信号时大概率还在处理中。
        try box.photo("Huge.jpg", width: 12000, height: 4000)
        let result = try runProcess(
            ["export", "Huge.jpg", "--preset", "douyin-panorama", "--preset", "xhs-panorama", "--preset", "instagram-panorama",
             "-o", "Exports", "--jobs", "1"],
            in: box.root
        ) { process, _ in
            Thread.sleep(forTimeInterval: 0.5)
            process.interrupt()
        }
        // 任务在信号到达前就全部完成时退出码是 0；两种情况都不能留下临时目录或半成品。
        #expect(result.status == 130 || result.status == 0, "\(result.stderr)")
        #expect(!box.tree().contains { $0.contains(".photoframe-staging") }, "\(box.tree())")
        for dir in box.tree().filter({ $0.split(separator: "/").count == 2 }) {
            let files = box.tree(box.exports.appending(path: dir))
            #expect(files.first == "00_Cover.jpg", "\(dir) 应是完整的作品目录")
        }
        if result.status == 130 {
            #expect(result.stderr.contains("canceled"))
        }
    }
}

/// 运行 hdiutil，成功时返回 true。
@discardableResult
func hdiutil(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/hdiutil")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}
