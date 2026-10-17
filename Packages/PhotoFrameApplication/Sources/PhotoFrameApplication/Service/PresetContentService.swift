import Foundation
import PhotoFrameCore
import PhotoFrameStorage

/// GUI 需要、但 ``PhotoFrameService`` 还没有的预设与素材操作（§4.2「存储为预设」、UI 设计文档第 6–7 节）。
///
/// 单独成协议、只做新增，不改 ``PhotoFrameService`` 已有的接口；以后可以并入主协议。
public protocol PresetContentService: Sendable {
    /// 「存储为预设」：以给定内容新建用户预设（生成新 presetId）。内容必须通过与导入相同的校验。
    func savePreset(_ content: ExportPreset, name: String) async throws(ApplicationError) -> CatalogPresetSummary
    /// 在 Inspector 里编辑预设本身后保存：用完整内容替换库里同 ID 的预设。分组不变（D-81）；内置预设只读。
    func replacePreset(_ content: ExportPreset) async throws(ApplicationError) -> CatalogPresetSummary
    /// 素材内容文件，只给界面显示缩略图用；找不到时为 nil。
    func assetContentURL(_ id: UUID) async -> URL?
}

extension LocalPhotoFrameService: PresetContentService {
    public func savePreset(_ content: ExportPreset, name: String) async throws(ApplicationError) -> CatalogPresetSummary {
        do {
            return librarySummary(try library.presets.create(name: name, from: content))
        } catch {
            throw ApplicationError(error)
        }
    }

    public func replacePreset(_ content: ExportPreset) async throws(ApplicationError) -> CatalogPresetSummary {
        do {
            return librarySummary(try library.presets.update(content))
        } catch {
            throw ApplicationError(error)
        }
    }

    public nonisolated func assetContentURL(_ id: UUID) async -> URL? { library.assets.contentURL(for: id) }

    private nonisolated func librarySummary(_ entry: PresetEntry) -> CatalogPresetSummary {
        CatalogPresetSummary(CatalogPreset(entry), catalog: library.presets.platforms)
    }
}
