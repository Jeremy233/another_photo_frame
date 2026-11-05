import Foundation

/// 内置的相机品牌 logo 和胶卷图标（D-131）。
///
/// 源文件和清单在仓库 `resources/`；`resources/generate_swift.py` 把它们生成到 `BuiltInWatermarkData.swift`，
/// 编译进程序（同 D-126），单独复制出来的 `photoframe` 也能用。logo、品牌名和胶卷名是各公司的商标，不在 GPL 范围内。
public enum BuiltInWatermarks {
    /// 一个相机品牌（`resources/cameras/brands.json` 的一项）。
    public struct Brand: Hashable, Sendable, Codable, Identifiable {
        public enum Kind: String, Hashable, Sendable, Codable {
            /// 单色字标：没有自己的颜色，按画布深浅用黑或白。
            case mono
            /// 彩色字标：原色时用自己的颜色，「自动」「自定」时整个变成一种颜色。
            case color
            /// 标志：不跟着变色。
            case emblem
        }

        /// 各种版本的文件，路径相对 `resources/cameras/`。
        public struct Files: Hashable, Sendable, Codable {
            /// 主文件。
            public var logo: String
            /// 另一种样式（Nikon 的标志）。
            public var alt: String?
            /// 单色版（Kodak）：标志在「自定」颜色时用。
            public var mono: String?
            /// 深色画布用的白字版。
            public var dark: String?
        }

        public var id: String
        /// 界面上的品牌名。
        public var name: String
        /// `{brand}` 的文字，大小写照 logo 写（D-133）。
        public var text: String
        public var kind: Kind
        /// 主文件的宽高比。
        public var ratio: Double
        /// EXIF 品牌或型号里含这些字（不分大小写）就认成这个品牌。
        public var match: [String]
        /// 经典品牌（左栏分组用）。
        public var classic: Bool
        public var altKind: Kind?
        public var altRatio: Double?
        public var monoRatio: Double?
        public var files: Files
    }

    /// 一种胶卷（`resources/films/films.json` 的一项）。
    public struct Film: Hashable, Sendable, Codable, Identifiable {
        /// 胶卷名，源图里填的胶卷按它匹配。
        public var name: String
        public var id: String
        /// 胶片厂（文件夹名）。
        public var maker: String
        /// 冲洗工艺，目前不画在图标上。
        public var process: String
        /// 图标文件，路径相对 `resources/films/`。
        public var icon: String
    }

    public static let brands: [Brand] = decodeManifest(brandsJSON)
    public static let films: [Film] = decodeManifest(filmsJSON)

    private static func decodeManifest<T: Decodable>(_ json: String) -> [T] {
        do { return try JSONDecoder().decode([T].self, from: Data(json.utf8)) } catch {
            preconditionFailure("内置素材清单无法解析，请重新运行 resources/generate_swift.py：\(error)")
        }
    }

    public static func brand(id: String) -> Brand? { brands.first { $0.id == id } }
    public static func film(id: String) -> Film? { films.first { $0.id == id } }

    /// 按相机品牌和型号认出品牌（D-132）：品牌或型号里含 `match` 的字就算，不分大小写；
    /// 同时匹配几个品牌时取匹配词最长的（KONICA MINOLTA 不会认成 Konica；理光出的 PENTAX 机身认成 Pentax）。
    public static func brand(make: String?, model: String?) -> Brand? {
        let haystack = [make, model].compactMap { $0 }.joined(separator: " ").lowercased()
        guard !haystack.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var best: (brand: Brand, length: Int)?
        for brand in brands {
            for word in brand.match where haystack.contains(word.lowercased()) {
                if word.count > (best?.length ?? 0) { best = (brand, word.count) }
            }
        }
        return best?.brand
    }

    /// 胶卷名比较时只看字母和数字、不分大小写，开头的 Kodak Professional 当作 Kodak（D-134）。
    public static func normalizedFilmName(_ name: String) -> String {
        let folded = name.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        let key = String(String.UnicodeScalarView(folded))
        return key.hasPrefix("kodakprofessional") ? "kodak" + key.dropFirst("kodakprofessional".count) : key
    }

    /// 源图填的胶卷对应的内置胶卷；没有图标的胶卷返回 nil。
    public static func film(named name: String) -> Film? {
        let key = normalizedFilmName(name)
        guard !key.isEmpty else { return nil }
        return films.first { normalizedFilmName($0.name) == key }
    }

    /// 胶片厂（``Film/maker``，文件夹名，全小写）在界面上的写法：照这个厂的胶卷名开头怎么写（`CineStill 400D` → CineStill），
    /// 不另记一张表；没有这个厂的胶卷时首字母大写。
    public static func makerName(_ maker: String) -> String {
        for film in films where film.maker == maker && film.name.lowercased().hasPrefix(maker.lowercased()) {
            return String(film.name.prefix(maker.count))
        }
        return maker.capitalized
    }

    /// 胶卷名以某个内置品牌开头时的品牌（胶卷没有图标时用它的 logo，D-134）。
    public static func filmBrand(forFilmName name: String) -> Brand? {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lower.isEmpty else { return nil }
        return brands.first { brand in brand.match.contains { lower.hasPrefix($0.lowercased()) } }
    }

    /// 品牌文件的内容，`file` 是 ``Brand/Files`` 里的路径。
    public static func brandFileData(_ file: String) -> Data? { fileData("cameras/" + file) }
    /// 胶卷图标的内容。
    public static func iconData(for film: Film) -> Data? { fileData("films/" + film.icon) }
}
