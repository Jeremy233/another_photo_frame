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

extension Workbench {
    /// 在正在编辑的预设（单个任务或左栏预设）里加一个图层；需要素材的同时加一个同名素材槽。
    public func addLayer(_ template: LayerTemplate) {
        guard editedPreset != nil else { return }
        edit { preset in
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

    /// 删除图层；它的素材槽没有别的图层用时一起删除。
    public func removeLayer(_ layerId: String) {
        edit { preset in
            guard let i = preset.layers.firstIndex(where: { $0.layerId == layerId }) else { return }
            let slotId = preset.layers.remove(at: i).slotId
            if let slotId, !preset.layers.contains(where: { $0.slotId == slotId }) {
                preset.assetSlots.removeAll { $0.slotId == slotId }
            }
        }
    }

    public func updateLayer(_ layerId: String, _ body: (inout OverlayLayer) -> Void) {
        edit { preset in
            if let i = preset.layers.firstIndex(where: { $0.layerId == layerId }) { body(&preset.layers[i]) }
        }
    }
}
