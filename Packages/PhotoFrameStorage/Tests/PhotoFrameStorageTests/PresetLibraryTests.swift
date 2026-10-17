import Foundation
import Testing
import PhotoFrameCore
@testable import PhotoFrameStorage

private func code(_ body: () throws(LibraryError) -> Void) -> String? {
    do {
        try body()
        return nil
    } catch {
        return error.code
    }
}

@Suite("预设库")
struct PresetLibraryTests {
    let root = TempRoot()
    var presets: PresetLibrary { root.library().presets }

    @Test("空库：只有 6 个内置预设，三组分开")
    func emptyLibrary() {
        let l = presets.list()
        #expect(l.builtIn.count == 6)
        #expect(l.builtIn.allSatisfy { $0.isReadOnly && $0.origin == .builtIn })
        #expect(l.user.isEmpty && l.imported.isEmpty && l.warnings.isEmpty)
        #expect(l.builtIn.map(\.slug).contains("instagram-panorama"))
    }

    @Test("新建、复制、重命名、保存修改、删除，换一个实例读取结果一致")
    func crud() throws {
        let template = presets.list().builtIn[0].preset
        let created = try presets.create(name: "  My Landscape  ", from: template)
        #expect(created.name == "My Landscape")
        #expect(created.presetId != template.presetId)
        #expect(created.origin == .user)

        let copy = try presets.duplicate(created.presetId)
        #expect(copy.name == "My Landscape Copy")
        let copy2 = try presets.duplicate(created.presetId)
        #expect(copy2.name == "My Landscape Copy 2")

        try presets.rename(copy.presetId, to: "Gallery")
        var edited = try presets.entry(created.presetId).preset
        edited.canvas.minMarginPx = 90
        let updated = try presets.update(edited)
        #expect(updated.createdAt == created.createdAt)
        #expect(updated.origin == .user)

        try presets.delete(copy2.presetId)

        let fresh = PresetLibrary(root: root.url, platforms: testCatalog).list()
        #expect(fresh.user.map(\.name) == ["Gallery", "My Landscape"])
        #expect(fresh.entry(created.presetId)?.preset.canvas.minMarginPx == 90)
        #expect(fresh.entry(copy2.presetId) == nil)
        #expect(fresh.warnings.isEmpty)
        // 只有正式文件，没有残留的临时文件。
        #expect(root.allFiles().allSatisfy { $0.hasPrefix("Presets/") && !$0.contains(".tmp-") })
        #expect(root.allFiles().count == 2)
    }

    @Test("内置预设只读：修改、重命名、删除都拒绝，复制后可以改")
    func builtInReadOnly() throws {
        let builtIn = presets.list().builtIn[1]
        var modified = builtIn.preset
        modified.canvas.minMarginPx = 10
        #expect(code { () throws(LibraryError) in _ = try presets.update(modified) } == "library.builtin_read_only")
        #expect(code { () throws(LibraryError) in _ = try presets.rename(builtIn.presetId, to: "x") } == "library.builtin_read_only")
        #expect(code { () throws(LibraryError) in try presets.delete(builtIn.presetId) } == "library.builtin_read_only")
        #expect(code { () throws(LibraryError) in _ = try presets.add(builtIn.preset) } == "library.builtin_read_only")

        let copy = try presets.duplicate(builtIn.presetId)
        #expect(copy.name == "\(builtIn.name) Copy")
        modified.presetId = copy.presetId
        modified.name = copy.name
        #expect(try presets.update(modified).preset.canvas.minMarginPx == 10)
        #expect(presets.list().builtIn[1].preset.canvas.minMarginPx == 60)
    }

    @Test("名称和内容校验")
    func validation() throws {
        let template = presets.list().builtIn[0].preset
        #expect(code { () throws(LibraryError) in _ = try presets.create(name: "   ", from: template) } == "library.invalid_name")
        #expect(code { () throws(LibraryError) in _ = try presets.create(name: String(repeating: "a", count: 201), from: template) } == "library.invalid_name")
        #expect(code { () throws(LibraryError) in _ = try presets.create(name: "a\u{0}b", from: template) } == "library.invalid_name")
        var bad = samplePreset()
        bad.output.quality = 500
        #expect(code { () throws(LibraryError) in _ = try presets.add(bad) } == "library.invalid_preset")
        let ok = try presets.add(samplePreset())
        #expect(code { () throws(LibraryError) in _ = try presets.add(ok.preset) } == "library.preset_exists")
        #expect(code { () throws(LibraryError) in _ = try presets.update(samplePreset()) } == "library.preset_not_found")
    }

