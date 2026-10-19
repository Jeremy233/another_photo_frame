import Foundation
import PhotoFrameCore

public enum PlatformCatalogError: Error, Hashable, Sendable {
    case invalid(String)

    public var code: String {
        switch self {
        case .invalid: "platform.catalog_invalid"
        }
    }
}

/// 读取平台配置：程序内置一份（``builtInJSON``，D-126）；用户目录中可以放一份更新的覆盖文件。
public enum PlatformCatalogStore {
    /// 程序内置的平台配置。
    public static func builtIn() throws(PlatformCatalogError) -> PlatformCatalog {
        try decode(Data(builtInJSON.utf8))
    }

    public static func decode(_ data: Data) throws(PlatformCatalogError) -> PlatformCatalog {
        let catalog: PlatformCatalog
        do {
            catalog = try JSONDecoder().decode(PlatformCatalog.self, from: data)
        } catch {
            throw .invalid(String(describing: error))
        }
        let ids = catalog.platforms.map(\.platformId)
        guard Set(ids).count == ids.count else { throw .invalid("platformId 重复") }
        for p in catalog.platforms {
            guard p.standardCanvas.isPositive, p.panoramaTile.isPositive, p.maxCarouselItems >= 1, !p.outputFormats.isEmpty else {
                throw .invalid("平台 \(p.platformId) 的取值无效")
            }
        }
        return catalog
    }

    /// 内置配置与覆盖文件中 `revision` 较大的那份。覆盖文件不存在或无效时用内置配置。
    public static func load(overrideAt url: URL?) throws(PlatformCatalogError) -> PlatformCatalog {
        let bundled = try builtIn()
        guard let url, let data = try? Data(contentsOf: url), let override = try? decode(data) else { return bundled }
        return override.revision > bundled.revision ? override : bundled
    }
}
