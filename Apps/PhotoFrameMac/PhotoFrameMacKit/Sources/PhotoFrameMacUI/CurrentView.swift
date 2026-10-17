import PhotoFrameApplication
import PhotoFrameMacModel
import SwiftUI

/// 「当前」界面：上方预览，下方源图与任务列表，中间分隔线可上下拖动（UI 设计文档第 9、10 节）。
struct CurrentView: View {
    let workbench: Workbench

    var body: some View {
        VerticalSplit(autosaveName: "PreviewAndBatch") {
            PreviewPane(workbench: workbench, preview: workbench.preview)
        } bottom: {
            BatchList(workbench: workbench)
        }
    }
}

/// 源图与任务列表：按源图分组，每张源图下面是它的导出任务。
struct BatchList: View {
    @Bindable var workbench: Workbench
    @State private var savingPreset: RenameRequest?

    var body: some View {
        Group {
            if workbench.sources.isEmpty {
                ContentUnavailableView {
                    Label("拖入图片", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("从 Finder 拖入 JPEG、PNG 或 TIFF，再把左栏的预设拖到图片上创建导出任务。")
                } actions: {
                    Button("添加图片…") { workbench.isAddingImages = true }
                }
            } else {
                list
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await workbench.dropFiles(urls) }
            return urls.contains { $0.isFileURL }
        }
        .renameAlert($savingPreset)
    }

    private var list: some View {
        List(selection: $workbench.selection) {
            ForEach(workbench.sources) { item in
                SourceRow(item: item)
                    .tag(BatchItemID.source(item.id))
                    .dropTarget(workbench, item: .source(item.id))
                ForEach(item.jobs) { job in
                    JobRow(workbench: workbench, job: job)
                        .padding(.leading, 20)
                        .tag(BatchItemID.job(job.id))
                        .dropTarget(workbench, item: .job(job.id))
                }
            }
        }
        .contextMenu(forSelectionType: BatchItemID.self) { items in
            if items.contains(where: { if case .job = $0 { true } else { false } }) {
                Button("复制任务") { workbench.duplicateSelectedJobs() }
                if workbench.selectedJobIds.count == 1 { Button("存储为预设…") { askPresetName() } }
                Divider()
            }
            Button("删除", role: .destructive) { workbench.removeSelection() }
        }
        .onDeleteCommand { workbench.removeSelection() }
    }

    private func askPresetName() {
        let name = workbench.selectedJobIds.first.flatMap(workbench.job)?.preset.name ?? ""
        savingPreset = RenameRequest(title: "存储为预设", name: name, confirm: "存储") { name in
            Task { await workbench.saveSelectedJobAsPreset(name: name) }
        }
    }
}

private extension View {
    /// 接收左栏拖来的预设、位置，以及 Finder 拖来的图片。
    func dropTarget(_ workbench: Workbench, item: BatchItemID) -> some View {
        dropDestination(for: String.self) { strings, _ in
            if let payload = strings.first.flatMap(DragPayload.init(string:)) {
                Task { await workbench.drop(payload, on: item) }
                return true
            }
            let urls = strings.compactMap(URL.init(string:)).filter(\.isFileURL)
            Task { await workbench.dropFiles(urls) }
            return !urls.isEmpty
        }
    }
}

private struct SourceRow: View {
    let item: SourceItem

    var body: some View {
        HStack {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text(item.source.displayName)
                .fontWeight(.medium)
            Spacer()
            if let inspection = item.inspection {
                if inspection.hdr.kind != "none" { Text("HDR").font(.caption).foregroundStyle(.secondary) }
                Text(inspection.displaySize.text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if let error = item.inspectionError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(error.message)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

private struct JobRow: View {
    let workbench: Workbench
    let job: DraftJob

    var body: some View {
        HStack(spacing: 12) {
            Text(job.preset.name)
            if job.isModified {
                Text("已修改").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let outputs = job.validation?.outputs, let first = outputs.first {
                Text(first.pixelSize.text).monospacedDigit()
                if outputs.count > 1 { Text("\(outputs.count - 1) 张切片") }
            }
            Text(workbench.locationName(for: job.destination) ?? job.destination.lastPathComponent)
                .foregroundStyle(.secondary)
            warning
        }
        .font(.callout)
    }

    @ViewBuilder private var warning: some View {
        if let validation = job.validation, job.warningCount > 0 {
            let lines = validation.errors.map(\.message) + validation.warnings.map(\.message)
            Image(systemName: validation.errors.isEmpty ? "exclamationmark.triangle" : "xmark.octagon.fill")
                .foregroundStyle(validation.errors.isEmpty ? Color.yellow : Color.red)
                .help(lines.joined(separator: "\n"))
        }
    }
}
