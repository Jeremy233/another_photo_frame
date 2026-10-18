import Foundation
import ImageIO
import PhotoFrameCore
import PhotoFrameStorage

/// 校验结果（§11.2 `validate`、CLI `--dry-run`）：不渲染、不写任何文件，列出每个任务会输出什么、会遇到什么问题。
public struct ValidationResult: Hashable, Sendable, Codable {
    /// 每个「源图 × 预设」一项，顺序与提交时生成任务的顺序相同。
    public var items: [ValidationItem]

    public init(items: [ValidationItem]) {
        self.items = items
    }

    public var isValid: Bool { items.allSatisfy(\.errors.isEmpty) }
    public var errors: [ApplicationError] { items.flatMap(\.errors) }
}

public struct ValidationItem: Hashable, Sendable, Codable {
    public struct PlannedFile: Hashable, Sendable, Codable {
        public var role: JobOutputRole
        /// 发布后的文件名，例如 `00_Cover.jpg`。
        public var fileName: String
        public var pixelSize: PixelSize
    }

    public var sourceId: SourceID
    public var sourceURL: URL
    public var presetId: UUID
    public var presetName: String
    /// 预计发布到的作品目录。默认策略下按当前磁盘状态推算版本后缀，真正导出时可能因为别的程序同时写入而不同。
    public var directory: URL
    /// 没有图像分析器或预估失败时为空。
    public var outputs: [PlannedFile]
    public var warnings: [ApplicationWarning]
    public var errors: [ApplicationError]
}

/// 校验阶段的检查。队列的 `validating` 与服务的 `validate` 共用，结论一致。
enum ExportChecks {
    /// 源文件存在、是普通文件、可读。
    static func checkSource(_ url: URL) throws(ApplicationError) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path)
        else { throw .sourceUnreadable(url.path) }
    }

    /// 预设自身与平台能力检查。有 error 级问题时抛出，否则返回警告。
    static func checkPreset(_ preset: ExportPreset, platform: PlatformProfile?) throws(ApplicationError) -> [ApplicationWarning] {
        var issues = preset.validate()
        if let platform { issues += platform.check(preset) }
        let errors = issues.filter { $0.severity == .error }
        guard errors.isEmpty else { throw .invalidPreset(errors.map { "\($0.path)：\($0.message)" }) }
        return issues.map { ApplicationWarning(code: $0.code, message: $0.message) }
    }

    /// 输出根目录可用。`create` 为 false 时不创建，只检查最近的已存在上级目录可写（`--dry-run` 不写任何东西）。
    static func checkDestination(_ root: URL, create: Bool) throws(ApplicationError) {
        let fm = FileManager.default
        let root = root.standardizedFileURL
        if root.pathComponents.contains(AtomicExporter.stagingDirectoryName) {
            throw .destinationInsideStaging(root.path)
        }
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw .destinationUnavailable(root.path, "不是目录") }
            guard fm.isWritableFile(atPath: root.path) else { throw .destinationUnavailable(root.path, "没有写权限") }
        } else if create {
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                throw .destinationUnavailable(root.path, error.localizedDescription)
            }
        } else {
            var ancestor = root.deletingLastPathComponent()
            while !fm.fileExists(atPath: ancestor.path, isDirectory: &isDirectory), ancestor.path != "/" {
                ancestor = ancestor.deletingLastPathComponent()
            }
            guard isDirectory.boolValue else { throw .destinationUnavailable(root.path, "\(ancestor.path) 不是目录") }
            guard fm.isWritableFile(atPath: ancestor.path) else {
                throw .destinationUnavailable(root.path, "无法在 \(ancestor.path) 中创建目录")
            }
        }
    }

    /// 素材槽解析（D-14、D-28、D-29）。缺少必需素材时抛出 `slot.missing_required`。
    /// 有图层写了相机匹配规则（D-111）时读源图的 EXIF Make / Model。
    ///
    /// 预设没有启用的素材图层时，解析结果与素材库、绑定、相机都无关（只有「单任务绑定没被使用」的提示），
    /// 这时不读本地库，用空的解析器得到同样的结果。
    static func resolveSlots(
        _ resolver: inout LazySlotResolver, preset: ExportPreset, bindings: [String: UUID], source: URL
    ) throws(ApplicationError) -> (SlotResolution?, [ApplicationWarning]) {
        guard resolver.isConfigured else { return (nil, []) }
        let usesAssets = preset.layers.contains { $0.enabled && $0.type.usesAssetSlot }
        let current = usesAssets ? resolver.get() : SlotResolver(library: InMemoryAssetLibrary(), bindings: AssetBindingTable())
        return try resolveSlots(current, preset: preset, bindings: bindings, source: source)
    }

    static func resolveSlots(
        _ resolver: SlotResolver?, preset: ExportPreset, bindings: [String: UUID], source: URL
    ) throws(ApplicationError) -> (SlotResolution?, [ApplicationWarning]) {
        guard let resolver else { return (nil, []) }
        let usesCamera = preset.layers.contains { $0.enabled && !$0.cameraMatch.isEmpty }
        do {
            let slots = try resolver.resolve(preset, jobBindings: bindings, camera: usesCamera ? camera(of: source) : nil)
            return (slots, slots.warnings.map { ApplicationWarning(code: $0.code, message: $0.message) })
        } catch {
            throw ApplicationError(code: error.code, message: error.message, hint: error.hint)
        }
    }

    /// 源图的相机（TIFF Make / Model）。读不到属性时是空的相机信息。
    static func camera(of url: URL) -> CameraIdentity {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return CameraIdentity(make: nil, model: nil) }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        return CameraIdentity(make: tiff[kCGImagePropertyTIFFMake] as? String, model: tiff[kCGImagePropertyTIFFModel] as? String)
    }
}

/// 用到时才取的素材解析器：取一次就留着，同一次校验里的多个任务共用；没有素材图层的预设不触发读库。
struct LazySlotResolver {
    private let configuration: QueueConfiguration
    private var resolved: SlotResolver??

    init(_ configuration: QueueConfiguration) {
        self.configuration = configuration
    }

    /// 配置了素材来源（不读库就能知道）。
    var isConfigured: Bool { configuration.assets != nil || configuration.slotResolver != nil }

    mutating func get() -> SlotResolver? {
        if let resolved { return resolved }
        let value = configuration.currentSlotResolver()
        resolved = .some(value)
        return value
    }
}
