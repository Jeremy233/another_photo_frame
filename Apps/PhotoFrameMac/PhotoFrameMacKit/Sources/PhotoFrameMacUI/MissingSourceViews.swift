import AppKit
import PhotoFrameApplication
import PhotoFrameMacModel
import SwiftUI

// 原图不见了时的界面：预览上的提示、「重新链接…」、两个确认框，以及什么时候检查原图在不在。

/// 什么时候检查原图在不在：App 变为活跃，卷装上、推出、改名（NAS 断开、重新连上）。只留最新的一个信号，检查做完再处理。
@MainActor
enum SourceAvailabilityTriggers {
    static func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [(NotificationCenter, Notification.Name)] = [
            (NotificationCenter.default, NSApplication.didBecomeActiveNotification),
            (workspace, NSWorkspace.didMountNotification),
            (workspace, NSWorkspace.didUnmountNotification),
            (workspace, NSWorkspace.didRenameVolumeNotification),
        ]
        let observers = names.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { _ in continuation.yield() })
        }
        let tokens = Observers(observers)
        continuation.onTermination = { _ in tokens.remove() }
        return stream
    }

    private final class Observers: @unchecked Sendable {
        let observers: [(NotificationCenter, any NSObjectProtocol)]
        init(_ observers: [(NotificationCenter, any NSObjectProtocol)]) { self.observers = observers }
        func remove() { for (center, token) in observers { center.removeObserver(token) } }
    }
}

/// 「重新链接…」：选择源图现在的位置。面板从原来的文件夹开始。
@MainActor
enum RelinkPanel {
    static func show(_ id: SourceID, workbench: Workbench) {
        guard let item = workbench.sourceItem(id) else { return }
        let old = item.source.fileURL
        let panel = NSOpenPanel()
        panel.title = "重新链接"
        panel.message = "「\(old.lastPathComponent)」原来在 \(old.deletingLastPathComponent().displayPath)，请选择它现在的位置"
        panel.prompt = "重新链接"
        panel.allowedContentTypes = FileTypes.images
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // 不在主线程上检查原来的文件夹还在不在（卷断开时会卡住）：不在时面板自己退回上次的位置。
        panel.directoryURL = old.deletingLastPathComponent()
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            Task { await workbench.relink(id, to: url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}

/// 预览上的提示：原图不见了，画面是上一次的结果（调暗显示在下面）。参照 Lightroom 缺失原图时仍显示预览。
struct StalePreviewNotice: View {
    let workbench: Workbench
    let sourceId: SourceID

    var body: some View {
        VStack(spacing: 10) {
            Label {
                Text("原图不见了，预览不是最新的").font(.body.weight(.semibold))
            } icon: {
                JobIssueIcon(isError: true)
            }
            if let url = workbench.sourceItem(sourceId)?.source.fileURL {
                Text(url.displayPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.displayPath)
            }
            Button("重新链接…") { RelinkPanel.show(sourceId, workbench: workbench) }
                .controlSize(.regular)
        }
        .padding(16)
        .frame(maxWidth: 420)
        .background(Palette.group, in: .rect(cornerRadius: GroupStyle.cornerRadius))
        .padding(20)
    }
}

extension View {
    /// 重新链接的文件与原图不一致时的确认，和开始批处理时「N 张原图找不到」的询问。
    func missingSourceDialogs(_ workbench: Workbench) -> some View {
        let relink = workbench.relinkPrompt
        let relinkShown = Binding(
            get: { workbench.relinkPrompt != nil },
            set: { if !$0, workbench.relinkPrompt != nil { Task { await workbench.resolveRelink(false) } } })
        let missing = workbench.missingPrompt
        let missingShown = Binding(
            get: { workbench.missingPrompt != nil },
            set: { if !$0, workbench.missingPrompt != nil { Task { await workbench.resolveMissingSources(.cancel) } } })
        return self
            .confirmationDialog("这可能不是同一张照片", isPresented: relinkShown, titleVisibility: .visible) {
                Button("仍然重新链接") { Task { await workbench.resolveRelink(true) } }
                Button("取消", role: .cancel) { Task { await workbench.resolveRelink(false) } }
            } message: {
                if let relink {
                    let lines = relink.differences.isEmpty
                        ? ["没有原图的信息，无法核对「\(relink.fileURL.lastPathComponent)」是不是同一张照片。"]
                        : ["「\(relink.fileURL.lastPathComponent)」与原图不一致："] + relink.differences.map { "· \($0.text)" }
                    Text((lines + ["", "重新链接后任务和改动都保留，按新文件导出。"]).joined(separator: "\n"))
                }
            }
            .confirmationDialog(missing.map { "\($0.fileURLs.count) 张原图找不到" } ?? "", isPresented: missingShown, titleVisibility: .visible) {
                Button("跳过并导出其余的") { Task { await workbench.resolveMissingSources(.skip) } }
                Button("取消", role: .cancel) { Task { await workbench.resolveMissingSources(.cancel) } }
            } message: {
                if let missing {
                    let names = missing.fileURLs.map { "· \($0.path)" }
                    Text((names + ["", "跳过的 \(missing.skippedJobs) 个任务留在「当前」里，重新链接后可以再导出。"]).joined(separator: "\n"))
                }
            }
    }
}
