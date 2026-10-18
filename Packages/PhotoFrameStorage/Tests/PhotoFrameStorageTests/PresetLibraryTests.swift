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

/// 加快速路径之前 `find` 对 UUID 的做法：读出整个库再查。用来核对快速路径的结果。
private func findInListing(_ presets: PresetLibrary, _ id: UUID) -> Result<PresetEntry, LibraryError> {
    let listing = presets.list()
    if let e = listing.entry(id) { return .success(e) }
    if listing.unreadableIds.contains(id) { return Result { () throws(LibraryError) in try presets.entry(id) } }
    return .failure(.presetNotFound(id))
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
        // 只有正式文件，没有残留的临时文件（库根目录的 `.lock` 是修改时用的锁文件）。
        let files = root.allFiles().filter { $0 != ".lock" }
        #expect(files.allSatisfy { $0.hasPrefix("Presets/") && !$0.contains(".tmp") })
        #expect(files.count == 2)
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

    @Test("引用的短名为空（只有 emoji 或符号）时不按短名匹配；完整名称仍能找到")
    func findEmptySlug() throws {
        let camera = try presets.add(samplePreset(name: "📷"))
        #expect(PresetLibrary.slug(for: "🎞").isEmpty && camera.slug.isEmpty)
        for reference in ["🎞", "!!", ""] {
            #expect(throws: LibraryError.presetReferenceNotFound(reference)) { try presets.find(reference) }
        }
        #expect(try presets.find("📷") == camera)
        _ = try presets.add(samplePreset(name: "🎥"))
        #expect(try presets.find("📷") == camera)
    }

    @Test("按 UUID 查找：快速路径与读出整个库的结果完全相同（找到、损坏、缺失、文件名不规范）")
    func findByIdMatchesListing() throws {
        let dir = presets.directory
        let user = try presets.add(samplePreset(name: "User"))
        let imported = try presets.importPackage(try PresetPackage.export(samplePreset(name: "Imported"))).entry

        // 带不认识的字段：条目的警告里有文件名。
        func addUnknownField(_ url: URL) throws {
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var manifest = object["preset"] as! [String: Any]
            manifest["futureThing"] = 1
            object["preset"] = manifest
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }
        let unknown = try presets.add(samplePreset(name: "Unknown")).presetId
        try addUnknownField(presets.fileURL(unknown))

        // 读不出来：缺字段、存储格式过新、文件名与 presetId 不符、不是 JSON。
        let corrupt = UUID()
        try Data(#"{"storageFormat": 1, "origin": "user"}"#.utf8).write(to: presets.fileURL(corrupt))
        let newer = UUID()
        try Data(#"{"storageFormat": 7}"#.utf8).write(to: presets.fileURL(newer))
        let mismatch = UUID()
        try FileManager.default.copyItem(at: presets.fileURL(user.presetId), to: presets.fileURL(mismatch))
        let notJSON = UUID()
        try Data("{ not json".utf8).write(to: presets.fileURL(notJSON))

        // 与内置预设同 ID 的用户文件：仍然返回内置预设。
        let builtIn = presets.list().builtIn[3].preset
        try LibraryPresetFile(origin: .user, createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0))
            .encode(builtIn).write(to: presets.fileURL(builtIn.presetId))

        // 文件名不规范（list() 读不到或读到的文件名不同）：小写 UUID、大写扩展名、符号链接、隐藏、目录。
        let lower = try presets.add(samplePreset(name: "Lower")).presetId
        let lowerURL = dir.appending(path: "\(lower.uuidString.lowercased()).json")
        #expect(rename(presets.fileURL(lower).path, lowerURL.path) == 0)
        try addUnknownField(lowerURL)
        let upperExtension = try presets.add(samplePreset(name: "Upper")).presetId
        #expect(rename(presets.fileURL(upperExtension).path, dir.appending(path: "\(upperExtension.uuidString).JSON").path) == 0)
        let linked = UUID()
        try FileManager.default.createSymbolicLink(at: presets.fileURL(linked), withDestinationURL: presets.fileURL(user.presetId))
        let hidden = try presets.add(samplePreset(name: "Hidden")).presetId
        #expect(chflags(presets.fileURL(hidden).path, UInt32(UF_HIDDEN)) == 0)
        let folder = UUID()
        try FileManager.default.createDirectory(at: presets.fileURL(folder), withIntermediateDirectories: false)

        // 卷不区分大小写时（macOS 默认）正常文件走快速路径。
        let caseInsensitive = try dir.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false
        for id in [user.presetId, imported.presetId, unknown, corrupt, newer, mismatch, notJSON] {
            #expect(presets.hasCanonicalFile(id) == caseInsensitive)
        }
        for id in [lower, upperExtension, linked, hidden, folder, UUID()] {
            #expect(!presets.hasCanonicalFile(id))
        }

        let all = [user.presetId, imported.presetId, unknown, corrupt, newer, mismatch, builtIn.presetId,
                   lower, upperExtension, linked, hidden, folder, UUID()]
        for id in all {
            for reference in [id.uuidString, id.uuidString.lowercased()] {
                let found = Result { () throws(LibraryError) in try presets.find(reference) }
                #expect(found == findInListing(presets, id), "\(reference)")
            }
        }
        // 不是 JSON 时原因里带着 NSError 的 userInfo，字典的打印顺序每次可能不同（以前就这样），不逐字比较原因。
        for r in [Result { () throws(LibraryError) in try presets.find(notJSON.uuidString) }, findInListing(presets, notJSON)] {
            guard case .failure(.unreadableItem(let id, let reason)) = r else {
                Issue.record("应为 library.unreadable_item：\(r)")
                continue
            }
            #expect(id == notJSON.uuidString && reason.hasPrefix("DecodingError.dataCorrupted"))
        }

        // 几个结果本身。
        #expect(try presets.find(user.presetId.uuidString) == user)
        #expect(try presets.find(imported.presetId.uuidString).origin == .imported)
        #expect(try presets.find(unknown.uuidString).warnings.map(\.item) == ["\(unknown.uuidString).json"])
        #expect(try presets.find(lower.uuidString).warnings.map(\.item) == [lowerURL.lastPathComponent])
        #expect(try presets.find(builtIn.presetId.uuidString).origin == .builtIn)
        #expect(throws: LibraryError.unreadableItem(id: corrupt.uuidString, reason: "读写文件失败：缺少 preset 字段")) {
            try presets.find(corrupt.uuidString)
        }
        for id in [newer, mismatch] {
            #expect(code { () throws(LibraryError) in _ = try presets.find(id.uuidString) } == "library.unreadable_item")
        }
        for id in [upperExtension, linked, hidden, folder] {
            #expect(throws: LibraryError.presetNotFound(id)) { try presets.find(id.uuidString) }
        }
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

    @Test("不同进程同时改名和修改同一个预设：两边的修改都保留")
    func concurrentRenameAndEdit() throws {
        let margin = try PresetFieldPath(parsing: "canvas.minMarginPx")
        // 两个实例模拟 GUI 与 CLI / MCP 两个进程（锁文件各自打开，与跨进程相同）。
        let a = PresetLibrary(root: root.url, platforms: testCatalog)
        let b = PresetLibrary(root: root.url, platforms: testCatalog)
        for round in 0..<60 {
            let copy = try presets.duplicate(presets.list().builtIn[0].presetId, name: "Race \(round)")
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                if i == 0 {
                    _ = try? a.rename(copy.presetId, to: "Renamed \(round)")
                } else {
                    _ = try? b.edit(copy.presetId, [.set(margin, .number(Double(100 + round)))])
                }
            }
            let result = try presets.entry(copy.presetId).preset
            #expect(result.name == "Renamed \(round)", "第 \(round) 轮改名丢了")
            #expect(result.canvas.minMarginPx == 100 + round, "第 \(round) 轮修改丢了")
        }
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
        #expect(root.allFiles().filter { $0.contains(".tmp") }.isEmpty)
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
        // 崩溃留下的临时文件：旧版本的命名和现在的命名。
        try Data("partial".utf8).write(to: dir.appending(path: ".\(UUID().uuidString).json.tmp-123"))
        try Data("partial".utf8).write(to: dir.appending(path: ".pf-\(UUID().uuidString).tmp"))

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

    @Test("原子写：目标文件名有 250 个字符也能写入，不留临时文件")
    func longFileName() throws {
        let entry = try presets.add(samplePreset())
        let dir = root.url.appending(path: "out", directoryHint: .isDirectory)
        let url = dir.appending(path: String(repeating: "a", count: 239) + ".photoframe")
        #expect(url.lastPathComponent.utf16.count == 250)
        try presets.exportPackage(entry.presetId, to: url)
        #expect(try PresetPackage.importPreset(PresetPackage.readFile(at: url)).preset == entry.preset)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [url.lastPathComponent])
    }

    @Test("存盘后会超过读取上限的预设不写入：导入、新增、替换都报错，已有文件不变")
    func oversizedStoredFile() throws {
        // manifest 本身不到 1 MiB，能通过导入检查；存盘时多一层缩进，超过 1 MiB。
        var big = samplePreset(name: "Big")
        big.extensions["x-padding"] = .array(Array(repeating: .number(0), count: 120_000))
        #expect(try PresetSchema.encode(big).count < PresetLibrary.maxFileBytes)
        let package = try PresetPackage.export(big)

        do {
            _ = try presets.importPackage(package)
            Issue.record("应拒绝")
        } catch {
            #expect(error.code == "library.io")
            #expect(error.message.hasPrefix("读写文件失败：写入 "))
            #expect(error.message.hasSuffix(" 字节，超过上限 \(PresetLibrary.maxFileBytes) 字节"))
        }
        #expect(code { () throws(LibraryError) in _ = try presets.add(big) } == "library.io")
        #expect(root.allFiles().isEmpty)

        // 替换同 ID 的已有预设失败时，原文件不变。
        var small = big
        small.extensions = [:]
        let existing = try presets.add(small)
        let before = try Data(contentsOf: presets.fileURL(existing.presetId))
        #expect(code { () throws(LibraryError) in _ = try presets.importPackage(package, onConflict: .replace) } == "library.io")
        #expect(try Data(contentsOf: presets.fileURL(existing.presetId)) == before)
        #expect(root.allFiles() == ["Presets/\(existing.presetId.uuidString).json"])
        let listing = presets.list()
        #expect(listing.user.map(\.presetId) == [existing.presetId] && listing.warnings.isEmpty)
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
