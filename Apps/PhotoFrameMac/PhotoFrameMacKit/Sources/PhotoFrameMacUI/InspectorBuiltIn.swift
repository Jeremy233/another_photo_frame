import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameMacModel
import PhotoFrameStorage
import SwiftUI

// MARK: - 内置装饰（D-132–D-136）

/// 品牌 logo 的设置：来源、当前照片认出的品牌、认不出时、样式、高度、颜色。
struct BrandLogoRows: View {
    let workbench: Workbench
    let layer: OverlayLayer

    var body: some View {
        InspectorPicker("来源", selection: binding(\.brand)) {
            Text("自动（按相机品牌）").tag(BrandLogoStyle.automatic)
            Section("现役品牌") { ForEach(BuiltInWatermarks.brands.filter { !$0.classic }) { Text($0.name).tag($0.id) } }
            Section("经典品牌") { ForEach(BuiltInWatermarks.brands.filter(\.classic)) { Text($0.name).tag($0.id) } }
        }
        if style.brand == BrandLogoStyle.automatic {
            LabeledContent("当前照片") { MatchLabel(text: currentMatch.text, matched: currentMatch.matched) }
            InspectorPicker("认不出时", selection: binding(\.fallback)) {
                Text("不显示").tag(BrandLogoStyle.Fallback.none)
                Text("显示品牌文字").tag(BrandLogoStyle.Fallback.text)
            }
        }
        InspectorPicker("样式", selection: binding(\.variant)) {
            Text("字标").tag(BrandLogoStyle.Variant.wordmark)
            Text("标志").tag(BrandLogoStyle.Variant.emblem)
        }
        InspectorRow { Hint("只影响同时有字标和标志的品牌，目前是 Nikon") }
        NumberField(title: "高度", value: binding(\.heightPx))
        InspectorPicker("颜色", selection: binding(\.colorMode)) {
            Text("原色").tag(BrandLogoStyle.ColorMode.original)
            Text("自动（随背景深浅）").tag(BrandLogoStyle.ColorMode.auto)
            Text("自定").tag(BrandLogoStyle.ColorMode.custom)
        }
        if style.colorMode == .custom {
            ColorField(title: "自定颜色", value: Binding(get: { style.color ?? PresetColor(hex: "#1A1A1A") },
                                                      set: { v in if let v { update { $0.color = v } } }))
        }
        InspectorRow { Hint(colorNote) }
    }

    private var style: BrandLogoStyle { layer.logo ?? BrandLogoStyle() }

    /// 预览的源图认出的品牌（手填的相机优先，D-135）。
    private var currentMatch: (text: String, matched: Bool) {
        guard let camera = workbench.previewCamera else { return ("源图没有相机品牌（可在源图上手动填写）", false) }
        if let brand = BuiltInWatermarks.brand(make: camera.make, model: camera.model) { return ("\(brand.name)（内置）", true) }
        return ("认不出「\([camera.make, camera.model].compactMap { $0 }.joined(separator: " "))」", false)
    }

    private var colorNote: String {
        switch style.colorMode {
        case .original: "彩色 logo 用品牌自己的颜色，深色画布上换成白字版；单色 logo 没有自己的颜色，浅色画布用黑色、深色画布用白色"
        case .auto: "浅色画布用黑色、深色画布用白色；带底色的标志（Leica、Zeiss、Kodak 等）仍用原色"
        case .custom: "整个 logo 换成这个颜色；带底色的标志仍用原色，Kodak 换成同形状的单色版"
        }
    }

    private func binding<V>(_ path: WritableKeyPath<BrandLogoStyle, V>) -> Binding<V> {
        Binding(get: { style[keyPath: path] }, set: { v in update { $0[keyPath: path] = v } })
    }

    private func update(_ body: (inout BrandLogoStyle) -> Void) {
        workbench.updateLayer(layer.layerId) { l in
            var s = l.logo ?? BrandLogoStyle()
            body(&s)
            l.logo = s
        }
    }
}

/// 胶卷装饰的设置：来源、当前照片的胶卷、显示、没有图标时、图标大小、文字模板。
struct FilmIconRows: View {
    let workbench: Workbench
    let layer: OverlayLayer

