import CoreGraphics
import Foundation
import PhotoFrameApplication
import PhotoFrameCore
@testable import PhotoFrameMacModel
import Testing

@MainActor @Suite struct PreviewModelTests {
    @Test func previewFollowsSelectedJob() async throws {
        let f = try Fixture()
        await f.workbench.load()
        try await f.addJob()
        let preview = f.workbench.preview
        await f.workbench.settle()
        let page = try #require(preview.pageImage)
        // 预览从不大于导出尺寸；长边上限足够大时就是成品尺寸。
        #expect(page.pixelSize == page.exportPixelSize)
        #expect(preview.roles == [.cover])
        #expect(!preview.hasStrip)

        f.workbench.setField(\.canvas.background.hex, "#000000")
        await f.workbench.settle()
        #expect(preview.pageImage != page)

        f.workbench.selection = []
        await f.workbench.settle()
        #expect(preview.subject == nil && preview.pageImage == nil)
    }

    @Test func panoramaStripAndPageSwitching() async throws {
        let f = try Fixture()
        await f.workbench.load()
        try await f.addJob("Wide.jpg", preset: "Instagram Panorama")
        let preview = f.workbench.preview
        await f.workbench.settle()
        #expect(preview.hasStrip)
        let slides = preview.roles.count - 1
        #expect(slides >= 1)

        preview.page = .page(1)
        await f.workbench.settle()
        #expect(preview.pageImage?.role == .slide(position: 1))

        preview.page = .strip
        await f.workbench.settle()
        #expect(preview.strip.count == preview.roles.count)
        #expect(preview.strip.allSatisfy { $0.pixelSize.width <= PreviewModel.stripLongEdge && $0.pixelSize.height <= PreviewModel.stripLongEdge })
    }

