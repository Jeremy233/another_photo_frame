import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameMacModel
import PhotoFrameRendering
import SwiftUI

// MARK: - 图层（UI 设计文档第 8.3 节）

struct LayersTab: View {
    let workbench: Workbench

    var body: some View {
        if let preset = workbench.editedPreset {
            ForEach(preset.layers.sorted { $0.zIndex < $1.zIndex }, id: \.layerId) { layer in
                LayerSection(workbench: workbench, layer: layer)
            }
            InspectorSection {
                Menu("添加图层") {
                    ForEach(LayerTemplate.allCases) { template in
                        Button(template.title) { workbench.addLayer(template) }
                    }
                }
            }
        } else {
            InspectorSection { Text("多个任务的图层不能批量修改，请只选一个任务。").foregroundStyle(.secondary) }
        }
    }
}

private struct LayerSection: View {
    let workbench: Workbench
    let layer: OverlayLayer

    var body: some View {
        InspectorSection("\(layer.type.title) · \(layer.layerId)") {
            Toggle("启用", isOn: workbench.layerBinding(layer.layerId, \.enabled, default: true))
            if let slotId = layer.slotId, layer.type.usesAssetSlot {
                SlotBindingRow(workbench: workbench, slotId: slotId)
            }
            if layer.type == .text {
                TextField("文字", text: text(\.content))
            } else if layer.type == .metadataText {
                TextField("模板", text: text(\.template))
            }
            Picker("位置", selection: workbench.layerBinding(layer.layerId, \.anchor, default: .bottomRight)) {
                ForEach(OverlayAnchor.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("参照", selection: workbench.layerBinding(layer.layerId, \.reference, default: .default)) {
                Text("照片外侧").tag(OverlayReference.photo(.outside))
                Text("照片内侧").tag(OverlayReference.photo(.inside))
                Text("画布").tag(OverlayReference.canvas)
            }
            IntField(title: "水平偏移", value: optional(\.offset.x))
            IntField(title: "垂直偏移", value: optional(\.offset.y))
            LabeledContent("不透明度") {
                Slider(value: workbench.layerBinding(layer.layerId, \.opacity, default: 1), in: 0...1)
            }
            VisibilityPicker(workbench: workbench, layer: layer)
            Button("删除图层", role: .destructive) { workbench.removeLayer(layer.layerId) }
        }
    }

    private func optional(_ path: WritableKeyPath<OverlayLayer, Int>) -> Binding<Int?> {
        let b = workbench.layerBinding(layer.layerId, path, default: 0)
        return Binding(get: { b.wrappedValue }, set: { if let v = $0 { b.wrappedValue = v } })
    }

    private func text(_ path: WritableKeyPath<TextStyle, String?>) -> Binding<String> {
        Binding(
            get: { layer.text?[keyPath: path] ?? "" },
            set: { value in workbench.updateLayer(layer.layerId) { l in
                var style = l.text ?? TextStyle()
                style[keyPath: path] = value
                l.text = style
            } })
    }
}

/// 显示在哪些页：仅封面（默认）、所有页、指定页（D-27：0 = 封面）。
private struct VisibilityPicker: View {
    let workbench: Workbench
    let layer: OverlayLayer

    var body: some View {
        Picker("显示在", selection: kind) {
            Text("仅封面").tag(0)
            Text("所有页").tag(1)
            Text("指定页").tag(2)
        }
        if case .selectedSlides = layer.visibility {
            TextField("页码", text: pages, prompt: Text("0 = 封面，例如 0, 2, 3"))
        }
    }

    private var kind: Binding<Int> {
        Binding(
            get: {
                switch layer.visibility {
                case .coverOnly: 0
                case .allSlides: 1
                case .selectedSlides: 2
                }
            },
            set: { k in workbench.updateLayer(layer.layerId) { $0.visibility = k == 0 ? .coverOnly : k == 1 ? .allSlides : .selectedSlides([0]) } })
    }

    private var pages: Binding<String> {
        Binding(
            get: {
                guard case .selectedSlides(let set) = layer.visibility else { return "" }
                return set.sorted().map(String.init).joined(separator: ", ")
            },
            set: { text in
                let numbers = Set(text.split { !$0.isNumber }.compactMap { Int($0) })
                workbench.updateLayer(layer.layerId) { $0.visibility = .selectedSlides(numbers) }
            })
    }
}

/// 素材占位符：把左栏的素材拖到这里完成绑定（UI 设计文档第 7.3 节），也可以从菜单选。
private struct SlotBindingRow: View {
    let workbench: Workbench
    let slotId: String
    @State private var targeted = false

    var body: some View {
        LabeledContent("素材") {
            Menu(label) {
                ForEach(workbench.assets) { asset in
                    Button(asset.displayName) { bind(asset.assetId) }
                }
                Divider()
                Button("清除绑定") { bind(nil) }
            }
            .fixedSize()
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2))
        .dropDestination(for: String.self) { items, _ in
            guard case .asset(let id)? = items.first.flatMap(DragPayload.init(string:)) else { return false }
            bind(id)
            return true
        } isTargeted: { targeted = $0 }
        .help("把左栏「素材」里的素材拖到这里")
    }

    private var label: String {
        guard let binding = workbench.binding(for: slotId) else { return "未绑定" }
        let name = workbench.assets.first { $0.assetId == binding.assetId }?.displayName ?? "已删除的素材"
        let level = switch binding.level {
        case .job: "本任务"
        case .preset: "预设"
        case .userDefault: "默认"
        }
        return "\(name)（\(level)）"
    }

    private func bind(_ id: UUID?) {
        Task { await workbench.bindAsset(id, slotId: slotId) }
    }
}

// MARK: - 源图信息（第 6 节：选中源图时不显示四个标签）

struct SourceInspector: View {
    let workbench: Workbench
    let item: SourceItem

