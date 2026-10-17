import AppKit
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
            Divider()
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

/// 固定深色界面的中性灰（不随桌面壁纸染色，便于判断照片颜色）。明度参照 Compressor 的取样，只用灰阶。
enum Palette {
    static let toolbar = Color(white: 0.15)
    static let sidebar = Color(white: 0.118)
    static let panel = Color(white: 0.122)
    static let list = Color(white: 0.086)
    static let preview = Color(white: 0.09)
    /// 分组框、源图头部。
    static let group = Color(white: 0.176)
}
