/// 平台能力描述（§5.4、D-17、D-18）。
///
/// 第三方平台的规则会变，所以这些值是**可更新的数据**（随应用附带一份 JSON，可被用户目录中的新版本覆盖），
/// 不是永久常数。上传前仍须以平台实机预览为准。
public struct PlatformProfile: Hashable, Sendable, Codable, Identifiable {
    public enum HDRStatus: String, Hashable, Sendable, Codable {
        /// 已确认上传后 HDR 效果正常。
        case supported
        /// 提供 HDR 选项，但上传效果尚待用户实测（D-17：小红书、抖音）。
        case pendingVerification
        case unsupported
    }

    /// HDR 输出的编码方式。
    public enum HDRFormat: String, Hashable, Sendable, Codable {
        /// SDR 底图 + ISO 21496-1 gain map 的 JPEG。
        case jpegGainMap
    }

    public struct HDRSupport: Hashable, Sendable, Codable {
        public var status: HDRStatus
        /// 选择 HDR 输出时使用的格式，按优先级排列。
        public var formats: [HDRFormat]
        public var note: String?

        public init(status: HDRStatus, formats: [HDRFormat], note: String? = nil) {
            self.status = status
            self.formats = formats
            self.note = note
        }
    }

    public var platformId: String
    public var displayName: String
    /// 单图 / 封面画布。
    public var standardCanvas: PixelSize
    /// 全景切片尺寸。
    public var panoramaTile: PixelSize
    /// 一组轮播最多几张（包括封面）。
    public var maxCarouselItems: Int
    /// 可上传的 SDR 输出格式。
    public var outputFormats: [OutputSettings.Format]
    public var hdr: HDRSupport
    /// 平台单文件体积上限；未知时为 nil。
    public var maxFileSizeBytes: Int?
    /// 数据来源与核实状态等说明。
    public var notes: String?

    public var id: String { platformId }

    public init(
        platformId: String, displayName: String,
        standardCanvas: PixelSize, panoramaTile: PixelSize,
        maxCarouselItems: Int, outputFormats: [OutputSettings.Format],
        hdr: HDRSupport, maxFileSizeBytes: Int? = nil, notes: String? = nil
    ) {
        self.platformId = platformId
        self.displayName = displayName
        self.standardCanvas = standardCanvas
        self.panoramaTile = panoramaTile
        self.maxCarouselItems = maxCarouselItems
        self.outputFormats = outputFormats
        self.hdr = hdr
        self.maxFileSizeBytes = maxFileSizeBytes
        self.notes = notes
    }

    /// 预设在该平台上的兼容性问题（输出格式、HDR）。
    public func check(_ preset: ExportPreset) -> [PresetIssue] {
        var issues: [PresetIssue] = []
        if !outputFormats.contains(preset.output.format) {
            issues.append(PresetIssue(
                .error, code: "platform.unsupported_format", path: "output.format",
                message: "\(displayName) 不支持输出 \(preset.output.format.rawValue)"))
        }
        if preset.output.dynamicRange == .hdr {
            switch hdr.status {
            case .supported:
                break
            case .pendingVerification:
                issues.append(PresetIssue(
                    .warning, code: "platform.hdr_unverified", path: "output.dynamicRange",
                    message: "\(displayName) 的 HDR 上传效果尚待实测"))
            case .unsupported:
                issues.append(PresetIssue(
                    .error, code: "platform.hdr_unsupported", path: "output.dynamicRange",
                    message: "\(displayName) 不支持 HDR 输出"))
            }
        }
        return issues
    }
}

/// 一组平台配置。`revision` 递增表示数据更新，用来决定用户目录中的覆盖文件是否比内置的新。
public struct PlatformCatalog: Hashable, Sendable, Codable {
    public var revision: Int
    /// 数据最后核对日期，例如 `2026-10-16`。
    public var updatedAt: String
    public var platforms: [PlatformProfile]

    public init(revision: Int, updatedAt: String, platforms: [PlatformProfile]) {
        self.revision = revision
        self.updatedAt = updatedAt
        self.platforms = platforms
    }

    public func profile(id: String) -> PlatformProfile? {
        platforms.first { $0.platformId == id }
    }
}
