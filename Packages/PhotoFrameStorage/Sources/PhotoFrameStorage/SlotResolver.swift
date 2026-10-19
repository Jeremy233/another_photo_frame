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
    /// 相机匹配到的素材槽没有可用的绑定，改用下一个候选（D-111）。
    case cameraMatchUnbound(slotId: String, layerId: String)
    /// 图层写了相机匹配规则，但源图没有相机品牌 / 型号，用默认素材（D-111）。
    case cameraUnknown(layerIds: [String])
    /// 图层只靠相机匹配选素材（没有默认 slotId），这台相机没有匹配的规则或素材：跳过图层（D-111）。
    case cameraNoMatch(layerId: String)

    public var code: String {
        switch self {
        case .optionalSlotMissing: "slot.optional_missing"
        case .staleBinding: "slot.stale_binding"
        case .incompatibleFormat: "slot.incompatible_format"
        case .unusedJobBinding: "slot.unused_job_binding"
        case .cameraMatchUnbound: "slot.camera_match_unbound"
        case .cameraUnknown: "slot.camera_unknown"
        case .cameraNoMatch: "slot.camera_no_match"
        }
    }

    public var message: String {
        switch self {
        case .optionalSlotMissing(let s, let layers): "可选素材槽\(quoted(s))没有绑定素材，跳过装饰\(quoted(layers))"
        case .staleBinding(let s, let scope, _): "素材槽\(quoted(s))的\(scope.label)绑定指向已删除的素材"
        case .incompatibleFormat(let s, let scope, _, let f): "素材槽\(quoted(s))的\(scope.label)绑定是 \(f.rawValue)，这个素材槽不接受这种格式"
        case .unusedJobBinding(let s): "单任务绑定的素材槽\(quoted(s))没有被预设使用"
        case .cameraMatchUnbound(let s, let layer): "装饰\(quoted(layer))按相机匹配到素材槽\(quoted(s))，但它没有可用的素材，改用下一个候选"
        case .cameraUnknown(let layers): "源图没有相机品牌和型号，装饰\(quoted(layers))使用默认素材"
        case .cameraNoMatch(let layer): "这台相机没有匹配的相机图标，跳过装饰\(quoted(layer))"
        }
    }
}

/// 消息里的素材槽 ID、图层 ID 用「」括起来（GUI 按 ID 换成图层的名字）。
private func quoted(_ id: String) -> String { "「\(id)」" }
private func quoted(_ ids: [String]) -> String { ids.map(quoted).joined(separator: "、") }