    var body: some View {
        InspectorPicker("来源", selection: binding(\.film)) {
            Text("自动（按源图填的胶卷）").tag(FilmIconStyle.automatic)
            ForEach(Self.makers, id: \.self) { maker in
                Section(maker.capitalized) {
                    ForEach(BuiltInWatermarks.films.filter { $0.maker == maker }) { Text($0.name).tag($0.id) }
                }
            }
        }
        if style.film == FilmIconStyle.automatic {
            LabeledContent("当前照片") { MatchLabel(text: currentFilm.text, matched: currentFilm.matched) }
        }
        InspectorPicker("显示", selection: binding(\.show)) {
            Text("图标和文字").tag(FilmIconStyle.Show.iconAndText)
            Text("只有图标").tag(FilmIconStyle.Show.icon)
            Text("只有文字").tag(FilmIconStyle.Show.text)
        }
        if style.show != .text {
            InspectorPicker("没有图标时", selection: binding(\.noIcon)) {
                Text("用胶卷品牌 logo").tag(FilmIconStyle.NoIcon.brandLogo)
                Text("只显示文字").tag(FilmIconStyle.NoIcon.text)
                Text("不显示").tag(FilmIconStyle.NoIcon.none)
            }
            NumberField(title: "图标大小", value: binding(\.iconSizePx))
        }
        if style.show != .icon {
            InspectorTextField("文字", text: Binding(
                get: { layer.text?.template ?? FilmIconStyle.defaultTemplate },
                set: { v in workbench.updateLayer(layer.layerId) { l in
                    var t = l.text ?? TextStyle(template: FilmIconStyle.defaultTemplate)
                    t.template = v
                    l.text = t
                } }), prompt: FilmIconStyle.defaultTemplate)
        }
    }

    static let makers: [String] = BuiltInWatermarks.films.map(\.maker).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }

    private var style: FilmIconStyle { layer.filmIcon ?? FilmIconStyle() }

    private var currentFilm: (text: String, matched: Bool) {
        guard let film = workbench.previewFilm, !film.isEmpty else { return ("源图没有填胶卷，不显示", false) }
        if let builtIn = BuiltInWatermarks.film(named: film) { return ("\(builtIn.name)（内置图标）", true) }
        return ("「\(film)」没有内置图标", false)
    }

    private func binding<V>(_ path: WritableKeyPath<FilmIconStyle, V>) -> Binding<V> {
        Binding(get: { style[keyPath: path] }, set: { v in workbench.updateLayer(layer.layerId) { l in
            var s = l.filmIcon ?? FilmIconStyle()
            s[keyPath: path] = v
            l.filmIcon = s
        } })
    }
}

/// 「当前照片」一行：认出时绿点，认不出时橙点。
private struct MatchLabel: View {
    let text: String
    let matched: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(matched ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(text).lineLimit(1).truncationMode(.middle).help(text)
        }
    }
}

/// 灰色说明文字。
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 源图的胶卷、相机与参数（D-135）

/// 选中一张或几张源图时的「胶卷、相机与参数」：手填的值优先于 EXIF，几张源图一起写。
struct SourceMetadataSection: View {
    let workbench: Workbench
    let ids: [SourceID]

    var body: some View {
        InspectorSection("胶卷、相机与参数", key: "source.metadata") {
            ForEach(SourceMetadataField.allCases) { field in
                LabeledContent(field.title) {
                    HStack(spacing: 4) {
                        CommitTextField(title: field.title, text: value(field), prompt: prompt(field)) {
                            workbench.setMetadataOverride(field, $0, for: ids)
                        }
                        .labelsHidden()
                        if field == .film { FilmMenu { workbench.setMetadataOverride(.film, $0, for: ids) } }
                    }
                }
            }
            InspectorRow { Hint(note) }
        }
    }

    private var hasExif: Bool {
        ids.count == 1 && ids.first.flatMap { id in workbench.exifValue(.make, for: id) ?? workbench.exifValue(.model, for: id) } != nil
    }

    private var note: String {
        if ids.count > 1 { return "这里填的值会写给选中的 \(ids.count) 张源图；留空就用各自的 EXIF" }
        return hasExif ? "留空就用 EXIF；填了会覆盖 EXIF（例如翻拍、借来的机身、推拉冲洗）"
            : "这张图没有 EXIF（常见于胶片扫描），手填的相机和参数用于品牌 logo、品牌文字和 EXIF 文字"
    }

    private func value(_ field: SourceMetadataField) -> String {
        workbench.metadataOverride(field, for: ids).value ?? ""
    }

    private func prompt(_ field: SourceMetadataField) -> String {
        if case .mixed = workbench.metadataOverride(field, for: ids) { return "多个值" }
        if ids.count == 1, let id = ids.first, let exif = workbench.exifValue(field, for: id) { return "\(exif)（EXIF）" }
        return field.example
    }
}

/// 胶卷输入框旁的菜单：从内置胶卷里选。
private struct FilmMenu: View {
    let pick: (String) -> Void

    var body: some View {
        Menu {
            ForEach(FilmIconRows.makers, id: \.self) { maker in
                Section(maker.capitalized) {
                    ForEach(BuiltInWatermarks.films.filter { $0.maker == maker }) { film in
                        Button(film.name) { pick(film.name) }
                    }
                }
            }
        } label: {
            Image(systemName: "film")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("从内置胶卷中选择")
    }
}
