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
///
/// 全量并行跑测试时机器很忙，菜单打开、SwiftUI 更新和重新布局都可能比平时慢得多。所以这里不用固定的等待时间：
/// 菜单真的开始跟踪、菜单项出现后才去点；点完以后转动 run loop，直到结果出现（或者 10 秒超时）。
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
        func fitButton() -> NSButton? { Self.button(in: host) { $0.title.hasPrefix("适合窗口") } }

        // 等预览区画好：缩放菜单出现，成品页的宽度连续两次量得一样。
        Self.wait(in: host) { fitButton() != nil }
        let button = try #require(fitButton(), "找不到缩放菜单")
        var measured: CGFloat?
        Self.wait(every: 0.1, in: host) {
            let width = Self.imageWidth(in: host)
            defer { measured = width }
            return width != nil && width == measured
        }
        let fitWidth = try #require(measured)

        var titles: [String] = []
        for (title, expected) in [("实际大小（100%）", PreviewZoom.actualSize), ("放大预览", .scale(1.5)), ("缩小预览", .actualSize), ("适合窗口", .fit)] {
            titles = Self.choose(title, from: button)
            #expect(Self.wait(in: host) { workbench.preview.zoom == expected }, "\(title)：\(workbench.preview.zoom)")
        }
        // 菜单里都是中文，与菜单栏「显示」里的缩放命令同名、同顺序。
        // （下拉菜单的第一项是按钮自己的标题，不比较它。）
        let commands = ["放大预览", "缩小预览", "实际大小（100%）", "适合窗口"]
        #expect(titles.filter(commands.contains) == commands, "\(titles)")
        #expect(!titles.contains { $0.lowercased().contains("zoom") }, "\(titles)")
        #expect(Self.wait(in: host) { button.title.hasPrefix("适合窗口") }, "\(button.title)")

        _ = Self.choose("实际大小（100%）", from: button)
        #expect(Self.wait(in: host) { button.title == "100%" }, "\(button.title)")
        // 页面比可视区宽时只量得到可见部分，所以只比较「适合窗口」和 100% 的差别。
        var actualWidth: CGFloat?
        Self.wait(every: 0.1, in: host) {
            actualWidth = Self.imageWidth(in: host)
            return actualWidth.map { abs($0 - fitWidth) > 20 } ?? false
        }
        let width = try #require(actualWidth)
        #expect(abs(width - fitWidth) > 20, "fit \(fitWidth) → 100% \(width)")
    }

    /// 转动主线程的 run loop，直到条件成立；超过 `timeout` 秒返回 false。
    @discardableResult
    static func wait(timeout: TimeInterval = 10, every step: TimeInterval = 0.02, in host: NSView, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(step))
        }
    }

    /// 点菜单的过程中要记的事（定时器和通知的回调里改它）。
    @MainActor final class MenuState {
        var tracking = false
        var done = false
        /// `performClick` 已经返回（菜单关了）。
        var clicked = false
        var titles: [String] = []
    }

    /// 像用户一样点开菜单并选中一项，返回菜单里的全部标题。`performClick` 要等菜单关掉才返回：
    /// 菜单开始跟踪（进入它自己的事件循环）、要点的项出现后，定时器触发这一项并关掉菜单。
    /// 10 秒还没等到就直接关掉菜单（测试会失败，但不会卡住）。
    static func choose(_ title: String, from button: NSButton) -> [String] {
        let state = MenuState()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { state.tracking = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let deadline = Date().addingTimeInterval(10)
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let menu = (button as? NSPopUpButton)?.menu ?? button.menu else { return }
                // 已经点过（或放弃了）：菜单要是还开着，就再关一次。
                guard !state.done else { menu.cancelTracking(); return }
                let index = state.tracking ? menu.items.firstIndex { $0.title == title } : nil
                guard index != nil || Date() > deadline else { return }
                state.titles = menu.items.map(\.title)
                if let index { menu.performActionForItem(at: index) }
                state.done = true
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        // performClick 要放在我们自己的一次 run loop 里调用：菜单收起时 AppKit 会停掉「当前」这次 run loop（CFRunLoopStop）。
        // 直接在测试函数里调用时，「当前」的常常是测试进程最外层、async main 的那次 run loop：它一停，进程就以 0 退出，
        // 别的还没跑完的测试不再运行，也不报错（以前偶尔少跑测试、留下临时文件就是这个原因）。
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                button.performClick(nil)
                state.clicked = true
            }
        }
        while !state.clicked { _ = CFRunLoopRunInMode(.defaultMode, 0.05, false) }
        timer.invalidate()
        return state.titles
    }

    static func button(in view: NSView, where match: (NSButton) -> Bool) -> NSButton? {
        if let button = view as? NSButton, match(button) { return button }
        for sub in view.subviews { if let found = button(in: sub, where: match) { return found } }
        return nil
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
