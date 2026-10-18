import PhotoFrameApplication
@testable import PhotoFrameMacUI
import Testing

/// 界面上的中文名称（审查报告 T 组）。
@Suite struct LabelsTests {
    /// V31 / T8：EXIF 用中文名、固定顺序，不认识的键排在最后。
    @Test func exifRowsUseChineseNamesInAFixedOrder() {
        let rows = ExifLabels.rows(["iso": "ISO 100", "make": "FUJIFILM", "aperture": "f/2", "camera": "FUJIFILM X100VI", "custom": "x"])
        #expect(rows.map(\.title) == ["相机", "品牌", "光圈", "ISO", "custom"])
        #expect(rows.map(\.key) == ["camera", "make", "aperture", "iso", "custom"])
    }

    /// T20：状态文字只有一套（参照 Compressor）。
    @Test func statusWords() {
        #expect(JobStatus.queued.title == "等待")
        #expect(JobStatus.completed.title == "成功")
        #expect(JobStatus.rendering.title == "渲染")
    }

    /// B21：ICC 一行与「按此解释」、警告用同一个名字（`SourceColorOverride.displayName`）。
    @Test func colorSpacesHaveOneName() {
        #expect(ColorProfileName.display("kCGColorSpaceAdobeRGB1998") == "Adobe RGB")
        #expect(ColorProfileName.display("kCGColorSpaceROMMRGB") == "ProPhoto RGB")
        #expect(ColorProfileName.display("kCGColorSpaceITUR_2020") == "Rec. 2020")
    }
}