    @Test func sourceWithoutJobsShowsOriginalOnly() async throws {
        let f = try Fixture()
        let ids = await f.workbench.addSources([try f.photo("Solo.jpg")])
        f.workbench.selection = [.source(try #require(ids.first))]
        await f.workbench.settle()
        #expect(f.workbench.preview.subject?.preset == nil)
        #expect(f.workbench.preview.pageImage == nil)
    }

    @Test func hdrRangeShowsGainMapPages() async throws {
        let f = try Fixture()
        await f.workbench.load()
        try await f.addJob("Bright.tif", hdr: true)
        f.workbench.setField(\.output.dynamicRange, .hdr)
        let preview = f.workbench.preview
        // HDR 源图自动打开 HDR 预览；手动切回 SDR 后同一张源图上保持 SDR。
        #expect(preview.range == .hdr)
        preview.range = .sdr
        await f.workbench.settle()
        #expect(preview.pageImage?.dynamicRange == .sdr, "SDR 模式显示 SDR 底图")

        preview.range = .hdr
        await f.workbench.settle()
        let page = try #require(preview.pageImage)
        #expect(page.dynamicRange == .hdr && page.format == .jpeg)
        let image = try #require(page.displayImage())
        #expect(image.contentHeadroom > 1, "按 HDR 解码：\(image.contentHeadroom)")
        // 画面用的是后台解码好的同一张图，同样按 HDR 解码。
        let shown = try #require(preview.pageDisplayImage)
        #expect(shown.contentHeadroom == image.contentHeadroom && shown.width == image.width)

        // 预设输出 SDR：HDR 模式仍是 SDR，并说明原因。
        f.workbench.setField(\.output.dynamicRange, .sdr)
        await f.workbench.settle()
        #expect(preview.pageImage?.dynamicRange == .sdr)
        #expect(preview.warnings.contains { $0.code == "preview.output_sdr" })
        // 预览区不显示提示，Inspector 的「警告」里有，作为说明排在最后。
        let issue = try #require(f.workbench.inspectorIssues.last)
        #expect(issue.code == "preview.output_sdr" && issue.isInfo)
    }

    @Test func previewRangeFollowsTheSelectedSource() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let sdr = try await f.addJob()
        let hdr = try await f.addJob("Bright.tif", hdr: true)
        let wb = f.workbench
        let preview = wb.preview
        wb.selection = [.job(hdr)]
        #expect(preview.range == .hdr)
        // 还在同一张源图上：手动选的 SDR 不被改回来。
        preview.range = .sdr
        wb.setField(\.canvas.minMarginPx, 30)
        #expect(preview.range == .sdr)
        wb.selection = [.job(sdr)]
        #expect(preview.range == .sdr)
        wb.selection = [.job(hdr)]
        #expect(preview.range == .hdr)
        wb.selection = [.job(sdr)]
        #expect(preview.range == .sdr)
    }

    @Test func autoRangeFollowsSource() async throws {
        let f = try Fixture()
        await f.workbench.load()
        try await f.addJob("Bright.tif", hdr: true)
        let preview = f.workbench.preview
        preview.range = .hdr
        await f.workbench.settle()
        // 内置预设跟随源图（D-125）：HDR 源图直接导出 HDR，不用手动改。
        #expect(f.workbench.editedPreset?.output.dynamicRange == .auto)
        #expect(f.workbench.autoRangeResult == "HDR（源图是 HDR）")
        #expect(preview.pageImage?.dynamicRange == .hdr)
        #expect(!preview.warnings.contains { $0.code == "preview.output_sdr" })

        f.workbench.setField(\.output.format, .png)
        await f.workbench.settle()
        #expect(f.workbench.autoRangeResult == "SDR（PNG 不支持 HDR）")
        #expect(preview.pageImage?.dynamicRange == .sdr)

        f.workbench.setField(\.output.dynamicRange, .sdr)
        #expect(f.workbench.autoRangeResult == nil)

        let plain = try await f.addJob("Plain.jpg")
        f.workbench.selection = [.job(plain)]
        #expect(f.workbench.autoRangeResult == "SDR（源图不是 HDR）")
    }

    @Test func presetPreviewUsesFirstSource() async throws {
        let f = try Fixture()
        await f.workbench.load()
        await f.workbench.addSources([try f.photo("P.jpg")])
        f.workbench.selectedPresetId = f.presetId("XHS Standard")
        await f.workbench.settle()
        #expect(f.workbench.preview.subject?.preset?.name == "XHS Standard")
        #expect(f.workbench.preview.pageImage != nil)
    }
}

@MainActor @Suite struct PreviewZoomTests {
    @Test func fitScaleFitsWholePage() {
        // 1080 × 1440 的页放进 880 × 440 pt 的区域（Retina），四周留 16 pt。
        let fit = PreviewZoom.fitScale(contentPixels: CGSize(width: 1080, height: 1440), in: CGSize(width: 880, height: 440), displayScale: 2)
        #expect(abs(fit - (408.0 * 2 / 1440)) < 0.0001)
        let shown = CGSize(width: 1080 * fit / 2, height: 1440 * fit / 2)
        #expect(shown.width <= 848 && shown.height <= 408 + 0.001)
        // 很宽的全景长卷按宽度适配。
        let strip = PreviewZoom.fitScale(contentPixels: CGSize(width: 6000, height: 640), in: CGSize(width: 880, height: 440), displayScale: 2)
        #expect(abs(strip - (848.0 * 2 / 6000)) < 0.0001)
    }

    @Test func menuTitleAndSteps() throws {
        let f = try Fixture()
        let preview = f.workbench.preview
        preview.fitScale = 0.567
        #expect(preview.zoom == .fit && preview.effectiveScale == 0.567)
        #expect(preview.zoomTitle == "适合窗口 57%")

        // 从「适合窗口」开始放大、缩小都从实际比例出发。
        preview.zoomIn()
        #expect(preview.zoom == .scale(0.75) && preview.zoomTitle == "75%")
        preview.zoomIn()
        #expect(preview.zoom == .actualSize && preview.zoomTitle == "100%")
        preview.zoom = .fit
        preview.zoomOut()
        #expect(preview.zoom == .scale(0.5))
        for _ in 0..<20 { preview.zoomOut() }
        #expect(preview.zoom == .scale(PreviewZoom.steps.first!))
        for _ in 0..<20 { preview.zoomIn() }
        #expect(preview.zoom == .scale(PreviewZoom.steps.last!))
    }

