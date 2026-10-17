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
                    HStack {
                        Button(workbench.isQueuePaused ? "继续" : "暂停", systemImage: workbench.isQueuePaused ? "play.fill" : "pause.fill") {
                            Task { await workbench.toggleQueuePaused() }
                        }
                        .help("暂停只停止派发新任务，正在执行的任务会做完（D-51）")
                        Spacer()
                        if let progress = workbench.batchProgress { BatchProgressLabel(progress: progress) }
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 10)
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
                Button { Task { await workbench.cancel([record.jobId]) } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("取消")
            }
            .width(28)
        }
        .contextMenu(forSelectionType: JobID.self) { ids in
            Button("取消") { Task { await workbench.cancel(ids) } }
        }
    }
}

/// 名称：源图 · 预设。
private struct JobName: View {
    let record: JobRecord

    var body: some View {
        Label {
            Text("\(record.spec.source.displayName) · \(record.spec.preset.name)").lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: record.spec.preset.panorama.enabled ? "rectangle.split.3x1" : "rectangle.portrait")
                .foregroundStyle(.secondary)
        }
        .help(record.spec.destination.rootDirectory.displayPath)
    }
}

/// 状态文字用强调色（失败为红色），参照 Compressor。
private struct StatusText: View {
    let record: JobRecord

    var body: some View {
        switch record.status {
        case .failed: Text("失败").foregroundStyle(.red).help(record.error?.message ?? "")
        case .canceled: Text("已取消").foregroundStyle(.secondary)
        case .completed: Text("成功").foregroundStyle(.tint)
        case .queued: Text("等待").foregroundStyle(.tint)
        default: Text("处理中 · \(record.status.title)").foregroundStyle(.tint)
        }
    }
}

/// 已用时间：执行中每秒刷新。
private struct ElapsedTime: View {
    let record: JobRecord

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(elapsed(at: context.date))).monospacedDigit()
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

