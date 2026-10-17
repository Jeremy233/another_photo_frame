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

/// 主窗口的三栏：左栏 | 中栏 | 右栏（Inspector），分隔线可拖动，拖动后的栏宽按 `autosaveName` 记住（规范 §4.1）。
///
/// 不用 NavigationSplitView + inspector：那样系统会把顶栏按栏切成三段，而且窗口比三栏最小宽度之和窄时会崩溃。
/// 收起和展开交给 `NSSplitViewItem.isCollapsed`：收起时分隔线一起隐藏，展开时恢复收起前的宽度，
/// 不会像直接隐藏子视图那样留下分隔线、每次展开宽度越来越窄。
struct ColumnSplit<Leading: View, Center: View, Trailing: View>: NSViewControllerRepresentable {
    var autosaveName: String
    var showsLeading: Bool
    var showsTrailing: Bool
    @ViewBuilder var leading: Leading
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    func makeNSViewController(context: Context) -> ColumnSplitController {
        let controller = ColumnSplitController(
            leading: host(leading), center: host(center), trailing: host(trailing), autosaveName: autosaveName)
        controller.setVisibility(leading: showsLeading, trailing: showsTrailing)
        return controller
    }

    func updateNSViewController(_ controller: ColumnSplitController, context: Context) {
        (controller.leadingItem.viewController as? NSHostingController<Leading>)?.rootView = leading
        (controller.centerItem.viewController as? NSHostingController<Center>)?.rootView = center
        (controller.trailingItem.viewController as? NSHostingController<Trailing>)?.rootView = trailing
        controller.setVisibility(leading: showsLeading, trailing: showsTrailing)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: ColumnSplitController, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 1200, height: proposal.height ?? 800)
    }

    private func host<Content: View>(_ content: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: content)
        // 不让 SwiftUI 内容的固有尺寸变成约束，栏宽只由分隔线决定。
        controller.sizingOptions = []
        return controller
    }
}

/// 三栏分割的 AppKit 部分（也给测试直接用）。左右栏宽度有上下限，窗口缩放时只有中栏伸缩。
final class ColumnSplitController: NSSplitViewController {
    static let leadingWidth: ClosedRange<CGFloat> = 200...420
    static let trailingWidth: ClosedRange<CGFloat> = 260...480
    static let centerMinWidth: CGFloat = 420

    let leadingItem: NSSplitViewItem
    let centerItem: NSSplitViewItem
    let trailingItem: NSSplitViewItem

    init(leading: NSViewController, center: NSViewController, trailing: NSViewController, autosaveName: String?) {
        leadingItem = NSSplitViewItem(viewController: leading)
        centerItem = NSSplitViewItem(viewController: center)
        trailingItem = NSSplitViewItem(viewController: trailing)
        dragTrackingSplitView = DragTrackingSplitView()
        // 不用 NSSplitView 自带的 autosave：它连「已收起」一起恢复，和 NSSplitViewItem.isCollapsed 对不上，
        // 再展开时栏宽退回最小值。这里只记左右栏展开时的宽度，收起与否由 view model 决定。
        widthsKey = autosaveName.map { "ColumnSplit \($0)" }
        super.init(nibName: nil, bundle: nil)
        // 只在用户拖完分隔线后记栏宽：窗口缩放、收起展开、程序摆放都会发出 resize 通知，不能用通知判断。
        splitView = dragTrackingSplitView
        dragTrackingSplitView.didEndDrag = { [weak self] in self?.recordWidths() }
        for (item, range) in [(leadingItem, Self.leadingWidth), (trailingItem, Self.trailingWidth)] {
            item.canCollapse = true
            item.minimumThickness = range.lowerBound
            item.maximumThickness = range.upperBound
            item.holdingPriority = .init(260)
        }
        centerItem.minimumThickness = Self.centerMinWidth
        centerItem.holdingPriority = .init(250)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        for item in [leadingItem, centerItem, trailingItem] { addSplitViewItem(item) }
    }

