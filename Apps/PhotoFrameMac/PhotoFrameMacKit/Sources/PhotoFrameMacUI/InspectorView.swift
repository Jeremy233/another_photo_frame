import AppKit
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameMacModel
import SwiftUI

/// 右栏（UI 设计文档第 6、8 节）。布局参照 Compressor 的 Inspector：顶部一行标签或标题，
/// 下面是信息卡和分节的圆角分组框，表单是右对齐标签 + 左对齐小号控件的两列。
/// 颜色全部用系统语义色，浅色和深色外观都适用（Compressor 只有深色）。
struct InspectorView: View {
    @Bindable var workbench: Workbench

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader { header }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(12)
            }
        }
        .background(Palette.panel)
        .controlSize(.small)
    }

    @ViewBuilder private var header: some View {
        switch workbench.inspectorSubject {
        case .jobs, .preset:
            Picker("标签", selection: $workbench.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        case .source: Text("源图").font(.callout)
        case .location: Text("位置").font(.callout)
        case .none: EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch workbench.inspectorSubject {
        case .none:
            Text("没有可检查的内容")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        case .source(let id):
            if let item = workbench.sourceItem(id) { SourceInspector(workbench: workbench, item: item) }
        case .location(let id):
            if let location = workbench.location(id) { LocationInspector(workbench: workbench, location: location) }
        case .jobs, .preset:
            PresetInfoCard(workbench: workbench)
            Group { tab }
                .disabled(!workbench.isInspectorEditable)
        }
    }

    @ViewBuilder private var tab: some View {
        switch workbench.inspectorTab {
        case .canvas: CanvasTab(workbench: workbench)
        case .panorama: PanoramaTab(workbench: workbench)
        case .layers: LayersTab(workbench: workbench)
        case .output: OutputTab(workbench: workbench)
        }
    }
}

// MARK: - 共用的版式

/// 每栏顶部一行（约 28 pt）：放小号分段控件或标题，居中。
struct ColumnHeader<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            Divider()
        }
    }
}

/// 分节：小号粗体标题 + 圆角分组框，框里是两列表单。
struct InspectorSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).padding(.leading, 4)
            }
            Form { content }
                .formStyle(.columns)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Palette.group, in: .rect(cornerRadius: 8))
        }
    }
}

/// 顶部信息卡：图标 + 粗体名称 + 灰色摘要，右上角可放标记（SDR / HDR）。
struct InfoCard<Actions: View>: View {
    var symbol: String
    var title: String
    var lines: [String]
    var badge: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                Text(title).font(.headline).lineLimit(2)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill.secondary, in: .rect(cornerRadius: 4))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 26)
            .textSelection(.enabled)
            actions.padding(.leading, 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.group, in: .rect(cornerRadius: 8))
    }
}

// MARK: - 预设 / 任务的信息卡与「存储为预设」

private struct PresetInfoCard: View {
    let workbench: Workbench
    @State private var saving: RenameRequest?

    var body: some View {
        InfoCard(symbol: symbol, title: title, lines: lines) {
            HStack { actions }
        }
        .renameAlert($saving)
    }

    private var symbol: String {
        if case .jobs(let ids) = workbench.inspectorSubject, ids.count > 1 { return "square.stack" }
        return workbench.field(\.panorama.enabled) == .single(true) ? "rectangle.split.3x1" : "rectangle.portrait"
    }

    private var title: String {
        switch workbench.inspectorSubject {
        case .preset: workbench.presetEditor?.draft.name ?? ""
        case .jobs(let ids) where ids.count > 1: "\(ids.count) 个任务"
        default: workbench.editedPreset?.name ?? ""
        }
    }

