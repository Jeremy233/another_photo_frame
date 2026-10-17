import Foundation

/// 按 EXIF 相机品牌 / 型号自动选素材槽的一条规则（§7.2「智能匹配」、D-111）。写在素材图层的 `cameraMatch` 上：
///
/// ```json
/// "cameraMatch": [
///   {"make": "FUJIFILM", "model": "X100VI", "slotId": "camera.x100vi"},
///   {"make": "Nikon", "slotId": "camera.nikon"}
/// ]
/// ```
///
/// 规则只指向本预设的素材槽，不指向具体素材：预设仍可分享，接收者把这些槽绑定到自己的素材（D-24）。
public struct CameraMatchRule: Hashable, Sendable, Codable {
    /// 品牌：EXIF Make 里包含这段文字即匹配（不区分大小写，`Nikon` 匹配 `NIKON CORPORATION`）。
    public var make: String?
    /// 型号：与 EXIF Model 相同即匹配（不区分大小写；EXIF Model 开头带品牌时去掉品牌再比一次，`EOS R5` 匹配 `Canon EOS R5`）。
    public var model: String?
    public var slotId: String
    public var extensions: ExtensionFields

    public init(make: String? = nil, model: String? = nil, slotId: String, extensions: ExtensionFields = [:]) {
        self.make = make
        self.model = model
        self.slotId = slotId
        self.extensions = extensions
    }

    /// 写了的条件都满足才匹配；`make`、`model` 都没写的规则不匹配任何相机。
    public func matches(_ camera: CameraIdentity) -> Bool {
        let wantMake = make.map(Self.normalized) ?? ""
        let wantModel = model.map(Self.normalized) ?? ""
        guard !wantMake.isEmpty || !wantModel.isEmpty else { return false }
        let exifMake = Self.normalized(camera.make ?? "")
        if !wantMake.isEmpty, !exifMake.contains(wantMake) { return false }
        if !wantModel.isEmpty {
            let exifModel = Self.normalized(camera.model ?? "")
            let brand = exifMake.split(separator: " ").first.map { String($0) + " " } ?? ""
            let stripped = !brand.isEmpty && exifModel.hasPrefix(brand) ? String(exifModel.dropFirst(brand.count)) : exifModel
            if exifModel != wantModel, stripped != wantModel { return false }
        }
        return true
    }

    /// 小写、去掉首尾空白、连续空白合并成一个空格。
    static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case make, model, slotId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        make = try c.decodeIfPresent(String.self, forKey: .make)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        slotId = try c.decode(String.self, forKey: .slotId)
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(make, forKey: .make)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(slotId, forKey: .slotId)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }
}

/// 源图的相机：EXIF（TIFF）Make / Model。
public struct CameraIdentity: Hashable, Sendable, Codable {
    public var make: String?
    public var model: String?

    public init(make: String?, model: String?) {
        self.make = make
        self.model = model
    }

    public var isEmpty: Bool {
        (make ?? "").trimmingCharacters(in: .whitespaces).isEmpty && (model ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

extension OverlayLayer {
    /// 这个图层按顺序尝试的素材槽：先是匹配到的规则（写了型号的规则优先于只写品牌的，同类按数组顺序），
    /// 最后是图层自己的 `slotId`（默认素材）。去重。没有相机信息时只有 `slotId`。
    public func slotCandidates(for camera: CameraIdentity?) -> [String] {
        var ordered: [String] = []
        if let camera, !camera.isEmpty {
            let matched = cameraMatch.filter { $0.matches(camera) }
            let withModel = matched.filter { !($0.model ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            let makeOnly = matched.filter { ($0.model ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            ordered = (withModel + makeOnly).map(\.slotId)
        }
        if let slotId { ordered.append(slotId) }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }
    }
}
