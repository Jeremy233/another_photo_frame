import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameMacModel
import SwiftUI

/// 右栏（UI 设计文档第 6、8 节）：选中源图显示原图信息；选中任务或预设显示「画布 | 全景 | 图层 | 输出」。
struct InspectorView: View {
    @Bindable var workbench: Workbench

    var body: some View {
        switch workbench.inspectorSubject {
        case .none:
            ContentUnavailableView("没有选择", systemImage: "sidebar.trailing", description: Text("选中源图、任务或左栏的预设"))
        case .source(let id):
            if let item = workbench.sourceItem(id) { SourceInspector(workbench: workbench, item: item) }
        case .jobs, .preset:
            VStack(spacing: 0) {
                InspectorHeader(workbench: workbench)
                Picker("标签", selection: $workbench.inspectorTab) {
                    ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                Divider()
                Form { tab }
                    .formStyle(.grouped)
                    .disabled(!workbench.isInspectorEditable)
            }
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

// MARK: - 标题与「存储为预设」

private struct InspectorHeader: View {
    let workbench: Workbench
    @State private var saving: RenameRequest?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .controlSize(.small)
        .padding(12)
        .renameAlert($saving)
    }

    private var title: String {
        switch workbench.inspectorSubject {
        case .preset: workbench.presetEditor?.draft.name ?? ""
        case .jobs(let ids) where ids.count > 1: "\(ids.count) 个任务"
        default: workbench.editedPreset?.name ?? ""
        }
    }

    private var subtitle: String {
        switch workbench.inspectorSubject {
        case .preset:
            guard let editor = workbench.presetEditor else { return "" }
            return editor.isReadOnly ? "内置预设（只读）" : "编辑预设 · \(editor.entry.origin.groupTitle)"
        case .jobs(let ids) where ids.count > 1:
            return "只显示可以批量修改的共同字段"
        default:
            return "修改只影响这个任务，不写回预设"
        }
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
        Section("尺寸") {
            IntField(title: "宽", value: workbench.binding(\.canvas.width))
            IntField(title: "高", value: workbench.binding(\.canvas.height))
            if let preset = workbench.editedPreset {
                LabeledContent("比例", value: ratio(preset.canvas.width, preset.canvas.height))
            }
        }
        Section("适配") {
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
        Section {
            Toggle("全景分割", isOn: workbench.binding(\.panorama.enabled, default: false))
            Toggle("封面", isOn: workbench.binding(\.panorama.cover, default: true))
        }
        if workbench.field(\.panorama.enabled) == .single(true) {
            Section("切片") {
                Picker("张数", selection: manual) {
                    Text("自动").tag(false)
                    Text("手动").tag(true)
                }
                if case .single(.fixed(let n)) = workbench.field(\.panorama.tileCount) {
                    Stepper("\(n) 张", value: fixedCount(n), in: 1...35)
                }
                IntField(title: "上下边距", value: workbench.binding(\.panorama.verticalMarginPx))
            }
            Section("预览") {
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
        Section("文件") {
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
        Section("元数据") {
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
        Section("位置与命名") {
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
