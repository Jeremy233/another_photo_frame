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
/// 行都是 13 pt、单行；行之间不画分隔线（Compressor 的批次列表也没有）。
struct BatchList: View {
    @Bindable var workbench: Workbench
    @State private var savingPreset: RenameRequest?
    /// 拖放悬停在哪一行上（源图头部或任务行）。
    @State private var targeted: BatchItemID?

    var body: some View {
        Group {
            if workbench.sources.isEmpty {
                EmptyState(
                    title: "拖入图片", symbol: "photo.on.rectangle.angled",
                    description: "1. 从 Finder 拖入 JPEG、PNG 或 TIFF 图片，或点下面的按钮\n2. 把左栏的预设拖到源图上，或选中源图（⌘A 全选）后点预设，创建导出任务\n3. 选中任务，在右栏修改设置，然后点「开始批处理」",
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
                .listRowSeparator(.hidden)
            ForEach(workbench.sources) { item in
                let collapsed = workbench.isCollapsed(item.id)
                Section {
                    SourceRow(workbench: workbench, item: item, isExpanded: !collapsed) { workbench.setCollapsed(item.id, !collapsed) }
                        .tag(BatchItemID.source(item.id))
                        .listRowBackground(sourceBackground(item.id))
                        .listRowSeparator(.hidden)
                        .dropTarget(workbench, item: .source(item.id), targeted: $targeted)
                        .onRowClick { workbench.focusBatch() }
                    if !collapsed {
                        if !item.jobs.isEmpty {
                            JobColumns.header
                                .selectionDisabled()
                                .listRowSeparator(.hidden)
                        }
                        ForEach(item.jobs) { job in
                            JobRow(workbench: workbench, job: job, source: item.source, isSelected: workbench.selection.contains(.job(job.id)))
                                .tag(BatchItemID.job(job.id))
                                .listRowBackground(jobBackground(job.id))
                                .listRowSeparator(.hidden)
                                .dropTarget(workbench, item: .job(job.id), targeted: $targeted)
                                .onRowClick { workbench.focusBatch() }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Palette.list)
        .environment(\.defaultMinListRowHeight, 22)
        // 右键菜单作用于右键点到的行（点到选中的行时是全部选中的行），与「活跃」「已完成」两个表格一致；空白处没有菜单。
        .contextMenu(forSelectionType: BatchItemID.self) { items in menu(for: items) }
        .onDeleteCommand { workbench.removeSelection() }
        // ⌘A 选中全部源图和任务；⌘ 点按、⇧ 点按是列表自带的多选。
        .onCommand(#selector(NSResponder.selectAll(_:))) { workbench.selectAll() }
    }

    @ViewBuilder private func menu(for items: Set<BatchItemID>) -> some View {
        if !items.isEmpty {
            let jobs = items.compactMap { if case .job(let id) = $0 { id } else { nil } }
            // 与把位置拖到行上一样：源图改它的全部任务。
            if !workbench.jobIds(in: items).isEmpty {
                Menu("位置") {
                    ForEach(workbench.locations.locations) { location in
                        Button(location.name) { workbench.setDestination(location.url, for: items) }
                    }
                }
            }
            if !jobs.isEmpty {
                Button("复制任务") { workbench.duplicateJobs(Set(jobs)) }
                if jobs.count == 1, let id = jobs.first { Button("存储为预设…") { askPresetName(id) } }
            }
            Divider()
            // 只从批次里拿掉，不删文件。
            Button("移除", role: .destructive) { workbench.remove(items) }
        }
    }

    /// 源图头部用分组底色，选中时用选中的底色（自定义的行底色盖住了列表自己的选中高亮）；
    /// 拖动预设或图片悬停时用强调色高亮（参照 Compressor 的拖放高亮）。
    private func sourceBackground(_ id: SourceID) -> some View {
        let isTargeted = targeted == .source(id)
        let fill: AnyShapeStyle = if isTargeted {
            AnyShapeStyle(Color.accentColor.opacity(0.25))
        } else if workbench.selection.contains(.source(id)) {
            AnyShapeStyle(Palette.selection)
        } else {
            AnyShapeStyle(Palette.group)
        }
        return RoundedRectangle(cornerRadius: GroupStyle.cornerRadius)
            .fill(fill)
            .overlay {
                if isTargeted { RoundedRectangle(cornerRadius: GroupStyle.cornerRadius).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
    }

    /// 任务行平时用列表自己的底色（含选中高亮）；拖动位置悬停时与源图头部一样高亮。
    private func jobBackground(_ id: UUID) -> AnyView? {
        guard targeted == .job(id) else { return nil }
        return AnyView(RoundedRectangle(cornerRadius: GroupStyle.cornerRadius)
            .fill(Color.accentColor.opacity(0.25))
            .overlay { RoundedRectangle(cornerRadius: GroupStyle.cornerRadius).strokeBorder(Color.accentColor, lineWidth: 2) })
    }

    private func askPresetName(_ id: UUID) {
        let name = workbench.job(id)?.preset.name ?? ""
        savingPreset = RenameRequest(title: "存储为预设", name: name, confirm: "存储") { name in
            Task { await workbench.saveJobAsPreset(id, name: name) }
        }
    }
}

private extension View {
    /// 接收左栏拖来的预设、位置，以及 Finder 拖来的图片；悬停时记下是哪一行，用来高亮。
    func dropTarget(_ workbench: Workbench, item: BatchItemID, targeted: Binding<BatchItemID?>) -> some View {
        dropDestination(for: String.self) { strings, _ in
            if let payload = strings.first.flatMap(DragPayload.init(string:)) {
                Task { await workbench.drop(payload, on: item) }
                return true
            }
            let urls = strings.compactMap(URL.init(string:)).filter(\.isFileURL)
            Task { await workbench.dropFiles(urls) }
            return !urls.isEmpty
        } isTargeted: { on in
            if on { targeted.wrappedValue = item } else if targeted.wrappedValue == item { targeted.wrappedValue = nil }
        }
    }
}

/// 最上面一行：全部源图的名字 + 「添加…」图片（打开文件面板，所以带「…」）。
private struct BatchTitleRow: View {
    let workbench: Workbench

    var body: some View {
        let names = workbench.sources.map(\.source.displayName).joined(separator: "、")
        HStack {
            Text(names)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(names)
            Spacer()
            Button("添加…") { workbench.isAddingImages = true }
                .buttonStyle(.link)
                .help("添加图片（⌘O）")
        }
        .font(.body)
        .selectionDisabled()
    }
}

/// 任务行的列：预设 | 输出 | 位置 | 作品目录 | 按钮。按比例分配宽度，各行对齐，中栏变窄时一起缩。
/// 每一格都必须是一个视图：没有内容的 `if` 不算子视图，后面的列会错位，所以可能为空的格子用 ``JobCell`` 包一层。
enum JobColumns {
    static let layout = FractionColumns(fractions: [0.32, 0.2, 0.2, 0.28], trailing: 44)

    /// 列标题 11 pt，与「活跃」「已完成」表格的列标题一样大。
    static var header: some View {
        layout {
            Text("预设")
            Text("输出")
            Text("位置")
            Text("作品目录")
            Color.clear.frame(height: 1)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// 任务行的一格：内容为空时也占一列（见 ``JobColumns``）。
struct JobCell<Content: View>: View {
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
                    .help(isExpanded ? "折叠" : "展开")
                    .accessibilityLabel(isExpanded ? "折叠" : "展开")
                Thumbnail(url: item.source.fileURL)
            }
            .padding(.leading, -(DisclosureChevron.width + Self.chevronGap))
            Text(item.source.displayName)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.source.fileURL.displayPath)
            Spacer()
            if !isExpanded {
                Text("\(item.jobs.count) 个任务").font(.subheadline).foregroundStyle(.secondary)
            }
            info
            // 拖放之外的等价操作（§4.2）：从菜单选预设创建任务，作用的源图与拖放相同。
            Menu {
                ForEach(workbench.presets, id: \.presetId) { preset in
                    Button(preset.name) { Task { await workbench.addJobs(preset: preset.presetId, onto: item.id) } }
                }
            } label: {
                Text("添加").foregroundStyle(Color.accentColor)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("用预设为这张源图创建导出任务；选中多张源图时每张各建一个")
        }
        .font(.body)
        .padding(.vertical, 4)
    }

    private static let chevronGap: CGFloat = 2

    @ViewBuilder private var info: some View {
        if let inspection = item.inspection {
            // 只标出真正的 HDR；标为 HDR 但没有超出 SDR 的高光的源图按 SDR 导出，不标（右栏写明原因）。
            if item.dynamicRange == .hdr { Badge(text: "HDR") }
            Text(inspection.displaySize.text).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        } else if let error = item.inspectionError {
            // 读不出来是错误（红色八角形），不是警告。
            JobIssueIcon(isError: true).help(error.displayText)
        } else {
            ProgressView().controlSize(.small)
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
        JobColumns.layout {
            name
            // 与「已完成」的「输出」同一种写法：主文字色、等宽数字。
            Text(job.outputSummary ?? "").monospacedDigit().lineLimit(1)
            Label {
                Text(workbench.locationName(for: job.destination) ?? job.destination.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder").foregroundStyle(Palette.icon)
            }
            .help(job.destination.displayPath)
            JobCell { directory }
            JobCell(alignment: .trailing) { trailing }
        }
        .font(.body)
    }

    private var name: some View {
        Label {
            HStack(spacing: 4) {
                Text(job.preset.name).lineLimit(1).truncationMode(.middle).help(job.preset.name)
                if job.isModified { Text("已修改").font(.subheadline).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: job.preset.panorama.enabled ? "rectangle.split.3x1" : "rectangle.portrait").foregroundStyle(Palette.icon)
        }
    }

    /// 推算的作品目录；同名目录已存在、会加版本号时带警告色的图标（参照 Compressor 文件已存在时的警告角标）。
    @ViewBuilder private var directory: some View {
        if let dir = job.validation?.directory {
            let exists = dir.lastPathComponent != job.naming.workName(source: source, preset: job.preset)
            Label {
                Text(dir.lastPathComponent).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: exists ? "folder.badge.questionmark" : "folder")
                    .foregroundStyle(exists ? Palette.warning : Palette.icon)
            }
            .help(exists ? "同名作品目录已存在，开始批处理时会询问覆盖还是保留两者" : dir.displayPath)
        }
    }

    @ViewBuilder private var trailing: some View {
        if isSelected {
            // 从批次里拿掉，不删文件。
            Button("移除") { workbench.removeSelection() }
                .buttonStyle(.link)
                .foregroundStyle(Palette.error)
        } else if !job.issues.isEmpty {
            IssueButton(issues: job.issues)
        }
    }
}

/// 任务行右端的问题图标：悬停显示全文，点按弹出完整列表和修改建议。
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
