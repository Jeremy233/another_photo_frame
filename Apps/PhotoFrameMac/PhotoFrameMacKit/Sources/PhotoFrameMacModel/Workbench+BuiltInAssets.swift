import Foundation
import PhotoFrameApplication
import PhotoFrameStorage

/// 左栏「素材」里的一个内置素材（D-136）：品牌 logo（Nikon 的字标和标志各一项）或胶卷图标。不能改名、删除。
public struct BuiltInAssetItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case logo(brandId: String, emblem: Bool)
        case film(String)
    }

    public var kind: Kind
    public var title: String
    /// 相对 `resources/` 的文件路径。
    public var path: String
    public var id: String { path }

    public var isSVG: Bool { path.hasSuffix(".svg") }
    public var data: Data? { BuiltInWatermarks.fileData(path) }
    /// 复制为自己的素材时放进哪一组。
    public var copyCategory: AssetCategory {
        if case .film = kind { return .filmIcon }
        return .cameraBadge
    }

    /// 「内置」下的品牌 logo、经典品牌 logo、胶卷图标三组（D-136、D-138）。
    public static let groups: [(title: String, items: [BuiltInAssetItem])] = {
        func logos(_ classic: Bool) -> [BuiltInAssetItem] {
            BuiltInWatermarks.brands.filter { $0.classic == classic }.flatMap { brand -> [BuiltInAssetItem] in
                var items = [BuiltInAssetItem(kind: .logo(brandId: brand.id, emblem: false),
                                              title: brand.files.alt == nil ? brand.name : "\(brand.name) 字标",
                                              path: "cameras/" + brand.files.logo)]
                if let alt = brand.files.alt {
                    items.append(BuiltInAssetItem(kind: .logo(brandId: brand.id, emblem: true), title: "\(brand.name) 标志",
                                                  path: "cameras/" + alt))
                }
                return items
            }
        }
        let films = BuiltInWatermarks.films.map { BuiltInAssetItem(kind: .film($0.id), title: $0.name, path: "films/" + $0.icon) }
        return [("品牌 logo", logos(false)), ("经典品牌 logo", logos(true)), ("胶卷图标", films)]
    }()

    /// 按路径找内置素材（左栏选中的项）。
    public static func item(path: String) -> BuiltInAssetItem? { byPath[path] }
    private static let byPath = Dictionary(groups.flatMap(\.items).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
}

/// 左栏「素材」选中的一项：自己的素材（按 ID）或内置素材（按路径）。
public enum AssetSelection: Hashable, Sendable {
    case user(UUID)
    case builtIn(String)
}

extension Workbench {
    /// 中间预览要显示的素材：左栏在「素材」、选中了一个素材，而且没有选中图片（预览为空）时才有。
    public var previewedAsset: (title: String, image: AssetSelection)? {
        guard sidebarTab == .assets, previewSubject == nil, let selection = selectedAsset else { return nil }
        switch selection {
        case .user(let id):
            return assets.first { $0.assetId == id }.map { ($0.displayName, selection) }
        case .builtIn(let path):
            return BuiltInAssetItem.item(path: path).map { ($0.title, selection) }
        }
    }
}

extension Workbench {
    /// 内置素材「复制为我的素材」：内容由界面给出（受限 SVG，或画好的 PNG），导入后可以改名、改颜色、删除。
    public func copyBuiltInAsset(_ item: BuiltInAssetItem, content: Data, isSVG: Bool) async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "BuiltInCopy-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = dir.appending(path: "\(item.title) 副本.\(isSVG ? "svg" : "png")")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: file)
        } catch {
            alert = WorkbenchAlert(title: "无法复制素材", message: error.localizedDescription)
            return
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        await importAssets([file], category: item.copyCategory)
    }
}
