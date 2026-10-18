import Foundation
import PhotoFrameApplication
import PhotoFrameCore
@testable import PhotoFrameMacModel
import Testing

/// 2026-10-18 审查报告里用户同意修改的界面行为（B 组）与文字（T 组）。
@MainActor @Suite struct InteractionTests {
    /// 加一张源图并用预设创建任务，返回（源图、任务）。
    private func job(_ f: Fixture, _ url: URL, preset: String = "Instagram Standard") async throws -> (SourceID, UUID) {
        let wb = f.workbench
        let ids = await wb.addSources([url])
        let sourceId = try #require(ids.first)
        await wb.drop(.preset(f.presetId(preset)), on: .source(sourceId))
        await wb.settle()
        return (sourceId, try #require(wb.sourceItem(sourceId)?.jobs.last?.id))
    }

    /// 预览渲染完、回退到存在的页之后再看（回退会再渲染一次）。
    private func settlePreview(_ wb: Workbench) async {
        for _ in 0..<4 { await wb.settle() }
    }

    // MARK: B1 右键菜单作用于右键点到的行

    @Test func menuActionsApplyToTheClickedRows() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let (sourceA, a) = try await job(f, try f.photo("A.jpg"))
        let (_, b) = try await job(f, try f.photo("B.jpg"))
        wb.selection = [.job(a)]

        // 右键点到没选中的 B 选「移除」：移除的是 B，A 仍然选中。
        wb.remove([.job(b)])
        #expect(wb.job(b) == nil && wb.job(a) != nil)
        #expect(wb.selection == [.job(a)])

        // 「位置」作用于源图时改它的全部任务。
        wb.addLocation(f.root.appending(path: "Other", directoryHint: .isDirectory), name: "Other")
        let other = try #require(wb.locations.locations.last)
        wb.duplicateJobs([a])
        wb.setDestination(other.url, for: [.source(sourceA)])
        #expect(wb.sourceItem(sourceA)?.jobs.count == 2)
        #expect(wb.sourceItem(sourceA)?.jobs.allSatisfy { $0.destination == other.url } == true)

        // 「存储为预设…」作用于点到的任务，不看选择。
        wb.selection = []
        wb.updateJobs([a]) { $0.preset.canvas.minMarginPx = 99 }
        await wb.saveJobAsPreset(a, name: "Clicked")
        #expect(wb.presets.first { $0.name == "Clicked" }?.minMarginPx == 99)
    }

    // MARK: B19 拖放与菜单作用于同样的对象

    @Test func dropsAndMenusTargetTheSameRows() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let (sourceA, a) = try await job(f, try f.photo("A.jpg"))
        let (sourceB, b) = try await job(f, try f.photo("B.jpg"))
        wb.addLocation(f.root.appending(path: "Other", directoryHint: .isDirectory), name: "Other")
        let other = try #require(wb.locations.locations.last)

        // 位置拖到多选的任务之一：全部选中的任务都改。
        wb.selection = [.job(a), .job(b)]
        #expect(await wb.drop(.location(other.id), on: .job(a)))
        #expect(wb.job(a)?.destination == other.url && wb.job(b)?.destination == other.url)

        // 拖到没选中的行：只改这一行。
        wb.selection = [.job(b)]
        await wb.drop(.location(try #require(wb.locations.locations.first).id), on: .job(a))
        #expect(wb.job(a)?.destination == f.exports && wb.job(b)?.destination == other.url)

        // 源图头部的「添加」菜单与拖放一样：这张源图是选中的之一时，每张选中的源图各建一个。
        wb.selection = [.source(sourceA), .source(sourceB)]
        await wb.addJobs(preset: f.presetId("XHS Standard"), onto: sourceA)
        #expect(wb.sourceItem(sourceA)?.jobs.count == 2 && wb.sourceItem(sourceB)?.jobs.count == 2)
    }

    // MARK: B4 不输出封面的全景

    @Test func panoramaWithoutCoverPagesThroughSlides() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        _ = try await job(f, try f.photo("Wide.jpg", width: 720, height: 240), preset: "Instagram Panorama")
        wb.setField(\.panorama.cover, false)
        await settlePreview(wb)
        let preview = wb.preview
        // 没有第 0 页：显示第 1 张切片，不是空白。
        #expect(preview.roles.first == .slide(position: 1) && !preview.roles.contains(.cover))
        #expect(preview.page == .page(1) && preview.pageImage != nil)
        #expect(!preview.canStep(-1) && preview.canStep(1))
        // ‹ › 按页面列表翻，能到最后一张。
        for _ in 1..<preview.roles.count { preview.step(1) }
        await settlePreview(wb)
        #expect(preview.page == .page(preview.roles.count) && preview.pageImage != nil && !preview.canStep(1))
    }

