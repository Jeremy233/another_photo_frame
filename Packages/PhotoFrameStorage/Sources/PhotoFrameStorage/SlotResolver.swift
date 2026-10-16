import Foundation
import PhotoFrameCore

/// 绑定的作用范围，按 D-14 的优先级从高到低排列。
public enum BindingScope: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    /// 只对当前任务生效。
    case job
    /// 保存在本机、只对某个预设生效（不随预设导出）。
    case presetLocal
    /// 本用户的默认绑定。
    case userGlobal

    /// 数值越小优先级越高。
    public var priority: Int {
        switch self {
        case .job: 0
        case .presetLocal: 1
        case .userGlobal: 2
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.priority < b.priority }
}

/// 一条绑定：把某个 slot 指向本地素材库中的一个素材（§8.2、§11.1）。
public struct AssetBinding: Hashable, Sendable, Codable {
    public var slotId: String
    public var assetId: UUID
    public var scope: BindingScope

    public init(slotId: String, assetId: UUID, scope: BindingScope) {
        self.slotId = slotId
        self.assetId = assetId
        self.scope = scope
    }
}

/// 本机保存的持久绑定（预设本地 + 用户全局）。单任务绑定随任务传入，不在这里。
///
/// 这份数据只存在本机，**不**写进 `.photoframe`。
public struct AssetBindingTable: Hashable, Sendable, Codable {
    /// presetId（UUID 字符串）→ (slotId → assetId)。用字符串作键，JSON 才是对象而不是数组。
    public var presetLocal: [String: [String: UUID]]
    /// slotId → assetId
    public var userGlobal: [String: UUID]

    public init(presetLocal: [String: [String: UUID]] = [:], userGlobal: [String: UUID] = [:]) {
        self.presetLocal = presetLocal
        self.userGlobal = userGlobal
    }

    public mutating func bindForPreset(_ presetId: UUID, slotId: String, assetId: UUID) {
        presetLocal[presetId.uuidString, default: [:]][slotId] = assetId
    }

    public func presetBinding(_ presetId: UUID, slotId: String) -> UUID? {
        presetLocal[presetId.uuidString]?[slotId]
    }

    public mutating func bindGlobally(slotId: String, assetId: UUID) {
        userGlobal[slotId] = assetId
    }
}

/// 素材库里的一个素材。真实文件路径由素材库自己管理，这里只需要身份和格式。
public struct AssetRecord: Hashable, Sendable, Codable {
    public var assetId: UUID
    public var format: AssetSlot.Format
    public var displayName: String

    public init(assetId: UUID, format: AssetSlot.Format, displayName: String) {
        self.assetId = assetId
        self.format = format
        self.displayName = displayName
    }
}

/// 按 ID 查素材。由本地 Asset Library 实现。
public protocol AssetLookup: Sendable {
    func asset(withId id: UUID) -> AssetRecord?
}

/// 内存中的素材表，供测试和 CLI dry-run 使用。
public struct InMemoryAssetLibrary: AssetLookup {
    public var assets: [UUID: AssetRecord]