    private let widthsKey: String?
    private let dragTrackingSplitView: DragTrackingSplitView

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 没有记住的栏宽时用的默认宽度（否则 AppKit 给最小宽度）。
    static let defaultWidths: (leading: CGFloat, trailing: CGFloat) = (260, 300)
    /// 左右栏展开时的宽度：拖动分隔线时更新，收起再展开时恢复。
    private(set) var widths = ColumnSplitController.defaultWidths
    private var placed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        if let key = widthsKey, let saved = UserDefaults.standard.array(forKey: key) as? [Double], saved.count == 2 {
            widths = (CGFloat(saved[0]).clamped(to: Self.leadingWidth), CGFloat(saved[1]).clamped(to: Self.trailingWidth))
        }
    }

    /// 第一次有了足够的宽度时，按记住的（或默认的）栏宽摆放。放到这次布局之后做：布局过程中改分隔线会被随后的布局覆盖。
    override func viewDidLayout() {
        super.viewDidLayout()
        if canPlace { DispatchQueue.main.async { [weak self] in self?.placeIfNeeded() } }
    }

    private var canPlace: Bool {
        !placed && view.bounds.width >= Self.leadingWidth.lowerBound + Self.trailingWidth.lowerBound + Self.centerMinWidth
    }

    /// 按记住的栏宽摆放一次（`viewDidLayout` 之后自动调用；测试里直接调用）。
    func placeIfNeeded() {
        guard canPlace else { return }
        placed = true
        applyWidths()
    }

    /// 每次 `setPosition` 之后先完成布局：连续两次 `setPosition` 时后一次会被前一次待做的布局覆盖。
    private func applyWidths() {
        let (leading, trailing) = fittedWidths()
        if !leadingItem.isCollapsed {
            splitView.setPosition(leading, ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
        }
        if !trailingItem.isCollapsed {
            splitView.setPosition(view.bounds.width - trailing - splitView.dividerThickness, ofDividerAt: 1)
            splitView.layoutSubtreeIfNeeded()
        }
    }

    /// 窗口放不下记住的栏宽时（中栏会小于最小宽度），左右栏按比例缩向最小宽度，只用于显示，不改记住的宽度。
    func fittedWidths() -> (leading: CGFloat, trailing: CGFloat) {
        let leading = leadingItem.isCollapsed ? 0 : widths.leading
        let trailing = trailingItem.isCollapsed ? 0 : widths.trailing
        let available = view.bounds.width - Self.centerMinWidth - 2 * splitView.dividerThickness
        let excess = leading + trailing - available
        guard excess > 0 else { return (leading, trailing) }
        let slackL = leadingItem.isCollapsed ? 0 : leading - Self.leadingWidth.lowerBound
        let slackT = trailingItem.isCollapsed ? 0 : trailing - Self.trailingWidth.lowerBound
        let ratio = slackL + slackT > 0 ? min(excess / (slackL + slackT), 1) : 0
        return (leading - slackL * ratio, trailing - slackT * ratio)
    }


    /// 记下展开着的左右栏的当前宽度并保存。
    func recordWidths() {
        if !leadingItem.isCollapsed { widths.leading = leadingItem.viewController.view.frame.width.clamped(to: Self.leadingWidth) }
        if !trailingItem.isCollapsed { widths.trailing = trailingItem.viewController.view.frame.width.clamped(to: Self.trailingWidth) }
        if let key = widthsKey { UserDefaults.standard.set([Double(widths.leading), Double(widths.trailing)], forKey: key) }
    }

    /// 显示或收起左右栏。状态没变时什么也不做，所以 SwiftUI 每次刷新调用也不会改动栏宽。
    ///
    /// 不做动画：动画进行中再次切换（快速连按 ⌃⌘S）时，AppKit 会把动画中途的宽度当成展开宽度记下，栏会越来越窄。
    func setVisibility(leading: Bool, trailing: Bool) {
        var expanded = false
        for (item, visible) in [(leadingItem, leading), (trailingItem, trailing)] where item.isCollapsed == visible {
            item.isCollapsed = !visible
            expanded = expanded || visible
        }
        // 展开时明确恢复记住的宽度（AppKit 自己恢复时，窗口变过宽度就可能不准）。
        if expanded, placed {
            view.layoutSubtreeIfNeeded()
            applyWidths()
        }
    }

    /// 只显示、可拖动的分隔线：收起的栏旁边的分隔线隐藏。
    override func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        dividerIndex == 0 ? leadingItem.isCollapsed : trailingItem.isCollapsed
    }
}

/// 鼠标在分隔线上拖动结束时回调（`mouseDown` 在拖动结束后才返回）。
final class DragTrackingSplitView: NSSplitView {
    var didEndDrag: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        didEndDrag?()
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
