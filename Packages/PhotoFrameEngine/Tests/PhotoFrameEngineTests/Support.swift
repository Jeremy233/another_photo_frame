import CoreGraphics
import Foundation
import ImageIO
import PhotoFrameApplication
import Synchronization
import Testing
import UniformTypeIdentifiers

// 测试只用代码合成的图片，不使用任何真实照片。

/// 每个测试一个临时目录，测试结束删除。
final class Sandbox: Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "PhotoFrameEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var exports: URL { root.appending(path: "Exports", directoryHint: .isDirectory) }

    /// 横向渐变的合成「照片」，嵌入 Display P3 ICC。
    func photo(_ name: String, width: Int, height: Int, type: UTType = .jpeg) throws -> URL {
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
        guard CGImageDestinationFinalize(dest) else { throw TestFailure("写出 \(name) 失败") }
        return url
    }

    func tree() -> [String] {
        guard let e = FileManager.default.enumerator(atPath: exports.path) else { return [] }
        return (e.allObjects as? [String] ?? []).sorted()
    }
}

struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// 读出成品的像素尺寸和嵌入的 ICC 名称。
func imageInfo(_ url: URL) -> (width: Int, height: Int, profile: String?) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    else { return (0, 0, nil) }
    return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0,
            props[kCGImagePropertyProfileName] as? String)
}

/// 在后台收集事件。
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
}

func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("条件在 \(timeout) 内没有成立", sourceLocation: sourceLocation)
}
