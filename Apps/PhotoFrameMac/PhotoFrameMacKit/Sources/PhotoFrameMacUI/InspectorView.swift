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
        .controlSize(.regular)
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
        case .source: Text("源图")
        case .location: Text("位置")
        case .none: EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch workbench.inspectorSubject {
        case .none:
            VStack(spacing: 10) {
                Text("没有可检查的内容").font(.title3).foregroundStyle(.secondary)
                Text(Self.startHint).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        case .source(let id):
            NoticeBar(symbol: "hand.point.up.left", text: Self.startHint)
            if let item = workbench.sourceItem(id) { SourceInspector(workbench: workbench, item: item) }
        case .location(let id):
            if let location = workbench.location(id) { LocationInspector(workbench: workbench, location: location) }
        case .jobs, .preset(_):
            if case .preset(let id) = workbench.inspectorSubject, workbench.presetEditor?.isReadOnly == true {
                NoticeBar(symbol: "lock", text: "内置预设只读，复制后才能修改。") {
                    Button("复制后编辑") { Task { await workbench.duplicatePreset(id) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
            }
            if case .jobs(let ids) = workbench.inspectorSubject, ids.count == 1,
               let issues = workbench.job(ids[0])?.issues, !issues.isEmpty {
                InspectorSection("警告") { JobIssueList(issues: issues) }
            }
            PresetInfoCard(workbench: workbench)
            // 只读时不用 `.disabled`：系统的禁用样式在深色界面上暗到像是功能没做。这里只拦截操作、略微变淡，
            // 内容仍看得清；view model 也会拒绝对只读内容的修改。
            let editable = workbench.isInspectorEditable
            Group { tab }
                .allowsHitTesting(editable)
                .opacity(editable ? 1 : 0.75)
        }
    }

    static let startHint = "选中任务即可修改设置；把左栏的预设拖到源图上来创建任务。"

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

/// 每栏顶部一行（28 pt）：放常规尺寸的分段控件或标题，居中。
struct ColumnHeader<Content: View>: View {
    @ViewBuilder var content: Content

    /// 内容为空（例如 Inspector 没有选中任何东西）时也占满 28 pt，分隔线不会被顶到工具栏下面。
    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
                .overlay { content.controlSize(.regular) }
            Hairline()
        }
    }
}

/// Inspector 顶部的提示条：图标 + 一句话，可带一个操作按钮（例如内置预设的「复制后编辑」）。
struct NoticeBar<Action: View>: View {
    var symbol: String
    var text: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: symbol)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            action
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1) }
    }
}

extension NoticeBar where Action == EmptyView {
    init(symbol: String, text: String) {
        self.init(symbol: symbol, text: text) { EmptyView() }
    }
}

/// 分节：粗体标题 + 圆角分组框，框里是两列的行（参照 Compressor 的 Inspector）。
///
/// 不用系统 `Form`：它按控件决定行高，带输入框的行高、纯文字的行矮，间距不齐。这里每一行最小 32 pt
/// （Compressor 弹出菜单行的行距），标签在固定宽度的左列右对齐、与值按首行基线对齐，分组框上下内边距相同。
/// 行里用 `LabeledContent`（有标签）、`Toggle`（复选框放在值的一列）或 `InspectorRow`（只有值）。
struct InspectorSection<Content: View>: View {
    var title: String?
    /// 整组都是复选框（没有带标签的行）时为 true：复选框从分组框左边开始，不留空的标签列。
    var checkboxes = false
    @ViewBuilder var content: Content

    init(_ title: String? = nil, checkboxes: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.checkboxes = checkboxes
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.body.weight(.semibold)).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .labeledContentStyle(InspectorRowStyle())
                .toggleStyle(InspectorToggleStyle(leading: checkboxes))
                .padding(.horizontal, 12)
                .padding(.vertical, InspectorMetrics.groupPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.group, in: .rect(cornerRadius: 8))
        }
    }
}

