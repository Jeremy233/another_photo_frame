import AppKit
import CoreGraphics
import ImageIO
import PhotoFrameApplication
@testable import PhotoFrameMacModel
@testable import PhotoFrameMacUI
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// 端到端：把真实的预览区放进窗口，像用户一样点缩放菜单里的项，确认预览画面真的变了。
@MainActor @Suite struct PreviewZoomMenuTests {
    @Test func menuItemsChangeThePreview() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ZoomMenu-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try LocalPhotoFrameService.makeDefault(.init(startsPaused: true, libraryRoot: root.appending(path: "Library")))
        let workbench = Workbench(service: service, locationStore: MemoryLocationStore(), debounce: .zero)
        await workbench.load()
        let ids = await workbench.addSources([try Self.photo(in: root)])
        let presetId = try #require(workbench.presets.first { $0.name == "Instagram Standard" }?.presetId)
        await workbench.addJobs(preset: presetId, to: ids)
        await workbench.settle()
        #expect(workbench.preview.pageImage != nil)

        _ = NSApplication.shared
        let host = NSHostingView(rootView: PreviewPane(workbench: workbench, preview: workbench.preview).frame(width: 900, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        func pump() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        pump()

        let fitWidth = try #require(Self.imageWidth(in: host))
        let button = try #require(Self.button(in: host) { $0.title.hasPrefix("适合窗口") }, "找不到缩放菜单")
        var titles: [String] = []
        for (title, expected) in [("实际大小（100%）", PreviewZoom.actualSize), ("放大预览", .scale(1.5)), ("缩小预览", .actualSize), ("适合窗口", .fit)] {
            titles = Self.choose(title, from: button)
            pump()
            #expect(workbench.preview.zoom == expected, "\(title)")
        }
        // 菜单里都是中文，与菜单栏「显示」里的缩放命令同名、同顺序。
        // （下拉菜单的第一项是按钮自己的标题，不比较它。）
        let commands = ["放大预览", "缩小预览", "实际大小（100%）", "适合窗口"]
        #expect(titles.filter(commands.contains) == commands, "\(titles)")
        #expect(!titles.contains { $0.lowercased().contains("zoom") }, "\(titles)")
        #expect(button.title.hasPrefix("适合窗口"))

        _ = Self.choose("实际大小（100%）", from: button)
        pump()
        #expect(button.title == "100%")
        let actualWidth = try #require(Self.imageWidth(in: host))
        // 页面比可视区宽时只量得到可见部分，所以只比较「适合窗口」和 100% 的差别。
        #expect(abs(actualWidth - fitWidth) > 20, "fit \(fitWidth) → 100% \(actualWidth)")
    }

    /// 像用户一样点开菜单并选中一项：打开期间（菜单的事件循环里）用定时器找到这一项、触发它。返回菜单里的全部标题。
    static func choose(_ title: String, from button: NSButton) -> [String] {
        var titles: [String] = []
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = (button as? NSPopUpButton)?.menu ?? button.menu else { return }
                titles = menu.items.map(\.title)
                if let index = menu.items.firstIndex(where: { $0.title == title }) { menu.performActionForItem(at: index) }
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        button.performClick(nil)
        return titles
    }

    static func button(in view: NSView, where match: (NSButton) -> Bool) -> NSButton? {
        if let button = view as? NSButton, match(button) { return button }
        for sub in view.subviews { if let found = button(in: sub, where: match) { return found } }
        return nil
    }

    /// SwiftUI 的菜单按钮在打开时才生成菜单项：先让它生成，再返回菜单。
    static func menu(of button: NSButton) -> NSMenu? {
        let menu = (button as? NSPopUpButton)?.menu ?? button.menu
        if let menu { menu.delegate?.menuNeedsUpdate?(menu) }
        return menu
    }

    /// 预览画面里成品页（底色 #FAFAF8）的显示宽度（pt）：把视图渲染成位图后量出来。
    static func imageWidth(in host: NSView) -> CGFloat? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        var minX = Int.max, maxX = -1
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - 250 / 255) < 0.02, abs(c.greenComponent - 250 / 255) < 0.02, abs(c.blueComponent - 248 / 255) < 0.02 {
                    minX = min(minX, x); maxX = max(maxX, x)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGFloat(maxX - minX + 1) * host.bounds.width / CGFloat(rep.pixelsWide)
    }

    static func photo(in root: URL) throws -> URL {
        let url = root.appending(path: "Zoom.jpg")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
