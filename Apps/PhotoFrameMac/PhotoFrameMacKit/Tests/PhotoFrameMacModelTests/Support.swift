import CoreGraphics
import Foundation
import ImageIO
import PhotoFrameApplication
@testable import PhotoFrameMacModel
import UniformTypeIdentifiers

/// 每个测试一个临时目录：本地库、源图、导出目录都在里面，测试结束删除。
/// 图片全部用代码合成，不使用任何真实照片。
@MainActor
final class Fixture {
    let root: URL
    let service: LocalPhotoFrameService
    /// 工作台用的服务：转发给 `service`，测试可以在调用中间插入动作或让调用失败。
    let hooks: HookedService
    let workbench: Workbench
    let store: MemoryLocationStore
    let settingsStore = MemorySettingsStore()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "PhotoFrameMacTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = try LocalPhotoFrameService.makeDefault(.init(startsPaused: true, libraryRoot: root.appending(path: "Library")))
        hooks = HookedService(service)
        let exports = ExportLocation(name: "Exports", url: root.appending(path: "Exports", directoryHint: .isDirectory))
        store = MemoryLocationStore(LocationList(locations: [exports], defaultId: exports.id))
        workbench = Workbench(service: hooks, locationStore: store, settingsStore: settingsStore, debounce: .zero)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var exports: URL { root.appending(path: "Exports", directoryHint: .isDirectory) }

    /// 横向渐变的合成「照片」，嵌入 Display P3。
    func photo(_ name: String, width: Int = 360, height: Int = 240, properties: [CFString: Any] = [:]) throws -> URL {
        let url = root.appending(path: "Originals/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colors = [CGColor(colorSpace: space, components: [0.9, 0.3, 0.2, 1])!, CGColor(colorSpace: space, components: [0.2, 0.4, 0.9, 1])!]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [])
        try write(ctx.makeImage()!, to: url, type: .jpeg, properties: properties)
        return url
    }

    /// 没有颜色描述的 PNG：合成后去掉 iCCP、sRGB、cICP、gAMA、cHRM 块（「缺少 ICC」的源图）。
    func photoWithoutProfile(_ name: String, width: Int = 360, height: Int = 240) throws -> URL {
        let url = root.appending(path: "Originals/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try write(ctx.makeImage()!, to: url, type: .png)
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
        return url
    }

    /// 32 位浮点 TIFF（extended 线性 sRGB），右半边亮到 4 倍 SDR 白：按 D-62 第 3 条认作 HDR。
    func hdrPhoto(_ name: String, width: Int = 360, height: Int = 240) throws -> URL {
        let url = root.appending(path: "Originals/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v: Float = x < width / 2 ? 0.5 : 4
                let i = (y * width + x) * 4
                (pixels[i], pixels[i + 1], pixels[i + 2]) = (v, v * 0.8, v * 0.6)
            }
        }
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGImageByteOrderInfo.order32Little.rawValue
        let image = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
                            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                            provider: CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        try write(image, to: url, type: .tiff)
        return url
    }

    /// 带透明度的合成 PNG 素材。
    func assetPNG(_ name: String) throws -> URL {
        let url = root.appending(path: "Assets/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))
        ctx.fill(CGRect(x: 4, y: 4, width: 56, height: 24))
        try write(ctx.makeImage()!, to: url, type: .png)
        return url
    }

    private func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    func presetId(_ name: String) -> UUID {
        workbench.presets.first { $0.name == name }!.presetId
    }

    /// 加一张源图并用内置预设创建任务，返回任务 ID。
    @discardableResult
    func addJob(_ photo: String = "Badlands.jpg", preset: String = "Instagram Standard", hdr: Bool = false) async throws -> UUID {
        let url = try hdr ? hdrPhoto(photo) : self.photo(photo)
        let ids = await workbench.addSources([url])
        let sourceId = try #require(ids.first ?? workbench.sources.first { $0.source.fileURL == url }?.id)
        await workbench.drop(.preset(presetId(preset)), on: .source(sourceId))
        await workbench.settle()
        return try #require(workbench.sources.first { $0.id == sourceId }?.jobs.last?.id)
    }

    /// 等最近一次批处理的任务全部结束，再同步任务列表。
    func waitForRun() async {
        _ = await service.waitUntilFinished(workbench.runJobIds)
        await workbench.refreshJobs()
    }
}

import Testing
