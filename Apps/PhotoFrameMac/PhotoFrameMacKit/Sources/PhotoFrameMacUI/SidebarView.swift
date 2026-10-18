import AppKit
import ImageIO
import PhotoFrameApplication
import PhotoFrameMacModel
import PhotoFrameStorage
import SwiftUI

/// 左栏：预设 | 位置 | 素材（UI 设计文档第 4、7 节）。
///
/// 三个标签页同一套规则（README：一行一项、过长截断、悬停显示完整信息，图标中性灰），底部都是「+」和齿轮；
/// 有「删除 / 移除」菜单的地方都支持 ⌫，删除库里的预设、素材前先确认。
struct SidebarView: View {
    @Bindable var workbench: Workbench

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader {
                Picker("左栏", selection: $workbench.sidebarTab) {
                    ForEach(SidebarTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Group {
                switch workbench.sidebarTab {
                case .presets: PresetList(workbench: workbench)
                case .locations: LocationList(workbench: workbench)
                case .assets: AssetList(workbench: workbench)
                }
            }
            .environment(\.sidebarRowSize, .medium)
            .scrollContentBackground(.hidden)
        }
        .background(Palette.sidebar)
    }
}

/// 一行的内容：图标（中性灰）+ 单行名称，过长截断；悬停显示完整信息。
private struct SidebarRow: View {
    let title: String
    let symbol: String
    var help: String?

    var body: some View {
        Label {
            Text(title).lineLimit(1).truncationMode(.tail)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Palette.icon)
        }
        .help(help ?? title)
    }
}

/// 删除库里的东西前的确认（⌫ 和菜单都经过这里）。
private struct DeleteRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var delete: () -> Void
}