extension BindingScope {
    var label: String {
        switch self {
        case .job: "单任务"
        case .presetLocal: "预设本地"
        case .userGlobal: "用户默认"
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
    public var message: String { "缺少必需的素材：素材槽\(quoted(missingRequiredSlots))没有绑定素材" }
    public var hint: String { "在素材库中导入素材，并绑定到这些素材槽（单任务、预设本地或用户默认）" }
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
    /// 素材图层实际使用的素材槽（layerId → slotId）。按相机匹配（D-111）时可能不是图层自己的 `slotId`。
    public var layerSlots: [String: String] = [:]
    /// 因可选素材缺失而跳过的图层。
    public var skippedLayerIds: [String]
    public var warnings: [SlotResolutionWarning]
}

/// 按 D-14（单任务 > 预设本地绑定 > 用户全局绑定）把预设的 slot 解析到本地素材。
///
/// 只解析被**启用的**素材图层引用的 slot；没有图层使用的 slot 不影响输出。
/// 某一层的绑定失效（素材已删除、格式不符）时给出警告并继续尝试下一层。
///
/// 相机匹配（D-111）：图层按 ``OverlayLayer/slotCandidates(for:)`` 依次尝试候选槽，用第一个有可用素材的；
/// 匹配到的槽没有素材时警告并退到下一个候选，最后是图层自己的 `slotId`。`required` 只对图层自己的 `slotId` 生效：
/// 匹配到的槽缺素材从不阻止输出。
public struct SlotResolver: Sendable {
    public var library: any AssetLookup
    public var bindings: AssetBindingTable

    public init(library: any AssetLookup, bindings: AssetBindingTable) {
        self.library = library
        self.bindings = bindings
    }

    /// - Parameter camera: 源图的相机；nil 表示调用方不按相机匹配（只用图层自己的 `slotId`）。
    public func resolve(
        _ preset: ExportPreset, jobBindings: [String: UUID] = [:], camera: CameraIdentity? = nil
    ) throws(SlotResolutionError) -> SlotResolution {
        var warnings: [SlotResolutionWarning] = []
        let slotsById = Dictionary(preset.assetSlots.map { ($0.slotId, $0) }, uniquingKeysWith: { first, _ in first })
        let layers = preset.layers.filter { $0.enabled && $0.type.usesAssetSlot }
        var candidates: [String: [String]] = [:]
        for layer in layers {
            candidates[layer.layerId] = layer.slotCandidates(for: camera).filter { slotsById[$0] != nil }
        }

        // 每个候选槽只解析一次。警告最后按预设中槽的顺序给出。
        let wanted = Set(candidates.values.joined())
        var resolved: [String: ResolvedSlot] = [:]
        var bindingWarnings: [String: [SlotResolutionWarning]] = [:]
        for slot in preset.assetSlots where wanted.contains(slot.slotId) {
            if let found = resolveSlot(slot, preset: preset, jobBindings: jobBindings, warnings: &bindingWarnings[slot.slotId, default: []]) {
                resolved[slot.slotId] = found
            }
        }
        var cameraWarnings: [SlotResolutionWarning] = []

        var layerSlots: [String: String] = [:]
        var missingRequired = Set<String>()
        var skippedBySlot: [String: [String]] = [:]
        var skippedLayers: [String] = []
        var unknownCamera: [String] = []
        for layer in layers {
            let list = candidates[layer.layerId] ?? []
            if !layer.cameraMatch.isEmpty, let camera, camera.isEmpty { unknownCamera.append(layer.layerId) }
            if let chosen = list.first(where: { resolved[$0] != nil }) {
                layerSlots[layer.layerId] = chosen
                for slotId in list.prefix(while: { $0 != chosen }) {
                    cameraWarnings.append(.cameraMatchUnbound(slotId: slotId, layerId: layer.layerId))
                }
                continue
            }
            for slotId in list where slotId != layer.slotId {
                cameraWarnings.append(.cameraMatchUnbound(slotId: slotId, layerId: layer.layerId))
            }
            skippedLayers.append(layer.layerId)
            if let slotId = layer.slotId, let slot = slotsById[slotId] {
                if slot.required { missingRequired.insert(slotId) } else { skippedBySlot[slotId, default: []].append(layer.layerId) }
            } else {
                cameraWarnings.append(.cameraNoMatch(layerId: layer.layerId))
            }
        }
        for slot in preset.assetSlots {
            warnings += bindingWarnings[slot.slotId] ?? []
            if let layerIds = skippedBySlot[slot.slotId] { warnings.append(.optionalSlotMissing(slotId: slot.slotId, layerIds: layerIds)) }
        }
        if !unknownCamera.isEmpty { warnings.append(.cameraUnknown(layerIds: unknownCamera)) }
        warnings += cameraWarnings

        for slotId in jobBindings.keys.sorted() where !wanted.contains(slotId) {
            warnings.append(.unusedJobBinding(slotId: slotId))
        }

        guard missingRequired.isEmpty else {
            let ordered = preset.assetSlots.map(\.slotId).filter { missingRequired.contains($0) }
            throw SlotResolutionError(missingRequiredSlots: ordered, warnings: warnings)
        }
        let used = Set(layerSlots.values)
        return SlotResolution(resolved: resolved.filter { used.contains($0.key) }, layerSlots: layerSlots,
                              skippedLayerIds: skippedLayers, warnings: warnings)
    }

    /// 按 D-14 的优先级找第一个有效的绑定；失效的绑定给出警告（D-28）。
    private func resolveSlot(
        _ slot: AssetSlot, preset: ExportPreset, jobBindings: [String: UUID], warnings: inout [SlotResolutionWarning]
    ) -> ResolvedSlot? {
        let candidates: [(BindingScope, UUID?)] = [
            (.job, jobBindings[slot.slotId]),
            (.presetLocal, bindings.presetBinding(preset.presetId, slotId: slot.slotId)),
            (.userGlobal, bindings.userGlobal[slot.slotId]),
        ]
        for case let (scope, assetId?) in candidates {
            guard let record = library.asset(withId: assetId) else {
                warnings.append(.staleBinding(slotId: slot.slotId, scope: scope, assetId: assetId))
                continue
            }
            guard slot.acceptedFormats.contains(record.format) else {
                warnings.append(.incompatibleFormat(slotId: slot.slotId, scope: scope, assetId: assetId, format: record.format))
                continue
            }
            return ResolvedSlot(slotId: slot.slotId, asset: record, scope: scope)
        }
        return nil
    }
}

extension SlotResolution {
    /// 把素材图层的 `slotId` 换成实际使用的槽（D-111），渲染时按 `slotId` 取素材。
    public func applied(to preset: ExportPreset) -> ExportPreset {
        var out = preset
        for i in out.layers.indices {
            if let slotId = layerSlots[out.layers[i].layerId] { out.layers[i].slotId = slotId }
        }
        return out
    }
}