    @Test func pinchIsClamped() throws {
        let f = try Fixture()
        let preview = f.workbench.preview
        preview.magnify(from: 1, by: 1.5)
        #expect(preview.zoom == .scale(1.5))
        preview.magnify(from: 1, by: 100)
        #expect(preview.zoom == .scale(PreviewZoom.range.upperBound))
        preview.magnify(from: 1, by: 0.001)
        #expect(preview.zoom == .scale(PreviewZoom.range.lowerBound))
    }
}

@MainActor @Suite struct PreviewCacheTests {
    @Test func switchingBackUsesCachedRender() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let a = try await f.addJob("A.jpg", preset: "Instagram Standard")
        let b = try await f.addJob("B.jpg", preset: "XHS Standard")
        let preview = f.workbench.preview
        f.workbench.selection = [.job(a)]
        await f.workbench.settle()
        f.workbench.selection = [.job(b)]
        await f.workbench.settle()
        let requests = preview.renderRequests
        let first = try #require(preview.pageImage)

        // 切回看过的任务：立即显示（不用等后台），也不再请求后端。
        f.workbench.selection = [.job(a)]
        #expect(preview.pageImage != nil && preview.pageImage != first && !preview.isRendering)
        await f.workbench.settle()
        #expect(preview.renderRequests == requests)

        // 改了参数就是新的内容，要重新渲染。
        f.workbench.setField(\.canvas.minMarginPx, 120)
        await f.workbench.settle()
        #expect(preview.renderRequests == requests + 1)
    }
}

/// 预览内容什么时候算变了：素材绑定、源图加入和检查、渲染失败；解码和缓存。
@MainActor @Suite struct PreviewFreshnessTests {
    @Test func presetBindingChangesRerenderAndRevalidate() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        await wb.importAssets([try f.assetPNG("sig.png")], category: .signature)
        let asset = try #require(wb.assets(in: .signature).first)
        await wb.duplicatePreset(f.presetId("Instagram Standard"))
        await wb.settle()
        let presetId = try #require(wb.selectedPresetId)
        wb.addLayer(.signature)
        await wb.savePresetEdits()
        await wb.settle()
        // 一张源图和一个用这个预设的任务；右栏回到预设，预览用这张源图。
        let sourceIds = await wb.addSources([try f.photo("P.jpg")])
        let sourceId = try #require(sourceIds.first)
        await wb.drop(.preset(presetId), on: .source(sourceId))
        let jobId = try #require(wb.sourceItem(sourceId)?.jobs.first?.id)
        wb.selectedPresetId = nil
        wb.selectedPresetId = presetId
        await wb.settle()
        let preview = wb.preview
        #expect(preview.subject?.preset?.presetId == presetId)
        #expect(preview.warnings.contains { $0.code == "slot.optional_missing" })
        #expect(wb.job(jobId)?.validation?.warnings.contains { $0.code == "slot.optional_missing" } == true)

        // 绑定保存在预设本地：预览重新渲染（不用缓存里的旧结果），用这个预设的任务重新校验。
        let requests = preview.renderRequests
        await wb.bindAsset(asset.assetId, slotId: "signature")
        await wb.settle()
        #expect(preview.renderRequests == requests + 1)
        #expect(!preview.warnings.contains { $0.code == "slot.optional_missing" })
        #expect(wb.job(jobId)?.validation?.warnings.contains { $0.code == "slot.optional_missing" } == false)

