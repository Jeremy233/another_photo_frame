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
