import AppKit
import PhotoFrameApplication
import PhotoFrameMacModel
import SwiftUI

/// 「活跃」：正在执行和排队中的任务，可以暂停、取消（UI 设计文档第 2 节）。
/// 版式参照 Compressor：全宽表格，列为名称 / 状态 / 已用时间 / 进度，每行右端是取消按钮。
struct ActiveJobsView: View {
    @Bindable var workbench: Workbench

    var body: some View {
        VStack(spacing: 0) {
            // 没有任务时这一行是空的、下面是空表格（与 Compressor 一样，见 `showsQueueControls`）。
            ColumnHeader {
                if workbench.showsQueueControls {
                    HStack(spacing: BarMetrics.gap) {
                        Button(workbench.isQueuePaused ? "继续" : "暂停", systemImage: workbench.isQueuePaused ? "play.fill" : "pause.fill") {
                            Task { await workbench.toggleQueuePaused() }
                        }
                        .help(workbench.isQueuePaused ? "继续派发排队中的任务" : "暂停后不再派发新任务，正在执行的任务会做完")
                        Spacer()
                        if let progress = workbench.batchProgress { BatchProgressLabel(progress: progress) }
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, BarMetrics.padding)
                }
            }
            table.scrollContentBackground(.hidden)
        }
    }

    private var table: some View {
        Table(workbench.activeJobs, selection: $workbench.jobSelection) {
            TableColumn("名称") { JobName(record: $0) }
            TableColumn("状态") { StatusText(record: $0) }.width(min: 80, ideal: 110)
            TableColumn("已用时间") { ElapsedTime(record: $0) }.width(80)
            TableColumn("进度") { JobProgressView(record: $0) }.width(min: 120, ideal: 160)
            TableColumn("") { record in
                RowButton(symbol: "xmark.circle.fill", help: "取消") { Task { await workbench.cancel([record.jobId]) } }
            }
            .width(28)
        }
        .contextMenu(forSelectionType: JobID.self) { ids in
            if !ids.isEmpty { Button("取消") { Task { await workbench.cancel(ids) } } }
        }
        .onDeleteCommand { Task { await workbench.cancel(workbench.jobSelection) } }
    }
}

/// 名称：源图 · 预设。两段各自中间截断，分隔点总在；悬停看全文和输出位置。
private struct JobName: View {
    let record: JobRecord

    var body: some View {
        let source = record.spec.source.displayName, preset = record.spec.preset.name
        Label {
            HStack(spacing: 4) {
                Text(source).lineLimit(1).truncationMode(.middle)
                Text("·").foregroundStyle(.secondary).fixedSize()
                Text(preset).lineLimit(1).truncationMode(.middle)
            }
        } icon: {
            Image(systemName: record.spec.preset.panorama.enabled ? "rectangle.split.3x1" : "rectangle.portrait")
                .foregroundStyle(Palette.icon)
        }
        .help("\(source) · \(preset)\n\(record.spec.destination.rootDirectory.displayPath)")
    }
}

/// 状态文字用强调色（失败为红色），参照 Compressor。文字都在 Labels.swift。
private struct StatusText: View {
    let record: JobRecord

    var body: some View {
        switch record.status {
        case .failed: Text(record.statusTitle).foregroundStyle(Palette.error).help(record.error?.displayText ?? "")
        case .canceled: Text(record.statusTitle).foregroundStyle(.secondary)
        default: Text(record.statusTitle).foregroundStyle(.tint)
        }
    }
}

/// 已用时间：执行中每秒刷新。排队中和已结束的任务时间不变，不挂定时刷新（「已完成」列表里每行都有这一列）。
private struct ElapsedTime: View {
    let record: JobRecord

    var body: some View {
        if record.currentAttempt.startedAt != nil, record.currentAttempt.finishedAt == nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.format(elapsed(at: context.date))).monospacedDigit()
            }
        } else {
            Text(Self.format(elapsed(at: .now))).monospacedDigit()
        }
    }

    private func elapsed(at now: Date) -> TimeInterval {
        guard let start = record.currentAttempt.startedAt else { return 0 }
        return (record.currentAttempt.finishedAt ?? now).timeIntervalSince(start)
    }

    /// `h:mm:ss`；不到一分钟时保留一位小数，很快的任务不会显示成 0。
    static func format(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "0:00:%04.1f", seconds) }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

/// 每个任务的真实进度：已写出页数 / 计划页数；还不知道页数时显示不定进度。
private struct JobProgressView: View {
    let record: JobRecord

    var body: some View {
        if let planned = record.progress.plannedOutputs, planned > 0 {
            ProgressView(value: Double(record.progress.completedOutputs), total: Double(planned))
                .help("\(record.progress.completedOutputs) / \(planned) 页")
        } else if record.status == .queued {
            ProgressView(value: 0)
        } else {
            ProgressView().progressViewStyle(.linear)
        }
    }
}

