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
        f.workbench.preview.range = .hdr
        #expect(!f.workbench.preview.showsHDRFallbackNote)
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
