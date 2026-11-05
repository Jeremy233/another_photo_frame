import Foundation
import Testing
@testable import PhotoFrameStorage

/// D-131–D-134：内置品牌 logo 和胶卷图标。
@Suite("内置品牌 logo 与胶卷图标（D-131）")
struct BuiltInWatermarksTests {
    /// 仓库里的 resources/。
    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("resources")

    @Test("生成的 Swift 数据和 resources/ 一致（改了 resources/ 要重新运行 generate_swift.py）")
    func generatedDataIsCurrent() throws {
        let brands = try JSONDecoder().decode([BuiltInWatermarks.Brand].self,
                                              from: Data(contentsOf: Self.resources.appendingPathComponent("cameras/brands.json")))
        let films = try JSONDecoder().decode([BuiltInWatermarks.Film].self,
                                             from: Data(contentsOf: Self.resources.appendingPathComponent("films/films.json")))
        #expect(brands == BuiltInWatermarks.brands)
        #expect(films == BuiltInWatermarks.films)
        for path in BuiltInWatermarks.filePaths {
            let original = try Data(contentsOf: Self.resources.appendingPathComponent(path))
            let embedded = try #require(BuiltInWatermarks.fileData(path), "\(path)")
            if path.hasSuffix(".svg") {
                let folded = String(decoding: original, as: UTF8.self).map { $0.isASCII && ($0.asciiValue ?? 32) < 32 ? " " : String($0) }.joined()
                #expect(String(decoding: embedded, as: UTF8.self) == folded, "\(path)")
            } else {
                #expect(embedded == original, "\(path)")
            }
        }
    }

    @Test("每个品牌、每种胶卷的文件都在；30 个品牌、29 种胶卷")
    func everyFileIsEmbedded() {
        #expect(BuiltInWatermarks.brands.count == 30 && BuiltInWatermarks.films.count == 29)
        for brand in BuiltInWatermarks.brands {
            for file in [brand.files.logo, brand.files.alt, brand.files.mono, brand.files.dark].compactMap({ $0 }) {
                #expect(BuiltInWatermarks.brandFileData(file) != nil, "\(brand.id): \(file)")
            }
            #expect(brand.ratio > 0 && !brand.match.isEmpty && !brand.text.isEmpty, "\(brand.id)")
        }
        for film in BuiltInWatermarks.films {
            #expect(BuiltInWatermarks.iconData(for: film) != nil, "\(film.id)")
        }
    }

    @Test("按 EXIF 认品牌：包含、不分大小写，取匹配词最长的")
    func brandMatching() {
        func id(_ make: String?, _ model: String? = nil) -> String? { BuiltInWatermarks.brand(make: make, model: model)?.id }
        #expect(id("NIKON CORPORATION", "NIKON Z 8") == "nikon")
        #expect(id("Canon", "Canon EOS R5") == "canon")
        #expect(id("RICOH IMAGING COMPANY, LTD.", "PENTAX K-3 Mark III") == "pentax")
        #expect(id("RICOH IMAGING COMPANY, LTD.", "RICOH GR III") == "ricoh")
        #expect(id("KONICA MINOLTA", "DiMAGE A2") == "konicaminolta")
        #expect(id("Minolta Co., Ltd.", "DiMAGE 7") == "minolta")
        #expect(id("OM Digital Solutions", "OM-1") == "om")
        #expect(id("FUJIFILM", "X-T5") == "fujifilm")
        #expect(id(nil, "Makina 67") == "plaubel")
        #expect(id("GoPro", "HERO12") == nil)
        #expect(id(nil, nil) == nil && id("  ") == nil)
    }

    @Test("胶卷名只比字母和数字；Kodak Professional 当作 Kodak；胶卷品牌按名字开头")
    func filmMatching() {
        #expect(BuiltInWatermarks.film(named: "kodak portra-400")?.id == "kodak-portra-400")
        #expect(BuiltInWatermarks.film(named: "Kodak Professional Portra 400")?.id == "kodak-portra-400")
        #expect(BuiltInWatermarks.film(named: "FUJIFILM PRO 400H")?.id == "fujifilm-pro-400h")
        #expect(BuiltInWatermarks.film(named: "Kodak Portra 400 (pushed)") == nil)
        #expect(BuiltInWatermarks.film(named: "") == nil)
        #expect(BuiltInWatermarks.filmBrand(forFilmName: "Kodak Vision3 50D")?.id == "kodak")
        #expect(BuiltInWatermarks.filmBrand(forFilmName: "Fujifilm Superia 200")?.id == "fujifilm")
        #expect(BuiltInWatermarks.filmBrand(forFilmName: "Ilford Pan F") == nil)
    }
}
