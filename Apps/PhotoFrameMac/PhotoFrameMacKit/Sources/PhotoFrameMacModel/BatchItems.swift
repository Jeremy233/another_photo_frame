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

    init(_ error: ApplicationError, title: String = "操作失败") {
        self.init(title: title, message: [error.message, error.hint].compactMap(\.self).joined(separator: "\n"))
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
