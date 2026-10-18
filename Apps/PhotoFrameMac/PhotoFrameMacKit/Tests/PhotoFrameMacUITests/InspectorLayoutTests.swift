import AppKit
@testable import PhotoFrameMacUI
import SwiftUI
import Testing

/// 右栏的版式：放进真实的窗口里量控件的尺寸（审查报告 V30）。
@MainActor @Suite struct InspectorLayoutTests {
    /// 同一分节的弹出菜单一样宽（不按最长的选项定宽），也不超过上限。
    @Test func popUpMenusInASectionShareOneWidth() throws {
        let widths = Self.menuWidths(columnWidth: 300)
        #expect(widths.count == 2 && Set(widths).count == 1, "\(widths)")
        #expect(widths.allSatisfy { $0 <= InspectorMetrics.controlWidth }, "\(widths)")
        // 右栏很窄时菜单跟着变窄，不把右栏撑宽。
        let narrow = Self.menuWidths(columnWidth: 240)
        #expect(narrow.count == 2 && Set(narrow).count == 1 && narrow.allSatisfy { $0 < InspectorMetrics.controlWidth }, "\(narrow)")
    }

    /// 两个弹出菜单（选项一短一长）在这么宽的右栏里的宽度。macOS 26 的菜单由 SwiftUI 自己画，没有 NSPopUpButton，
    /// 量的是它们的焦点环（与控件一样大）。
    static func menuWidths(columnWidth: CGFloat) -> [CGFloat] {
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
        return focusRings(in: host).filter { $0.height > 16 && $0.height < 32 }.map { $0.width.rounded() }
    }

    static func focusRings(in view: NSView) -> [CGRect] {
        (String(describing: type(of: view)) == "_FocusRingView" ? [view.frame] : []) + view.subviews.flatMap(focusRings)
    }
}
