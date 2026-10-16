import CoreGraphics
import Foundation
import ImageIO
import PhotoFrameApplication
import PhotoFrameCore
import Synchronization
import Testing
import UniformTypeIdentifiers

/// 每个测试一个独立的临时目录，测试结束删除。
final class Sandbox: Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "PhotoFrameApplicationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var exports: URL { root.appending(path: "Exports", directoryHint: .isDirectory) }

    /// 写一张假的源图（内容不重要，渲染器是假的）。
    func makeSource(_ name: String = "Badlands.tif", contents: Data = Data("original-pixels".utf8)) throws -> PhotoSource {
        let url = root.appending(path: "Originals/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return PhotoSource(fileURL: url)
    }

    func spec(_ source: PhotoSource, preset: ExportPreset = .testPanorama, hashes: Bool = false) -> JobSpec {
        JobSpec(source: source, preset: preset, destination: ExportDestination(rootDirectory: exports, computeHashes: hashes))
    }

    /// 输出根目录下的全部文件和目录（相对路径），包括隐藏的临时目录。
    func exportTree() -> [String] {
        guard let e = FileManager.default.enumerator(atPath: exports.path) else { return [] }
        return (e.allObjects as? [String] ?? []).sorted()
    }

    /// 代码合成的「照片」：横向渐变，嵌入 Display P3 ICC（`profile: false` 时是去掉颜色描述的 PNG）。不使用任何真实照片。
    func photo(_ name: String, width: Int, height: Int, type: UTType = .jpeg, profile: Bool = true) throws -> URL {
        let url = root.appending(path: name)
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(colorSpace: space, components: [0.9, 0.3, 0.2, 1])!,
            CGColor(colorSpace: space, components: [0.2, 0.4, 0.9, 1])!,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        if !profile {
            precondition(type == .png, "只支持去掉 PNG 的颜色描述")
            // 去掉 iCCP、sRGB、cICP、gAMA、cHRM 块，得到「无 ICC」的文件。
            let data = try Data(contentsOf: url)
            var out = Data(data.prefix(8))
            var i = 8
            while i + 12 <= data.count {
                let length = data[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
                let end = i + 12 + length
                if !["iCCP", "sRGB", "cICP", "gAMA", "cHRM"].contains(String(decoding: data[i + 4..<i + 8], as: UTF8.self)) {
                    out += data[i..<end]
                }
                i = end
            }
            try out.write(to: url)
        }
        return url
    }

    var stagingRoot: URL { AtomicExporter.stagingRoot(for: exports) }

    var stagingExists: Bool { FileManager.default.fileExists(atPath: stagingRoot.path) }
}

extension ExportPreset {
    static let testPanorama = ExportPreset(
        presetId: UUID(uuidString: "53EABC50-58DB-4F46-BC2E-A5A334C0B7E8")!,
        name: "Instagram Panorama", platform: "instagram",
        canvas: CanvasSettings(width: 1080, height: 1440, background: .defaultBackground, minMarginPx: 60, mode: .fit),
        panorama: PanoramaSettings(enabled: true))

    static let testStandard = ExportPreset(
        presetId: UUID(uuidString: "60978D90-F0A0-4369-B82D-6EEEE52F89BA")!,
        name: "Instagram Standard", platform: "instagram",
        canvas: CanvasSettings(width: 1080, height: 1440, background: .defaultBackground, minMarginPx: 60, mode: .fit))
}

/// 测试用的渲染器：按设定写出假的 JPEG，报告阶段与进度，可以在中途卡住、失败或写出坏文件。
final class FakeRenderer: JobRenderer {
    enum Behavior: Sendable {
        /// 正常写出封面 + `slides` 张切片。
        case succeed(slides: Int)
        /// 写完 `after` 个文件后抛错。
        case fail(after: Int)
        /// 写出的第 `index` 个文件内容不是 JPEG。
        case corruptFile(index: Int)
        /// 把源文件路径当作输出返回（试图让队列移动原图）。
        case returnSourceFile
        /// 返回临时目录外的一个文件。
        case returnOutsideFile(URL)
        /// 在临时目录里放一个指向原图的硬链接。
        case hardLinkSource
    }

    struct State {
        var behaviors: [Behavior] = []
        var defaultBehavior: Behavior = .succeed(slides: 2)
        var calls = 0
        var running = 0
        var maxRunning = 0
        /// 为 true 时，写完封面后一直等待，直到 `release()` 或被取消。
        var holds = false
        var released = false
        var outputDirectories: [URL] = []
        var memoryEstimate: Int64?
    }

    let state = Mutex(State())

    init(_ behaviors: [Behavior] = [], holds: Bool = false, memoryEstimate: Int64? = nil) {
        state.withLock {
            $0.behaviors = behaviors
            $0.holds = holds
            $0.memoryEstimate = memoryEstimate
        }
    }

    var calls: Int { state.withLock { $0.calls } }
    var running: Int { state.withLock { $0.running } }
    var maxRunning: Int { state.withLock { $0.maxRunning } }
    var outputDirectories: [URL] { state.withLock { $0.outputDirectories } }

    func release() { state.withLock { $0.released = true } }

    func estimatedPeakMemoryBytes(for job: JobRenderRequest) -> Int64? { state.withLock { $0.memoryEstimate } }

    func render(_ job: JobRenderRequest, outputDirectory: URL, progress: RenderProgressReporter) async throws -> JobRenderResult {
        let behavior = state.withLock { s in
            s.calls += 1
            s.running += 1
            s.maxRunning = max(s.maxRunning, s.running)
            s.outputDirectories.append(outputDirectory)
            return s.behaviors.isEmpty ? s.defaultBehavior : s.behaviors.removeFirst()
        }
        defer { state.withLock { $0.running -= 1 } }

        let slides = if case .succeed(let n) = behavior { n } else { 2 }
        let roles: [JobOutputRole] = [.cover] + (0..<slides).map { .slide(position: $0 + 1) }
        await progress.report(.plannedOutputs(roles.count))
        await progress.report(.stage(.rendering))

        var outputs: [JobRenderedOutput] = []
        for (i, role) in roles.enumerated() {
            if case .fail(let after) = behavior, i == after {
                throw FakeRenderError()
            }
            if i == 1 { try await holdIfNeeded() }
            try Task.checkCancellation()
            await progress.report(.stage(.encoding))
            let url = outputDirectory.appending(path: "out-\(i).bin")
            var data = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("fake jpeg \(role)".utf8)
            if case .corruptFile(let index) = behavior, index == i { data = Data("not a jpeg".utf8) }
            try data.write(to: url)
            outputs.append(JobRenderedOutput(role: role, fileURL: url, pixelSize: PixelSize(width: 1080, height: 1440), colorProfile: "sRGB IEC61966-2.1"))
            await progress.report(.outputFinished(role))
        }

        switch behavior {
        case .returnSourceFile:
            outputs[0].fileURL = job.source.fileURL
        case .returnOutsideFile(let url):
            outputs[0].fileURL = url
        case .hardLinkSource:
            let link = outputDirectory.appending(path: "link.bin")
            try FileManager.default.linkItem(at: job.source.fileURL, to: link)
            outputs[0].fileURL = link
        default:
            break
        }
        return JobRenderResult(outputs: outputs, warnings: [ApplicationWarning(code: "test.note", message: "fake")])
    }

    private func holdIfNeeded() async throws {
        while state.withLock({ $0.holds && !$0.released }) {
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

struct FakeRenderError: ApplicationErrorConvertible {
    var applicationError: ApplicationError { ApplicationError(code: "render.decode_failed", message: "假的解码错误") }
}

/// 轮询直到条件成立；超时则记录失败。
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("条件在 \(timeout) 内没有成立", sourceLocation: sourceLocation)
}

/// 在后台收集事件，供之后检查。
final class EventLog: Sendable {
    private final class Storage: Sendable {
        let events = Mutex<[JobEvent]>([])
    }

    private let storage = Storage()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<JobEvent>) {
        task = Task { [storage] in
            for await event in stream { storage.events.withLock { $0.append(event) } }
        }
    }

    deinit { task.cancel() }

    var all: [JobEvent] { storage.events.withLock { $0 } }

    func statuses(of job: JobID) -> [JobStatus] {
        all.compactMap {
            if case .statusChanged(let id, _, let s) = $0, id == job { s } else { nil }
        }
    }

    func progress(of job: JobID) -> [JobProgress] {
        all.compactMap {
            if case .progress(let id, _, let p) = $0, id == job { p } else { nil }
        }
    }
}

/// 读出图片的像素尺寸和嵌入的 ICC 名称。
func imageInfo(_ url: URL) -> (width: Int, height: Int, profile: String?) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    else { return (0, 0, nil) }
    return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0,
            props[kCGImagePropertyProfileName] as? String)
}