        // 删除素材：绑定失效，同样重新渲染、重新校验。
        await wb.deleteAsset(asset.assetId)
        await wb.settle()
        #expect(preview.renderRequests == requests + 2)
        #expect(preview.warnings.contains { $0.code == "slot.stale_binding" })
        #expect(wb.job(jobId)?.validation?.warnings.contains { $0.code == "slot.stale_binding" } == true)
    }

    @Test func addingASourceShowsThePresetPreview() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        wb.selectedPresetId = f.presetId("XHS Standard")
        await wb.settle()
        #expect(wb.preview.subject == nil)
        // 选着预设时才加入第一张图：预览马上用它（不等源图检查完）。
        let ids = await wb.addSources([try f.photo("Late.jpg")])
        #expect(wb.sources.first?.inspection == nil)
        #expect(wb.preview.subject?.sourceId == ids.first && wb.preview.subject?.preset?.name == "XHS Standard")
        await wb.settle()
        #expect(wb.preview.pageImage != nil)
    }

    @Test func inspectionDoesNotChangeThePreviewSubject() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let ids = await wb.addSources([try f.hdrPhoto("Bright.tif")])
        let id = try #require(ids.first)
        wb.selection = [.source(id)]
        #expect(wb.sourceItem(id)?.inspection == nil)
        let before = try #require(wb.previewSubject)
        await wb.settle()
        #expect(wb.sourceItem(id)?.inspection.map { $0.hdr.kind != "none" } == true)
        // 检查结果不是预览内容：不会因此重新渲染，预览也没有过时，它的提示仍然显示在 Inspector「警告」里。
        #expect(wb.previewSubject == before)
        #expect(wb.preview.subject == wb.previewSubject)
    }

    @Test func failedRenderClearsPagesAndWarnings() async throws {
        let f = try Fixture()
        await f.workbench.load()
        try await f.addJob("Wide.jpg", preset: "Instagram Panorama")
        let preview = f.workbench.preview
        await f.workbench.settle()
        #expect(preview.roles.count > 1 && !preview.warnings.isEmpty)
        // 源图被删掉后改参数：渲染失败，不留上一次的页数和提示。
        try FileManager.default.removeItem(at: try #require(f.workbench.sources.first?.source.fileURL))
        f.workbench.setField(\.canvas.minMarginPx, 80)
        await f.workbench.settle()
        #expect(preview.error != nil)
        #expect(preview.roles.isEmpty && preview.warnings.isEmpty && preview.pageImage == nil)
    }

    @Test func pagesAreDecodedOnceForDisplay() async throws {
        let f = try Fixture()
        await f.workbench.load()
        try await f.addJob("Wide.jpg", preset: "Instagram Panorama")
        let preview = f.workbench.preview
        await f.workbench.settle()
        let page = try #require(preview.pageImage)
        let image = try #require(preview.pageDisplayImage)
        #expect(image.width == page.pixelSize.width && image.height == page.pixelSize.height)

        preview.page = .strip
        await f.workbench.settle()
        #expect(preview.stripImages.count == preview.strip.count && preview.stripImages.allSatisfy { $0 != nil })
        #expect(preview.stripThumbnail?.height == 120)
    }

    @Test func removedSourcesLeaveTheRenderCache() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let a = try await f.addJob("A.jpg")
        let b = try await f.addJob("B.jpg")
        let wb = f.workbench
        let preview = wb.preview
        wb.selection = [.job(a)]
        await wb.settle()
        let sourceA = try #require(wb.job(a)?.sourceId)
        let sourceB = try #require(wb.job(b)?.sourceId)
        #expect(preview.cachedRenderSources == [sourceA, sourceB])
        var remaining: Set<URL>?
        wb.onSourcesRemoved = { remaining = $0 }

        // 移除源图：它的渲染结果不再留着，界面也知道还剩哪些原图。
        wb.selection = [.source(sourceA)]
        wb.removeSelection()
        #expect(preview.cachedRenderSources == [sourceB])
        #expect(remaining == Set(wb.sources.map(\.source.fileURL)))

        // 提交后源图离开「当前」，同样清掉。
        await wb.startBatch()
        await f.waitForRun()
        #expect(preview.cachedRenderSources.isEmpty)
        #expect(remaining?.isEmpty == true)
    }
}
