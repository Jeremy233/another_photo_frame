import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import PhotoFrameStorage

/// 左栏「素材」里的一个内置素材（D-136）：品牌 logo（Nikon 的字标和标志各一项）或胶卷图标。不能改名、删除；
/// 和自己导入的素材一样能绑定到素材槽（D-139），绑定存的是它固定的素材 ID。
public struct BuiltInAssetItem: Identifiable, Hashable, Sendable {
    public var asset: BuiltInAsset

    public var title: String { asset.title }
    /// 相对 `resources/` 的文件路径。
    public var path: String { asset.path }
    public var id: String { path }
    /// 绑定到素材槽时用的素材 ID。
    public var assetId: UUID { asset.id }

    public var isSVG: Bool { asset.format == .svg }
    public var data: Data? { asset.data }
    /// 复制为自己的素材时放进哪一组。
    public var copyCategory: AssetCategory {
        if case .film = asset.kind { return .filmIcon }
        return .cameraBadge
    }

    /// 「内置」下的品牌 logo、经典品牌 logo、胶卷图标三组（D-136、D-138）。
    public static let groups: [(title: String, items: [BuiltInAssetItem])] = {
        let all = BuiltInAsset.all.map(BuiltInAssetItem.init)
        func isFilm(_ item: BuiltInAssetItem) -> Bool { if case .film = item.asset.kind { true } else { false } }
        return [("品牌 logo", all.filter { !isFilm($0) && !$0.asset.isClassicBrand }),
                ("经典品牌 logo", all.filter { $0.asset.isClassicBrand }),
                ("胶卷图标", all.filter(isFilm))]
    }()

    /// 按路径找内置素材（左栏选中的项）。
    public static func item(path: String) -> BuiltInAssetItem? { BuiltInAsset.asset(path: path).map(BuiltInAssetItem.init) }
}

/// 左栏「素材」选中的一项：自己的素材（按 ID）或内置素材（按路径）。
public enum AssetSelection: Hashable, Sendable {
    case user(UUID)
    case builtIn(String)
}

extension Workbench {
    /// 中间预览要显示的素材：左栏在「素材」、选中了一个素材，而且没有选中图片（预览为空）时才有。
    public var previewedAsset: (title: String, image: AssetSelection)? {
        guard sidebarTab == .assets, previewSubject == nil, let selection = selectedAsset else { return nil }
        switch selection {
        case .user(let id):
            return assets.first { $0.assetId == id }.map { ($0.displayName, selection) }
        case .builtIn(let path):
            return BuiltInAssetItem.item(path: path).map { ($0.title, selection) }
        }
    }
}

extension Workbench {
    /// 内置素材「复制为我的素材」：内容由界面给出（受限 SVG，或画好的 PNG），导入后可以改名、改颜色、删除。
    public func copyBuiltInAsset(_ item: BuiltInAssetItem, content: Data, isSVG: Bool) async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "BuiltInCopy-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = dir.appending(path: "\(item.title) 副本.\(isSVG ? "svg" : "png")")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: file)
        } catch {
            alert = WorkbenchAlert(title: "无法复制素材", message: error.localizedDescription)
            return
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        await importAssets([file], category: item.copyCategory)
    }
}

extension BrandLogoStyle {
    /// 颜色选「自定」、还没挑颜色时用的颜色（右栏颜色框里显示的也是它）。
    public static let defaultCustomColor = PresetColor(hex: "#1A1A1A")
}

extension FilmIconStyle {
    /// 右栏显示「没有图标时」：要画图标、而且图标来自内置胶卷时才有用（选了自己的图标时总有图，D-139）。
    public var offersNoIconChoice: Bool { show != .text && film != FilmIconStyle.fromSlot }
    /// 右栏显示「图标大小」：要画图标时都有，自己的图标也按它画（2026-11-05 确认）。
    public var offersIconSize: Bool { show != .text }
}

// MARK: - 内置的和自己的素材放在同一个菜单里（D-139）

/// 菜单里的一项：给 ID 和显示的名字。
public struct MenuChoice<ID: Hashable & Sendable>: Hashable, Sendable, Identifiable {
    public var id: ID
    public var title: String
}

public enum MenuTitles {
    /// 内置的和用户的列在同一个菜单里时（D-139）：名字相同（不分大小写、忽略首尾空白）的，内置的后面加「（内置）」，
    /// 用户的后面加「（用户）」；不重名的照原样。没有优先级，两个都能选。
    public static func label<B: Hashable & Sendable, U: Hashable & Sendable>(
        builtIn: [(id: B, name: String)], user: [(id: U, name: String)]
    ) -> (builtIn: [MenuChoice<B>], user: [MenuChoice<U>]) {
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let builtInNames = Set(builtIn.map { key($0.name) }), userNames = Set(user.map { key($0.name) })
        return (builtIn.map { MenuChoice(id: $0.id, title: userNames.contains(key($0.name)) ? "\($0.name)（内置）" : $0.name) },
                user.map { MenuChoice(id: $0.id, title: builtInNames.contains(key($0.name)) ? "\($0.name)（用户）" : $0.name) })
    }
}

