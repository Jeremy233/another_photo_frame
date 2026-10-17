import PhotoFrameMacModel
import SwiftUI

/// 主窗口：左栏（预设 | 位置 | 素材）、中间（当前 / 活跃 / 已完成）、右栏 Inspector、底栏（UI 设计文档顶部示意）。
///
/// 三栏用系统的 NavigationSplitView + inspector（AppKit 分割视图，分隔线可拖动、宽度自动记住）。
/// 布局参照 Compressor：顶栏没有窗口标题，正中是三个界面的切换，左右两端是侧栏开关；每栏顶部一行小号控件，
/// 底部各有一段操作栏。与 Compressor 一样固定深色，背景用中性灰；控件都用 macOS 26 系统样式。
public struct WorkbenchView: View {
    @Bindable var workbench: Workbench
    @SceneStorage("sidebarVisibility") private var sidebarVisible = true

    public init(workbench: Workbench) {
        self.workbench = workbench
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(workbench: workbench)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 420)
        } detail: {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if workbench.mode == .current { BottomBar(workbench: workbench) }
                }
                .toolbar { toolbar }
                .inspector(isPresented: $workbench.showsInspector) {
                    InspectorView(workbench: workbench)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 480)
                }
        }
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
        // 窗口最小宽度要容得下三栏的最小宽度，否则 AppKit 分栏会反复调整约束而崩溃（实测 1080 会崩、1120 稳定）。
        .frame(minWidth: 1120, minHeight: 640)
    }

    /// 「活跃」「已完成」时左栏自动收起，中栏变成全宽列表（与 Compressor 一致）；回到「当前」恢复。
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible && workbench.mode == .current ? .all : .detailOnly },
            set: { if workbench.mode == .current { sidebarVisible = $0 != .detailOnly } })
    }

    @ViewBuilder private var content: some View {
        switch workbench.mode {
        case .current: CurrentView(workbench: workbench)
        case .active: ActiveJobsView(workbench: workbench)
        case .completed: CompletedJobsView(workbench: workbench)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
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
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("显示或隐藏 Inspector（⌥⌘I）")
        }
    }

    /// 有任务在跑时显示「活跃 (N)」。
    private func title(_ mode: WorkbenchMode) -> String {
        let count = workbench.activeCount
        return mode == .active && count > 0 ? "\(mode.title) (\(count))" : mode.title
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
