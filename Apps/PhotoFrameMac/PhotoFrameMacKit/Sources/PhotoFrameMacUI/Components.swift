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
            HStack(spacing: 6) {
                content
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
        .background(Palette.panel)
    }
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

/// 任务的错误和警告：每条完整显示，有修改建议的另起一行（任务行的弹出框和 Inspector 的「警告」共用）。
struct JobIssueList: View {
    let issues: [JobIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(issues) { issue in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    JobIssueIcon(isError: issue.isError)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.message)
                        if let hint = issue.hint {
                            Text("建议：\(hint)").font(.caption).foregroundStyle(.secondary)
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

struct JobIssueIcon: View {
    let isError: Bool

    var body: some View {
        Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(isError ? Color.red : Color.yellow)
    }
}
