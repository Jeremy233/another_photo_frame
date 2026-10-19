import Foundation
import PhotoFrameCore

/// 右栏「图层」里可以添加的图层（UI 设计文档第 8.3 节）。只决定新图层的初始值，之后各字段都能改。
public enum LayerTemplate: String, CaseIterable, Identifiable, Sendable {
    case watermark, signature, cameraBadge, exifText, text
    public var id: Self { self }

    func make(id: String) -> (OverlayLayer, AssetSlot?) {
        switch self {
        case .watermark:
            (OverlayLayer(layerId: id, type: .asset, anchor: .bottomRight, reference: .photo(.inside), offset: OverlayOffset(x: 24, y: 24),
                          maxBoundsPx: PixelSize(width: 240, height: 96), opacity: 0.8, slotId: id),
             AssetSlot(slotId: id, label: "水印"))
        case .signature:
            (OverlayLayer(layerId: id, type: .asset, anchor: .bottomRight, offset: OverlayOffset(x: 0, y: 16),
                          maxBoundsPx: PixelSize(width: 240, height: 80), slotId: id),
             AssetSlot(slotId: id, label: "签名"))
        case .cameraBadge:
            (OverlayLayer(layerId: id, type: .cameraBadge, anchor: .bottomLeft, offset: OverlayOffset(x: 0, y: 16),
                          maxBoundsPx: PixelSize(width: 120, height: 48), slotId: id),
             AssetSlot(slotId: id, label: "相机图标"))
        case .exifText:
            (OverlayLayer(layerId: id, type: .metadataText, anchor: .bottom, offset: OverlayOffset(x: 0, y: 16),
                          text: TextStyle(template: "{camera} · {focalLength} · {aperture} · {shutter} · {iso}")),
             nil)
        case .text:
            (OverlayLayer(layerId: id, type: .text, anchor: .bottomLeft, offset: OverlayOffset(x: 0, y: 16), text: TextStyle(content: "")),
             nil)
        }
    }
}

/// 图层「显示在 → 指定页」的页码（D-27：0 = 封面）。输入框里是文字，回车或离开输入框时才解析写回，
/// 逐字输入「0, 2」时逗号和空格不会被吞掉。
public enum SlidePages {
    /// 任何非数字字符都当分隔符：「0, 2，3」→ {0, 2, 3}。
    public static func parse(_ text: String) -> Set<Int> {
        Set(text.split { !$0.isASCII || !$0.isNumber }.compactMap { Int($0) })
    }

    public static func text(_ pages: Set<Int>) -> String {
        pages.sorted().map(String.init).joined(separator: ", ")
    }
}

extension Workbench {
    /// 在正在编辑的预设（单个任务或左栏预设）里加一个图层；需要素材的同时加一个同名素材槽。
    public func addLayer(_ template: LayerTemplate) {
        guard editedPreset != nil else { return }
        edit("添加装饰") { preset in
            let used = Set(preset.layers.map(\.layerId) + preset.assetSlots.map(\.slotId))
            var id = template.rawValue
            var n = 2
            while used.contains(id) {
                id = "\(template.rawValue)-\(n)"
                n += 1
            }
            var (layer, slot) = template.make(id: id)
            layer.zIndex = (preset.layers.map(\.zIndex).max() ?? -1) + 1
            preset.layers.append(layer)
            if let slot { preset.assetSlots.append(slot) }
        }
    }

    /// 删除图层；它的素材槽（含相机匹配规则的槽）没有别的图层用时一起删除。
    public func removeLayer(_ layerId: String) {
        edit("删除装饰") { preset in
            guard let i = preset.layers.firstIndex(where: { $0.layerId == layerId }) else { return }
            let removed = preset.layers.remove(at: i)
            Self.dropUnusedSlots([removed.slotId].compactMap { $0 } + removed.cameraMatch.map(\.slotId), in: &preset)
        }
    }

    /// 当前预览源图的相机（EXIF Make / Model），用来预填相机匹配规则。
    public var previewCamera: CameraIdentity? {
        guard let id = previewSubject?.sourceId, let metadata = sourceItem(id)?.inspection?.metadata else { return nil }
        let camera = CameraIdentity(make: metadata["make"], model: metadata["model"])
        return camera.isEmpty ? nil : camera
    }

    /// 给素材图层加一条相机匹配规则（D-111），同时加一个规则专用的素材槽。品牌、型号预填当前预览源图的相机。
    public func addCameraRule(_ layerId: String) {
        let camera = previewCamera
        edit("添加相机规则") { preset in
            guard let i = preset.layers.firstIndex(where: { $0.layerId == layerId }), preset.layers[i].type.usesAssetSlot else { return }
            let used = Set(preset.assetSlots.map(\.slotId))
            var n = preset.layers[i].cameraMatch.count + 1
            while used.contains("\(layerId).camera-\(n)") { n += 1 }
            let slotId = "\(layerId).camera-\(n)"
            let label = [camera?.make, camera?.model].compactMap { $0 }.joined(separator: " ")
            preset.assetSlots.append(AssetSlot(slotId: slotId, label: label.isEmpty ? "相机图标" : label))
            preset.layers[i].cameraMatch.append(CameraMatchRule(make: camera?.make, model: camera?.model, slotId: slotId))
        }
    }

    /// 删除一条相机匹配规则；它的素材槽没有别处用时一起删除。
    public func removeCameraRule(_ layerId: String, at index: Int) {
        edit("删除相机规则") { preset in
            guard let i = preset.layers.firstIndex(where: { $0.layerId == layerId }),
                  preset.layers[i].cameraMatch.indices.contains(index) else { return }
            let rule = preset.layers[i].cameraMatch.remove(at: index)
            Self.dropUnusedSlots([rule.slotId], in: &preset)
        }
    }

    private static func dropUnusedSlots(_ slotIds: [String], in preset: inout ExportPreset) {
        let used = Set(preset.layers.flatMap { [$0.slotId].compactMap { $0 } + $0.cameraMatch.map(\.slotId) })
        preset.assetSlots.removeAll { slotIds.contains($0.slotId) && !used.contains($0.slotId) }
    }

    public func updateLayer(_ layerId: String, coalescing key: AnyHashable? = nil, _ body: (inout OverlayLayer) -> Void) {
        edit("修改装饰", coalescing: key) { preset in
            if let i = preset.layers.firstIndex(where: { $0.layerId == layerId }) { body(&preset.layers[i]) }
        }
    }
}