    @Test("按 UUID、名称、短名查找")
    func find() throws {
        let a = try presets.add(samplePreset(name: "My Landscape"))
        #expect(try presets.find("my-landscape").presetId == a.presetId)
        #expect(try presets.find("MY LANDSCAPE").presetId == a.presetId)
        #expect(try presets.find(a.presetId.uuidString).presetId == a.presetId)
        #expect(try presets.find("xhs-panorama").origin == .builtIn)
        _ = try presets.add(samplePreset(name: "My  Landscape!"))
        #expect(code { () throws(LibraryError) in _ = try presets.find("my-landscape") } == "library.ambiguous_preset")
        #expect(code { () throws(LibraryError) in _ = try presets.find("nope") } == "library.preset_not_found")
    }

    // MARK: 导入导出

    @Test("导入：没有冲突时保留 presetId，归入「导入」组")
    func importNew() throws {
        let original = samplePreset()
        let data = try PresetPackage.export(original)
        let preview = try presets.previewImport(data)
        #expect(preview.canImport && preview.idConflictResolutions.isEmpty)
        let result = try presets.importPackage(data)
        #expect(result.entry.presetId == original.presetId)
        #expect(result.conflictResolution == nil)
        #expect(presets.list().imported.map(\.presetId) == [original.presetId])
    }

    @Test("导入：presetId 冲突时默认另存为副本（D-39）")
    func importConflictCopy() throws {
        let mine = try presets.add(samplePreset(name: "Mine"))
        var incoming = mine.preset
        incoming.name = "Theirs"
        let data = try PresetPackage.export(incoming)
        #expect(try presets.previewImport(data).idConflictResolutions == [.saveAsCopy, .replace])

        let result = try presets.importPackage(data)
        #expect(result.conflictResolution == .saveAsCopy)
        #expect(result.entry.presetId != mine.presetId)
        #expect(result.entry.name == "Theirs Copy")
        #expect(result.entry.origin == .imported)
        #expect(try presets.entry(mine.presetId).name == "Mine")

        // 再导入一次：按复制预设的规则继续编号（D-80）。
        #expect(try presets.importPackage(data).entry.name == "Theirs Copy 2")
    }

    @Test("在「用户保存」和「导入」之间移动；编辑不改变分组；内置预设不能移动（D-81）")
    func moveBetweenGroups() throws {
        let imported = try presets.importPackage(try PresetPackage.export(samplePreset(name: "Shared"))).entry
        var edited = imported.preset
        edited.canvas.minMarginPx = 80
        #expect(try presets.update(edited).origin == .imported)
        #expect(presets.list().imported.map(\.presetId) == [imported.presetId])

        let stored = try presets.entry(imported.presetId)
        let moved = try presets.move(imported.presetId, to: .user)
        #expect(moved.origin == .user)
        #expect(moved.preset == stored.preset)
        #expect(moved.createdAt == stored.createdAt && moved.modifiedAt == stored.modifiedAt)
        let fresh = PresetLibrary(root: root.url, platforms: testCatalog).list()
        #expect(fresh.user.map(\.presetId) == [imported.presetId])
        #expect(fresh.imported.isEmpty)

        #expect(try presets.move(imported.presetId, to: .user).origin == .user)
        #expect(try presets.move(imported.presetId, to: .imported).origin == .imported)

        let builtIn = presets.list().builtIn[0].presetId
        #expect(code { () throws(LibraryError) in _ = try presets.move(builtIn, to: .user) } == "library.builtin_read_only")
        #expect(code { () throws(LibraryError) in _ = try presets.move(imported.presetId, to: .builtIn) } == "library.builtin_read_only")
        #expect(code { () throws(LibraryError) in _ = try presets.move(UUID(), to: .user) } == "library.preset_not_found")
        #expect(try presets.entry(imported.presetId).origin == .imported)
    }

