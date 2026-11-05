import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameStorage

/// 源图上手填的胶卷、相机与参数（D-135）。手填的值优先于 EXIF；照片没有 EXIF（胶片扫描）时靠它。
public enum SourceMetadataField: String, CaseIterable, Identifiable, Sendable {
    case film, make, model, aperture, shutter, iso
    public var id: Self { self }

    public var title: String {
        switch self {
        case .film: "胶卷"
        case .make: "相机品牌"
        case .model: "相机型号"
        case .aperture: "光圈"
        case .shutter: "快门"
        case .iso: "ISO"
        }
    }

    /// 没有 EXIF 值时输入框里的示例。
    public var example: String {
        switch self {
        case .film: "例如 Kodak Portra 400"
        case .make: "例如 Leica"
        case .model: "例如 M6"
        case .aperture: "例如 8 或 f/8"
        case .shutter: "例如 1/250"
        case .iso: "例如 400"
        }
    }

    /// 检查源图得到的 EXIF 里对应的键；胶卷没有。
    var exifKey: String? { self == .film ? nil : rawValue }
}

extension Workbench {
    /// 右栏「胶卷、相机与参数」作用的源图：选中的一张或几张源图。
    public var inspectedSourceIds: [SourceID] {
        switch inspectorSubject {
        case .source(let id): [id]
        case .sources(let ids): ids
        default: []
        }
    }

    /// 手填的值；几张源图的值不一样时是 `.mixed`，都没填时是 `.single("")`。
    public func metadataOverride(_ field: SourceMetadataField, for ids: [SourceID]) -> FieldValue<String> {
        let values = ids.compactMap { sourceItem($0) }.map { $0.metadataOverrides[field.rawValue] ?? "" }
        guard let first = values.first else { return .none }
        return values.allSatisfy { $0 == first } ? .single(first) : .mixed
    }

    /// 源图 EXIF 里的值（只看一张源图），做输入框的占位提示。
    public func exifValue(_ field: SourceMetadataField, for id: SourceID) -> String? {
        guard let key = field.exifKey else { return nil }
        return sourceItem(id)?.inspection?.metadata[key]
    }

    /// 写入手填的值（D-135）；空白表示不填、用 EXIF。选中几张源图时一起写。
    public func setMetadataOverride(_ field: SourceMetadataField, _ value: String, for ids: [SourceID]) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = ids.compactMap { id in sources.firstIndex { $0.id == id } }
            .filter { (sources[$0].metadataOverrides[field.rawValue] ?? "") != v }
        guard !targets.isEmpty else { return }
        undoable("修改\(field.title)") {
            for i in targets {
                if v.isEmpty { sources[i].metadataOverrides.removeValue(forKey: field.rawValue) }
                else { sources[i].metadataOverrides[field.rawValue] = v }
            }
        }
        scheduleValidation(targets.flatMap { sources[$0].jobs.map(\.id) })
        refreshPreview()
    }

    /// 预览的源图手填的胶卷（胶卷装饰的「当前照片」）。
    public var previewFilm: String? {
        previewSubject.flatMap { sourceItem($0.sourceId) }?.metadataOverrides[SourceMetadataField.film.rawValue]
    }

    /// 「胶卷」输入框的候选：内置的胶卷名。
    public static var builtInFilmNames: [String] { BuiltInWatermarks.films.map(\.name) }
}
