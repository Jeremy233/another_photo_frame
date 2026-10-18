import PhotoFrameMacModel
import SwiftUI

/// 主窗口：左栏（预设 | 位置 | 素材）、中间（当前 / 活跃 / 已完成）、右栏（代码里叫 Inspector，UI 设计文档顶部示意）。
///
/// 布局参照 Compressor：整个窗口一条顶栏（左侧左栏开关，正中三个界面的切换，右侧 Inspector 开关），没有窗口标题；
/// 下面三栏是自己封装的 AppKit 分栏（`ColumnSplit`），每栏顶部一行小号控件、底部各有一段操作栏。
/// 与 Compressor 一样固定深色，背景用中性灰；控件都用 macOS 26 系统样式。
public struct WorkbenchView: View {
    @Bindable var workbench: Workbench

    public init(workbench: Workbench) {
        self.workbench = workbench
    }

    public var body: some View {
        ColumnSplit(
            autosaveName: "MainColumns",
            showsLeading: workbench.showsSidebar && workbench.mode == .current,
            showsTrailing: workbench.showsInspector
        ) {
            SidebarView(workbench: workbench)
                .filling(Palette.sidebar)
        } center: {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if workbench.mode == .current { BottomBar(workbench: workbench) }
                }
                .filling(Palette.list)
        } trailing: {
            InspectorView(workbench: workbench)
                .filling(Palette.panel)
        }
        // 工具栏下面一条贯穿整个窗口的黑线（系统自己的分隔线不是纯黑，由各栏决定画不画，所以关掉自己画）。
        .safeAreaInset(edge: .top, spacing: 0) { Hairline() }
        .background(WindowConfigurator { $0.titlebarSeparatorStyle = .none })
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .toolbarBackground(Palette.toolbar, for: .windowToolbar)
        .task {
            await workbench.load()
            await PhotoFrameAppDelegate.register(workbench)
            #if DEBUG
            await workbench.loadDemoIfRequested()
            #endif
        }
        .task { await workbench.observeJobs() }
        .fileImporter(isPresented: $workbench.isAddingImages, allowedContentTypes: FileTypes.images, allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { Task { await workbench.addSources(urls) } }
        }
        .alert(item: $workbench.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .overwriteConfirmation(workbench)
        .onChange(of: workbench.warningPrompt?.id) { _, id in
            if id != nil, let prompt = workbench.warningPrompt { WarningReviewAlert.show(prompt, workbench: workbench) }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder private var content: some View {
        switch workbench.mode {
        case .current: CurrentView(workbench: workbench)
        case .active: ActiveJobsView(workbench: workbench)
        case .completed: CompletedJobsView(workbench: workbench)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                workbench.showsSidebar.toggle()
            } label: {
                Label("左栏", systemImage: "sidebar.leading")
            }
            .disabled(!workbench.canToggleSidebar)
            .help("显示或隐藏左栏（⌃⌘S）")
        }
        ToolbarItem(placement: .principal) {
            Picker("界面", selection: $workbench.mode) {
                ForEach(WorkbenchMode.allCases) { mode in
                    Text(title(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                workbench.showsInspector.toggle()
            } label: {
                Label("右栏", systemImage: "sidebar.trailing")
            }
            .help("显示或隐藏右栏（⌥⌘I）")
        }
    }

    /// 有任务在跑时显示「活跃（N）」。
    private func title(_ mode: WorkbenchMode) -> String {
        let count = workbench.activeCount
        return mode == .active && count > 0 ? "\(mode.title)（\(count)）" : mode.title
    }
}

private extension View {
    /// 目标作品目录已存在时确认（D-49）：默认保留两者（加版本号），覆盖要明确选择。
    func overwriteConfirmation(_ workbench: Workbench) -> some View {
        let prompt = workbench.overwritePrompt
        let isPresented = Binding(
            get: { workbench.overwritePrompt != nil },
            set: { if !$0, workbench.overwritePrompt != nil { Task { await workbench.resolveOverwrite(.cancel) } } })
        return confirmationDialog("作品目录已存在", isPresented: isPresented, titleVisibility: .visible) {
            Button("保留两者（加版本号）") { Task { await workbench.resolveOverwrite(.keepBoth) } }
            Button("覆盖", role: .destructive) { Task { await workbench.resolveOverwrite(.overwrite) } }
            Button("取消", role: .cancel) { Task { await workbench.resolveOverwrite(.cancel) } }
        } message: {
            let names = prompt?.conflicts.map { "· \($0.directory.path)" } ?? []
            Text((names + ["", "覆盖只替换本软件之前导出的目录，替换前会完整校验新作品。"]).joined(separator: "\n"))
        }
    }
}

/// 开始批处理前有警告时的询问，参照 Compressor「The batch has warnings」：继续 / 查看 / 取消 + 不再询问。
/// 用 NSAlert，因为 SwiftUI 的提示框放不下「不再询问」复选框。
@MainActor
enum WarningReviewAlert {
    static func show(_ prompt: WarningPrompt, workbench: Workbench) {
        let alert = NSAlert()
        alert.messageText = prompt.jobIds.count == 1 ? "1 个任务带警告" : "\(prompt.jobIds.count) 个任务带警告"
        alert.informativeText = "共 \(prompt.warningCount) 条警告。要先查看，还是忽略警告继续？"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "查看")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "不再询问"
        let finish = { (response: NSApplication.ModalResponse) in
            let choice: WarningChoice = switch response {
            case .alertFirstButtonReturn: .proceed
            case .alertSecondButtonReturn: .review
            default: .cancel
            }
            let dontAsk = alert.suppressionButton?.state == .on
            Task { await workbench.resolveWarnings(choice, dontAskAgain: dontAsk) }
        }
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
