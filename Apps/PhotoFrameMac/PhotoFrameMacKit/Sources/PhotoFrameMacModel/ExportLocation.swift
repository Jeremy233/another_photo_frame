import Foundation

/// 左栏「位置」里的一个常用导出位置（UI 设计文档第 7.2 节）：名称 + 目录。
public struct ExportLocation: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var url: URL

    public init(id: UUID = UUID(), name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }
}

/// 全部位置和默认位置。
public struct LocationList: Hashable, Sendable, Codable {
    public var locations: [ExportLocation]
    public var defaultId: UUID?

    public init(locations: [ExportLocation] = [], defaultId: UUID? = nil) {
        self.locations = locations
        self.defaultId = defaultId
    }

    /// 没有任何位置时的初始值：`~/Pictures/Social Exports`（UI 设计文档顶部示意）。
    public static func initial(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> LocationList {
        let location = ExportLocation(name: "Social Exports", url: home.appending(path: "Pictures/Social Exports", directoryHint: .isDirectory))
        return LocationList(locations: [location], defaultId: location.id)
    }

    public var defaultLocation: ExportLocation? {
        locations.first { $0.id == defaultId } ?? locations.first
    }
}

/// 位置列表存在哪里。位置只是 GUI 的快捷方式，CLI 直接用 `--output`，所以不放进共享的本地库。
public protocol LocationStore: Sendable {
    func load() -> LocationList?
    func save(_ list: LocationList)
}

/// 存在应用的 UserDefaults。
public struct UserDefaultsLocationStore: LocationStore {
    private let key: String

    public init(key: String = "exportLocations") { self.key = key }

    public func load() -> LocationList? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LocationList.self, from: $0) }
    }

    public func save(_ list: LocationList) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }
}

/// 只在内存里（测试、预览用）。
public final class MemoryLocationStore: LocationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var list: LocationList?

    public init(_ list: LocationList? = nil) { self.list = list }

    public func load() -> LocationList? { lock.withLock { list } }
    public func save(_ list: LocationList) { lock.withLock { self.list = list } }
}
