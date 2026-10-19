import Foundation
import PhotoFrameCore
import Testing
@testable import PhotoFrameMacModel

/// 「上下边框」的「自动计算」：输入框显示按源图算出来的宽度。
@MainActor
struct VerticalBorderTests {
    @Test func computedWidthFollowsTheSource() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let wb = f.workbench
        let url = try f.photo("Wide.jpg", width: 1600, height: 400)
        let ids = await wb.addSources([url])
        let sourceId = try #require(ids.first)
        await wb.drop(.preset(f.presetId("Instagram Panorama")), on: .source(sourceId))
        await wb.settle()
        let job = try #require(wb.sourceItem(sourceId)?.jobs.last?.id)
        wb.selection = [.job(job)]

        // 关闭时就是填写的宽度。
        #expect(wb.computedVerticalMargin == .single(0))
        wb.setField(\.panorama.autoVerticalMargin, true)
        // R = 4、切片 1080 × 1440、居中：v = (5760 − 5400) / 6 = 60。
        #expect(wb.computedVerticalMargin == .single(60))
        wb.setField(\.panorama.alignment, .left)
        #expect(wb.computedVerticalMargin == .single(51))
    }
}
