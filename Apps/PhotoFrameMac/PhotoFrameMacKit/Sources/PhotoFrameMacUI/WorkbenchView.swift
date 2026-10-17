import PhotoFrameMacModel
import SwiftUI

/// 主窗口：左栏（预设 | 位置 | 素材）、中间（当前 / 活跃 / 已完成）、右栏 Inspector、底栏（UI 设计文档顶部示意）。
///
/// 三栏用系统的 NavigationSplitView + inspector（AppKit 分割视图，分隔线可拖动、宽度自动记住）；
/// 视觉细节等 Compressor 截图后再调。
public struct WorkbenchView: View {
    @Bindable var workbench: Workbench
    @SceneStorage("sidebarVisibility") private var sidebarVisible = true

    public init(workbench: Workbench) {
        self.workbench = workbench
    }

    public var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: columnVisibility) {
                SidebarView(workbench: workbench)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
            } detail: {
                content
                    .toolbar { toolbar }
                    .inspector(isPresented: $workbench.showsInspector) {
                        InspectorView(workbench: workbench)
                            .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                    }
            }
            Divider()
            BottomBar(workbench: workbench)
        }
        .task { await workbench.load() }
        .task { await workbench.observeJobs() }
        .fileImporter(isPresented: $workbench.isAddingImages, allowedContentTypes: FileTypes.images, allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { Task { await workbench.addSources(urls) } }
        }
        .alert(item: $workbench.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .overwriteConfirmation(workbench)
        .frame(minWidth: 960, minHeight: 600)
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = $0 != .detailOnly })
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
                ForEach(WorkbenchMode.allCases) { Text($0.title).tag($0) }
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
