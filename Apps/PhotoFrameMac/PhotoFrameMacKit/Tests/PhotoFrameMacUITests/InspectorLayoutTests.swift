import AppKit
@testable import PhotoFrameMacUI
import SwiftUI
import Testing

/// 右栏的版式：放进真实的窗口里量控件的尺寸（审查报告 V30）。
@MainActor @Suite struct InspectorLayoutTests {
    /// 同一分节的弹出菜单一样宽（不按最长的选项定宽），也不超过上限。
    @Test func popUpMenusInASectionShareOneWidth() throws {
        let measured = Self.menuFrames(columnWidth: 300)
        let widths = measured.frames.map { $0.width.rounded() }
        #expect(widths.count == 2 && Set(widths).count == 1, "\(widths)；视图：\(measured.classes)")
        #expect(widths.allSatisfy { $0 <= InspectorMetrics.controlWidth }, "\(widths)")
        // 右栏很窄时菜单跟着变窄，不把右栏撑宽。
        let narrow = Self.menuWidths(columnWidth: 240)
        #expect(narrow.count == 2 && Set(narrow).count == 1 && narrow.allSatisfy { $0 < InspectorMetrics.controlWidth }, "\(narrow)")
    }

    /// 两个弹出菜单（选项一短一长）在这么宽的右栏里的宽度。菜单的实现随系统版本变化：有 NSPopUpButton 时量它；
    /// 没有时（SwiftUI 自己画的菜单）量它们的焦点环（与控件一样大）。两样都找不到时返回空，失败信息里列出视图层级。
    static func menuWidths(columnWidth: CGFloat) -> [CGFloat] {
        menuFrames(columnWidth: columnWidth).frames.map { $0.width.rounded() }
    }

    static func menuFrames(columnWidth: CGFloat) -> (frames: [CGRect], classes: String) {
        _ = NSApplication.shared
        let view = InspectorSection("测试") {
            InspectorPicker("短", selection: .constant(0)) { Text("右下").tag(0) }
            InspectorPicker("长", selection: .constant(0)) { Text("动态范围跟随源图").tag(0) }
        }
        .frame(width: columnWidth)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: columnWidth, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let all = subviews(of: host)
        let popUps = all.filter { $0 is NSPopUpButton }
        let candidates = popUps.isEmpty ? all.filter { String(describing: type(of: $0)) == "_FocusRingView" } : popUps
        let frames = candidates.map(\.frame).filter { $0.height > 16 && $0.height < 32 }
        let classes = Set(all.map { String(describing: type(of: $0)) }).sorted().joined(separator: ", ")
        return (frames, classes)
    }

    static func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(subviews)
    }
}
