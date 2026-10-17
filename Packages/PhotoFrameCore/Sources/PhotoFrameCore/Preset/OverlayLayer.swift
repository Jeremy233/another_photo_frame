/// 一个排版图层的存储形式（§7.1、D-23）。拖动图层时修改的就是这些可序列化参数。
///
/// 定位用的类型（``OverlayAnchor``、``OverlayReference``、``OverlayOffset``、``OverlayVisibility``）
/// 与几何计算共用；渲染前用 ``geometry(contentSize:)`` 转成 ``OverlayGeometry``，再交给 ``OverlayPlacement`` 计算位置。
///
/// JSON 字段：`layerId`、`type`、`enabled`、`visibleOn`、`slides`、`anchor`、`reference`、`side`、
/// `offsetPx`、`sizePx`、`maxBoundsPx`、`opacity`、`zIndex`、`slotId`、`text`（D-25、D-41）、`cameraMatch`（D-111）。
public struct OverlayLayer: Hashable, Sendable, Codable {
    public enum LayerType: String, Hashable, Sendable, Codable, CaseIterable {
        case text, asset, metadataText, cameraBadge

        /// 是否需要通过 `slotId` 绑定本地素材。
        public var usesAssetSlot: Bool { self == .asset || self == .cameraBadge }
        /// 是否有文本内容。
        public var usesText: Bool { self == .text || self == .metadataText }
    }

    public var layerId: String
    public var type: LayerType
    public var enabled: Bool
    /// 显示在哪些页。页码是轮播位置：0 = 封面，切片 k 是第 k + 1 页（D-27）。
    public var visibility: OverlayVisibility
    public var anchor: OverlayAnchor
    /// 参照物与内外侧（D-41）。默认照片外侧，即留白区域（D-12）。
    public var reference: OverlayReference
    /// 偏移（px），正负号约定见 ``OverlayOffset``（D-42）。
    public var offset: OverlayOffset
    /// 固定尺寸（D-45：固定像素，不随画布缩放）。
    public var sizePx: PixelSize?
    /// 没有固定尺寸时，内容（素材或排版后的文字）超过此尺寸则等比缩小。
    public var maxBoundsPx: PixelSize?
    public var opacity: Double
    public var zIndex: Int
    /// `asset` / `cameraBadge` 图层绑定的素材槽；有 `cameraMatch` 时是匹配不到时的默认素材。
    public var slotId: String?
    /// 按 EXIF 相机品牌 / 型号改用别的素材槽（D-111，只用于素材图层）。旧预设没有这个字段时为空。
    public var cameraMatch: [CameraMatchRule]
    /// `text` / `metadataText` 图层的文字与样式。
    public var text: TextStyle?
    public var extensions: ExtensionFields

    public init(
        layerId: String,
        type: LayerType,
        enabled: Bool = true,
        visibility: OverlayVisibility = .coverOnly,
        anchor: OverlayAnchor = .bottomRight,
        reference: OverlayReference = .default,
        offset: OverlayOffset = .zero,
        sizePx: PixelSize? = nil,
        maxBoundsPx: PixelSize? = nil,
        opacity: Double = 1,
        zIndex: Int = 0,
        slotId: String? = nil,
        cameraMatch: [CameraMatchRule] = [],
        text: TextStyle? = nil,
        extensions: ExtensionFields = [:]
    ) {
        self.layerId = layerId
        self.type = type
        self.enabled = enabled
        self.visibility = visibility
        self.anchor = anchor
        self.reference = reference
        self.offset = offset
        self.sizePx = sizePx
        self.maxBoundsPx = maxBoundsPx
        self.opacity = opacity
        self.zIndex = zIndex
        self.slotId = slotId
        self.cameraMatch = cameraMatch
        self.text = text
        self.extensions = extensions
    }