enum InspectorMetrics {
    /// 每一行的最小高度。
    static let rowHeight: CGFloat = 32
    /// 左列（标签）的宽度。
    static let labelWidth: CGFloat = 88
    static let columnSpacing: CGFloat = 8
    /// 分组框上下内边距（相同）。
    static let groupPadding: CGFloat = 8
    /// 小号复选框的方框 + 间距，说明文字从这里开始，与复选框的文字对齐。
    static let checkboxTextInset: CGFloat = 22
}

/// 一行：左列右对齐的标签 + 右列的值，按首行基线对齐，最小高度一致。
struct InspectorRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: InspectorMetrics.columnSpacing) {
            configuration.label
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(width: InspectorMetrics.labelWidth, alignment: .trailing)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: InspectorMetrics.rowHeight)
    }
}

/// 复选框行，和其他行一样高（32 pt，单行居中）。和带标签的行在同一组时，复选框与其他行的值左对齐；
/// 整组都是复选框时（`leading`）从分组框左边开始。补充说明用 ``InspectorCheckboxNote`` 另起一行挂在下面。
struct InspectorToggleStyle: ToggleStyle {
    var leading = false

    func makeBody(configuration: Configuration) -> some View {
        if leading {
            // 分组里设了两列的 LabeledContent 样式，复选框内部也会用到它（标签跑到左边、方框到右边），这里换回系统样式。
            Toggle(configuration).toggleStyle(.checkbox)
                .labeledContentStyle(.automatic)
                .frame(maxWidth: .infinity, minHeight: InspectorMetrics.rowHeight, alignment: .leading)
        } else {
            LabeledContent {
                Toggle(configuration).toggleStyle(.checkbox)
            } label: {
                Text(verbatim: "")
            }
        }
    }
}

/// 挂在复选框下面的说明（例如 GPS 的隐私提示）：与复选框的文字对齐，不改变复选框行本身的高度。
struct InspectorCheckboxNote: View {
    var text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, InspectorMetrics.checkboxTextInset)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 只有值的一行（按钮、说明文字、菜单），放在值的一列。
struct InspectorRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LabeledContent {
            content
        } label: {
            // 空标签也要占住左列的宽度（EmptyView 不占宽度，值会跑到最左边）。
            Text(verbatim: "")
        }
    }
}

/// 带标签的弹出菜单行。
struct InspectorPicker<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder var options: Options

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.title = title
        _selection = selection
        self.options = options()
    }

    var body: some View {
        LabeledContent(title) {
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .fixedSize()
        }
    }
}