    // MARK: B5 手动张数

    @Test func manualSlideCountStartsFromEachJobsAutomaticCount() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let (_, narrow) = try await job(f, try f.photo("Narrow.jpg", width: 360, height: 240), preset: "Instagram Panorama")
        let (_, wide) = try await job(f, try f.photo("Wide.jpg", width: 720, height: 240), preset: "Instagram Panorama")
        let narrowAuto = try #require(wb.job(narrow)?.slideCount)
        let wideAuto = try #require(wb.job(wide)?.slideCount)
        #expect(narrowAuto < wideAuto)

        // 不输出封面也一样从自动张数开始（不是「封面 + 切片」的页数减一）；多选时每个任务按自己的源图算。
        wb.selection = [.job(narrow), .job(wide)]
        wb.setField(\.panorama.cover, false)
        #expect(wb.slideCountIsManual == .single(false))
        wb.setSlideCountManual(true)
        await wb.settle()
        #expect(wb.job(narrow)?.preset.panorama.tileCount == .fixed(narrowAuto))
        #expect(wb.job(wide)?.preset.panorama.tileCount == .fixed(wideAuto))
        #expect(wb.job(narrow)?.validation?.errors.isEmpty == true && wb.job(wide)?.validation?.errors.isEmpty == true)

        // 步进范围：自动张数 … 平台轮播上限（Instagram 20 项；没有封面时 20 张切片都可以）。
        wb.selection = [.job(narrow)]
        #expect(wb.manualSlideCountRange == narrowAuto...20)
        wb.setField(\.panorama.cover, true)
        #expect(wb.manualSlideCountRange == narrowAuto...19)

