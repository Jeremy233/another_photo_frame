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
                InspectorRow {
                    Menu("添加装饰") {
                        ForEach(LayerTemplate.allCases) { template in
                            Button(template.title) { workbench.addLayer(template) }
                        }
                    }
                    .fixedSize()
                }
            }
        } else {
            // 与内置预设只读的说明同一种样式。
            NoticeBar(symbol: "square.stack", text: "多个任务的装饰不能批量修改，请只选一个任务")
        }
    }
}

private struct LayerSection: View {
    let workbench: Workbench
    let layer: OverlayLayer

    var body: some View {
        // 标题用添加时选的名字（「水印」「签名 2」），不显示 layerId。
        InspectorSection(workbench.editedPreset?.title(ofLayer: layer.layerId) ?? layer.type.title, key: "layer.\(layer.type)") {
            Toggle("启用", isOn: workbench.layerBinding(layer.layerId, \.enabled, default: true))
            if let slotId = layer.slotId, layer.type.usesAssetSlot {
                SlotBindingRow(workbench: workbench, slotId: slotId)
            }
            if layer.type == .text {
                InspectorTextField("文字", text: text(\.content))
            } else if layer.type == .metadataText {
                InspectorTextField("模板", text: text(\.template))
            }
            if layer.type.usesText {
                TextStyleRows(workbench: workbench, layer: layer)
            }
            // 「位置」专指输出位置，图层贴在哪个角叫「锚点」。
            InspectorPicker("锚点", selection: workbench.layerBinding(layer.layerId, \.anchor, default: .bottomRight)) {
                ForEach(OverlayAnchor.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            InspectorPicker("参照", selection: workbench.layerBinding(layer.layerId, \.reference, default: .default)) {
                Text("照片外侧").tag(OverlayReference.photo(.outside))
                Text("照片内侧").tag(OverlayReference.photo(.inside))
                Text("画布").tag(OverlayReference.canvas)
            }
            IntField(title: "水平偏移", value: optional(\.offset.x))
            IntField(title: "垂直偏移", value: optional(\.offset.y))
            LabeledContent("不透明度") {
                SliderWithValue(workbench: workbench, value: workbench.layerBinding(layer.layerId, \.opacity, default: 1), range: 0...1,
                                text: "\(Int((layer.opacity * 100).rounded()))%")
            }
            VisibilityPicker(workbench: workbench, layer: layer)
            InspectorRow { DestructiveButton(title: "删除装饰") { workbench.removeLayer(layer.layerId) } }
        }
        if layer.type.usesAssetSlot {
            CameraMatchSection(workbench: workbench, layer: layer)
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

/// 文字样式（D-111）：字体、字重、斜体、字号、字间距、颜色。
private struct TextStyleRows: View {
    let workbench: Workbench
    let layer: OverlayLayer

    var body: some View {
        InspectorTextField("字体", text: Binding(get: { style.fontFamily ?? "" }, set: { v in update { $0.fontFamily = v.isEmpty ? nil : v } }),
                           prompt: "系统字体")
        InspectorPicker("字重", selection: Binding(get: { style.fontWeight }, set: { v in update { $0.fontWeight = v } })) {
            ForEach(TextStyle.FontWeight.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Toggle("斜体", isOn: Binding(get: { style.italic }, set: { v in update { $0.italic = v } }))
        NumberField(title: "字号", value: Binding(get: { style.fontSizePx }, set: { v in update { $0.fontSizePx = v } }))
        NumberField(title: "字间距", value: Binding(get: { style.letterSpacingPx }, set: { v in update { $0.letterSpacingPx = v } }))
        ColorField(title: "颜色", value: Binding(get: { style.color }, set: { v in if let v { update { $0.color = v } } }))
    }

    private var style: TextStyle { layer.text ?? TextStyle() }

    private func update(_ body: (inout TextStyle) -> Void) {
        workbench.updateLayer(layer.layerId) { l in
            var s = l.text ?? TextStyle()
            body(&s)
            l.text = s
        }
    }
}

/// 小数输入框（px）。
private struct NumberField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: $value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                Text("px").foregroundStyle(.secondary)
            }
        }
    }
}

/// 按相机自动选素材（D-111）：每条规则「品牌 / 型号 → 自己的素材槽」，匹配不到时用上面的默认素材。
private struct CameraMatchSection: View {
    let workbench: Workbench
    let layer: OverlayLayer

    var body: some View {
        InspectorSection("按相机选素材", key: "cameraMatch") {
            ForEach(Array(layer.cameraMatch.enumerated()), id: \.offset) { index, rule in
                InspectorTextField("品牌", text: field(index, \.make), prompt: "例如 FUJIFILM")
                InspectorTextField("型号", text: field(index, \.model), prompt: "留空表示该品牌所有型号")
                SlotBindingRow(workbench: workbench, slotId: rule.slotId)
                InspectorRow { DestructiveButton(title: "删除规则") { workbench.removeCameraRule(layer.layerId, at: index) } }
                Hairline().padding(.vertical, 4)
            }
            InspectorRow { Button("添加相机规则") { workbench.addCameraRule(layer.layerId) } }
            InspectorRow {
                Text("写了型号的规则优先，其次是只写品牌的；都匹配不到或没有素材时用默认素材")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ index: Int, _ path: WritableKeyPath<CameraMatchRule, String?>) -> Binding<String> {
        Binding(
            get: { layer.cameraMatch.indices.contains(index) ? layer.cameraMatch[index][keyPath: path] ?? "" : "" },
            set: { value in workbench.updateLayer(layer.layerId) { l in
                guard l.cameraMatch.indices.contains(index) else { return }
                l.cameraMatch[index][keyPath: path] = value.isEmpty ? nil : value
            } })
    }
}

/// 显示在哪些页：仅封面（默认）、所有页、指定页（D-27：0 = 封面）。
private struct VisibilityPicker: View {
    let workbench: Workbench
    let layer: OverlayLayer

    var body: some View {
        InspectorPicker("显示在", selection: kind) {
            Text("仅封面").tag(0)
            Text("所有页").tag(1)
            Text("指定页").tag(2)
        }
        if case .selectedSlides(let set) = layer.visibility {
            // 回车或离开输入框时才解析写回：逐字输入「0, 2」时逗号和空格不会被吞掉。
            LabeledContent("页码") {
                CommitTextField(title: "页码", text: SlidePages.text(set), prompt: "0 = 封面，例如 0, 2, 3") { text in
                    workbench.updateLayer(layer.layerId) { $0.visibility = .selectedSlides(SlidePages.parse(text)) }
                }
                .labelsHidden()
            }
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

}

/// 素材槽：把左栏的素材拖到这里完成绑定（UI 设计文档第 7.3 节），也可以从菜单选。
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
            // 与同一分节的弹出菜单一样宽（见 `InspectorPicker`）。
            .buttonSizing(.flexible)
            .frame(maxWidth: InspectorMetrics.controlWidth, alignment: .leading)
        }
        // 拖放高亮框画在行外侧，不改变行高和对齐；圆角与所在的分组框一致。
        .overlay {
            RoundedRectangle(cornerRadius: GroupStyle.cornerRadius).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2).padding(-4)
        }
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
        // 与 CLI、警告同一套叫法（D-14）。
        let level = switch binding.level {
        case .job: "单任务"
        case .preset: "预设本地"
        case .userDefault: "用户默认"
        }
        return "\(name)（\(level)）"
    }

    private func bind(_ id: UUID?) {
        Task { await workbench.bindAsset(id, slotId: slotId) }
    }
}

// MARK: - 源图信息（第 6 节：选中源图时不显示四个标签）

struct SourceInspector<AfterCard: View>: View {
    let workbench: Workbench
    let item: SourceItem
    /// 放在信息卡和分节之间（「警告」、提示条）。
    @ViewBuilder var afterCard: AfterCard

    var body: some View {
        InfoCard(symbol: "photo", title: item.source.displayName, lines: summary, badge: badge,
                 badgeHelp: item.dynamicRange == .taggedWithoutHighlights ? "源图标为 HDR，但没有超出 SDR 的高光，按 SDR 导出" : nil) { EmptyView() }
        // 「警告」里有源图检查的提示和读不出来时的错误（与任务的警告同一种列表）。
        afterCard
        if let info = item.inspection {
            InspectorSection("图像") {
                LabeledContent("尺寸") { Text(info.displaySize.text) }
                LabeledContent("位深") { Text("\(info.bitDepth) bit\(info.isFloat ? " 浮点" : "")") }
                LabeledContent("方向") { Text(info.orientationTitle) }
            }
            InspectorSection("色彩") {
                LabeledContent("ICC") { Text(ColorProfileName.display(info.colorProfile.description)).help(info.colorProfile.description) }
                if !info.colorProfile.embedded {
                    InspectorPicker("按此解释", selection: override) {
                        Text("\(SourceColorOverride.sRGB.title)（默认）").tag(SourceColorOverride?.none)
                        ForEach(SourceColorOverride.allCases.filter { $0 != .sRGB }, id: \.self) {
                            Text($0.title).tag(SourceColorOverride?.some($0))
                        }
                    }
                    InspectorRow { Text("没有 ICC 的源图默认按 sRGB 解释").font(.callout).foregroundStyle(.secondary) }
                }
                LabeledContent("HDR") { Text(hdr(info.hdr)) }
            }
            if !info.metadata.isEmpty || info.hasGPS || info.hasAuthorOrCopyright {
                InspectorSection("EXIF") {
                    // 中文名、固定顺序；悬停看图层文字模板里对应的占位符。
                    ForEach(ExifLabels.rows(info.metadata), id: \.key) { row in
                        LabeledContent(row.title) { Text(row.value).lineLimit(1).truncationMode(.middle) }
                            .help("EXIF 文字模板里写 {\(row.key)}")
                    }
                    if info.hasGPS { LabeledContent("GPS") { Text("有（默认不写出）") } }
                    if info.hasAuthorOrCopyright { LabeledContent("作者和版权") { Text("有（默认不写出）") } }
                }
            }
        } else if item.inspectionError == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    private var summary: [String] {
        var lines = [item.source.fileURL.deletingLastPathComponent().displayPath]
        if let info = item.inspection {
            let size = info.fileSizeBytes.map { "，" + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            lines.append("\(info.format.uppercased())\(size)")
            lines.append("\(info.displaySize.text)，\(ColorProfileName.display(info.colorProfile.description))")
        }
        return lines
    }

    /// 标为 HDR 但没有超出 SDR 的高光的源图按 SDR 导出，标 SDR（悬停说明原因）。
    private var badge: String? {
        item.dynamicRange.map { $0 == .hdr ? "HDR" : "SDR" }
    }

    private var override: Binding<SourceColorOverride?> {
        Binding(get: { item.colorOverride }, set: { workbench.setColorOverride($0, for: item.id) })
    }

    private func hdr(_ hdr: SourceInspection.HDR) -> String {
        switch SourceDynamicRange(hdr) {
        case .sdr: return "否"
        case .taggedWithoutHighlights: return "标为 HDR，但没有超出 SDR 的高光"
        case .hdr:
            let headroom = hdr.headroom.map { String(format: "，余量 %.1f×", $0) } ?? ""
            return "是（\(hdr.kindTitle)\(headroom)）"
        }
    }
}