/// 带标签的文字输入行。
struct InspectorTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String?

    init(_ title: String, text: Binding<String>, prompt: String? = nil) {
        self.title = title
        _text = text
        self.prompt = prompt
    }

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: prompt.map { Text($0) })
                .labelsHidden()
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
                // 一行放不下时中间省略（文件名的扩展名还在），悬停看全名。
                Text(title).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle).help(title)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.fill.secondary, in: .rect(cornerRadius: 4))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                // 路径等长的行最多两行、中间省略，不逐字折成很多行。
                ForEach(lines, id: \.self) { Text($0).lineLimit(2).truncationMode(.middle).help($0) }
            }
            .font(.callout)
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
            let range = switch preset.output.dynamicRange {
            case .sdr: "SDR"
            case .hdr: "HDR"
            case .auto: "动态范围跟随源图"
            }
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
                if !editor.isReadOnly {
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
            InspectorTextField("名称", text: Binding(get: { location.name }, set: { workbench.renameLocation(location.id, to: $0) }))
            LabeledContent("路径") {
                Text(location.url.displayPath).lineLimit(3).truncationMode(.middle)
            }
            InspectorRow { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([location.url]) } }
            InspectorRow {
                Button("设为默认位置") { workbench.setDefaultLocation(location.id) }
                    .disabled(location.id == workbench.locations.defaultLocation?.id)
            }
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
            InspectorPicker("方式", selection: workbench.binding(\.canvas.mode)) {
                Text("完整嵌入").tag(CanvasSettings.Mode?.some(.fit))
                Text("比例裁切").tag(CanvasSettings.Mode?.some(.crop))
                if workbench.field(\.canvas.mode) == .mixed { Text("多个值").tag(CanvasSettings.Mode?.none) }
            }
            if workbench.field(\.canvas.mode) == .single(.crop) {
                InspectorPicker("裁切对齐", selection: cropAnchor) {
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
        InspectorSection(checkboxes: true) {
            Toggle("全景分割", isOn: workbench.binding(\.panorama.enabled, default: false))
            Toggle("封面", isOn: workbench.binding(\.panorama.cover, default: true))
        }
        if workbench.field(\.panorama.enabled) == .single(true) {
            InspectorSection("切片") {
                InspectorPicker("张数", selection: manual) {
                    Text("自动").tag(false)
                    Text("手动").tag(true)
                }
                if case .single(.fixed(let n)) = workbench.field(\.panorama.tileCount) {
                    InspectorRow { Stepper("\(n) 张", value: fixedCount(n), in: 1...35) }
                }
                IntField(title: "上下边距", value: workbench.binding(\.panorama.verticalMarginPx))
            }
            InspectorSection("预览", checkboxes: true) {
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
            InspectorPicker("格式", selection: workbench.binding(\.output.format)) {
                Text("JPEG").tag(OutputSettings.Format?.some(.jpeg))
                Text("PNG").tag(OutputSettings.Format?.some(.png))
                if workbench.field(\.output.format) == .mixed { Text("多个值").tag(OutputSettings.Format?.none) }
            }
            if workbench.field(\.output.format) == .single(.jpeg) {
                LabeledContent("质量") {
                    Slider(value: quality, in: 1...100, step: 1) { Text("质量") } minimumValueLabel: { Text("1").font(.callout) } maximumValueLabel: { Text("100").font(.callout) }
                        .labelsHidden()
                }
            }
            InspectorPicker("动态范围", selection: workbench.binding(\.output.dynamicRange)) {
                Text("跟随源图").tag(OutputSettings.DynamicRange?.some(.auto))
                Text("SDR").tag(OutputSettings.DynamicRange?.some(.sdr))
                Text("HDR").tag(OutputSettings.DynamicRange?.some(.hdr))
                if workbench.field(\.output.dynamicRange) == .mixed { Text("多个值").tag(OutputSettings.DynamicRange?.none) }
            }
            if let result = workbench.autoRangeResult {
                LabeledContent("实际输出") { Text(result).foregroundStyle(.secondary) }
            }
        }
        InspectorSection("元数据", checkboxes: true) {
            Toggle("保留拍摄参数", isOn: workbench.binding(\.output.metadata.keepShootingInfo, default: false))
            Toggle("保留作者和版权", isOn: workbench.binding(\.output.metadata.keepAuthorAndCopyright, default: false))
            Toggle("保留 GPS", isOn: workbench.binding(\.output.metadata.keepGps, default: false))
            InspectorCheckboxNote(text: "照片里的位置会随图片一起公开", color: .orange)
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
            // 菜单按最长的一项定宽：不在位置列表里的文件夹只显示名字，完整路径看悬停提示，长路径不会把右栏撑宽。
            InspectorPicker("输出位置", selection: destination) {
                ForEach(workbench.locations.locations) { Text($0.name).tag(URL?.some($0.url)) }
                if let url = workbench.jobField(\.destination).value, workbench.locationName(for: url) == nil {
                    Text(url.lastPathComponent).tag(URL?.some(url))
                }
                if workbench.jobField(\.destination) == .mixed { Text("多个值").tag(URL?.none) }
            }
            .help(workbench.jobField(\.destination).value?.displayPath ?? "")
            InspectorRow { Button("选取其他文件夹…") { choosingFolder = true } }
            InspectorTextField("作品目录", text: template, prompt: "多个值")
            // 值的一列放不下一行：按变量分成两行，不在中间断开。
            InspectorRow { Text("可用：{source}、{variant}\n{preset}、{platform}").font(.callout).foregroundStyle(.secondary) }
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
