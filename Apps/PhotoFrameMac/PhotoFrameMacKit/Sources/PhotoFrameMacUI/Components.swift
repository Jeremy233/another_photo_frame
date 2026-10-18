import AppKit
import PhotoFrameMacModel
import SwiftUI

/// 需要输入名称的操作（重命名、存储为预设）。
struct RenameRequest: Identifiable {
    let id = UUID()
    var title: String
    var name: String
    var confirm = "好"
    var commit: (String) -> Void
}

private struct RenameAlert: ViewModifier {
    @Binding var request: RenameRequest?
    @State private var text = ""

    func body(content: Content) -> some View {
        content.alert(
            request?.title ?? "", isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
            presenting: request
        ) { request in
            TextField("名称", text: $text)
                .onAppear { text = request.name }
            Button(request.confirm) {
                let name = text.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { request.commit(name) }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

extension View {
    func renameAlert(_ request: Binding<RenameRequest?>) -> some View {
        modifier(RenameAlert(request: request))
    }
}

extension URL {
    var displayPath: String {
        (path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}

/// 每栏底部的操作栏（约 28 pt）：小号按钮靠左排列。
struct ColumnFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            // 不用末尾的 Spacer：它和最后一个控件之间还会多出 6 pt 间距，右边距就比左边宽。
            HStack(spacing: BarMetrics.gap) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
            .buttonStyle(.bordered)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .padding(.horizontal, BarMetrics.padding)
            .frame(height: BarMetrics.height)
        }
        .background(Palette.panel)
    }
}

/// 各栏标题栏、底栏里相邻控件之间看得见的空隙（13 pt，以中栏底栏「位置」标签到菜单边框为准）。
/// 带边框的小号按钮边框就是它的边界；其他控件自带内缩，在用到的地方减掉（数值是实测的）。
enum BarMetrics {
    /// 每栏顶部标题行、底部操作栏、预览上下两行的高度（参照 Compressor 约 28 pt）。
    static let height: CGFloat = 28
    /// 这些栏左右两端的内边距：各栏标题从同一处开始，与下面底栏的「+」对齐。
    static let padding: CGFloat = 10
    static let gap: CGFloat = 13
    /// 弹出菜单（带边框）边框外的内缩。
    static let popUpInset: CGFloat = 1
    /// 无边框菜单文字左边、右边（含 ⌄）的内缩。
    static let borderlessMenuLeading: CGFloat = 3
    static let borderlessMenuTrailing: CGFloat = 6.5
}

/// 界面上所有分隔线：纯黑、1 个物理像素（Retina 上 0.5 pt），与 Compressor 一致。
/// 用物理像素而不是 1 pt：Compressor 截图（@2x）里量到的是 1 px；1 pt 在 Retina 上是 2 px，明显更粗。
struct Hairline: View {
    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let thickness = 1 / max(displayScale, 1)
        Rectangle()
            .fill(Palette.line)
            .frame(width: axis == .vertical ? thickness : nil, height: axis == .horizontal ? thickness : nil)
    }
}

/// 固定深色界面的中性灰（不随桌面壁纸染色，便于判断照片颜色）。明度参照 Compressor 的取样，只用灰阶。
enum Palette {
    static let toolbar = Color(white: 0.15)
    static let sidebar = Color(white: 0.118)
    static let panel = Color(white: 0.122)
    static let list = Color(white: 0.086)
    static let preview = Color(white: 0.09)
    /// 分组框、源图头部。
    static let group = Color(white: 0.176)
    /// 分隔线、描边。
    static let line = Color.black
    /// 行图标（预设、位置、文件夹…）：所有列表和表格都是中性灰。用具体的颜色而不是层级样式 `.secondary`：
    /// 非侧栏的 List 会把层级样式染成强调色。
    static let icon = Color(nsColor: .secondaryLabelColor)
    /// 警告（黄色三角）与错误（红色八角形）：全应用只用这两种颜色表示问题，没有橙色的「提醒」级别。
    static let warning = Color.yellow
    static let error = Color.red
}

/// 分组底色（源图头部、右栏分组框、信息卡）和放在它们上面的拖放高亮框的圆角。
enum GroupStyle {
    static let cornerRadius: CGFloat = 8
}

/// 标记（SDR / HDR、默认）：全应用一种胶囊样式，参照 Compressor 右栏的 SDR 标记。
struct Badge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.fill.secondary, in: .rect(cornerRadius: 4))
            .fixedSize()
    }
}

