import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameRendering

/// 顶栏中间的三个界面（UI 设计文档第 2 节）。
public enum WorkbenchMode: String, CaseIterable, Identifiable, Sendable {
    case current, active, completed
    public var id: Self { self }
}

/// 左栏的三个标签（第 4 节）。
public enum SidebarTab: String, CaseIterable, Identifiable, Sendable {
    case presets, locations, assets
    public var id: Self { self }
}

/// 素材列表的显示方式（第 7.3 节）。
public enum AssetDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case text, icons
    public var id: Self { self }
}

/// 右栏的四个标签（第 6 节）。
public enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    case canvas, panorama, layers, output
    public var id: Self { self }
}

/// 「当前」界面里的一张源图，以及它下面还没开始的导出任务（第 10 节）。
public struct SourceItem: Identifiable, Hashable, Sendable {
    public var source: PhotoSource
    /// 检查完成前为 nil。
    public var inspection: SourceInspection?
    public var inspectionError: ApplicationError?
    /// 没有 ICC 时按什么色彩空间解释（D-04、D-75）；nil 按 sRGB 并警告。
    public var colorOverride: SourceColorOverride?
    public var jobs: [DraftJob]
    /// 原图不见了（移走、改名、删除，或所在的卷断开）。任务和改动都留着，文件回来或重新链接后恢复。
    public var isMissing = false
    /// 加入时记下的识别信息，重新链接时核对新文件是不是同一张照片。读完之前为 nil。
    public var fingerprint: SourceFingerprint?
    /// 加入时记下的书签：原图移动或改名后用它找新位置。
    var bookmark: Data?
    /// 右栏「警告」里的说明（例如已经自动重新链接到新位置）。
    public var notices: [JobIssue] = []

    public var id: SourceID { source.sourceId }
}

/// 还没提交的导出任务：一张源图 × 一份可以单独修改的预设副本（§4.2：改动不自动写回预设）。
///
/// 点「开始批处理」时才交给服务创建真正的任务（`JobRecord`），所以排队前随时可以改参数、换位置、换素材。
public struct DraftJob: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sourceId: SourceID
    /// 创建时用的库里的预设；用来显示「已修改」和「存储为预设」。
    public var basePreset: ExportPreset
    public var preset: ExportPreset
    public var destination: URL
    public var naming: OutputNaming
    /// 单任务素材绑定（D-14 最高优先级）。
    public var assetBindings: [String: UUID]
    /// 最近一次校验的结果（输出尺寸、页数、作品目录、警告）。
    public var validation: ValidationItem?

    public init(sourceId: SourceID, preset: ExportPreset, destination: URL) {
        id = UUID()
        self.sourceId = sourceId
        basePreset = preset
        self.preset = preset
        self.destination = destination
        naming = OutputNaming()
        assetBindings = [:]
    }

    public var isModified: Bool { preset != basePreset }
    public var warningCount: Int { (validation?.warnings.count ?? 0) + (validation?.errors.count ?? 0) }

    /// 任务列表「输出」一列：最近一次校验的尺寸和页数（含封面），与「已完成」同一种写法。
    public var outputSummary: String? {
        guard let outputs = validation?.outputs, let first = outputs.first else { return nil }
        return OutputSummary.text(size: first.pixelSize, pages: outputs.count)
    }

    /// 切片张数（不含封面）。
    public var slideCount: Int? {
        validation.map { $0.outputs.count { $0.role != .cover } }
    }
}

/// 输出摘要的唯一写法：「1080 × 1440 · 4 页」。页数含封面（与进度、D-27、CLI 一致），「张」只用于切片。
public enum OutputSummary {
    public static func text(size: PixelSize, pages: Int) -> String {
        "\(size.width) × \(size.height) · \(pages) 页"
    }
}

extension JobRecord {
    /// 「已完成」里的输出摘要：实际写出的文件。
    public var outputSummary: String? {
        guard let manifest, let first = manifest.items.first else { return nil }
        return OutputSummary.text(size: first.pixelSize, pages: manifest.items.count)
    }

    /// 这次执行的警告。任务结束时队列已经把清单里的警告并入执行的警告，不再和 `manifest.warnings` 相加。
    public var displayWarnings: [ApplicationWarning] { currentAttempt.warnings }
}

