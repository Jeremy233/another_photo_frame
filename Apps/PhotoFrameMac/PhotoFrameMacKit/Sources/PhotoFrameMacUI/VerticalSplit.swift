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