    @Test("导入：选择替换时覆盖已有预设；内置预设不能被替换")
    func importConflictReplace() throws {
        let mine = try presets.add(samplePreset(name: "Mine"))
        var incoming = mine.preset
        incoming.name = "Theirs"
        let result = try presets.importPackage(try PresetPackage.export(incoming), onConflict: .replace)
        #expect(result.conflictResolution == .replace)
        #expect(result.entry.presetId == mine.presetId)
        let stored = try presets.entry(mine.presetId)
        #expect(stored.name == "Theirs" && stored.origin == .imported)
        #expect(presets.list().all.count == 7)

        let builtIn = presets.list().builtIn[0].preset
        let builtInData = try PresetPackage.export(builtIn)
        #expect(code { () throws(LibraryError) in _ = try presets.importPackage(builtInData, onConflict: .replace) } == "library.builtin_read_only")
        #expect(try presets.importPackage(builtInData).entry.presetId != builtIn.presetId)
    }

    @Test("逐项修改（D-93）：通过与导入相同的检查后原子写入；失败时不改文件；内置只读")
    func edit() throws {
        let copy = try presets.duplicate(presets.list().builtIn[0].presetId, name: "Mine")
        let margin = try PresetFieldPath(parsing: "canvas.minMarginPx")
        let result = try presets.edit(copy.presetId, [.set(margin, .number(80))])
        #expect(result.entry.preset.canvas.minMarginPx == 80)
        #expect(result.entry.origin == .user && result.entry.createdAt == copy.createdAt)
        #expect(try presets.entry(copy.presetId).preset.canvas.minMarginPx == 80)
        let before = try Data(contentsOf: presets.fileURL(copy.presetId))

        let unknown = try PresetFieldPath(parsing: "canvas.blur")
        #expect(code { () throws(LibraryError) in _ = try presets.edit(copy.presetId, [.set(margin, .number(10)), .set(unknown, .number(1))]) }
                == "package.invalid_preset")
        #expect(code { () throws(LibraryError) in _ = try presets.edit(copy.presetId, [.set(margin, .string("wide"))]) }
                == "preset.invalid_field")
        #expect(code { () throws(LibraryError) in _ = try presets.edit(copy.presetId, [.set(margin, .number(-5))]) }
                == "package.invalid_preset")
        let id = try PresetFieldPath(parsing: "presetId")
        #expect(code { () throws(LibraryError) in _ = try presets.edit(copy.presetId, [.set(id, .string(UUID().uuidString))]) }
                == "preset.field_read_only")
        #expect(try Data(contentsOf: presets.fileURL(copy.presetId)) == before)

        let builtIn = presets.list().builtIn[0].presetId
        #expect(code { () throws(LibraryError) in _ = try presets.edit(builtIn, [.set(margin, .number(80))]) } == "library.builtin_read_only")
        #expect(root.allFiles().filter { $0.contains(".tmp-") }.isEmpty)
    }

    @Test("导入失败的包不写任何文件")
    func importInvalid() throws {
        var newer = try JSONSerialization.jsonObject(with: PresetSchema.encode(samplePreset())) as! [String: Any]
        newer["schemaVersion"] = 99
        var zip = ZipWriter()
        zip.add(name: PresetPackage.manifestName, data: try JSONSerialization.data(withJSONObject: newer))
        let data = zip.finish()
        #expect(try presets.previewImport(data).requiresNewerApp)
        #expect(code { () throws(LibraryError) in _ = try presets.importPackage(data) } == "preset.newer_schema_version")
        #expect(code { () throws(LibraryError) in _ = try presets.importPackage(Data("not a zip".utf8)) } == "archive.not_zip")
        #expect(root.allFiles().isEmpty)
    }

    @Test("导出：可以再导入；内置预设也能导出；文件名去掉路径分隔符")
    func export() throws {
        let entry = try presets.add(samplePreset())
        let out = root.url.appending(path: "out/" + PresetLibrary.suggestedFileName(for: entry.name))
        try presets.exportPackage(entry.presetId, to: out)
        let back = try PresetPackage.importPreset(try PresetPackage.readFile(at: out))
        #expect(back.preset == entry.preset)
        _ = try presets.exportPackage(presets.list().builtIn[0].presetId)
        #expect(PresetLibrary.suggestedFileName(for: "a/b:c\\d") == "a-b-c-d.photoframe")
        #expect(PresetLibrary.suggestedFileName(for: "..") == "Preset.photoframe")
    }

    @Test("导出前的隐私检查（D-37）")
    func exportPrivacy() throws {
        var p = samplePreset()
        p.extensions["x-note"] = .string("/Users/someone/Pictures/signature.png")
        let entry = try presets.add(p)
        #expect(code { () throws(LibraryError) in _ = try presets.exportPackage(entry.presetId) } == "package.private_data")
    }

    // MARK: 损坏与兼容

    @Test("损坏、版本过新、ID 不符的文件只跳过它自己并警告，文件不被改动")
    func corruptFilesAreSkipped() throws {
        let good = try presets.add(samplePreset(name: "Good"))
        let dir = presets.directory

        let corruptId = UUID()
        try Data("{ not json".utf8).write(to: dir.appending(path: "\(corruptId.uuidString).json"))

        let newerId = UUID()
        var newerManifest = try JSONSerialization.jsonObject(with: PresetSchema.encode(samplePreset(id: newerId))) as! [String: Any]
        newerManifest["schemaVersion"] = 42
        let newerFile = try JSONSerialization.data(withJSONObject: [
            "storageFormat": 1, "origin": "user", "createdAt": "2026-10-16T00:00:00Z",
            "modifiedAt": "2026-10-16T00:00:00Z", "preset": newerManifest,
        ])
        try newerFile.write(to: dir.appending(path: "\(newerId.uuidString).json"))

        let futureStorageId = UUID()
        try Data(#"{"storageFormat": 7, "whatever": true}"#.utf8).write(to: dir.appending(path: "\(futureStorageId.uuidString).json"))

        let mismatchId = UUID()
        try FileManager.default.copyItem(at: dir.appending(path: "\(good.presetId.uuidString).json"),
                                         to: dir.appending(path: "\(mismatchId.uuidString).json"))
        try Data("x".utf8).write(to: dir.appending(path: "notes.json"))
        try Data("partial".utf8).write(to: dir.appending(path: ".\(UUID().uuidString).json.tmp-123"))

        let listing = presets.list()
        #expect(listing.user.map(\.presetId) == [good.presetId])
        let codes = Dictionary(grouping: listing.warnings, by: \.item).mapValues { $0.map(\.code) }
        #expect(codes["\(corruptId.uuidString).json"] == ["library.unreadable_preset"])
        #expect(codes["\(newerId.uuidString).json"] == ["library.newer_schema_version"])
        #expect(codes["\(futureStorageId.uuidString).json"] == ["library.newer_storage_format"])
        #expect(codes["\(mismatchId.uuidString).json"] == ["library.id_mismatch"])
        #expect(codes["notes.json"] == ["library.unexpected_file"])
        #expect(listing.unreadableIds == [corruptId, newerId, futureStorageId, mismatchId])
        // 警告里不出现绝对路径。
        #expect(listing.warnings.allSatisfy { !$0.message.contains(root.url.path) && !$0.item.contains("/") })

        // 读不出来的文件保持原样。
        #expect(try Data(contentsOf: dir.appending(path: "\(newerId.uuidString).json")) == newerFile)
        #expect(code { () throws(LibraryError) in _ = try presets.entry(corruptId) } == "library.unreadable_item")
        #expect(code { () throws(LibraryError) in _ = try presets.update(samplePreset(id: corruptId)) } == "library.unreadable_item")

        // 导入同 ID 的预设：算作冲突，默认另存为副本，不覆盖读不出来的文件。
        let incoming = try PresetPackage.export(samplePreset(id: newerId))
        #expect(try presets.importPackage(incoming).entry.presetId != newerId)
        #expect(try Data(contentsOf: dir.appending(path: "\(newerId.uuidString).json")) == newerFile)

        // 读不出来的文件可以删除。
        try presets.delete(corruptId)
        #expect(!presets.list().unreadableIds.contains(corruptId))
    }

    @Test("文件里不认识的字段保留并警告，保存后仍在")
    func unknownFieldsKept() throws {
        let entry = try presets.add(samplePreset())
        let url = presets.directory.appending(path: "\(entry.presetId.uuidString).json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var manifest = object["preset"] as! [String: Any]
        manifest["futureThing"] = 1
        manifest["x-mine"] = "keep"
        object["preset"] = manifest
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let loaded = try presets.entry(entry.presetId)
        #expect(loaded.warnings.map(\.code) == ["library.unknown_fields"])
        try presets.rename(entry.presetId, to: "Renamed")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let savedManifest = saved["preset"] as! [String: Any]
        #expect(savedManifest["futureThing"] as? Int == 1)
        #expect(savedManifest["x-mine"] as? String == "keep")
    }

    @Test("原子写：写入失败时原文件不变，不留临时文件")
    func atomicWriteFailure() throws {
        let entry = try presets.add(samplePreset(name: "Before"))
        let url = presets.directory.appending(path: "\(entry.presetId.uuidString).json")
        let before = try Data(contentsOf: url)
        chmod(presets.directory.path, 0o500)
        defer { chmod(presets.directory.path, 0o755) }
        #expect(code { () throws(LibraryError) in _ = try presets.rename(entry.presetId, to: "After") } == "library.io")
        chmod(presets.directory.path, 0o755)
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: presets.directory.path) == [url.lastPathComponent])
        #expect(try presets.entry(entry.presetId).name == "Before")
    }

    @Test("原子写：并发保存同一个预设，结果总是某一次完整的内容")
    func concurrentSaves() throws {
        let entry = try presets.add(samplePreset())
        let library = presets
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            var p = entry.preset
            p.name = "Name \(i)"
            p.canvas.minMarginPx = i
            _ = try? library.update(p)
        }
        let final = try presets.entry(entry.presetId).preset
        #expect(final.name == "Name \(final.canvas.minMarginPx)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: presets.directory.path).count == 1)
    }
}

