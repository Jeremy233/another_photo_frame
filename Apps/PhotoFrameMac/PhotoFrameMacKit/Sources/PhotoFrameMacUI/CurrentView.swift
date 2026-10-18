import AppKit
import ImageIO
import PhotoFrameApplication
import PhotoFrameMacModel
import SwiftUI

/// 「当前」界面：上方预览，下方源图与任务列表，中间分隔线可上下拖动（UI 设计文档第 9、10 节）。
/// 比例参照 Compressor：预览约占 45%。
struct CurrentView: View {
    let workbench: Workbench

    var body: some View {
        VerticalSplit(autosaveName: "PreviewAndBatch", topFraction: 0.45) {
            PreviewPane(workbench: workbench, preview: workbench.preview)
        } bottom: {
            BatchList(workbench: workbench)
        }
    }
}

/// 源图与任务列表：每张源图一组（头部 + 列标题 + 它的任务），参照 Compressor 的批处理卡片。
struct BatchList: View {
    @Bindable var workbench: Workbench
    @State private var savingPreset: RenameRequest?
    @State private var targeted: SourceID?
    /// 折起来的源图：只显示头部，不显示它的任务。
    @State private var collapsed: Set<SourceID> = []

    var body: some View {
        Group {
            if workbench.sources.isEmpty {
                EmptyState(
                    title: "拖入图片", symbol: "photo.on.rectangle.angled",
                    description: "1. 从 Finder 拖入 JPEG、PNG 或 TIFF，或点下面的按钮\n2. 把左栏的预设拖到图片上，创建导出任务\n3. 选中任务，在右栏修改设置，然后点「开始批处理」",
                    alignment: .leading
                ) {
                    Button("添加图片…") { workbench.isAddingImages = true }
                }
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.list)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await workbench.dropFiles(urls) }
            return urls.contains { $0.isFileURL }
        }
        .renameAlert($savingPreset)
    }

    private var list: some View {
        List(selection: $workbench.selection) {
            BatchTitleRow(workbench: workbench)
            ForEach(workbench.sources) { item in
                Section {
                    SourceRow(workbench: workbench, item: item, isExpanded: !collapsed.contains(item.id)) {
                        if collapsed.contains(item.id) { collapsed.remove(item.id) } else { collapsed.insert(item.id) }
                    }
                        .tag(BatchItemID.source(item.id))
                        .listRowBackground(sourceBackground(item.id))
                        .dropTarget(workbench, item: .source(item.id)) { on in
                            if on { targeted = item.id } else if targeted == item.id { targeted = nil }
                        }
                    if !collapsed.contains(item.id) {
                        if !item.jobs.isEmpty {
                            JobColumns.header
                                .selectionDisabled()
                        }
                        ForEach(item.jobs) { job in
                            JobRow(workbench: workbench, job: job, source: item.source, isSelected: workbench.selection.contains(.job(job.id)))
                                .tag(BatchItemID.job(job.id))
                                .dropTarget(workbench, item: .job(job.id)) { _ in }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Palette.list)
        .environment(\.defaultMinListRowHeight, 22)
        .contextMenu(forSelectionType: BatchItemID.self) { items in
            if items.contains(where: { if case .job = $0 { true } else { false } }) {
                Menu("位置") {
                    ForEach(workbench.locations.locations) { location in
                        Button(location.name) { workbench.setDestinationForSelection(location.url) }
                    }
                }
                Button("复制任务") { workbench.duplicateSelectedJobs() }
                if workbench.selectedJobIds.count == 1 { Button("存储为预设…") { askPresetName() } }
                Divider()
            }
            Button("删除", role: .destructive) { workbench.removeSelection() }
        }
        .onDeleteCommand { workbench.removeSelection() }
    }

    /// 源图头部用分组底色；拖动预设或图片悬停时用强调色高亮（参照 Compressor 的拖放高亮）。
    private func sourceBackground(_ id: SourceID) -> some View {
        let isTargeted = targeted == id
        return RoundedRectangle(cornerRadius: 6)
            .fill(isTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(Palette.group))
            .overlay {
                if isTargeted { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
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
    func dropTarget(_ workbench: Workbench, item: BatchItemID, isTargeted: @escaping (Bool) -> Void) -> some View {
        dropDestination(for: String.self) { strings, _ in
            if let payload = strings.first.flatMap(DragPayload.init(string:)) {
                Task { await workbench.drop(payload, on: item) }
                return true
            }
            let urls = strings.compactMap(URL.init(string:)).filter(\.isFileURL)
            Task { await workbench.dropFiles(urls) }
            return !urls.isEmpty
        } isTargeted: { isTargeted($0) }
    }
}

/// 最上面一行：全部源图的名字 + 「添加」图片。
private struct BatchTitleRow: View {
    let workbench: Workbench

    var body: some View {
        HStack {
            Text(workbench.sources.map(\.source.displayName).joined(separator: ", "))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("添加") { workbench.isAddingImages = true }
                .buttonStyle(.link)
                .help("添加图片")
        }
        .font(.callout)
        .selectionDisabled()
    }
}

/// 任务行的列：预设 | 输出 | 位置 | 作品目录 | 按钮。按比例分配宽度，各行对齐，中栏变窄时一起缩。
/// 每一格都必须是一个视图：没有内容的 `if` 不算子视图，后面的列会错位，所以可能为空的格子用 ``JobCell`` 包一层。
struct JobColumns: Layout {
    static let fractions: [CGFloat] = [0.32, 0.2, 0.2, 0.28]
    static let trailing: CGFloat = 44
    static let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 400, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 按固定的列数算宽度：某一格暂时没有内容时，其他列的位置也不变。
        let flexible = max(bounds.width - Self.trailing - Self.spacing * CGFloat(Self.fractions.count), 0)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = index < Self.fractions.count ? flexible * Self.fractions[index] : Self.trailing
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + Self.spacing
        }
    }

    static var header: some View {
        JobColumns {
            Text("预设")
            Text("输出")
            Text("位置")
            Text("作品目录")
            Color.clear.frame(height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// 任务行的一格：内容为空时也占一列（见 ``JobColumns``）。
private struct JobCell<Content: View>: View {
    var alignment: Alignment = .leading
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: alignment) { content }
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

private struct SourceRow: View {
    let workbench: Workbench
    let item: SourceItem
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: Self.chevronGap) {
                // 三角放在缩略图左边的留白里（负的左边距），缩略图仍与下面任务行的图标对齐。
                Button(action: toggle) { DisclosureChevron(isExpanded: isExpanded).frame(maxHeight: .infinity).contentShape(.rect) }
                    .buttonStyle(.plain)
                    .opacity(item.jobs.isEmpty ? 0 : 1)
                    .disabled(item.jobs.isEmpty)
                    .help(isExpanded ? "折叠任务" : "展开任务")
                    .accessibilityLabel(isExpanded ? "折叠" : "展开")
                Thumbnail(url: item.source.fileURL)
            }
            .padding(.leading, -(DisclosureChevron.width + Self.chevronGap))
            Text(item.source.displayName).fontWeight(.medium)
            Spacer()
            if !isExpanded {
                Text("\(item.jobs.count) 个任务").font(.caption).foregroundStyle(.secondary)
            }
            info
            // 拖放之外的等价操作（§4.2）：从菜单选预设创建任务。
            Menu("添加") {
                ForEach(workbench.presets, id: \.presetId) { preset in
                    Button(preset.name) { Task { await workbench.addJobs(preset: preset.presetId, to: [item.id]) } }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.tint)
            .fixedSize()
            .help("用预设为这张图创建导出任务")
        }
        .padding(.vertical, 4)
    }

    private static let chevronGap: CGFloat = 2

    @ViewBuilder private var info: some View {
        if let inspection = item.inspection {
            if inspection.hdr.kind != "none" { Text("HDR").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            Text(inspection.displaySize.text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } else if let error = item.inspectionError {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(error.message)
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

/// 源图缩略图：按需缩小解码。解码结果按文件（URL + 修改时间）放在共用的小缓存里，行滚出去再回来时不再解码。
private struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    /// 每张 120 px，几百张也占不了多少内存；系统内存紧张时 NSCache 自己会清。
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        return cache
    }()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.fill.secondary)
            }
        }
        .frame(width: 44, height: 30)
        .clipShape(.rect(cornerRadius: 3))
        .task(id: url) {
            let key = Self.cacheKey(url)
            if let cached = Self.cache.object(forKey: key) {
                image = cached
                return
            }
            let loaded = await Self.load(url)
            // 行已经消失（任务被取消）就不放进缓存。
            if let loaded, !Task.isCancelled { Self.cache.setObject(loaded, forKey: key) }
            image = loaded
        }
    }

    /// 缓存键：文件路径 + 修改时间（文件改了就重新解码）。
    private static func cacheKey(_ url: URL) -> NSString {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        return "\(url.path)\n\(modified?.timeIntervalSinceReferenceDate ?? 0)" as NSString
    }

    private static func load(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 120,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
    }
}

private struct JobRow: View {
    let workbench: Workbench
    let job: DraftJob
    let source: PhotoSource
    let isSelected: Bool

    var body: some View {
        JobColumns {
            name
            Text(output).monospacedDigit().lineLimit(1)
            Label(workbench.locationName(for: job.destination) ?? job.destination.lastPathComponent, systemImage: "folder")
                .lineLimit(1)
                .help(job.destination.displayPath)
            JobCell { directory }
            JobCell(alignment: .trailing) { trailing }
        }
        .font(.callout)
    }

    private var name: some View {
        Label {
            HStack(spacing: 4) {
                Text(job.preset.name).lineLimit(1)
                if job.isModified { Text("已修改").font(.caption).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: job.preset.panorama.enabled ? "rectangle.split.3x1" : "rectangle.portrait").foregroundStyle(.secondary)
        }
    }

    private var output: String {
        guard let outputs = job.validation?.outputs, let first = outputs.first else { return "" }
        return outputs.count > 1 ? "\(first.pixelSize.text) · \(outputs.count - 1) 张" : first.pixelSize.text
    }

    /// 推算的作品目录；同名目录已存在、会加版本号时带提示图标（参照 Compressor 文件已存在时的警告角标）。
    @ViewBuilder private var directory: some View {
        if let dir = job.validation?.directory {
            let exists = dir.lastPathComponent != job.naming.workName(source: source, preset: job.preset)
            Label {
                Text(dir.lastPathComponent).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: exists ? "folder.badge.questionmark" : "folder")
                    .foregroundStyle(exists ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .help(exists ? "同名作品目录已存在，开始批处理时会询问覆盖还是加版本号" : dir.displayPath)
        }
    }

    @ViewBuilder private var trailing: some View {
        if isSelected {
            Button("移除") { workbench.removeSelection() }
                .buttonStyle(.link)
                .foregroundStyle(.red)
        } else if !job.issues.isEmpty {
            IssueButton(issues: job.issues)
        }
    }
}

/// 任务行右端的警告图标：悬停显示全文，点按弹出完整列表和修改建议。
private struct IssueButton: View {
    let issues: [JobIssue]
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            JobIssueIcon(isError: issues.contains(where: \.isError))
        }
        .buttonStyle(.borderless)
        .help(issues.map(\.message).joined(separator: "\n"))
        .accessibilityLabel(issues.contains(where: \.isError) ? "错误" : "警告")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            JobIssueList(issues: issues)
                .padding(12)
                .frame(width: 340)
        }
    }
}
