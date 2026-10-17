import AppKit
@testable import PhotoFrameMacUI
import Testing

/// 三栏分割：收起不留分隔线，反复收起展开栏宽不变，拖动后的宽度保留，窗口缩放只改中栏。
@MainActor @Suite struct ColumnSplitTests {
    private func make(width: CGFloat = 1400, name: String? = nil, collapsed: Bool = false) -> (NSWindow, ColumnSplitController) {
        _ = NSApplication.shared
        let controller = ColumnSplitController(
            leading: NSViewController.plain(), center: NSViewController.plain(), trailing: NSViewController.plain(), autosaveName: name)
        if collapsed { controller.setVisibility(leading: false, trailing: false) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: 800))
        controller.view.layoutSubtreeIfNeeded()
        controller.placeIfNeeded()
        return (window, controller)
    }

    private func widths(_ c: ColumnSplitController) -> [CGFloat] {
        c.view.layoutSubtreeIfNeeded()
        return [c.leadingItem, c.centerItem, c.trailingItem].map { $0.isCollapsed ? 0 : $0.viewController.view.frame.width }
    }

    @Test func collapseHidesDividers() {
        let (_, c) = make()
        c.setVisibility(leading: false, trailing: false)
        c.view.layoutSubtreeIfNeeded()
        #expect(c.leadingItem.isCollapsed && c.trailingItem.isCollapsed)
        #expect(c.splitView(c.splitView, shouldHideDividerAt: 0))
        #expect(c.splitView(c.splitView, shouldHideDividerAt: 1))
        // 中栏占满整个宽度，没有留下分隔线的位置。
        #expect(abs(c.centerItem.viewController.view.frame.width - c.view.bounds.width) <= 2)

        c.setVisibility(leading: true, trailing: true)
        #expect(!c.splitView(c.splitView, shouldHideDividerAt: 0))
    }

    @Test func repeatedToggleKeepsWidths() {
        let (window, c) = make()
        #expect(widths(c)[0] == ColumnSplitController.defaultWidths.leading)
        #expect(abs(widths(c)[2] - ColumnSplitController.defaultWidths.trailing) <= 1)
        // 模拟用户拖动后的宽度。
        c.splitView.setPosition(300, ofDividerAt: 0)
        c.splitView.setPosition(c.view.bounds.width - 340, ofDividerAt: 1)
        c.recordWidths()
        let before = widths(c)
        let windowWidth = window.frame.width
        #expect(abs(before[0] - 300) <= 1)
        for _ in 0..<20 {
            c.setVisibility(leading: false, trailing: false)
            _ = widths(c)
            c.setVisibility(leading: true, trailing: true)
            let after = widths(c)
            #expect(zip(before, after).allSatisfy { abs($0 - $1) <= 1 }, "\(before) → \(after)")
        }
        // 只收起左栏、只收起 Inspector 也一样；收起的一侧没有分隔线，另一侧的分隔线还在。
        for _ in 0..<20 {
            c.setVisibility(leading: false, trailing: true)
            #expect(widths(c)[0] == 0 && abs(widths(c)[2] - before[2]) <= 1)
            #expect(c.splitView(c.splitView, shouldHideDividerAt: 0) && !c.splitView(c.splitView, shouldHideDividerAt: 1))
            c.setVisibility(leading: true, trailing: true)
            #expect(zip(before, widths(c)).allSatisfy { abs($0 - $1) <= 1 })
        }
        for _ in 0..<20 {
            c.setVisibility(leading: true, trailing: false)
            #expect(widths(c)[2] == 0 && abs(widths(c)[0] - before[0]) <= 1)
            #expect(!c.splitView(c.splitView, shouldHideDividerAt: 0) && c.splitView(c.splitView, shouldHideDividerAt: 1))
            c.setVisibility(leading: true, trailing: true)
            #expect(zip(before, widths(c)).allSatisfy { abs($0 - $1) <= 1 })
        }
        #expect(zip(before, widths(c)).allSatisfy { abs($0 - $1) <= 1 })
        #expect(window.frame.width == windowWidth)
    }

    /// 拖动后的宽度在下次打开时恢复；上次退出时是收起状态也一样（之前会退回最小宽度）。
    @Test func draggedWidthsPersist() {
        let name = "test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "ColumnSplit \(name)") }
        do {
            let (_, c) = make(name: name)
            c.splitView.setPosition(330, ofDividerAt: 0)
            c.splitView.setPosition(c.view.bounds.width - 360, ofDividerAt: 1)
            c.recordWidths()
            #expect(abs(c.widths.leading - 330) <= 1 && abs(c.widths.trailing - 360) <= 1)
        }
        let (_, reopened) = make(name: name)
        #expect(abs(widths(reopened)[0] - 330) <= 1 && abs(widths(reopened)[2] - 360) <= 1)

        let (_, collapsed) = make(name: name, collapsed: true)
        #expect(widths(collapsed)[0] == 0 && widths(collapsed)[2] == 0)
        collapsed.setVisibility(leading: true, trailing: true)
        #expect(abs(widths(collapsed)[0] - 330) <= 1 && abs(widths(collapsed)[2] - 360) <= 1)
    }

    /// 拖完分隔线（鼠标松开）时记录并保存栏宽；窗口缩放不会被记录。
    /// 测试进程里收不到真实的拖动事件，这里直接触发分隔线视图的「拖动结束」回调。
    @Test func dragEndRecordsWidth() throws {
        let name = "test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "ColumnSplit \(name)") }
        let (window, c) = make(name: name)
        let split = try #require(c.splitView as? DragTrackingSplitView)
        split.setPosition(320, ofDividerAt: 0)
        split.didEndDrag?()
        #expect(abs(c.widths.leading - 320) <= 1)
        let saved = UserDefaults.standard.array(forKey: "ColumnSplit \(name)") as? [Double]
        #expect(saved.map { abs($0[0] - 320) <= 1 } == true)

        window.setContentSize(NSSize(width: 1000, height: 800))
        _ = widths(c)
        #expect(abs(c.widths.leading - 320) <= 1)
    }

    /// 窄窗口（用户报告的场景）：反复收起展开，栏宽和窗口宽都不变，中栏不小于最小宽度。
    @Test(arguments: [900, 1000, 1100] as [CGFloat])
    func narrowWindowToggle(width: CGFloat) {
        let (window, c) = make(width: width)
        let before = widths(c)
        #expect(before[1] >= ColumnSplitController.centerMinWidth - 1)
        let windowWidth = window.frame.width
        for _ in 0..<20 {
            c.setVisibility(leading: false, trailing: true)
            #expect(widths(c)[0] == 0)
            c.setVisibility(leading: true, trailing: true)
            #expect(zip(before, widths(c)).allSatisfy { abs($0 - $1) <= 1 }, "\(before) → \(widths(c))")
            c.setVisibility(leading: true, trailing: false)
            c.setVisibility(leading: true, trailing: true)
        }
        #expect(zip(before, widths(c)).allSatisfy { abs($0 - $1) <= 1 })
        #expect(window.frame.width == windowWidth)
        // 记住的宽度没有因为窄窗口被改小。
        #expect(c.widths.leading == ColumnSplitController.defaultWidths.leading)
    }

    @Test func windowResizeOnlyChangesCenter() {
        let (window, c) = make(width: 1400)
        let before = widths(c)
        window.setContentSize(NSSize(width: 1200, height: 800))
        let after = widths(c)
        #expect(abs(after[0] - before[0]) <= 1 && abs(after[2] - before[2]) <= 1)
        #expect(after[1] < before[1])
    }

    @Test func widthsStayInRange() {
        let (_, c) = make()
        c.splitView.setPosition(10, ofDividerAt: 0)
        #expect(widths(c)[0] >= ColumnSplitController.leadingWidth.lowerBound - 1)
        c.splitView.setPosition(900, ofDividerAt: 0)
        #expect(widths(c)[0] <= ColumnSplitController.leadingWidth.upperBound + 1)
    }
}

private extension NSViewController {
    static func plain() -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView()
        return controller
    }
}
