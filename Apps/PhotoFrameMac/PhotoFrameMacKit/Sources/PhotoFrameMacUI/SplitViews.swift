import AppKit
import SwiftUI

/// 上下两部分、分隔线可拖动的 AppKit `NSSplitView`（规范 §4.1 建议复杂分割用 AppKit 封装）。
///
/// SwiftUI 的 `VSplitView` 放在 `inspector` 旁边会让窗口约束反复失效而崩溃，所以自己封装。
/// 分隔线位置按 `autosaveName` 自动记住；双击分隔线恢复默认比例。
struct VerticalSplit<Top: View, Bottom: View>: NSViewRepresentable {
    var autosaveName: String
    var topFraction: Double = 0.6
    var minHeight: Double = 120
    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = ResettableSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        split.topFraction = topFraction
        context.coordinator.minHeight = minHeight
        for view in [host(top), host(bottom)] {
            split.addArrangedSubview(view)
        }
        split.autosaveName = autosaveName
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        (split.arrangedSubviews[0] as? NSHostingView<Top>)?.rootView = top
        (split.arrangedSubviews[1] as? NSHostingView<Bottom>)?.rootView = bottom
    }

    /// 完全随父视图伸缩，不把子视图的固有尺寸报给外层（否则外层分栏的最小宽度会反复变化，窗口约束死循环）。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    private func host<Content: View>(_ content: Content) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        // 不让 SwiftUI 内容的固有尺寸变成约束，分割比例只由分隔线决定。
        view.sizingOptions = []
        return view
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var minHeight = 120.0

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            max(proposed, minHeight)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            min(proposed, splitView.bounds.height - minHeight)
        }
    }
}

/// 第一次显示（没有记住的位置）和双击分隔线时，按默认比例放分隔线。
private final class ResettableSplitView: NSSplitView {
    var topFraction = 0.6
    private var placed = false

    override func layout() {
        super.layout()
        guard !placed, bounds.height > 0 else { return }
        placed = true
        if let name = autosaveName, UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(name)") != nil { return }
        resetDivider()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            resetDivider()
        } else {
            super.mouseDown(with: event)
        }
    }

    private func resetDivider() {
        setPosition(bounds.height * topFraction, ofDividerAt: 0)
    }
}

/// 主窗口的三栏：左栏 | 中栏 | 右栏（Inspector），分隔线可拖动，宽度按 `autosaveName` 记住（规范 §4.1）。
///
/// 不用 NavigationSplitView + inspector：那样系统会把顶栏按栏切成三段，而且窗口比三栏最小宽度之和窄时会崩溃。
/// 这里左右两栏收起时只隐藏对应的子视图；窗口变宽变窄时只有中栏跟着变。
struct ColumnSplit<Leading: View, Center: View, Trailing: View>: NSViewRepresentable {
    var autosaveName: String
    var showsLeading: Bool
    var showsTrailing: Bool
    var leadingWidth: ClosedRange<CGFloat> = 200...420
    var trailingWidth: ClosedRange<CGFloat> = 260...480
    var centerMinWidth: CGFloat = 420
    @ViewBuilder var leading: Leading
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = ColumnSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator
        let views: [NSView] = [host(leading), host(center), host(trailing)]
        for view in views { split.addArrangedSubview(view) }
        // 窗口缩放时左右栏保持宽度，只有中栏伸缩。
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 1)
        split.setHoldingPriority(.init(260), forSubviewAt: 2)
        split.autosaveName = autosaveName
        split.defaultWidths = (leadingWidth.lowerBound + 60, trailingWidth.lowerBound + 40)
        split.minWidths = (leadingWidth.lowerBound, trailingWidth.lowerBound)
        update(split, context: context)
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        (split.arrangedSubviews[0] as? NSHostingView<Leading>)?.rootView = leading
        (split.arrangedSubviews[1] as? NSHostingView<Center>)?.rootView = center
        (split.arrangedSubviews[2] as? NSHostingView<Trailing>)?.rootView = trailing
        update(split, context: context)
    }

    private func update(_ split: NSSplitView, context: Context) {
        context.coordinator.leadingWidth = leadingWidth
        context.coordinator.trailingWidth = trailingWidth
        context.coordinator.centerMinWidth = centerMinWidth
        let leading = split.arrangedSubviews[0], trailing = split.arrangedSubviews[2]
        guard leading.isHidden == showsLeading || trailing.isHidden == showsTrailing else { return }
        leading.isHidden = !showsLeading
        trailing.isHidden = !showsTrailing
        split.adjustSubviews()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 1200, height: proposal.height ?? 800)
    }

    private func host<Content: View>(_ content: Content) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        view.sizingOptions = []
        return view
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var leadingWidth: ClosedRange<CGFloat> = 200...420
        var trailingWidth: ClosedRange<CGFloat> = 260...480
        var centerMinWidth: CGFloat = 420

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            if index == 0 { return max(proposed, leadingWidth.lowerBound) }
            let leadingEnd = leadingVisible(splitView) ? splitView.arrangedSubviews[0].frame.maxX : 0
            return max(proposed, splitView.bounds.width - trailingWidth.upperBound, leadingEnd + centerMinWidth)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            if index == 0 {
                let trailingStart = trailingVisible(splitView) ? splitView.arrangedSubviews[2].frame.minX : splitView.bounds.width
                return min(proposed, leadingWidth.upperBound, trailingStart - centerMinWidth)
            }
            return min(proposed, splitView.bounds.width - trailingWidth.lowerBound)
        }

        private func leadingVisible(_ split: NSSplitView) -> Bool { !split.arrangedSubviews[0].isHidden }
        private func trailingVisible(_ split: NSSplitView) -> Bool { !split.arrangedSubviews[2].isHidden }
    }
}

/// 可见的左右栏比最小宽度还窄时（第一次显示、重新显示、记住的宽度不合适），按默认宽度摆放。
private final class ColumnSplitView: NSSplitView {
    var defaultWidths: (leading: CGFloat, trailing: CGFloat) = (260, 300)
    var minWidths: (leading: CGFloat, trailing: CGFloat) = (200, 260)

    override func layout() {
        super.layout()
        guard arrangedSubviews.count == 3, bounds.width > defaultWidths.leading + defaultWidths.trailing + 200 else { return }
        let leading = arrangedSubviews[0], trailing = arrangedSubviews[2]
        if !leading.isHidden, leading.frame.width < minWidths.leading {
            setPosition(defaultWidths.leading, ofDividerAt: 0)
        }
        if !trailing.isHidden, trailing.frame.width < minWidths.trailing {
            setPosition(bounds.width - defaultWidths.trailing, ofDividerAt: 1)
        }
    }
}
