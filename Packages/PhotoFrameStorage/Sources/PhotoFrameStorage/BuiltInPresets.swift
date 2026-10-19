import Foundation
import PhotoFrameCore

/// 内置预设：Instagram / 小红书 / 抖音 × Standard / Panorama（§2.2、§3）。
///
/// 画布尺寸取自平台配置；presetId 固定不变，便于用户的预设本地绑定跨版本保持有效。
/// 默认背景 `#FAFAF8`、最小边距 20 px、sRGB JPEG Q100、动态范围跟随源图（auto，D-125）、元数据不写出，不带装饰图层。
public enum BuiltInPresets {
    public struct Definition: Sendable {
        public var presetId: UUID
        public var name: String
        public var platformId: String
        public var panorama: Bool
    }

    public static let definitions: [Definition] = [
        Definition(presetId: UUID(uuidString: "60978D90-F0A0-4369-B82D-6EEEE52F89BA")!, name: "Instagram Standard", platformId: "instagram", panorama: false),
        Definition(presetId: UUID(uuidString: "53EABC50-58DB-4F46-BC2E-A5A334C0B7E8")!, name: "Instagram Panorama", platformId: "instagram", panorama: true),
        Definition(presetId: UUID(uuidString: "769FD9F3-48FC-4040-937C-D795B860B10A")!, name: "XHS Standard", platformId: "xiaohongshu", panorama: false),
        Definition(presetId: UUID(uuidString: "16AE8FDA-85CA-4BBC-B4C2-9C1A47324EA1")!, name: "XHS Panorama", platformId: "xiaohongshu", panorama: true),
        Definition(presetId: UUID(uuidString: "015CD1C9-90AF-4D3A-82B3-DD49BEDD3112")!, name: "Douyin Standard", platformId: "douyin", panorama: false),
        Definition(presetId: UUID(uuidString: "EBB88F5F-AB1F-4902-8C19-981F7B4AA913")!, name: "Douyin Panorama", platformId: "douyin", panorama: true),
    ]

    public static let defaultBackground = PresetColor.defaultBackground
    public static let defaultMinMarginPx = 20

    /// 按平台配置生成全部内置预设；配置里缺少的平台跳过。
    public static func all(catalog: PlatformCatalog) -> [ExportPreset] {
        definitions.compactMap { d in
            guard let profile = catalog.profile(id: d.platformId) else { return nil }
            let size = d.panorama ? profile.panoramaTile : profile.standardCanvas
            return ExportPreset(
                presetId: d.presetId,
                name: d.name,
                platform: d.platformId,
                canvas: CanvasSettings(
                    width: size.width, height: size.height,
                    background: defaultBackground,
                    minMarginPx: defaultMinMarginPx,
                    mode: .fit),
                panorama: d.panorama ? PanoramaSettings(enabled: true) : .disabled,
                output: OutputSettings())
        }
    }

    public static func isBuiltIn(_ presetId: UUID) -> Bool {
        definitions.contains { $0.presetId == presetId }
    }
}
