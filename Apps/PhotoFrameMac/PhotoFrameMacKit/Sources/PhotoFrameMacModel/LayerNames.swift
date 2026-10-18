import PhotoFrameCore

// 图层和素材槽在界面上的名字（右栏「图层」的分节标题、警告）。界面不显示 layerId、slotId。

extension LayerTemplate {
    /// 「添加图层」菜单里的名字，也是这样加出来的图层的名字。
    public var title: String {
        switch self {
        case .watermark: "水印"
        case .signature: "签名"
        case .cameraBadge: "相机图标"
        case .exifText: "EXIF 文字"
        case .text: "文字"
        }
    }
}

extension OverlayLayer.LayerType {
    public var title: String {
        switch self {
        case .text: "文字"
        case .asset: "素材"
        case .metadataText: "EXIF 文字"
        case .cameraBadge: "相机图标"
        }
    }
}

extension ExportPreset {
    /// 图层 ID、素材槽 ID → 界面上的名字。图层用添加时选的名字（「水印」「签名 2」）；
    /// 不是在 GUI 里加的图层用它素材槽的说明，再没有就用图层类型。重名时按叠放顺序加编号。
    public var layerTitles: [String: String] {
        var titles: [String: String] = [:]
        var used: Set<String> = []
        for layer in layers.sorted(by: { $0.zIndex < $1.zIndex }) {
            var title = Self.baseTitle(layer, slots: assetSlots)
            if used.contains(title) {
                var n = 2
                while used.contains("\(title) \(n)") { n += 1 }
                title = "\(title) \(n)"
            }
            used.insert(title)
            titles[layer.layerId] = title
            if let slotId = layer.slotId, titles[slotId] == nil { titles[slotId] = title }
            for (index, rule) in layer.cameraMatch.enumerated() where titles[rule.slotId] == nil {
                titles[rule.slotId] = "\(title)的相机规则 \(index + 1)"
            }
        }
        for slot in assetSlots where titles[slot.slotId] == nil {
            titles[slot.slotId] = slot.label.flatMap { $0.isEmpty ? nil : $0 } ?? slot.slotId
        }
        return titles
    }

    /// 一个图层的名字（右栏「图层」的分节标题）。
    public func title(ofLayer layerId: String) -> String {
        layerTitles[layerId] ?? layerId
    }

    private static func baseTitle(_ layer: OverlayLayer, slots: [AssetSlot]) -> String {
        // GUI 加的图层 ID 是模板名，同类的第二个起加「-2」「-3」（见 `addLayer`）。
        for template in LayerTemplate.allCases {
            let raw = template.rawValue
            if layer.layerId == raw { return template.title }
            if layer.layerId.hasPrefix(raw + "-"), let n = Int(layer.layerId.dropFirst(raw.count + 1)) { return "\(template.title) \(n)" }
        }
        if let slotId = layer.slotId, let label = slots.first(where: { $0.slotId == slotId })?.label, !label.isEmpty { return label }
        return layer.type.title
    }
}

extension JobIssue {
    /// 消息里用「」括起来的图层 ID、素材槽 ID 换成界面上的名字（后端的消息给 CLI 用，写的是 ID）。
    func naming(_ titles: [String: String]) -> JobIssue {
        guard message.contains("「") else { return self }
        var issue = self
        // 长的 ID 先换，「signature-2」不会被「signature」的替换弄乱（括号本身也防止了部分匹配）。
        for (id, title) in titles.sorted(by: { $0.key.count > $1.key.count }) {
            issue.message = issue.message.replacingOccurrences(of: "「\(id)」", with: "「\(title)」")
        }
        return issue
    }
}
