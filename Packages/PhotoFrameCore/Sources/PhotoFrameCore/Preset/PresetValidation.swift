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
        }
        if canvas.minMarginPx < 0 {
            error("invalid_margin", "canvas.minMarginPx", "边距不能为负：\(canvas.minMarginPx)")
        } else if canvas.width > 0, canvas.height > 0,
                  2 * canvas.minMarginPx >= min(canvas.width, canvas.height) {
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
        }
        if panorama.verticalMarginPx < 0 || (canvas.height > 0 && 2 * panorama.verticalMarginPx >= canvas.height) {
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
            if let s = layer.sizePx, !s.isPositive {
                error("invalid_size", "\(path).sizePx", "尺寸必须为正")
            }
            if let s = layer.maxBoundsPx, !s.isPositive {
                error("invalid_size", "\(path).maxBoundsPx", "尺寸必须为正")
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
                        error("unknown_slot_reference", "\(path).slotId", "图层引用了不存在的素材槽：\(slotId)")
                    }
                } else {
                    error("missing_slot_reference", "\(path).slotId", "\(layer.type.rawValue) 图层必须指定 slotId")
                }
            } else if layer.slotId != nil {
                warning("ignored_field", "\(path).slotId", "\(layer.type.rawValue) 图层不使用 slotId")
            }
            if layer.type.usesText {
                if let text = layer.text {
                    if !(text.fontSizePx > 0) { error("invalid_text", "\(path).text.fontSizePx", "字号必须为正") }
                    if !(text.lineHeight > 0) { error("invalid_text", "\(path).text.lineHeight", "行距必须为正") }
                    if text.paddingPx < 0 { error("invalid_text", "\(path).text.paddingPx", "内边距不能为负") }
                    checkColor(text.color, "\(path).text.color")
                } else {
                    warning("empty_text", "\(path).text", "文字图层没有内容")
                }
            }
        }
        for (i, slot) in assetSlots.enumerated() where !usedSlots.contains(slot.slotId) {
            warning("unused_slot", "assetSlots[\(i)]", "素材槽没有被任何图层使用：\(slot.slotId)")
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
