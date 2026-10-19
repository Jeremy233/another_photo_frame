import Foundation

/// 预设内容校验发现的问题。
public struct PresetIssue: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Severity: String, Hashable, Sendable, Codable {
        /// 阻止导入或输出。
        case error
        /// 可以继续，但需要让用户看到。
        case warning
    }

    public var severity: Severity
    /// 稳定的机器可读错误码，例如 `preset.duplicate_layer_id`。
    public var code: String
    /// 出问题的字段路径，例如 `layers[2].slotId`。
    public var path: String
    public var message: String

    public init(_ severity: Severity, code: String, path: String, message: String) {
        self.severity = severity
        self.code = code
        self.path = path
        self.message = message
    }

    public var description: String { "[\(severity.rawValue)] \(code) @ \(path): \(message)" }
}

extension ExportPreset {
    /// 像素量（画布、图层尺寸与偏移、文字字号、字间距、内边距）的上限，与素材单边上限（D-85）和图层绘制上限相同。
    /// 更大的值不会有用，只会让版式计算溢出或分配巨量内存。
    public static let maxPixelExtent = 16384
    /// 手动切片张数的上限：远高于各平台的轮播上限（≤ 35），防止版式一次排出海量切片。
    public static let maxTileCount = 1000
    /// 行距（字号的倍数）上限。
    public static let maxLineHeight = 100.0

