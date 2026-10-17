import AppKit
import PhotoFrameApplication
import PhotoFrameMacModel
import SwiftUI

/// 「活跃」：正在执行和排队中的任务，可以暂停、取消（UI 设计文档第 2 节）。
struct ActiveJobsView: View {
    @Bindable var workbench: Workbench

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(workbench.isQueuePaused ? "继续" : "暂停", systemImage: workbench.isQueuePaused ? "play.fill" : "pause.fill") {
                    Task { await workbench.toggleQueuePaused() }
                }
                .help("暂停只停止派发新任务，正在执行的任务会做完")
                Button("取消", systemImage: "xmark") { Task { await workbench.cancel(workbench.jobSelection) } }
                    .disabled(workbench.jobSelection.isEmpty)
                Spacer()
            }
            .padding(8)
            Divider()
            if workbench.activeJobs.isEmpty {
                ContentUnavailableView("没有活跃的任务", systemImage: "checkmark.circle")
            } else {
                Table(workbench.activeJobs, selection: $workbench.jobSelection) {
                    TableColumn("源图") { Text($0.spec.source.displayName) }
                    TableColumn("预设") { Text($0.spec.preset.name) }
                    TableColumn("阶段") { Text($0.status.title) }.width(70)
                    TableColumn("进度") { JobProgressView(record: $0) }
                    TableColumn("位置") { Text($0.spec.destination.rootDirectory.displayPath).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// 每个任务的真实进度：已写出页数 / 计划页数；还不知道页数时显示阶段。
private struct JobProgressView: View {
    let record: JobRecord

    var body: some View {
        if let planned = record.progress.plannedOutputs, planned > 0 {
            ProgressView(value: Double(record.progress.completedOutputs), total: Double(planned)) {
                EmptyView()
            } currentValueLabel: {
                Text("\(record.progress.completedOutputs) / \(planned) 页")
            }
        } else if record.status == .queued {
            Text("等待").foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// 「已完成」：导出历史，可以在 Finder 中显示、重新导出、重试（UI 设计文档第 2 节）。
struct CompletedJobsView: View {
    @Bindable var workbench: Workbench

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(workbench.outputURLs(workbench.jobSelection))
                }
                .disabled(workbench.outputURLs(workbench.jobSelection).isEmpty)
                Button("重新导出", systemImage: "arrow.clockwise") { Task { await workbench.reexport(workbench.jobSelection) } }
                    .disabled(workbench.jobSelection.isEmpty)
                Button("重试", systemImage: "arrow.uturn.backward") { Task { await workbench.retry(workbench.jobSelection) } }
                    .disabled(!workbench.jobSelection.contains(where: workbench.canRetry))
                Spacer()
            }
            .padding(8)
            Divider()
            if workbench.finishedJobs.isEmpty {
                ContentUnavailableView("还没有导出记录", systemImage: "tray")
            } else {
                VerticalSplit(autosaveName: "HistoryAndDetail", topFraction: 0.65) {
                    table
                } bottom: {
                    JobDetail(record: selectedRecord)
                }
            }
        }
    }

    private var table: some View {
        Table(workbench.finishedJobs, selection: $workbench.jobSelection) {
            TableColumn("源图") { Text($0.spec.source.displayName) }
            TableColumn("预设") { Text($0.spec.preset.name) }
            TableColumn("结果") { StatusLabel(record: $0) }.width(80)
            TableColumn("输出") { record in
                if let manifest = record.manifest, let first = manifest.items.first {
                    Text("\(manifest.items.count) 个文件 · \(first.pixelSize.text)")
                }
            }
            TableColumn("警告") { record in
                let count = (record.manifest?.warnings.count ?? 0) + record.currentAttempt.warnings.count
                if count > 0 { Label("\(count)", systemImage: "exclamationmark.triangle").foregroundStyle(.yellow) }
            }
            .width(60)
            TableColumn("耗时") { record in
                if let duration = record.manifest?.duration { Text(Duration.seconds(duration).formatted(.units(allowed: [.minutes, .seconds], fractionalPart: .show(length: 1)))) }
            }
            .width(80)
        }
        .contextMenu(forSelectionType: JobID.self) { ids in
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(workbench.outputURLs(ids)) }
            Button("重新导出") { Task { await workbench.reexport(ids) } }
            Button("重试") { Task { await workbench.retry(ids) } }.disabled(!ids.contains(where: workbench.canRetry))
        } primaryAction: { ids in
            NSWorkspace.shared.activateFileViewerSelecting(workbench.outputURLs(ids))
        }
    }

    private var selectedRecord: JobRecord? {
        workbench.jobSelection.count == 1 ? workbench.jobSelection.first.flatMap(workbench.record) : nil
    }
}

private struct StatusLabel: View {
    let record: JobRecord

    var body: some View {
        switch record.status {
        case .completed: Label("完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Label("失败", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        default: Label(record.status.title, systemImage: "minus.circle").foregroundStyle(.secondary)
        }
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
                            HStack {
                                Text(item.fileName)
                                Spacer()
                                Text(item.pixelSize.text).monospacedDigit()
                                Text(item.colorProfile ?? "").foregroundStyle(.secondary)
                                Text(ByteCountFormatter.string(fromByteCount: item.fileSizeBytes, countStyle: .file)).foregroundStyle(.secondary)
                            }
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

/// 底栏：添加图片、默认导出位置、批处理进度、开始批处理（UI 设计文档第 11、12 节）。
struct BottomBar: View {
    @Bindable var workbench: Workbench

    var body: some View {
        HStack(spacing: 16) {
            Button("添加图片", systemImage: "plus") { workbench.isAddingImages = true }
            Picker("位置", selection: defaultLocation) {
                ForEach(workbench.locations.locations) { location in
                    Text(location.name).tag(UUID?.some(location.id))
                }
            }
            .fixedSize()
            .help(workbench.locations.defaultLocation?.url.displayPath ?? "")
            Spacer()
            if let progress = workbench.batchProgress {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 220)
                Text(progressText(progress))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("开始批处理") { Task { await workbench.startBatch() } }
                .buttonStyle(.borderedProminent)
                .disabled(workbench.sources.allSatisfy(\.jobs.isEmpty) && !(workbench.isQueuePaused && !workbench.activeJobs.isEmpty))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var defaultLocation: Binding<UUID?> {
        Binding(get: { workbench.locations.defaultLocation?.id }, set: { if let id = $0 { workbench.setDefaultLocation(id) } })
    }

    private func progressText(_ p: BatchProgress) -> String {
        var text = "\(p.finishedJobs) / \(p.totalJobs) 个任务"
        if p.plannedOutputs > 0 { text += " · \(p.completedOutputs) / \(p.plannedOutputs) 页" }
        if p.failedJobs > 0 { text += " · \(p.failedJobs) 个失败" }
        return text
    }
}
