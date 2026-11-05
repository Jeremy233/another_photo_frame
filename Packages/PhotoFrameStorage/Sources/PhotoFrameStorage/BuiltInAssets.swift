import CryptoKit
import Foundation
import PhotoFrameCore

/// 内置的品牌 logo 和胶卷图标作为素材（D-136、D-139）：左栏「素材 › 内置」里的每一项，也能绑定到素材槽。
///
/// 每一项有固定的素材 ID（由文件路径算出，以后不变），所以单任务、预设本地、用户默认绑定都可以指向它，
/// 和导入的素材一样存、一样解析。内容不在素材库里，从程序自带的数据读；渲染器认 ``contentURL`` 的 scheme，
/// 按受信任的 SVG 解析（D-137）。
public struct BuiltInAsset: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// 品牌 logo；`emblem` 是同时有字标和标志的品牌（Nikon）的标志。
        case logo(brandId: String, emblem: Bool)
        case film(id: String)
    }

    public var id: UUID
    public var kind: Kind
    /// 给人看的名字：品牌名或胶卷名；Nikon 分「Nikon 字标」「Nikon 标志」。
    public var title: String
    /// 相对 `resources/` 的路径。
    public var path: String

    public var format: AssetSlot.Format { path.hasSuffix(".svg") ? .svg : .png }
    public var record: AssetRecord { AssetRecord(assetId: id, format: format, displayName: title) }
    public var data: Data? { BuiltInWatermarks.fileData(path) }
    /// 交给渲染器的地址（不是文件）：`photoframe-builtin:///cameras/nikon/nikon.svg`。
    public var contentURL: URL { URL(string: "\(Self.urlScheme):///\(path)")! }
    public var isClassicBrand: Bool {
        if case .logo(let brandId, _) = kind { return BuiltInWatermarks.brand(id: brandId)?.classic == true }
        return false
    }

    public static let urlScheme = "photoframe-builtin"

    /// 全部内置素材，按左栏的顺序：现役品牌、经典品牌（每个品牌先字标后标志）、胶卷。
    public static let all: [BuiltInAsset] = {
        let brands = BuiltInWatermarks.brands.filter { !$0.classic } + BuiltInWatermarks.brands.filter(\.classic)
        let logos = brands.flatMap { brand -> [BuiltInAsset] in
            var items = [BuiltInAsset(kind: .logo(brandId: brand.id, emblem: false),
                                      title: brand.files.alt == nil ? brand.name : "\(brand.name) 字标",
                                      path: "cameras/" + brand.files.logo)]
            if let alt = brand.files.alt {
                items.append(BuiltInAsset(kind: .logo(brandId: brand.id, emblem: true), title: "\(brand.name) 标志", path: "cameras/" + alt))
            }
            return items
        }
        let films = BuiltInWatermarks.films.map { BuiltInAsset(kind: .film(id: $0.id), title: $0.name, path: "films/" + $0.icon) }
        return logos + films
    }()

    private static let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    private static let byPath = Dictionary(all.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

    public static func asset(id: UUID) -> BuiltInAsset? { byId[id] }
    public static func asset(path: String) -> BuiltInAsset? { byPath[path] }
    /// 渲染器拿到的地址是不是内置素材；是的话给出它。
    public static func asset(contentURL url: URL) -> BuiltInAsset? {
        guard url.scheme == urlScheme else { return nil }
        return asset(path: String(url.path.drop { $0 == "/" }))
    }
    /// 每次建素材表（校验任务、解析素材槽）都要用，算一次就够了。
    public static let records: [AssetRecord] = all.map(\.record)

    init(kind: Kind, title: String, path: String) {
        self.kind = kind
        self.title = title
        self.path = path
        id = Self.stableId(path)
    }

    /// 由路径算出的固定 ID：SHA-256 的前 16 字节，标成 RFC 9562 的第 8 版（自定义）UUID。
    static func stableId(_ path: String) -> UUID {
        var b = Array(SHA256.hash(data: Data("photoframe.builtin/\(path)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x80
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