    var body: some View {
        InfoCard(symbol: "photo", title: item.source.displayName, lines: summary, badge: badge) { EmptyView() }
        if let info = item.inspection {
            InspectorSection("图像") {
                LabeledContent("尺寸") { Text(info.displaySize.text) }
                LabeledContent("位深") { Text("\(info.bitDepth) bit\(info.isFloat ? " 浮点" : "")") }
                LabeledContent("方向") { Text("\(info.orientation)") }
            }
            InspectorSection("色彩") {
                LabeledContent("ICC") { Text(info.colorProfile.description) }
                if !info.colorProfile.embedded {
                    Picker("按此解释", selection: override) {
                        Text("sRGB（默认）").tag(SourceColorOverride?.none)
                        ForEach(SourceColorOverride.allCases.filter { $0 != .sRGB }, id: \.self) {
                            Text($0.title).tag(SourceColorOverride?.some($0))
                        }
                    }
                    Text("源图没有 ICC，默认按 sRGB 解释").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("HDR") { Text(hdr(info.hdr)) }
            }
            if !info.metadata.isEmpty || info.hasGPS || info.hasAuthorOrCopyright {
                InspectorSection("EXIF") {
                    ForEach(info.metadata.sorted { $0.key < $1.key }, id: \.key) { entry in LabeledContent(entry.key) { Text(entry.value) } }
                    if info.hasGPS { LabeledContent("GPS") { Text("有（默认不写出）") } }
                    if info.hasAuthorOrCopyright { LabeledContent("作者 / 版权") { Text("有（默认不写出）") } }
                }
            }
            if !info.warnings.isEmpty {
                InspectorSection("提示") {
                    ForEach(info.warnings, id: \.self) { Text($0.message).foregroundStyle(.orange) }
                }
            }
        } else if let error = item.inspectionError {
            InspectorSection { Text(error.message).foregroundStyle(.red) }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private var summary: [String] {
        var lines = [item.source.fileURL.deletingLastPathComponent().displayPath]
        if let info = item.inspection {
            let size = info.fileSizeBytes.map { "，" + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            lines.append("\(info.format.uppercased())\(size)")
            lines.append("\(info.displaySize.text)，\(info.colorProfile.description)")
        }
        return lines
    }

    private var badge: String? {
        item.inspection.map { $0.hdr.kind == "none" ? "SDR" : "HDR" }
    }

    private var override: Binding<SourceColorOverride?> {
        Binding(get: { item.colorOverride }, set: { workbench.setColorOverride($0, for: item.id) })
    }

    private func hdr(_ hdr: SourceInspection.HDR) -> String {
        guard hdr.kind != "none" else { return "否" }
        let headroom = hdr.headroom.map { String(format: "，余量 %.1f×", $0) } ?? ""
        return "是（\(hdr.kind)\(headroom)）"
    }
}