    private var lines: [String] {
        var lines: [String] = []
        switch workbench.inspectorSubject {
        case .preset:
            guard let editor = workbench.presetEditor else { return [] }
            lines.append(editor.isReadOnly ? "内置预设（只读）" : "预设 · \(editor.entry.origin.groupTitle)")
        case .jobs(let ids) where ids.count > 1:
            return ["只显示可以批量修改的共同字段", "不同的值显示为「多个值」"]
        default:
            lines.append("修改只影响这个任务，不写回预设")
        }
        if let preset = workbench.editedPreset {
            lines.append("画布：\(preset.canvas.width) × \(preset.canvas.height)，\(preset.canvas.mode == .fit ? "完整嵌入" : "比例裁切")")
            let range = preset.output.dynamicRange == .hdr ? "HDR" : "SDR"
            lines.append("输出：\(preset.output.format.rawValue.uppercased())，\(range)，\(preset.output.colorSpace)")
            if case .jobs(let ids) = workbench.inspectorSubject, let outputs = workbench.job(ids[0])?.validation?.outputs, !outputs.isEmpty {
                lines.append(outputs.count == 1 ? "1 张图" : "封面 + \(outputs.count - 1) 张切片")
            }
        }
        return lines
    }

    @ViewBuilder private var actions: some View {
        switch workbench.inspectorSubject {
        case .preset(let id):
            if let editor = workbench.presetEditor {
                if editor.isReadOnly {
                    Button("复制后编辑") { Task { await workbench.duplicatePreset(id) } }
                } else {
                    Button("还原") { workbench.revertPresetEdits() }.disabled(!editor.isDirty)
                    Button("存储") { Task { await workbench.savePresetEdits() } }.disabled(!editor.isDirty)
                }
            }
        case .jobs(let ids) where ids.count == 1:
            Button("存储为预设…") {
                saving = RenameRequest(title: "存储为预设", name: workbench.editedPreset?.name ?? "", confirm: "存储") { name in
                    Task { await workbench.saveSelectedJobAsPreset(name: name) }
                }
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - 位置

private struct LocationInspector: View {
    let workbench: Workbench
    let location: ExportLocation
    @State private var choosing = false

    var body: some View {
        InfoCard(symbol: "folder", title: location.name, lines: [location.url.displayPath],
                 badge: location.id == workbench.locations.defaultLocation?.id ? "默认" : nil) { EmptyView() }
        InspectorSection("位置属性") {
            TextField("名称", text: Binding(get: { location.name }, set: { workbench.renameLocation(location.id, to: $0) }))
            LabeledContent("路径") {
                Text(location.url.displayPath).lineLimit(3).truncationMode(.middle)
            }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([location.url]) }
            Button("设为默认位置") { workbench.setDefaultLocation(location.id) }
                .disabled(location.id == workbench.locations.defaultLocation?.id)
        }
    }
}

// MARK: - 字段绑定

extension Workbench {
    /// 右栏字段的绑定：多个值不同时读出 nil，控件显示「多个值」；写入时改全部选中项。
    func binding<Value: Equatable>(_ path: WritableKeyPath<ExportPreset, Value>) -> Binding<Value?> {
        Binding(get: { self.field(path).value }, set: { if let v = $0 { self.setField(path, v) } })
    }

    func binding<Value: Equatable>(_ path: WritableKeyPath<ExportPreset, Value>, default value: Value) -> Binding<Value> {
        Binding(get: { self.field(path).value ?? value }, set: { self.setField(path, $0) })
    }

    func layerBinding<Value>(_ layerId: String, _ path: WritableKeyPath<OverlayLayer, Value>, default value: Value) -> Binding<Value> {
        Binding(
            get: { self.editedPreset?.layers.first { $0.layerId == layerId }?[keyPath: path] ?? value },
            set: { v in self.updateLayer(layerId) { $0[keyPath: path] = v } })
    }
}

/// 整数输入框；多个值不同时为空并提示「多个值」。
struct IntField: View {
    let title: String
    @Binding var value: Int?
    var unit = "px"

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: $value, format: .number, prompt: Text("多个值"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}

/// `#RRGGBB` 颜色：取色器 + 十六进制（D-35）。
struct ColorField: View {
    let title: String
    @Binding var value: PresetColor?

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: hex, prompt: Text("多个值"))
                    .labelsHidden()
                    .frame(maxWidth: 90)
                ColorPicker(title, selection: color, supportsOpacity: false).labelsHidden()
            }
        }
    }