        // 一个手动、一个自动：「多个值」。
        wb.setSlideCountManual(false)
        wb.selection = [.job(narrow), .job(wide)]
        #expect(wb.slideCountIsManual == .mixed)
    }

    // MARK: B6 再点仍然高亮的行

    @Test func clickingAHighlightedRowBringsTheInspectorBack() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let (_, a) = try await job(f, try f.photo("A.jpg"))
        let preset = f.presetId("XHS Standard")
        wb.selectedPresetId = preset
        await wb.settle()
        #expect(wb.inspectorSubject == .preset(preset))
        // 任务 A 还是选中的（选择没变）：点它时右栏切回任务。
        wb.focusBatch()
        #expect(wb.inspectorSubject == .jobs([a]))
        // 再点仍然选中的预设：切回预设。
        wb.focusPreset()
        #expect(wb.inspectorSubject == .preset(preset))
        let location = try #require(wb.locations.locations.first)
        wb.selectedLocationId = location.id
        wb.focusBatch()
        wb.focusLocation()
        #expect(wb.inspectorSubject == .location(location.id))
    }

    // MARK: B9 页码

    @Test func pageListIsParsedOnCommit() {
        #expect(SlidePages.parse("0, 2，3") == [0, 2, 3])
        #expect(SlidePages.parse("0, ") == [0])
        #expect(SlidePages.parse("") == [])
        #expect(SlidePages.text([3, 0, 2]) == "0, 2, 3")
    }

    // MARK: B11 菜单命令与按钮同样的可用规则

    @Test func commandsFollowTheirButtons() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        #expect(!wb.canStartBatch && !wb.canDuplicate)
        let (_, a) = try await job(f, try f.photo("A.jpg"))
        #expect(wb.canStartBatch && wb.canDuplicate && wb.isPreviewVisible && wb.canToggleSidebar)
        wb.mode = .active
        #expect(!wb.isPreviewVisible && !wb.canToggleSidebar && !wb.canDuplicate)
        wb.mode = .current
        // ⌘D 复制选中的任务；右栏是预设时复制预设。
        await wb.duplicateFocused()
        #expect(wb.sourceItem(try #require(wb.job(a)?.sourceId))?.jobs.count == 2)
        wb.selectedPresetId = f.presetId("XHS Standard")
        await wb.duplicateFocused()
        #expect(wb.presets(in: .user).map(\.name) == ["XHS Standard 副本"])
    }

    // MARK: B12「已完成」的选择和操作

    @Test func historyHasItsOwnSelectionAndOneRulePerAction() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let source = try await f.service.addSource(try f.photo("Q.jpg"))
        let preset = try await f.service.resolvePreset(.library("Instagram Standard")).preset
        let ids = try await f.service.submit(ExportRequest(
            sourceIds: [source.sourceId], presets: [preset], destination: ExportDestination(rootDirectory: f.exports)))
        await wb.refreshJobs()
        wb.jobSelection = Set(ids)
        // 「活跃」里选中的任务不出现在「已完成」的选择里。
        #expect(wb.selectedFinishedJobs.isEmpty)
        await wb.cancel(Set(ids))
        wb.historySelection = Set(ids)
        #expect(wb.selectedFinishedJobs == Set(ids))
        // 取消的任务只能重试，不能重新导出（行尾按钮、顶栏、右键菜单同一个判断）。
        #expect(wb.canRetry(ids[0]) && !wb.canReexport(ids[0]))
        await wb.reexport(Set(ids))
        #expect(wb.jobs.count == 1)
    }

    // MARK: B15 折起来的源图

    @Test func collapsedSourceOpensForItsSelectedJob() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let (sourceId, a) = try await job(f, try f.photo("A.jpg"))
        wb.selection = [.job(a)]
        wb.setCollapsed(sourceId, true)
        // 折起来后看不见的任务不再选中（⌫ 不会删掉看不见的东西）。
        #expect(wb.isCollapsed(sourceId) && wb.selection.isEmpty)
        // 新任务加到折起来的源图上：选中它时源图展开。
        await wb.drop(.preset(f.presetId("XHS Standard")), on: .source(sourceId))
        #expect(!wb.isCollapsed(sourceId))
        // 任务全部移除后不再记着折起来。
        wb.setCollapsed(sourceId, true)
        wb.remove(Set(try #require(wb.sourceItem(sourceId)).jobs.map { BatchItemID.job($0.id) }))
        #expect(wb.collapsedSources.isEmpty)
    }

    // MARK: B16 添加失败时的提示

    @Test func failedAddsAreReported() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let ids = await wb.addSources([try f.photo("A.jpg")])
        let location = try #require(wb.locations.locations.first)
        wb.removeLocation(location.id)
        await wb.addJobs(preset: f.presetId("Instagram Standard"), to: ids)
        #expect(wb.alert?.title == "无法添加任务" && wb.alert?.message.contains("没有输出位置") == true)
        #expect(wb.allJobs.isEmpty)

        // 拖入不支持的图片（HEIC）与「添加图片」一样汇总提示。
        wb.alert = nil
        let heic = f.root.appending(path: "IMG_0001.heic")
        try Data("not really".utf8).write(to: heic)
        #expect(await wb.dropFiles([heic]) == false)
        #expect(wb.alert?.title == "有图片没有添加" && wb.alert?.message.contains("IMG_0001.heic") == true)
        #expect(wb.alert?.message.contains("建议：") == true)
    }

    // MARK: B17 新图层先存储再绑定

    @Test func bindingANewLayerAsksToSaveFirst() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        await wb.importAssets([try f.assetPNG("mark.png")], category: .watermark)
        let asset = try #require(wb.assets.first)
        await wb.duplicatePreset(f.presetId("Instagram Standard"))
        await wb.settle()
        wb.addLayer(.watermark)
        await wb.bindAsset(asset.assetId, slotId: "watermark")
        #expect(wb.alert?.title == "无法绑定素材" && wb.alert?.message.contains("存储") == true)
        #expect(wb.binding(for: "watermark") == nil)
        wb.alert = nil
        await wb.savePresetEdits()
        await wb.settle()
        await wb.bindAsset(asset.assetId, slotId: "watermark")
        #expect(wb.alert == nil && wb.binding(for: "watermark")?.level == .preset)
    }

    // MARK: B18 批量导入一次提示

    @Test func batchImportReportsEveryProblemOnce() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let bad1 = f.root.appending(path: "One.photoframe"), bad2 = f.root.appending(path: "Two.photoframe")
        try Data("x".utf8).write(to: bad1)
        try Data("y".utf8).write(to: bad2)
        await wb.importPresets([bad1, bad2])
        let alert = try #require(wb.alert)
        #expect(alert.title == "有预设没有导入")
        #expect(alert.message.contains("One.photoframe") && alert.message.contains("Two.photoframe"))

        wb.alert = nil
        let badPNG = f.root.appending(path: "Broken.png")
        try Data("z".utf8).write(to: badPNG)
        await wb.importAssets([try f.assetPNG("ok.png"), badPNG], category: .signature)
        #expect(wb.alert?.title == "有素材没有导入" && wb.alert?.message.contains("Broken.png") == true)
        #expect(wb.assets.count == 1)
    }

    // MARK: T14 副本的名字

    @Test func copiesAreNamedInChinese() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        await wb.duplicatePreset(f.presetId("Instagram Standard"))
        await wb.duplicatePreset(f.presetId("Instagram Standard"))
        #expect(wb.presets(in: .user).map(\.name).sorted() == ["Instagram Standard 副本", "Instagram Standard 副本 2"])

        // 导入与已有预设 ID 相同的预设：另存为「原名 副本」，不是「原名 Copy」。
        let copy = try #require(wb.presets.first { $0.name == "Instagram Standard 副本" })
        let file = f.root.appending(path: "Mine.photoframe")
        await wb.exportPreset(copy.presetId, to: file)
        wb.alert = nil
        await wb.importPresets([file])
        #expect(wb.presets(in: .imported).map(\.name) == ["Instagram Standard 副本 副本"])
        #expect(wb.alert?.title == "导入完成" && wb.alert?.message.contains("另存为副本。") == true)
        #expect(Workbench.originalName(ofCopy: "My IG Copy 2") == "My IG")
    }

    // MARK: T5 / V24 输出摘要

    @Test func outputSummaryCountsPagesIncludingTheCover() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let (_, single) = try await job(f, try f.photo("A.jpg"))
        let (_, panorama) = try await job(f, try f.photo("B.jpg"), preset: "Instagram Panorama")
        #expect(wb.job(single)?.outputSummary == "1080 × 1440 · 1 页")
        let slides = try #require(wb.job(panorama)?.slideCount)
        #expect(wb.job(panorama)?.outputSummary == "1080 × 1440 · \(slides + 1) 页")
    }

    // MARK: T6 图层的名字

    @Test func layersAreNamedAsAddedNotByTheirIds() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let (_, a) = try await job(f, try f.photo("A.jpg"))
        wb.selection = [.job(a)]
        wb.addLayer(.watermark)
        wb.addLayer(.signature)
        wb.addLayer(.signature)
        let preset = try #require(wb.editedPreset)
        #expect(preset.title(ofLayer: "watermark") == "水印")
        #expect(preset.title(ofLayer: "signature-2") == "签名 2")
        // 警告里的图层、素材槽也用这些名字。
        await wb.settle()
        let messages = try #require(wb.job(a)?.issues).map(\.message)
        #expect(messages.contains { $0.contains("「水印」") }, "\(messages)")
        #expect(!messages.contains { $0.contains("watermark") || $0.contains("signature") }, "\(messages)")
        let issue = JobIssue(isError: false, code: "slot.optional_missing", message: "跳过图层「signature-2」和「signature」", hint: nil)
        #expect(issue.naming(preset.layerTitles).message == "跳过图层「签名 2」和「签名」")
    }

    // MARK: T9 修改建议

    @Test func hintsAreAlwaysLabelled() {
        #expect(ApplicationError(code: "x", message: "不能写入", hint: "换一个位置").displayText == "不能写入\n建议：换一个位置")
        #expect(ApplicationError(code: "x", message: "不能写入").displayText == "不能写入")
        // 多行弹窗正文每句都以句号结尾。
        #expect(WorkbenchAlert.paragraph(["a", "b。", "c：d\n建议：e"]) == "a。\nb。\nc：d。\n建议：e。")
    }

    // MARK: T22 标为 HDR 但没有高光

    @Test func taggedHDRWithoutHighlightsIsItsOwnCase() {
        #expect(SourceDynamicRange(.init(kind: "none", headroom: nil)) == .sdr)
        #expect(SourceDynamicRange(.init(kind: "gainMap", headroom: 1.0)) == .taggedWithoutHighlights)
        #expect(SourceDynamicRange(.init(kind: "gainMap", headroom: 4.0)) == .hdr)
        #expect(SourceDynamicRange(.init(kind: "floatLinear", headroom: nil)) == .hdr)
    }

    // MARK: V11 / B3 错误和警告各列一次

    @Test func warningsAreListedOnce() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let (sourceId, _) = try await job(f, try f.photoWithoutProfile("Scan.png"))
        // 源图的「警告」：源图检查和预览都报缺少 ICC，只列一次，并带修改建议。
        wb.selection = [.source(sourceId)]
        await settlePreview(wb)
        let missing = wb.inspectorIssues.filter { $0.code == "source.profile_missing" }
        #expect(missing.count == 1 && missing.first?.hint != nil, "\(wb.inspectorIssues)")

        // 「已完成」：执行的警告已经包含清单里的警告，不再相加。
        await wb.startBatch()
        await wb.resolveWarnings(.proceed)
        await f.waitForRun()
        let record = try #require(wb.finishedJobs.first)
        #expect(record.displayWarnings.count { $0.code == "source.profile_missing" } == 1, "\(record.displayWarnings)")
        #expect(record.issues.count == record.displayWarnings.count)

        // 读不出来的源图：错误也在同一个列表里。
        let broken = f.root.appending(path: "Broken.jpg")
        try Data("not a jpeg".utf8).write(to: broken)
        let ids = await wb.addSources([broken])
        await wb.settle()
        wb.selection = [.source(try #require(ids.first))]
        #expect(wb.inspectorIssues.contains { $0.isError })
    }
}