    public init(_ records: [AssetRecord] = []) {
        assets = Dictionary(records.map { ($0.assetId, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func asset(withId id: UUID) -> AssetRecord? { assets[id] }
}

/// 解析过程中的提示。
public enum SlotResolutionWarning: Hashable, Sendable {
    /// 可选素材缺失：跳过使用它的图层。
    case optionalSlotMissing(slotId: String, layerIds: [String])
    /// 绑定指向的素材已不在素材库中，改用下一优先级。
    case staleBinding(slotId: String, scope: BindingScope, assetId: UUID)
    /// 绑定的素材格式不被该 slot 接受，改用下一优先级。
    case incompatibleFormat(slotId: String, scope: BindingScope, assetId: UUID, format: AssetSlot.Format)
    /// 单任务绑定了预设中不存在（或没有图层使用）的 slot。
    case unusedJobBinding(slotId: String)

    public var code: String {
        switch self {
        case .optionalSlotMissing: "slot.optional_missing"
        case .staleBinding: "slot.stale_binding"
        case .incompatibleFormat: "slot.incompatible_format"
        case .unusedJobBinding: "slot.unused_job_binding"
        }
    }

    public var message: String {
        switch self {
        case .optionalSlotMissing(let s, let layers): "可选素材 \(s) 未绑定，跳过图层 \(layers.joined(separator: ", "))"
        case .staleBinding(let s, let scope, _): "素材槽 \(s) 的\(scope.label)绑定指向已删除的素材"
        case .incompatibleFormat(let s, let scope, _, let f): "素材槽 \(s) 的\(scope.label)绑定是 \(f.rawValue)，该槽不接受这种格式"
        case .unusedJobBinding(let s): "本任务绑定的素材槽 \(s) 没有被预设使用"
        }
    }
}

extension BindingScope {
    var label: String {
        switch self {
        case .job: "单任务"
        case .presetLocal: "预设本地"
        case .userGlobal: "用户全局"
        }
    }
}

/// 缺少必需素材：阻止输出（§8.2）。
public struct SlotResolutionError: Error, Hashable, Sendable {
    /// 缺失的必需 slot，按预设中的顺序。
    public var missingRequiredSlots: [String]
    /// 解析过程中的其他提示，方便一次性展示给用户。
    public var warnings: [SlotResolutionWarning]

    public var code: String { "slot.missing_required" }
    public var message: String { "缺少必需素材：\(missingRequiredSlots.joined(separator: ", "))" }
    public var hint: String { "在素材库中导入素材，并绑定到这些素材槽（本任务、此预设或全局默认）" }
}

/// 一个已解析的 slot。
public struct ResolvedSlot: Hashable, Sendable {
    public var slotId: String
    public var asset: AssetRecord
    /// 实际生效的绑定来自哪一层。
    public var scope: BindingScope
}

public struct SlotResolution: Hashable, Sendable {
    /// slotId → 解析结果。
    public var resolved: [String: ResolvedSlot]
    /// 因可选素材缺失而跳过的图层。
    public var skippedLayerIds: [String]
    public var warnings: [SlotResolutionWarning]
}

/// 按 D-14（单任务 > 预设本地绑定 > 用户全局绑定）把预设的 slot 解析到本地素材。
///
/// 只解析被**启用的**素材图层引用的 slot；没有图层使用的 slot 不影响输出。
/// 某一层的绑定失效（素材已删除、格式不符）时给出警告并继续尝试下一层。
public struct SlotResolver: Sendable {
    public var library: any AssetLookup
    public var bindings: AssetBindingTable

    public init(library: any AssetLookup, bindings: AssetBindingTable) {
        self.library = library
        self.bindings = bindings
    }

    public func resolve(_ preset: ExportPreset, jobBindings: [String: UUID] = [:]) throws(SlotResolutionError) -> SlotResolution {
        var resolved: [String: ResolvedSlot] = [:]
        var warnings: [SlotResolutionWarning] = []
        var missingRequired: [String] = []
        var skippedLayers: [String] = []

        let layersBySlot = Dictionary(grouping: preset.layers.filter { $0.enabled && $0.type.usesAssetSlot && $0.slotId != nil },
                                      by: { $0.slotId! })
        let slots = preset.assetSlots.filter { layersBySlot[$0.slotId] != nil }

        for slot in slots {
            let candidates: [(BindingScope, UUID?)] = [
                (.job, jobBindings[slot.slotId]),
                (.presetLocal, bindings.presetBinding(preset.presetId, slotId: slot.slotId)),
                (.userGlobal, bindings.userGlobal[slot.slotId]),
            ]
            var found: ResolvedSlot?
            for case let (scope, assetId?) in candidates {
                guard let record = library.asset(withId: assetId) else {
                    warnings.append(.staleBinding(slotId: slot.slotId, scope: scope, assetId: assetId))
                    continue
                }
                guard slot.acceptedFormats.contains(record.format) else {
                    warnings.append(.incompatibleFormat(slotId: slot.slotId, scope: scope, assetId: assetId, format: record.format))
                    continue
                }
                found = ResolvedSlot(slotId: slot.slotId, asset: record, scope: scope)
                break
            }
            if let found {
                resolved[slot.slotId] = found
            } else if slot.required {
                missingRequired.append(slot.slotId)
            } else {
                let layerIds = layersBySlot[slot.slotId, default: []].map(\.layerId)
                skippedLayers += layerIds
                warnings.append(.optionalSlotMissing(slotId: slot.slotId, layerIds: layerIds))
            }
        }

        let usedSlotIds = Set(slots.map(\.slotId))
        for slotId in jobBindings.keys.sorted() where !usedSlotIds.contains(slotId) {
            warnings.append(.unusedJobBinding(slotId: slotId))
        }

        guard missingRequired.isEmpty else {
            throw SlotResolutionError(missingRequiredSlots: missingRequired, warnings: warnings)
        }
        return SlotResolution(resolved: resolved, skippedLayerIds: skippedLayers, warnings: warnings)
    }
}