    /// ID（layerId、slotId）允许的字符：字母、数字、`.`、`_`、`-`，1…64 个字符。
    public static func isValidIdentifier(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-")
        }
    }

    /// 校验字段取值与相互引用。不检查平台限制（见 ``PlatformProfile/check(_:)``）。
    public func validate() -> [PresetIssue] {
        var issues: [PresetIssue] = []
        func error(_ code: String, _ path: String, _ message: String) {
            issues.append(PresetIssue(.error, code: "preset.\(code)", path: path, message: message))
        }
        func warning(_ code: String, _ path: String, _ message: String) {
            issues.append(PresetIssue(.warning, code: "preset.\(code)", path: path, message: message))
        }
        func checkColor(_ color: PresetColor, _ path: String) {
            if !color.isValidHex { error("invalid_color", "\(path).hex", "颜色应为 #RRGGBB：\(color.hex)") }
            if color.colorSpace != "sRGB" {
                error("unsupported_color_space", "\(path).colorSpace", "目前只支持 sRGB 颜色：\(color.colorSpace)")
            }
        }

        if schemaVersion != PresetSchema.currentVersion {
            error("schema_version_mismatch", "schemaVersion", "内存中的预设应为当前版本 \(PresetSchema.currentVersion)：\(schemaVersion)")
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error("empty_name", "name", "预设名称不能为空")
        } else if name.count > 200 {
            error("name_too_long", "name", "预设名称不能超过 200 个字符")
        }

        // 画布
        if canvas.width <= 0 || canvas.height <= 0 {
            error("invalid_canvas_size", "canvas", "画布尺寸必须为正：\(canvas.width)×\(canvas.height)")
        } else if canvas.width > Self.maxPixelExtent || canvas.height > Self.maxPixelExtent {
            error("invalid_canvas_size", "canvas", "画布单边不能超过 \(Self.maxPixelExtent) px：\(canvas.width)×\(canvas.height)")
        }
        // 写成 m ≥ L − m 而不是 2m ≥ L：边距极大时 2m 会溢出。
        if canvas.minMarginPx < 0 {
            error("invalid_margin", "canvas.minMarginPx", "边距不能为负：\(canvas.minMarginPx)")
        } else if canvas.width > 0, canvas.height > 0,
                  canvas.minMarginPx >= min(canvas.width, canvas.height) - canvas.minMarginPx {
            error("margin_too_large", "canvas.minMarginPx", "边距 \(canvas.minMarginPx) px 对画布过大")
        }
        checkColor(canvas.background, "canvas.background")
        if let crop = canvas.crop {
            if let r = crop.aspectRatio, !(r.first > 0 && r.second > 0 && r.first.isFinite && r.second.isFinite) {
                error("invalid_crop", "canvas.crop.aspectRatio", "裁切比例必须为正")
            }
            if !(0...1).contains(crop.anchor.first) || !(0...1).contains(crop.anchor.second) {
                error("invalid_crop", "canvas.crop.anchor", "裁切位置必须在 0…1 之间")
            }
        }

        // 全景
        if case .fixed(let n) = panorama.tileCount, n < 1 {
            error("invalid_tile_count", "panorama.tileCount", "切片张数必须 ≥ 1：\(n)")
        } else if case .fixed(let n) = panorama.tileCount, n > Self.maxTileCount {
            error("invalid_tile_count", "panorama.tileCount", "切片张数不能超过 \(Self.maxTileCount)：\(n)")
        }
        if panorama.verticalMarginPx < 0
            || (canvas.height > 0 && panorama.verticalMarginPx >= canvas.height - panorama.verticalMarginPx) {
            error("invalid_vertical_margin", "panorama.verticalMarginPx", "切片上下边距无效：\(panorama.verticalMarginPx)")
        }
        if case .color(let c) = panorama.padColor { checkColor(c, "panorama.padColor") }

        // 素材槽
        var slotIds = Set<String>()
        for (i, slot) in assetSlots.enumerated() {
            let path = "assetSlots[\(i)]"
            if !Self.isValidIdentifier(slot.slotId) {
                error("invalid_id", "\(path).slotId", "slotId 只能包含字母、数字、. _ -，长度 1…64：\(slot.slotId)")
            }
            if !slotIds.insert(slot.slotId).inserted {
                error("duplicate_slot_id", "\(path).slotId", "slotId 重复：\(slot.slotId)")
            }
            if slot.acceptedFormats.isEmpty {
                error("invalid_slot", "\(path).acceptedFormats", "至少要接受一种素材格式")
            }
        }

        // 图层
        var layerIds = Set<String>()
        var usedSlots = Set<String>()
        for (i, layer) in layers.enumerated() {
            let path = "layers[\(i)]"
            if !Self.isValidIdentifier(layer.layerId) {
                error("invalid_id", "\(path).layerId", "layerId 只能包含字母、数字、. _ -，长度 1…64：\(layer.layerId)")
            }
            if !layerIds.insert(layer.layerId).inserted {
                error("duplicate_layer_id", "\(path).layerId", "layerId 重复：\(layer.layerId)")
            }
            if !(0...1).contains(layer.opacity) {
                error("invalid_opacity", "\(path).opacity", "不透明度必须在 0…1 之间：\(layer.opacity)")
            }
            for (field, size) in [("sizePx", layer.sizePx), ("maxBoundsPx", layer.maxBoundsPx)] {
                guard let size else { continue }
                if !size.isPositive {
                    error("invalid_size", "\(path).\(field)", "尺寸必须为正")
                } else if size.width > Self.maxPixelExtent || size.height > Self.maxPixelExtent {
                    error("invalid_size", "\(path).\(field)", "尺寸不能超过 \(Self.maxPixelExtent) px")
                }
            }
            if abs(Double(layer.offset.x)) > Double(Self.maxPixelExtent) || abs(Double(layer.offset.y)) > Double(Self.maxPixelExtent) {
                error("invalid_offset", "\(path).offsetPx", "偏移不能超过 ±\(Self.maxPixelExtent) px")
            }
            if layer.anchor == .center, layer.reference == .photo(.outside) {
                error("center_anchor_outside", "\(path).anchor", "居中锚点不能放在照片外侧；请改为内侧或选择其他锚点")
            }
            if case .selectedSlides(let pages) = layer.visibility {
                if pages.isEmpty {
                    error("invalid_slides", "\(path).slides", "visibleOn 为 selectedSlides 时须列出页面")
                } else if pages.contains(where: { $0 < 0 }) {
                    error("invalid_slides", "\(path).slides", "页码不能为负")
                }
            }
            if layer.type.usesAssetSlot {
                if let slotId = layer.slotId {
                    usedSlots.insert(slotId)
                    if !assetSlots.contains(where: { $0.slotId == slotId }) {
                        error("unknown_slot_reference", "\(path).slotId", "装饰引用了不存在的素材槽：\(slotId)")
                    }
                } else if layer.cameraMatch.isEmpty {
                    error("missing_slot_reference", "\(path).slotId", "\(layer.type.rawValue) 装饰必须指定 slotId 或 cameraMatch")
                }
            } else if layer.slotId != nil {
                warning("ignored_field", "\(path).slotId", "\(layer.type.rawValue) 装饰不使用 slotId")
            }
            if !layer.type.usesAssetSlot, !layer.cameraMatch.isEmpty {
                warning("ignored_field", "\(path).cameraMatch", "\(layer.type.rawValue) 装饰不使用 cameraMatch")
            }
            for (j, rule) in layer.cameraMatch.enumerated() where layer.type.usesAssetSlot {
                let rulePath = "\(path).cameraMatch[\(j)]"
                usedSlots.insert(rule.slotId)
                if (rule.make ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                   (rule.model ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    error("invalid_camera_match", rulePath, "相机匹配规则至少要写 make 或 model")
                }
                if !assetSlots.contains(where: { $0.slotId == rule.slotId }) {
                    error("unknown_slot_reference", "\(rulePath).slotId", "相机匹配规则引用了不存在的素材槽：\(rule.slotId)")
                }
            }
            if layer.type.usesText {
                if let text = layer.text {
                    let limit = Double(Self.maxPixelExtent)
                    if !(text.fontSizePx > 0) {
                        error("invalid_text", "\(path).text.fontSizePx", "字号必须为正")
                    } else if !(text.fontSizePx <= limit) {
                        error("invalid_text", "\(path).text.fontSizePx", "字号不能超过 \(Self.maxPixelExtent) px")
                    }
                    if !(text.lineHeight > 0) {
                        error("invalid_text", "\(path).text.lineHeight", "行距必须为正")
                    } else if !(text.lineHeight <= Self.maxLineHeight) {
                        error("invalid_text", "\(path).text.lineHeight", "行距不能超过字号的 \(Int(Self.maxLineHeight)) 倍")
                    }
                    if !text.letterSpacingPx.isFinite || abs(text.letterSpacingPx) > limit {
                        error("invalid_text", "\(path).text.letterSpacingPx", "字间距无效")
                    }
                    if text.paddingPx < 0 {
                        error("invalid_text", "\(path).text.paddingPx", "内边距不能为负")
                    } else if text.paddingPx > Self.maxPixelExtent {
                        error("invalid_text", "\(path).text.paddingPx", "内边距不能超过 \(Self.maxPixelExtent) px")
                    }
                    checkColor(text.color, "\(path).text.color")
                } else {
                    warning("empty_text", "\(path).text", "文字装饰没有内容")
                }
            }
        }
        for (i, slot) in assetSlots.enumerated() where !usedSlots.contains(slot.slotId) {
            warning("unused_slot", "assetSlots[\(i)]", "素材槽没有被任何装饰使用：\(slot.slotId)")
        }

        // 输出
        if !(1...100).contains(output.quality) {
            error("invalid_quality", "output.quality", "质量必须在 1…100 之间：\(output.quality)")
        }
        if output.colorSpace != "sRGB" {
            error("unsupported_color_space", "output.colorSpace", "目前只支持输出 sRGB：\(output.colorSpace)")
        }
        return issues
    }
}

extension Array where Element == PresetIssue {
    public var errors: [PresetIssue] { filter { $0.severity == .error } }
    public var warnings: [PresetIssue] { filter { $0.severity == .warning } }
}