/// 拿到所在窗口做 AppKit 层面的设置（SwiftUI 没有对应修饰符的部分）。
struct WindowConfigurator: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ConfiguringView(configure: configure) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfiguringView: NSView {
        let configure: (NSWindow) -> Void

        init(configure: @escaping (NSWindow) -> Void) {
            self.configure = configure
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { configure(window) }
        }
    }
}

extension View {
    /// 撑满所在的栏并铺上中性灰：内容（例如空状态）比栏矮时，也不会露出被壁纸染色的窗口底色（D-105）。
    func filling(_ color: Color) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(color)
    }
}

/// 错误和警告的唯一写法：每条完整显示，图标 + 消息，有修改建议的另起一行「建议：…」。
/// 任务行的弹出框、右栏的「警告」（任务、源图）、「已完成」的详情共用。字号固定，不随所在的行变化。
struct JobIssueList: View {
    let issues: [JobIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if issue.isInfo {
                        Image(systemName: "info.circle").foregroundStyle(Palette.icon)
                    } else {
                        JobIssueIcon(isError: issue.isError)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.message).font(.body)
                        if let hint = issue.hint {
                            Text("建议：\(hint)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// 破坏性操作的按钮用红字（带边框的 macOS 按钮上 `role: .destructive` 看不出区别），参照 Compressor 的 Remove。
struct DestructiveButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) { Text(title).foregroundStyle(Palette.error) }
    }
}

/// 问题图标：错误是红色八角形，警告是黄色三角，都是实心的。
struct JobIssueIcon: View {
    let isError: Bool

    var body: some View {
        Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(isError ? Palette.error : Palette.warning)
    }
}

/// 空状态：图标 + 15 pt 半粗标题 + 13 pt 说明，与 Inspector 的「没有可检查的内容」同一套字号。
/// 不用系统 `ContentUnavailableView`：它的字号随所在区域变化，几处空状态大小不一。
struct EmptyState<Actions: View>: View {
    var title: String
    var symbol: String
    var description: String?
    var alignment: TextAlignment = .center
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            if let description {
                Text(description).font(.body).foregroundStyle(.secondary).multilineTextAlignment(alignment)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions.padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(title: String, symbol: String, description: String? = nil, alignment: TextAlignment = .center) {
        self.init(title: title, symbol: symbol, description: description, alignment: alignment) { EmptyView() }
    }
}

/// 按比例分配宽度的列（最后一列定宽放按钮）：各行用同一个布局时列对齐，栏变窄时一起缩。
/// 按固定的列数算宽度：某一格暂时没有内容时，其他列的位置也不变。批次列表的任务行和「已完成」的文件行共用。
struct FractionColumns: Layout {
    var fractions: [CGFloat]
    var trailing: CGFloat
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 400, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let flexible = max(bounds.width - trailing - spacing * CGFloat(fractions.count), 0)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = index < fractions.count ? flexible * fractions[index] : trailing
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

extension View {
    /// 点了列表里的一行（包括已经选中的行）时调用。不影响列表自己的选择、拖动和行里的按钮。
    func onRowClick(_ action: @escaping () -> Void) -> some View {
        contentShape(.rect).simultaneousGesture(TapGesture().onEnded(action))
    }
}

/// 结束正在进行的文字编辑：输入框交出焦点，还没回车的数字写回。「开始批处理」「存储」之前调用，
/// 否则最后输入的值不会用上（数字框只在回车或失焦时写回）。
@MainActor
func endEditing() {
    for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap(\.self) {
        window.makeFirstResponder(nil)
    }
}

/// 输入时只改本地草稿，回车或离开输入框时才写回：写回时会规范化文字的字段（例如页码）逐字输入不会被打断。
struct CommitTextField: View {
    let title: String
    /// 当前的值（规范化后的文字）。
    let text: String
    var prompt: String?
    let commit: (String) -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: Binding(get: { draft ?? text }, set: { draft = $0 }), prompt: prompt.map { Text($0) })
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, now in if !now { apply() } }
            .onDisappear(perform: apply)
    }

    private func apply() {
        guard let value = draft else { return }
        draft = nil
        commit(value)
    }
}

/// 折叠三角（参照左栏常驻的三角）：展开时朝下。Inspector 分节和批处理列表的源图头部共用。
struct DisclosureChevron: View {
    var isExpanded: Bool

    static let width: CGFloat = 12

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: Self.width)
    }
}