extension Workbench {
    /// 「品牌 logo」的来源菜单：内置品牌（现役、经典）和自己「相机图标」组里的素材（D-139）。
    public var brandLogoChoices: (current: [MenuChoice<String>], classic: [MenuChoice<String>], user: [MenuChoice<UUID>]) {
        let brands = BuiltInWatermarks.brands
        let labeled = MenuTitles.label(builtIn: brands.map { ($0.id, $0.name) },
                                       user: assets(in: .cameraBadge).map { ($0.assetId, $0.displayName) })
        let classic = Set(brands.filter(\.classic).map(\.id))
        return (labeled.builtIn.filter { !classic.contains($0.id) }, labeled.builtIn.filter { classic.contains($0.id) }, labeled.user)
    }

    /// 「胶卷」的来源菜单：内置胶卷（按胶片厂分组）和自己「胶卷图标」组里的素材（D-139）。
    public var filmChoices: (makers: [(maker: String, films: [MenuChoice<String>])], user: [MenuChoice<UUID>]) {
        let films = BuiltInWatermarks.films
        let labeled = MenuTitles.label(builtIn: films.map { ($0.id, $0.name) },
                                       user: assets(in: .filmIcon).map { ($0.assetId, $0.displayName) })
        var makers: [(maker: String, films: [MenuChoice<String>])] = []
        for (film, choice) in zip(films, labeled.builtIn) {
            if let i = makers.firstIndex(where: { $0.maker == film.maker }) { makers[i].films.append(choice) } else { makers.append((film.maker, [choice])) }
        }
        return (makers, labeled.user)
    }

    /// 素材槽的菜单：自己的素材和内置素材（D-139）。
    public var slotChoices: (user: [MenuChoice<UUID>], builtIn: [(title: String, items: [MenuChoice<UUID>])]) {
        let groups = BuiltInAssetItem.groups
        let labeled = MenuTitles.label(builtIn: groups.flatMap(\.items).map { ($0.assetId, $0.title) },
                                       user: assets.map { ($0.assetId, $0.displayName) })
        var rest = labeled.builtIn[...]
        let builtIn = groups.map { group in
            let items = Array(rest.prefix(group.items.count))
            rest = rest.dropFirst(group.items.count)
            return (title: "内置 · \(group.title)", items: items)
        }
        return (labeled.user, builtIn)
    }

    /// 素材在素材槽菜单里的名字（含同名时的括号）；不认识的 ID 是 nil（素材已删除）。
    public func assetMenuTitle(_ id: UUID) -> String? {
        let choices = slotChoices
        return (choices.user + choices.builtIn.flatMap(\.items)).first { $0.id == id }?.title
    }

    /// 品牌 logo、胶卷装饰当前选的素材（选了素材槽时，D-139）：素材槽在当前层级绑定的素材。
    public func layerAsset(_ layer: OverlayLayer) -> UUID? {
        guard layer.usesAssetSlot, let slotId = layer.slotId else { return nil }
        return binding(for: slotId)?.assetId
    }

    /// 品牌 logo 的颜色方式（右栏「颜色」）。改成「自定」而还没有颜色时，写入颜色框里显示的默认色：
    /// `custom` 必须有 `color`（D-137），否则预设校验不过，预览和导出都会报错。
    public func setBrandLogoColorMode(_ mode: BrandLogoStyle.ColorMode, forLayer layerId: String) {
        updateLayer(layerId) { l in
            var s = l.logo ?? BrandLogoStyle()
            s.colorMode = mode
            if mode == .custom, s.color == nil { s.color = BrandLogoStyle.defaultCustomColor }
            l.logo = s
        }
    }

    /// 品牌 logo、胶卷装饰改用一个素材（D-139）：图层没有素材槽时先加一个（和图层同名），来源改成素材槽，再绑定这个素材。
    /// 编辑任务时是单任务绑定；编辑预设时是预设本地绑定（同「素材」一行）。
    public func useAsset(_ assetId: UUID, forLayer layerId: String) async {
        var slotId: String?
        edit("选择素材") { preset in
            guard let i = preset.layers.firstIndex(where: { $0.layerId == layerId }) else { return }
            var layer = preset.layers[i]
            let label: String
            switch layer.type {
            case .brandLogo:
                layer.logo = { var s = layer.logo ?? BrandLogoStyle(); s.brand = BrandLogoStyle.fromSlot; return s }()
                label = "品牌 logo"
            case .filmIcon:
                layer.filmIcon = { var s = layer.filmIcon ?? FilmIconStyle(); s.film = FilmIconStyle.fromSlot; return s }()
                label = "胶卷图标"
            case .text, .metadataText, .asset, .cameraBadge:
                return
            }
            let slots = Set(preset.assetSlots.map(\.slotId))
            var id = layer.slotId ?? layerId
            if layer.slotId == nil || !slots.contains(id) {
                var n = 2
                while slots.contains(id) || preset.layers.contains(where: { $0.layerId != layerId && $0.slotId == id }) {
                    id = "\(layerId)-\(n)"
                    n += 1
                }
                preset.assetSlots.append(AssetSlot(slotId: id, label: label))
            }
            layer.slotId = id
            preset.layers[i] = layer
            slotId = id
        }
        guard let slotId else { return }
        await bindAsset(assetId, slotId: slotId)
    }
}