/// 「已完成」：导出历史，按天分组，可以在 Finder 中显示、重新导出、重试（UI 设计文档第 2 节）。
struct CompletedJobsView: View {
    @Bindable var workbench: Workbench

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader {
                HStack {
                    Button("在 Finder 中显示", systemImage: "folder") { reveal(workbench.jobSelection) }
                        .disabled(workbench.outputURLs(workbench.jobSelection).isEmpty)
                    Button("重新导出", systemImage: "arrow.clockwise") { Task { await workbench.reexport(workbench.jobSelection) } }
                        .disabled(workbench.jobSelection.isEmpty)
                    Button("重试", systemImage: "arrow.uturn.backward") { Task { await workbench.retry(workbench.jobSelection) } }
                        .disabled(!workbench.jobSelection.contains(where: workbench.canRetry))
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
            }
            // 没有记录时与「活跃」一样显示空表格（带列标题）。
            if workbench.finishedJobs.isEmpty {
                table.scrollContentBackground(.hidden)
            } else {
                VerticalSplit(autosaveName: "HistoryAndDetail", topFraction: 0.65) {
                    table.scrollContentBackground(.hidden).filling(Palette.list)
                } bottom: {
                    JobDetail(record: selectedRecord).scrollContentBackground(.hidden).filling(Palette.panel)
                }
            }
        }
    }

    private var table: some View {
        Table(of: JobRecord.self, selection: $workbench.jobSelection) {
            TableColumn("名称") { JobName(record: $0) }
            TableColumn("状态") { StatusText(record: $0) }.width(min: 60, ideal: 90)
            TableColumn("输出") { record in
                if let manifest = record.manifest, let first = manifest.items.first {
                    Text("\(manifest.items.count) 个文件 · \(first.pixelSize.text)").foregroundStyle(.secondary)
                }
            }
            TableColumn("警告") { record in
                let count = (record.manifest?.warnings.count ?? 0) + record.currentAttempt.warnings.count
                if count > 0 { Label("\(count)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
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
            Button("在 Finder 中显示") { reveal(ids) }
            Button("重新导出") { Task { await workbench.reexport(ids) } }
            Button("重试") { Task { await workbench.retry(ids) } }.disabled(!ids.contains(where: workbench.canRetry))
        } primaryAction: { ids in
            reveal(ids)
        }
    }

    /// 按结束日期分组：今天、昨天、更早的日期。
    private var days: [(title: String, records: [JobRecord])] {
        let calendar = Calendar.current
        var groups: [(title: String, records: [JobRecord])] = []
        for record in workbench.finishedJobs {
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

    private var selectedRecord: JobRecord? {
        workbench.jobSelection.count == 1 ? workbench.jobSelection.first.flatMap(workbench.record) : nil
    }

    private func reveal(_ ids: Set<JobID>) {
        NSWorkspace.shared.activateFileViewerSelecting(workbench.outputURLs(ids))
    }
}

/// 每行右端的按钮：成功的「重新导出」，失败或取消的「重试」（D-52）。
private struct RowAction: View {
    let workbench: Workbench
    let record: JobRecord

    var body: some View {
        Group {
            if workbench.canRetry(record.jobId) {
                Button { Task { await workbench.retry([record.jobId]) } } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("重试")
            } else {
                Button { Task { await workbench.reexport([record.jobId]) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("重新导出")
            }
        }
        .buttonStyle(.borderless)
    }
}

/// 选中一个已结束任务时的详情：输出文件、警告、错误。
private struct JobDetail: View {
    let record: JobRecord?

    var body: some View {
        if let record {
            List {
                if let error = record.error {
                    Section("错误") {
                        Text(error.message).foregroundStyle(.red)
                        if let hint = error.hint { Text(hint).foregroundStyle(.secondary) }
                    }
                }
                if let manifest = record.manifest {
                    Section(manifest.directory.displayPath) {
                        ForEach(manifest.items, id: \.fileURL) { item in
                            OutputFileRow(item: item)
                        }
                    }
                }
                let warnings = (record.manifest?.warnings ?? []) + record.currentAttempt.warnings
                if !warnings.isEmpty {
                    Section("警告") { ForEach(warnings, id: \.self) { Text($0.message) } }
                }
            }
        } else {
            ContentUnavailableView("选中一个任务查看详情", systemImage: "info.circle")
        }
    }
}

private struct OutputFileRow: View {
    let item: OutputManifestItem

    var body: some View {
        HStack {
            Label(item.fileName, systemImage: "doc")
            Spacer()
            Text(item.pixelSize.text).monospacedDigit()
            Text(item.colorProfile ?? "").foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: item.fileSizeBytes, countStyle: .file)).foregroundStyle(.secondary)
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) } label: { Image(systemName: "magnifyingglass.circle") }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
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

/// 中栏底部：添加图片、默认导出位置、批处理进度、开始批处理（UI 设计文档第 11、12 节）。
/// 参照 Compressor 每栏一段的底栏，只放在中栏下面；左栏底部是它自己的 + / 齿轮。
struct BottomBar: View {
    @Bindable var workbench: Workbench

    var body: some View {
        ColumnFooter {
            Button { workbench.isAddingImages = true } label: { Image(systemName: "plus") }
                .help("添加图片（⌘O）")
            Picker("位置", selection: defaultLocation) {
                ForEach(workbench.locations.locations) { location in
                    Text(location.name).tag(UUID?.some(location.id))
                }
            }
            .fixedSize()
            .help("新任务的默认导出位置：\(workbench.locations.defaultLocation?.url.displayPath ?? "")")
            Spacer()
            if let progress = workbench.batchProgress { BatchProgressLabel(progress: progress) }
            Spacer()
            Button("开始批处理") { Task { await workbench.startBatch() } }
                .disabled(workbench.sources.allSatisfy(\.jobs.isEmpty) && !(workbench.isQueuePaused && !workbench.activeJobs.isEmpty))
        }
    }

    private var defaultLocation: Binding<UUID?> {
        Binding(get: { workbench.locations.defaultLocation?.id }, set: { if let id = $0 { workbench.setDefaultLocation(id) } })
    }
}