/// 表格行尾的图标按钮：全应用一种样式（实心圆形图标、中性灰）。
private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.icon)
            .help(help)
            .accessibilityLabel(help)
    }
}

/// 「已完成」：导出历史，按天分组，可以在 Finder 中显示、重新导出、重试（UI 设计文档第 2 节）。
/// 选择与「活跃」分开；每个操作在顶栏、右键菜单、行尾按钮用同一个判断。
struct CompletedJobsView: View {
    @Bindable var workbench: Workbench

    var body: some View {
        // 历史要过滤、排序再按天分组：每次只算一遍。
        let days = Self.days(workbench.finishedJobs)
        let selected = workbench.selectedFinishedJobs
        VStack(spacing: 0) {
            ColumnHeader {
                HStack(spacing: BarMetrics.gap) {
                    Button("在 Finder 中显示", systemImage: "magnifyingglass") { reveal(selected) }
                        .disabled(!canReveal(selected))
                    Button("重新导出", systemImage: "arrow.clockwise") { Task { await workbench.reexport(selected) } }
                        .disabled(!selected.contains(where: workbench.canReexport))
                    Button("重试", systemImage: "arrow.uturn.backward") { Task { await workbench.retry(selected) } }
                        .disabled(!selected.contains(where: workbench.canRetry))
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, BarMetrics.padding)
            }
            // 没有记录时与「活跃」一样显示空表格（带列标题）。
            if days.isEmpty {
                table(days).scrollContentBackground(.hidden)
            } else {
                VerticalSplit(autosaveName: "HistoryAndDetail", topFraction: 0.65) {
                    table(days).scrollContentBackground(.hidden).filling(Palette.list)
                } bottom: {
                    JobDetail(record: selected.count == 1 ? selected.first.flatMap(workbench.record) : nil)
                        .scrollContentBackground(.hidden)
                        .filling(Palette.panel)
                }
            }
        }
    }

    private func table(_ days: [(title: String, records: [JobRecord])]) -> some View {
        Table(of: JobRecord.self, selection: $workbench.historySelection) {
            TableColumn("名称") { JobName(record: $0) }
            TableColumn("状态") { StatusText(record: $0) }.width(min: 60, ideal: 90)
            TableColumn("输出") { record in
                // 与批次列表的「输出」同一种写法：主文字色、等宽数字。
                Text(record.outputSummary ?? "").monospacedDigit().lineLimit(1)
            }
            TableColumn("警告") { record in
                let count = record.displayWarnings.count
                if count > 0 {
                    Label {
                        Text("\(count)").monospacedDigit()
                    } icon: {
                        JobIssueIcon(isError: false)
                    }
                    .help(record.displayWarnings.map(\.message).joined(separator: "\n"))
                }
            }
            .width(50)
            TableColumn("已用时间") { ElapsedTime(record: $0) }.width(80)
            TableColumn("") { record in RowAction(workbench: workbench, record: record) }.width(28)
        } rows: {
            ForEach(days, id: \.title) { day in
                Section(day.title) {
                    ForEach(day.records) { TableRow($0) }
                }
            }
        }
        .contextMenu(forSelectionType: JobID.self) { ids in
            if !ids.isEmpty {
                Button("在 Finder 中显示") { reveal(ids) }.disabled(!canReveal(ids))
                Button("重新导出") { Task { await workbench.reexport(ids) } }.disabled(!ids.contains(where: workbench.canReexport))
                Button("重试") { Task { await workbench.retry(ids) } }.disabled(!ids.contains(where: workbench.canRetry))
            }
        } primaryAction: { ids in
            if canReveal(ids) { reveal(ids) }
        }
    }

    /// 按结束日期分组：今天、昨天、更早的日期。
    private static func days(_ records: [JobRecord]) -> [(title: String, records: [JobRecord])] {
        let calendar = Calendar.current
        var groups: [(title: String, records: [JobRecord])] = []
        for record in records {
            let date = record.currentAttempt.finishedAt ?? record.createdAt
            let title = calendar.isDateInToday(date) ? "今天"
                : calendar.isDateInYesterday(date) ? "昨天"
                : date.formatted(date: .abbreviated, time: .omitted)
            if groups.last?.title == title {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append((title, [record]))
            }
        }
        return groups
    }

    private func canReveal(_ ids: Set<JobID>) -> Bool { !workbench.outputURLs(ids).isEmpty }

    private func reveal(_ ids: Set<JobID>) {
        NSWorkspace.shared.activateFileViewerSelecting(workbench.outputURLs(ids))
    }
}