    /// 转成几何参数。
    ///
    /// - 有 `sizePx` 时用固定尺寸。
    /// - 否则需要 `contentSize`（素材像素或排版后的文字框）：有 `maxBoundsPx` 时超出则等比缩小，没有时原样使用。
    public func geometry(contentSize: PixelSize? = nil) throws(OverlayError) -> OverlayGeometry {
        let size: OverlaySize
        if let sizePx {
            size = .fixed(sizePx)
        } else if let contentSize {
            size = maxBoundsPx.map { .fitting(contentSize, maximum: $0) } ?? .fixed(contentSize)
        } else {
            throw .missingSize
        }
        return OverlayGeometry(anchor: anchor, reference: reference, offset: offset, size: size, visibility: visibility)
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey, CaseIterable {
        case layerId, type, enabled, visibleOn, slides, anchor, reference, side
        case offsetPx, sizePx, maxBoundsPx, opacity, zIndex, slotId, cameraMatch, text
    }

    enum VisibleOn: String, Codable {
        case coverOnly, allSlides, selectedSlides
    }

    enum ReferenceName: String, Codable {
        case photo, canvas
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layerId = try c.decode(String.self, forKey: .layerId)
        type = try c.decode(LayerType.self, forKey: .type)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true

        let visibleOn = try c.decodeIfPresent(VisibleOn.self, forKey: .visibleOn) ?? .coverOnly
        let slides = try c.decodeIfPresent([Int].self, forKey: .slides)
        switch visibleOn {
        case .coverOnly: visibility = .coverOnly
        case .allSlides: visibility = .allSlides
        case .selectedSlides: visibility = .selectedSlides(Set(slides ?? []))
        }
        if visibleOn != .selectedSlides, slides != nil {
            throw DecodingError.dataCorruptedError(
                forKey: .slides, in: c, debugDescription: "只有 visibleOn 为 selectedSlides 时才能写 slides")
        }

        anchor = try c.decodeIfPresent(OverlayAnchor.self, forKey: .anchor) ?? .bottomRight
        let referenceName = try c.decodeIfPresent(ReferenceName.self, forKey: .reference) ?? .photo
        let side = try c.decodeIfPresent(OverlaySide.self, forKey: .side)
        switch referenceName {
        case .photo:
            reference = .photo(side ?? .outside)
        case .canvas:
            if side != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .side, in: c, debugDescription: "以画布为参照时不能写 side（图层总在画布内侧）")
            }
            reference = .canvas
        }

        let offsetPair = try c.decodeIfPresent(Pair<Int>.self, forKey: .offsetPx) ?? Pair(0, 0)
        offset = OverlayOffset(x: offsetPair.first, y: offsetPair.second)
        sizePx = try c.decodeIfPresent(Pair<Int>.self, forKey: .sizePx).map { PixelSize(width: $0.first, height: $0.second) }
        maxBoundsPx = try c.decodeIfPresent(Pair<Int>.self, forKey: .maxBoundsPx).map { PixelSize(width: $0.first, height: $0.second) }
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        zIndex = try c.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        slotId = try c.decodeIfPresent(String.self, forKey: .slotId)
        cameraMatch = try c.decodeIfPresent([CameraMatchRule].self, forKey: .cameraMatch) ?? []
        text = try c.decodeIfPresent(TextStyle.self, forKey: .text)
        extensions = try ExtraFieldsCoding.decode(from: decoder, known: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(layerId, forKey: .layerId)
        try c.encode(type, forKey: .type)
        try c.encode(enabled, forKey: .enabled)
        switch visibility {
        case .coverOnly: try c.encode(VisibleOn.coverOnly, forKey: .visibleOn)
        case .allSlides: try c.encode(VisibleOn.allSlides, forKey: .visibleOn)
        case .selectedSlides(let pages):
            try c.encode(VisibleOn.selectedSlides, forKey: .visibleOn)
            try c.encode(pages.sorted(), forKey: .slides)
        }
        try c.encode(anchor, forKey: .anchor)
        switch reference {
        case .photo(let side):
            try c.encode(ReferenceName.photo, forKey: .reference)
            try c.encode(side, forKey: .side)
        case .canvas:
            try c.encode(ReferenceName.canvas, forKey: .reference)
        }
        try c.encode(Pair(offset.x, offset.y), forKey: .offsetPx)
        try c.encodeIfPresent(sizePx.map { Pair($0.width, $0.height) }, forKey: .sizePx)
        try c.encodeIfPresent(maxBoundsPx.map { Pair($0.width, $0.height) }, forKey: .maxBoundsPx)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(zIndex, forKey: .zIndex)
        try c.encodeIfPresent(slotId, forKey: .slotId)
        if !cameraMatch.isEmpty { try c.encode(cameraMatch, forKey: .cameraMatch) }
        try c.encodeIfPresent(text, forKey: .text)
        try ExtraFieldsCoding.encode(extensions, known: CodingKeys.self, to: encoder)
    }
}
