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
        .background(.bar)
    }
}