/// 每行右端的按钮：成功的「重新导出」，失败或取消的「重试」（D-52）。判断与顶栏、右键菜单相同。
private struct RowAction: View {
    let workbench: Workbench
    let record: JobRecord

    var body: some View {
        switch record.status {
        case .failed, .canceled:
            RowButton(symbol: "arrow.uturn.backward.circle.fill", help: "重试") { Task { await workbench.retry([record.jobId]) } }
        case .completed:
            RowButton(symbol: "arrow.clockwise.circle.fill", help: "重新导出") { Task { await workbench.reexport([record.jobId]) } }
        default:
            EmptyView()
        }
    }
}

/// 选中一个已结束任务时的详情：错误和警告（与右栏同一种列表）、输出文件。
private struct JobDetail: View {
    let record: JobRecord?

    var body: some View {
        if let record {
            List {
                let issues = record.issues
                if !issues.isEmpty {
                    Section(record.error == nil ? "警告" : "错误") { JobIssueList(issues: issues) }
                }
                if let manifest = record.manifest {
                    Section {
                        ForEach(manifest.items, id: \.fileURL) { item in
                            OutputFileRow(item: item)
                        }
                    } header: {
                        // 路径从中间省略：开头的位置和结尾的作品目录名都看得到。
                        Text(manifest.directory.displayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(manifest.directory.displayPath)
                    }
                }
            }
        } else {
            EmptyState(title: "选中一个任务查看详情", symbol: "info.circle")
        }
    }
}

/// 一个输出文件：文件名 | 尺寸 | 色彩 | 大小 | 在 Finder 中显示。各行列宽相同（与批次列表的任务行同一种列布局）。
private struct OutputFileRow: View {
    let item: OutputManifestItem

    private static let layout = FractionColumns(fractions: [0.4, 0.2, 0.25, 0.15], trailing: 20)

    var body: some View {
        Self.layout {
            Label {
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "doc").foregroundStyle(Palette.icon)
            }
            .help(item.fileURL.displayPath)
            Text(item.pixelSize.text).monospacedDigit().lineLimit(1)
            Text(item.colorProfile ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(item.colorProfile ?? "")
            Text(ByteCountFormatter.string(fromByteCount: item.fileSizeBytes, countStyle: .file)).foregroundStyle(.secondary).monospacedDigit()
            RowButton(symbol: "magnifyingglass.circle.fill", help: "在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
            }
        }
    }
}

/// 批处理总进度的文字：只用真实指标（第 11 节）。
private struct BatchProgressLabel: View {
    let progress: BatchProgress

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: progress.fraction).frame(width: 140)
            Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var text: String {
        var text = "\(progress.finishedJobs) / \(progress.totalJobs) 个任务"
        if progress.plannedOutputs > 0 { text += " · \(progress.completedOutputs) / \(progress.plannedOutputs) 页" }
        if progress.failedJobs > 0 { text += " · \(progress.failedJobs) 个失败" }
        return text
    }
}

/// 中栏底部：添加图片、默认输出位置、批处理进度、开始批处理（UI 设计文档第 11、12 节）。
/// 参照 Compressor 每栏一段的底栏，只放在中栏下面；左栏底部是它自己的 + / 齿轮。
struct BottomBar: View {
    @Bindable var workbench: Workbench

    var body: some View {
        ColumnFooter {
            Button { workbench.isAddingImages = true } label: { Image(systemName: "plus") }
                .help("添加图片（⌘O）")
                .accessibilityLabel("添加图片")
            // 标签字号保持系统表单标签的 13 pt。
            HStack(spacing: BarMetrics.gap - BarMetrics.popUpInset) {
                Text("位置").font(.body)
                Picker("位置", selection: defaultLocation) {
                    ForEach(workbench.locations.locations) { location in
                        Text(location.name).tag(UUID?.some(location.id))
                    }
                }
                .labelsHidden()
            }
            .fixedSize()
            .help("新任务的默认输出位置：\(workbench.locations.defaultLocation?.url.displayPath ?? "")")
            Spacer()
            if let progress = workbench.batchProgress { BatchProgressLabel(progress: progress) }
            Spacer()
            Button("开始批处理") { startBatch(workbench) }
                .disabled(!workbench.canStartBatch)
        }
    }

    private var defaultLocation: Binding<UUID?> {
        Binding(get: { workbench.locations.defaultLocation?.id }, set: { if let id = $0 { workbench.setDefaultLocation(id) } })
    }
}

/// 「开始批处理」（底栏按钮和 ⌘↩）：先结束正在编辑的输入框，最后输入的值才会用上。
@MainActor
func startBatch(_ workbench: Workbench) {
    endEditing()
    Task { await workbench.startBatch() }
}
