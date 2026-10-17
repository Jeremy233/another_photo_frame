import PhotoFrameMacModel
import SwiftUI

/// 主窗口：左栏（预设 | 位置 | 素材）、中间（当前 / 活跃 / 已完成）、右栏 Inspector（UI 设计文档顶部示意）。
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
        } center: {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if workbench.mode == .current { BottomBar(workbench: workbench) }
                }
        } trailing: {
            InspectorView(workbench: workbench)
        }
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
            .disabled(workbench.mode != .current)
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
