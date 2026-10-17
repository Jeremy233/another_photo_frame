import AppKit
import PhotoFrameApplication
import PhotoFrameMacModel
import PhotoFrameStorage
import SwiftUI

/// 左栏：预设 | 位置 | 素材（UI 设计文档第 4、7 节）。
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
                // 与预览标题栏的「成品 | 原图」同为小号。
                .controlSize(.small)
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

// MARK: - 预设

private struct PresetList: View {
    @Bindable var workbench: Workbench
    @State private var renaming: RenameRequest?
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
                                Label(platform.name, systemImage: "rectangle.stack").fontWeight(.medium)
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
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .renameAlert($renaming)
        .fileImporter(isPresented: $importing, allowedContentTypes: [FileTypes.preset], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { Task { await workbench.importPresets(urls) } }
        }
    }

    @ViewBuilder private func rows(_ presets: [CatalogPresetSummary], group: CatalogPresetOrigin) -> some View {
        ForEach(presets, id: \.presetId) { preset in
            PresetRow(preset: preset)
                .tag(preset.presetId)
                .draggable(DragPayload.preset(preset.presetId).string)
                .contextMenu { menu(for: preset) }
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
            if let id = workbench.selectedPresetId, let preset = workbench.preset(id) {
                Menu {
                    menu(for: preset)
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("选中预设的操作")
            }
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
            Button("删除", role: .destructive) { Task { await workbench.deletePreset(preset.presetId) } }
        }
    }

    private func export(_ preset: CatalogPresetSummary) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [FileTypes.preset]
        panel.nameFieldStringValue = PresetLibrary.suggestedFileName(for: preset.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await workbench.exportPreset(preset.presetId, to: url) }
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

    var body: some View {
        Label {
            Text(preset.name).lineLimit(1).truncationMode(.tail)
        } icon: {
            Image(systemName: preset.panorama == nil ? "rectangle.portrait" : "rectangle.split.3x1")
                .foregroundStyle(.secondary)
        }
        .help("\(preset.name)\n\(detail)")
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
                    Label(location.name, systemImage: "folder")
                        .help(location.url.displayPath)
                    Spacer()
                    if location.id == workbench.locations.defaultLocation?.id {
                        Text("默认").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(location.id)
                .draggable(DragPayload.location(location.id).string)
                .contextMenu {
                    Button("设为默认位置") { workbench.setDefaultLocation(location.id) }
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([location.url]) }
                    Button("重命名…") {
                        renaming = RenameRequest(title: "重命名位置", name: location.name) { workbench.renameLocation(location.id, to: $0) }
                    }
                    Divider()
                    Button("删除", role: .destructive) { workbench.removeLocation(location.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ColumnFooter {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .help("添加位置")
            }
        }
        .renameAlert($renaming)
        .fileImporter(isPresented: $adding, allowedContentTypes: [.folder]) {
            if case .success(let url) = $0 { workbench.addLocation(url) }
        }
    }
}

// MARK: - 素材

private struct AssetList: View {
    @Bindable var workbench: Workbench
    @State private var renaming: RenameRequest?
    @State private var importCategory: AssetCategory?
    @State private var importing = false
    @State private var collapsed: Set<AssetCategory> = []

    private func expanded(_ category: AssetCategory) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(category) }, set: { if $0 { collapsed.remove(category) } else { collapsed.insert(category) } })
    }

    var body: some View {
        List {
            ForEach(AssetCategory.allCases, id: \.self) { category in
                DisclosureGroup(isExpanded: expanded(category)) {
                    let assets = workbench.assets(in: category)
                    if workbench.assetDisplay == .icons {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 8) {
                            ForEach(assets) { asset in
                                AssetTile(workbench: workbench, asset: asset)
                                    .contextMenu { menu(for: asset) }
                            }
                        }
                    } else {
                        ForEach(assets) { asset in
                            Label(asset.displayName, systemImage: asset.format == .svg ? "scribble" : "photo")
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
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .renameAlert($renaming)
        // 面板关闭时 SwiftUI 先把 isPresented 置为 false 再回调，所以分类单独记住，不能跟着清掉。
        .fileImporter(isPresented: $importing, allowedContentTypes: FileTypes.assets, allowsMultipleSelection: true) { result in
            guard let category = importCategory, case .success(let urls) = result else { return }
            Task { await workbench.importAssets(urls, category: category) }
        }
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
            Spacer()
            Picker("显示方式", selection: $workbench.assetDisplay) {
                Image(systemName: "list.bullet").tag(AssetDisplayMode.text)
                Image(systemName: "square.grid.2x2").tag(AssetDisplayMode.icons)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder private func menu(for asset: AssetInfo) -> some View {
        Button("重命名…") {
            renaming = RenameRequest(title: "重命名素材", name: asset.displayName) { name in
                Task { await workbench.renameAsset(asset.assetId, to: name) }
            }
        }
        Menu("移到分组") {
            ForEach(AssetCategory.allCases.filter { $0 != asset.category }, id: \.self) { category in
                Button(category.title) { Task { await workbench.setAssetCategory(asset.assetId, to: category) } }
            }
        }
        Divider()
        Button("删除", role: .destructive) { Task { await workbench.deleteAsset(asset.assetId) } }
    }
}

/// 图标预览方式下的一个素材。
private struct AssetTile: View {
    let workbench: Workbench
    let asset: AssetInfo
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 64, height: 48)
            Text(asset.displayName)
                .font(.caption)
                .lineLimit(1)
        }
        .draggable(DragPayload.asset(asset.assetId).string)
        .task(id: asset.assetId) {
            image = await workbench.assetContentURL(asset.assetId).flatMap(NSImage.init(contentsOf:))
        }
    }
}