@Suite("库的位置（D-78、D-124）")
struct LibraryLocationTests {
    let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    @Test("App Group 容器里的库目录")
    func groupContainerLayout() {
        let container = LibraryLocation.groupContainerPath(appGroupIdentifier: "group.example", home: home)
        #expect(container.path == "/Users/someone/Library/Group Containers/group.example")
        #expect(LibraryLocation.root(inGroupContainer: container).path
            == "/Users/someone/Library/Group Containers/group.example/Library/Application Support/AnotherPhotoFrame")
        #expect(LibraryLocation.appGroupIdentifier == "group.org.anotherphotoframe")
    }

    @Test("选根目录：环境变量 > 带 entitlement 的容器 > 已存在的 Group Containers 目录 > Application Support")
    func resolveRoot() {
        let group = "/Users/someone/Library/Group Containers/group.example/Library/Application Support/AnotherPhotoFrame"
        func resolve(_ env: [String: String] = [:], entitled: URL? = nil, exists: Bool = false) -> String {
            LibraryLocation.resolveRoot(environment: env, entitledContainer: entitled, home: home,
                                        appGroupIdentifier: "group.example", fileExists: { _ in exists }).path
        }
        #expect(resolve() == "/Users/someone/Library/Application Support/AnotherPhotoFrame")
        #expect(resolve(exists: true) == group)
        let sandboxed = URL(filePath: "/Users/someone/Library/Group Containers/group.example", directoryHint: .isDirectory)
        #expect(resolve(entitled: sandboxed) == group)
        #expect(resolve(["PHOTOFRAME_LIBRARY": "/tmp/lib"], entitled: sandboxed, exists: true) == "/tmp/lib")
        #expect(resolve(["PHOTOFRAME_LIBRARY": ""]) == "/Users/someone/Library/Application Support/AnotherPhotoFrame")
    }

    @Test("测试进程没有 App Group entitlement，默认根目录在真实主目录下")
    func defaultRootOfThisProcess() {
        #expect(!LibraryLocation.hasAppGroupEntitlement(LibraryLocation.appGroupIdentifier))
        #expect(LibraryLocation.defaultRoot().path.hasPrefix(LibraryLocation.userHomeDirectory().path)
            || ProcessInfo.processInfo.environment["PHOTOFRAME_LIBRARY"] != nil)
    }
}