    private var hex: Binding<String> {
        Binding(get: { value?.hex ?? "" }, set: { text in
            let candidate = PresetColor(hex: text.hasPrefix("#") ? text.uppercased() : "#" + text.uppercased())
            if candidate.isValidHex { value = candidate }
        })
    }

    private var color: Binding<CGColor> {
        Binding(
            get: { value.flatMap { CGColor.fromHex($0.hex) } ?? CGColor(gray: 1, alpha: 1) },
            set: { if let hex = $0.srgbHex { value = PresetColor(hex: hex) } })
    }
}

extension CGColor {
    static func fromHex(_ hex: String) -> CGColor? {
        guard hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        return CGColor(srgbRed: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255, alpha: 1)
    }

    /// 转到 sRGB 后的 `#RRGGBB`；色域外的颜色按通道截断。
    var srgbHex: String? {
        guard let srgb = converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = srgb.components, c.count >= 3 else { return nil }
        let bytes = c.prefix(3).map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }
}

// MARK: - 画布

private struct CanvasTab: View {
    let workbench: Workbench

    var body: some View {
        InspectorSection("尺寸") {
            IntField(title: "宽", value: workbench.binding(\.canvas.width))
            IntField(title: "高", value: workbench.binding(\.canvas.height))
            if let preset = workbench.editedPreset {
                LabeledContent("比例") { Text(ratio(preset.canvas.width, preset.canvas.height)) }
            }
        }
        InspectorSection("适配") {
            Picker("方式", selection: workbench.binding(\.canvas.mode)) {
                Text("完整嵌入").tag(CanvasSettings.Mode?.some(.fit))
                Text("比例裁切").tag(CanvasSettings.Mode?.some(.crop))
                if workbench.field(\.canvas.mode) == .mixed { Text("多个值").tag(CanvasSettings.Mode?.none) }
            }
            if workbench.field(\.canvas.mode) == .single(.crop) {
                Picker("裁切对齐", selection: cropAnchor) {
                    ForEach(OverlayAnchor.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            ColorField(title: "背景色", value: workbench.binding(\.canvas.background))
            IntField(title: "最小边距", value: workbench.binding(\.canvas.minMarginPx))
        }
    }

    private func ratio(_ w: Int, _ h: Int) -> String {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(a, 1) : gcd(b, a % b) }
        let g = gcd(w, h)
        return "\(w / g):\(h / g)"
    }

    /// 裁切范围在照片上的位置（`canvas.crop.anchor`，0…1）。
    private var cropAnchor: Binding<OverlayAnchor> {
        func position(_ a: OverlayAlignment) -> Double { a == .start ? 0 : a == .center ? 0.5 : 1 }
        func alignment(_ v: Double) -> OverlayAlignment { v < 0.25 ? .start : v > 0.75 ? .end : .center }
        return Binding(
            get: {
                let anchor = workbench.field(\.canvas.crop).value??.anchor ?? Pair(0.5, 0.5)
                return OverlayAnchor(horizontal: alignment(anchor.first), vertical: alignment(anchor.second))
            },
            set: { a in
                workbench.edit { preset in
                    var crop = preset.canvas.crop ?? CropSettings()
                    crop.anchor = Pair(position(a.horizontal), position(a.vertical))
                    preset.canvas.crop = crop
                }
            })
    }
}

// MARK: - 全景

private struct PanoramaTab: View {
    @Bindable var workbench: Workbench

    var body: some View {
        InspectorSection {
            Toggle("全景分割", isOn: workbench.binding(\.panorama.enabled, default: false))
            Toggle("封面", isOn: workbench.binding(\.panorama.cover, default: true))
        }
        if workbench.field(\.panorama.enabled) == .single(true) {
            InspectorSection("切片") {
                Picker("张数", selection: manual) {
                    Text("自动").tag(false)
                    Text("手动").tag(true)
                }
                if case .single(.fixed(let n)) = workbench.field(\.panorama.tileCount) {
                    Stepper("\(n) 张", value: fixedCount(n), in: 1...35)
                }
                IntField(title: "上下边距", value: workbench.binding(\.panorama.verticalMarginPx))
            }
            InspectorSection("预览") {
                Toggle("显示接缝位置", isOn: Bindable(workbench.preview).showsSeams)
            }
        }
    }

    /// 只允许手动改多（D-11）：切到手动时从自动算出的张数开始。
    private var manual: Binding<Bool> {
        Binding(
            get: { if case .single(.fixed) = workbench.field(\.panorama.tileCount) { true } else { false } },
            set: { on in
                let slides = max(workbench.preview.roles.count - 1, 1)
                workbench.setField(\.panorama.tileCount, on ? .fixed(slides) : .auto)
            })
    }

    private func fixedCount(_ n: Int) -> Binding<Int> {
        Binding(get: { n }, set: { workbench.setField(\.panorama.tileCount, .fixed($0)) })
    }
}

// MARK: - 输出

private struct OutputTab: View {
    let workbench: Workbench

    var body: some View {
        InspectorSection("文件") {
            Picker("格式", selection: workbench.binding(\.output.format)) {
                Text("JPEG").tag(OutputSettings.Format?.some(.jpeg))
                Text("PNG").tag(OutputSettings.Format?.some(.png))
                if workbench.field(\.output.format) == .mixed { Text("多个值").tag(OutputSettings.Format?.none) }
            }
            if workbench.field(\.output.format) == .single(.jpeg) {
                LabeledContent("质量") {
                    Slider(value: quality, in: 1...100, step: 1) { Text("质量") } minimumValueLabel: { Text("1") } maximumValueLabel: { Text("100") }
                        .labelsHidden()
                }
            }
            Picker("动态范围", selection: workbench.binding(\.output.dynamicRange)) {
                Text("SDR").tag(OutputSettings.DynamicRange?.some(.sdr))
                Text("HDR").tag(OutputSettings.DynamicRange?.some(.hdr))
                if workbench.field(\.output.dynamicRange) == .mixed { Text("多个值").tag(OutputSettings.DynamicRange?.none) }
            }
        }
        InspectorSection("元数据") {
            Toggle("保留拍摄参数", isOn: workbench.binding(\.output.metadata.keepShootingInfo, default: false))
            Toggle("保留作者和版权", isOn: workbench.binding(\.output.metadata.keepAuthorAndCopyright, default: false))
            Toggle(isOn: workbench.binding(\.output.metadata.keepGps, default: false)) {
                Text("保留 GPS")
                Text("照片里的位置会随图片一起公开").foregroundStyle(.orange)
            }
        }
        if case .jobs = workbench.inspectorSubject {
            JobOutputSection(workbench: workbench)
        }
    }

    private var quality: Binding<Double> {
        Binding(get: { Double(workbench.field(\.output.quality).value ?? 100) }, set: { workbench.setField(\.output.quality, Int($0)) })
    }
}

/// 任务才有的输出字段：命名规则、输出位置。
private struct JobOutputSection: View {
    let workbench: Workbench
    @State private var choosingFolder = false

    var body: some View {
        InspectorSection("位置与命名") {
            Picker("输出位置", selection: destination) {
                ForEach(workbench.locations.locations) { Text($0.name).tag(URL?.some($0.url)) }
                if let url = workbench.jobField(\.destination).value, workbench.locationName(for: url) == nil {
                    Text(url.displayPath).tag(URL?.some(url))
                }
                if workbench.jobField(\.destination) == .mixed { Text("多个值").tag(URL?.none) }
            }
            Button("选取其他文件夹…") { choosingFolder = true }
            TextField("作品目录", text: template, prompt: Text("多个值"))
            Text("可用 {source}、{variant}、{preset}、{platform}").font(.caption).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) {
            if case .success(let url) = $0 { workbench.setDestinationForSelection(url) }
        }
    }

    private var destination: Binding<URL?> {
        Binding(get: { workbench.jobField(\.destination).value }, set: { if let url = $0 { workbench.setDestinationForSelection(url) } })
    }

    private var template: Binding<String> {
        Binding(get: { workbench.jobField(\.naming.workNameTemplate).value ?? "" }, set: { if !$0.isEmpty { workbench.setNamingTemplate($0) } })
    }
}