private extension View {
    func deleteConfirmation(_ request: Binding<DeleteRequest?>) -> some View {
        confirmationDialog(
            request.wrappedValue?.title ?? "", isPresented: Binding(get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
            titleVisibility: .visible, presenting: request.wrappedValue
        ) { request in
            Button("删除", role: .destructive) { request.delete() }
            Button("取消", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }
}

// MARK: - 预设

private struct PresetList: View {
    @Bindable var workbench: Workbench
    @State private var renaming: RenameRequest?
    @State private var deleting: DeleteRequest?
    @State private var importing = false

    private let groups: [CatalogPresetOrigin] = [.builtIn, .user, .imported]

    @State private var collapsed: Set<String> = []

    /// 树形列表，三角常驻（参照 Compressor 左栏）：内置 ▸ 平台 ▸ 预设；用户保存、导入各一组。
    var body: some View {
        List(selection: $workbench.selectedPresetId) {
            ForEach(groups, id: \.kind) { group in
                DisclosureGroup(isExpanded: expanded(group.kind)) {
                    if group == .builtIn {
                        ForEach(platforms, id: \.name) { platform in
                            DisclosureGroup(isExpanded: expanded("platform-\(platform.name)")) {
                                rows(platform.presets, group: group)
                            } label: {
                                // 与下面的预设图标同一种中性灰。
                                SidebarRow(title: platform.name, symbol: "rectangle.stack").fontWeight(.medium)
                            }
                        }
                    } else {
                        rows(workbench.presets(in: group), group: group)
                    }
                } label: {
                    Text(group.groupTitle).fontWeight(.semibold)
                }
                .dropDestination(for: String.self) { items, _ in
                    move(items, to: group)
                    return group != .builtIn
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { if let preset = selectedPreset, !preset.readOnly { confirmDelete(preset) } }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .renameAlert($renaming)
        .deleteConfirmation($deleting)
        .fileImporter(isPresented: $importing, allowedContentTypes: [FileTypes.preset], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { Task { await workbench.importPresets(urls) } }
        }
    }

    private var selectedPreset: CatalogPresetSummary? { workbench.selectedPresetId.flatMap(workbench.preset) }

    @ViewBuilder private func rows(_ presets: [CatalogPresetSummary], group: CatalogPresetOrigin) -> some View {
        ForEach(presets, id: \.presetId) { preset in
            PresetRow(preset: preset, isModified: workbench.hasUnsavedEdits(preset.presetId))
                .tag(preset.presetId)
                .draggable(DragPayload.preset(preset.presetId).string)
                .contextMenu { menu(for: preset) }
                // 再点仍然选中的预设时右栏也切回它（选择没变，不会通知）。
                .onRowClick { workbench.focusPreset() }
        }
    }

    /// 内置预设按平台分组，保持原来的顺序。
    private var platforms: [(name: String, presets: [CatalogPresetSummary])] {
        var result: [(name: String, presets: [CatalogPresetSummary])] = []
        for preset in workbench.presets(in: .builtIn) {
            let name = preset.platformName ?? preset.platform ?? "其他"
            if let i = result.firstIndex(where: { $0.name == name }) {
                result[i].presets.append(preset)
            } else {
                result.append((name, [preset]))
            }
        }
        return result
    }

    private func expanded(_ kind: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(kind) }, set: { if $0 { collapsed.remove(kind) } else { collapsed.insert(kind) } })
    }

    private var footer: some View {
        ColumnFooter {
            Menu {
                Button("新建预设") { Task { await workbench.newPreset() } }
                Button("导入…") { importing = true }
            } label: {
                Image(systemName: "plus")
            }
            .help("新建或导入预设")
            .accessibilityLabel("新建或导入预设")
            Menu {
                if let preset = selectedPreset { menu(for: preset) }
            } label: {
                Image(systemName: "gearshape")
            }
            .disabled(selectedPreset == nil)
            .help("选中预设的操作")
            .accessibilityLabel("选中预设的操作")
        }
    }

    @ViewBuilder private func menu(for preset: CatalogPresetSummary) -> some View {
        Button("复制") { Task { await workbench.duplicatePreset(preset.presetId) } }
        Button("导出…") { export(preset) }
        if !preset.readOnly {
            Button("重命名…") {
                renaming = RenameRequest(title: "重命名预设", name: preset.name) { name in
                    Task { await workbench.renamePreset(preset.presetId, to: name) }
                }
            }
            if preset.origin == .user {
                Button("移到「导入」") { Task { await workbench.movePreset(preset.presetId, to: .imported) } }
            } else {
                Button("移到「用户保存」") { Task { await workbench.movePreset(preset.presetId, to: .user) } }
            }
            Divider()
            Button("删除…", role: .destructive) { confirmDelete(preset) }
        }
    }

    private func confirmDelete(_ preset: CatalogPresetSummary) {
        deleting = DeleteRequest(title: "删除预设「\(preset.name)」？", message: "预设会从库里删除，不能撤销。") {
            Task { await workbench.deletePreset(preset.presetId) }
        }
    }

    /// 导出为 `.photoframe`：与其他文件面板一样从窗口里滑出。
    private func export(_ preset: CatalogPresetSummary) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [FileTypes.preset]
        panel.nameFieldStringValue = PresetLibrary.suggestedFileName(for: preset.name)
        let save = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            Task { await workbench.exportPreset(preset.presetId, to: url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }

    /// 在「用户保存」和「导入」之间拖动（D-81）。
    private func move(_ items: [String], to group: CatalogPresetOrigin) {
        let target: PresetOrigin? = switch group {
        case .user: .user
        case .imported: .imported
        default: nil
        }
        guard let target, case .preset(let id)? = items.first.flatMap(DragPayload.init(string:)) else { return }
        Task { await workbench.movePreset(id, to: target) }
    }
}

/// 一行一个预设：小图标 + 名称；尺寸等信息放在悬停提示里，行高与 Compressor 一样紧凑。
private struct PresetRow: View {
    let preset: CatalogPresetSummary
    /// 有还没存储的修改（与任务行的「已修改」同一种写法）。
    var isModified = false

    var body: some View {
        HStack(spacing: 4) {
            SidebarRow(title: preset.name, symbol: preset.panorama == nil ? "rectangle.portrait" : "rectangle.split.3x1",
                       help: "\(preset.name)\n\(detail)")
            if isModified { Text("已修改").font(.subheadline).foregroundStyle(.secondary).fixedSize() }
        }
    }

    private var detail: String {
        var parts = [preset.canvas.text]
        if preset.panorama != nil { parts.append("全景") }
        if let platform = preset.platformName { parts.insert(platform, at: 0) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 位置

private struct LocationList: View {
    @Bindable var workbench: Workbench
    @State private var renaming: RenameRequest?
    @State private var adding = false

    var body: some View {
        List(selection: $workbench.selectedLocationId) {
            ForEach(workbench.locations.locations) { location in
                HStack {
                    SidebarRow(title: location.name, symbol: "folder", help: "\(location.name)\n\(location.url.displayPath)")
                    Spacer()
                    if isDefault(location) { Badge(text: "默认").help("新任务默认导出到这里") }
                }
                .tag(location.id)
                .draggable(DragPayload.location(location.id).string)
                .contextMenu { menu(for: location) }
                .onRowClick { workbench.focusLocation() }
            }
        }
        .listStyle(.sidebar)
        // 只移除快捷方式，不动文件夹，不用确认。
        .onDeleteCommand { if let id = workbench.selectedLocationId { workbench.removeLocation(id) } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ColumnFooter {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .help("添加位置")
                    .accessibilityLabel("添加位置")
                Menu {
                    if let location = selected { menu(for: location) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .disabled(selected == nil)
                .help("选中位置的操作")
                .accessibilityLabel("选中位置的操作")
            }
        }
        .renameAlert($renaming)
        .fileImporter(isPresented: $adding, allowedContentTypes: [.folder]) {
            if case .success(let url) = $0 { workbench.addLocation(url) }
        }
    }

    private var selected: ExportLocation? { workbench.selectedLocationId.flatMap(workbench.location) }

    private func isDefault(_ location: ExportLocation) -> Bool { location.id == workbench.locations.defaultLocation?.id }

    /// 与右栏的按钮同样的可用规则：已经是默认位置时「设为默认位置」不可用。
    @ViewBuilder private func menu(for location: ExportLocation) -> some View {
        Button("设为默认位置") { workbench.setDefaultLocation(location.id) }
            .disabled(isDefault(location))
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([location.url]) }
        Button("重命名…") {
            renaming = RenameRequest(title: "重命名位置", name: location.name) { workbench.renameLocation(location.id, to: $0) }
        }
        Divider()
        // 只从列表里拿掉这个快捷方式，不删文件夹。
        Button("移除", role: .destructive) { workbench.removeLocation(location.id) }
    }
}

// MARK: - 素材

private struct AssetList: View {
    @Bindable var workbench: Workbench
    @State private var renaming: RenameRequest?
    @State private var deleting: DeleteRequest?
    @State private var importCategory: AssetCategory?
    @State private var importing = false
    @State private var collapsed: Set<AssetCategory> = []
    @State private var selectedId: UUID?

    private func expanded(_ category: AssetCategory) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(category) }, set: { if $0 { collapsed.remove(category) } else { collapsed.insert(category) } })
    }

    var body: some View {
        List(selection: $selectedId) {
            ForEach(AssetCategory.allCases, id: \.self) { category in
                DisclosureGroup(isExpanded: expanded(category)) {
                    let assets = workbench.assets(in: category)
                    if workbench.assetDisplay == .icons {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 8) {
                            ForEach(assets) { asset in
                                AssetTile(workbench: workbench, asset: asset, isSelected: selectedId == asset.assetId)
                                    .onTapGesture { selectedId = asset.assetId }
                                    .contextMenu { menu(for: asset) }
                            }
                        }
                    } else {
                        ForEach(assets) { asset in
                            SidebarRow(title: asset.displayName, symbol: asset.format == .svg ? "scribble" : "photo", help: help(asset))
                                .tag(asset.assetId)
                                .draggable(DragPayload.asset(asset.assetId).string)
                                .contextMenu { menu(for: asset) }
                        }
                    }
                } label: {
                    Text(category.title).fontWeight(.semibold)
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { if let asset = selected { confirmDelete(asset) } }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .renameAlert($renaming)
        .deleteConfirmation($deleting)
        // 面板关闭时 SwiftUI 先把 isPresented 置为 false 再回调，所以分类单独记住，不能跟着清掉。
        .fileImporter(isPresented: $importing, allowedContentTypes: FileTypes.assets, allowsMultipleSelection: true) { result in
            guard let category = importCategory, case .success(let urls) = result else { return }
            Task { await workbench.importAssets(urls, category: category) }
        }
    }

    private var selected: AssetInfo? { selectedId.flatMap { id in workbench.assets.first { $0.assetId == id } } }

    private func help(_ asset: AssetInfo) -> String {
        "\(asset.displayName)\n\(asset.format.rawValue.uppercased()) · \(asset.category.title)"
    }

    private var footer: some View {
        ColumnFooter {
            Menu {
                ForEach(AssetCategory.allCases, id: \.self) { category in
                    Button("导入\(category.title)…") {
                        importCategory = category
                        importing = true
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .help("导入素材（PNG 或受限 SVG）")
            .accessibilityLabel("导入素材")
            Menu {
                if let asset = selected { menu(for: asset) }
            } label: {
                Image(systemName: "gearshape")
            }
            .disabled(selected == nil)
            .help("选中素材的操作")
            .accessibilityLabel("选中素材的操作")
            Spacer()
            Picker("显示方式", selection: $workbench.assetDisplay) {
                Label("仅文字", systemImage: "list.bullet").labelStyle(.iconOnly).tag(AssetDisplayMode.text)
                Label("图标预览", systemImage: "square.grid.2x2").labelStyle(.iconOnly).tag(AssetDisplayMode.icons)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("显示方式：仅文字 / 图标预览")
        }
    }

    @ViewBuilder private func menu(for asset: AssetInfo) -> some View {
        Button("重命名…") {
            renaming = RenameRequest(title: "重命名素材", name: asset.displayName) { name in
                Task { await workbench.renameAsset(asset.assetId, to: name) }
            }
        }
        // 与预设的「移到「导入」」同一种写法。
        ForEach(AssetCategory.allCases.filter { $0 != asset.category }, id: \.self) { category in
            Button("移到「\(category.title)」") { Task { await workbench.setAssetCategory(asset.assetId, to: category) } }
        }
        Divider()
        Button("删除…", role: .destructive) { confirmDelete(asset) }
    }

    private func confirmDelete(_ asset: AssetInfo) {
        deleting = DeleteRequest(title: "删除素材「\(asset.displayName)」？", message: "素材会从库里删除，不能撤销。指向它的绑定会回退到下一级。") {
            Task { await workbench.deleteAsset(asset.assetId) }
        }
    }
}

/// 图标预览方式下的一个素材。图片在后台读取、按需缩小，按 assetId 缓存（同一个 ID 的素材内容不会变）。
private struct AssetTile: View {
    let workbench: Workbench
    let asset: AssetInfo
    var isSelected = false
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(Palette.icon)
                }
            }
            .frame(width: 64, height: 48)
            Text(asset.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(4)
        .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.3)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .help("\(asset.displayName)\n\(asset.format.rawValue.uppercased()) · \(asset.category.title)")
        .draggable(DragPayload.asset(asset.assetId).string)
        .task(id: asset.assetId) {
            let key = asset.assetId.uuidString as NSString
            if let cached = Self.cache.object(forKey: key) {
                image = cached
                return
            }
            guard let url = await workbench.assetContentURL(asset.assetId) else {
                image = nil
                return
            }
            let isVector = asset.format == .svg
            let loaded = await Task.detached(priority: .utility) { Self.load(url, isVector: isVector) }.value
            if let loaded, !Task.isCancelled { Self.cache.setObject(loaded, forKey: key) }
            image = loaded
        }
    }

    /// 在后台读取。PNG 按 144 px 缩小解码（方块只有 64 × 48 pt，不用解码整张大图）；SVG 是矢量，交给 NSImage。
    private nonisolated static func load(_ url: URL, isVector: Bool) -> NSImage? {
        if isVector { return NSImage(contentsOf: url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 144,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}