/// 源图的动态范围（D-62）。标为 HDR 但画面没有超出 SDR 白的内容时单独一种：按 SDR 导出，但不能说「源图不是 HDR」。
public enum SourceDynamicRange: Sendable {
    case sdr, hdr
    case taggedWithoutHighlights

    public init(_ hdr: SourceInspection.HDR) {
        if hdr.kind == "none" {
            self = .sdr
        } else if let headroom = hdr.headroom, headroom <= 1.01 {
            self = .taggedWithoutHighlights
        } else {
            self = .hdr
        }
    }
}

extension SourceItem {
    /// 检查完成前为 nil。
    public var dynamicRange: SourceDynamicRange? { inspection.map { SourceDynamicRange($0.hdr) } }
}

/// 任务列表里的一行。
public enum BatchItemID: Hashable, Sendable {
    case source(SourceID)
    case job(UUID)
}

/// 右栏现在显示什么（第 6 节）。
public enum InspectorSubject: Equatable, Sendable {
    case none
    case source(SourceID)
    /// 一个或多个任务。多个时只显示可以批量修改的共同字段。
    case jobs([UUID])
    case preset(UUID)
    /// 左栏「位置」里的一项。
    case location(UUID)
}

/// 多选时字段的值：全部相同时是这个值，否则显示「多个值」。
public enum FieldValue<Value: Equatable>: Equatable {
    case none
    case single(Value)
    case mixed

    public var value: Value? {
        if case .single(let v) = self { v } else { nil }
    }
}

/// 一条提示（错误弹窗）。
public struct WorkbenchAlert: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    init(_ error: ApplicationError, title: String) {
        self.init(title: title, message: Self.paragraph([error.displayText]))
    }

    /// 多行的弹窗正文：每一行都是完整的句子，句末统一加「。」（提示、标签、单句说明不加）。
    static func paragraph(_ lines: [String]) -> String {
        lines.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false) }
            .map { line in
                guard let last = line.last, !"。！？.!?：；".contains(last) else { return String(line) }
                return line + "。"
            }
            .joined(separator: "\n")
    }
}

extension ApplicationError {
    /// 给人看的全文：消息，有修改建议时另起一行「建议：…」。弹窗、汇总列表、悬停提示都用这一种写法。
    public var displayText: String {
        [message, hint.map { "建议：\($0)" }].compactMap(\.self).joined(separator: "\n")
    }
}

/// 目标作品目录已存在时的确认（D-49：默认加版本号，覆盖要用户确认）。
public struct OverwritePrompt: Identifiable, Equatable, Sendable {
    public struct Conflict: Equatable, Sendable {
        public var jobId: UUID
        public var directory: URL
    }

    public var id = UUID()
    public var conflicts: [Conflict]
}

public enum OverwriteChoice: Sendable {
    /// 覆盖本软件之前发布的作品目录。
    case overwrite
    /// 保留旧目录，新作品加 `_v2`、`_v3`…（默认）。
    case keepBoth
    case cancel
}

/// 开始批处理前，有任务带警告时的询问（继续 / 查看 / 取消）。
public struct WarningPrompt: Identifiable, Equatable, Sendable {
    public var id = UUID()
    /// 带警告的任务，按列表顺序。
    public var jobIds: [UUID]
    public var warningCount: Int
}

/// 重新链接选中的文件与原图不一致时的确认：列出不同的地方，用户确认后才重新链接。
public struct RelinkPrompt: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var sourceId: SourceID
    public var fileURL: URL
    /// 与原图不同的地方。空表示没有原图的信息、无法核对。
    public var differences: [RelinkDifference]
}

/// 开始批处理时有原图找不到：跳过它们的任务、导出其余的，或者取消（只在 GUI；CLI、MCP 仍按 D-72 全部不提交）。
public struct MissingSourcesPrompt: Identifiable, Equatable, Sendable {
    public var id = UUID()
    /// 找不到的原图，按列表顺序。
    public var sourceIds: [SourceID]
    public var fileURLs: [URL]
    /// 会被跳过的任务数。
    public var skippedJobs: Int
}

public enum MissingSourcesChoice: Sendable {
    /// 跳过原图找不到的任务（留在「当前」里），导出其余的。
    case skip
    case cancel
}

public enum WarningChoice: Sendable {
    /// 忽略警告，开始批处理。
    case proceed
    /// 不开始，选中第一个带警告的任务，在 Inspector 里看警告。
    case review
    case cancel
}
