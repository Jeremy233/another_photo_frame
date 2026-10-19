import Foundation
import ImageIO
import PhotoFrameApplication
import PhotoFrameCore
@testable import PhotoFrameMacModel
import Synchronization
import Testing

/// 原图不见了：检查、留着预览、自动恢复、书签找回、重新链接（连同附近的）、开始批处理时跳过。
@MainActor @Suite struct MissingSourceTests {
    /// 带拍摄时间和相机的合成照片（重新链接时核对这些）。
    private func exif(time: String = "2026:10:16 08:30:00", model: String = "X100VI") -> [CFString: Any] {
        [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: time],
         kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: model]]
    }

    /// 等条件成立（检查在后台进行），最多 5 秒。
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// 把文件复制到别处再删掉原来的：书签找不到它（不是同一个文件了），只能手动重新链接。
    private func copyAway(_ url: URL, to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: target)
        try FileManager.default.removeItem(at: url)
        return target
    }

    private func source(_ f: Fixture, _ name: String) -> SourceItem? {
        f.workbench.sources.first { $0.source.displayName == name }
    }

    @Test func boundedCheckGivesUpOnHangingCalls() async {
        let start = ContinuousClock.now
        let result = await SourceFiles.bounded(.milliseconds(50), default: false) {
            Thread.sleep(forTimeInterval: 2)
            return true
        }
        #expect(result == false)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await SourceFiles.bounded(.seconds(1), default: 0) { 7 } == 7)
    }

    @Test func probesGroupByVolume() async throws {
        #expect(SourceFiles.volume(URL(filePath: "/Volumes/photos/2026/a.jpg")) == "/Volumes/photos")
        #expect(SourceFiles.volume(URL(filePath: "/Volumes")) == "/")
        #expect(SourceFiles.volume(URL(filePath: "/Users/x/a.jpg")) == "/")
        let f = try Fixture()
        let here = try f.photo("Here.jpg")
        let gone = f.root.appending(path: "Gone.jpg")
        let states = await SourceFiles.probe([here, gone, f.root], width: 1)
        #expect(states[here] == .present && states[gone] == .absent && states[f.root] == .absent)
    }

    @Test func missingSourcesAreNotSentToTheService() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let jobId = try await f.addJob()
        try FileManager.default.removeItem(at: wb.sources[0].source.fileURL)
        await wb.checkSources()
        // 卷断开时服务读这些路径会卡住：改参数后不校验、不预览，等原图回来。
        let validated = Mutex(false)
        f.hooks.set { $0.beforeValidate = { validated.withLock { $0 = true } } }
        let requests = wb.preview.renderRequests
        wb.setField(\.canvas.minMarginPx, 90)
        await wb.settle()
        #expect(validated.withLock { $0 } == false)
        #expect(wb.preview.renderRequests == requests)
        #expect(wb.issues(for: try #require(wb.job(jobId))).map(\.code) == [JobIssue.missingCode])
    }

    @Test func triggerMarksMissingSourceAndKeepsPreview() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let jobId = try await f.addJob()
        let url = try #require(wb.sources.first?.source.fileURL)
        let shown = try #require(wb.preview.pageImage)

        let (triggers, trigger) = AsyncStream.makeStream(of: Void.self)
        let observing = Task { await wb.observeSourceAvailability(triggers) }
        defer { observing.cancel() }
        try FileManager.default.removeItem(at: url)
        // 什么都不做时不检查。
        #expect(wb.sources[0].isMissing == false)
        trigger.yield()
        await until { wb.sources[0].isMissing }
        #expect(wb.sources[0].isMissing)
        await wb.settle()

        // 源图行、右栏都是错误；任务行不再重复「源文件不存在或不可读」。
        let issues = wb.inspectorIssues
        #expect(issues.first?.code == JobIssue.missingCode && issues.first?.isError == true)
        #expect(issues.first?.message.contains(url.path) == true)
        #expect(!issues.contains { JobIssue.unreadableCodes.contains($0.code) })
        // 预览留着上一次的画面，标为不是最新的，没有「无法预览」。
        #expect(wb.preview.isStale)
        #expect(wb.preview.pageImage == shown)
        #expect(wb.preview.error == nil)
        #expect(wb.inspectedMissingSource == wb.sources[0].id)

        // 改参数照常记住，但不渲染。
        let requests = wb.preview.renderRequests
        wb.setField(\.canvas.minMarginPx, 77)
        await wb.settle()
        #expect(wb.job(jobId)?.preset.canvas.minMarginPx == 77)
        #expect(wb.preview.renderRequests == requests)
        #expect(wb.preview.pageImage == shown && wb.preview.isStale)
    }

    @Test func renderFailureMarksSourceMissing() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        try await f.addJob()
        let shown = try #require(wb.preview.pageImage)
        try FileManager.default.removeItem(at: wb.sources[0].source.fileURL)
        // 还没检查出来就改了参数：预览读不到原图，同样留着画面并标出缺失。
        wb.setField(\.canvas.minMarginPx, 66)
        await wb.settle()
        #expect(wb.sources[0].isMissing)
        #expect(wb.preview.isStale && wb.preview.error == nil)
        #expect(wb.preview.pageImage == shown)
    }

    @Test func returningFileRecoversWithLatestParameters() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let jobId = try await f.addJob()
        let url = wb.sources[0].source.fileURL
        let width = try #require(wb.preview.pageImage?.pixelSize.width)
        let parked = f.root.appending(path: "parked.jpg")
        try FileManager.default.copyItem(at: url, to: parked)
        try FileManager.default.removeItem(at: url)
        await wb.checkSources()
        #expect(wb.sources[0].isMissing)

        wb.setField(\.canvas.width, width / 2)
        await wb.settle()
        #expect(wb.preview.pageImage?.pixelSize.width == width)

        // 放回原处：下一次检查自动恢复，按最新的参数重新渲染、重新校验。
        try FileManager.default.moveItem(at: parked, to: url)
        await wb.checkSources()
        await wb.settle()
        #expect(wb.sources[0].isMissing == false)
        #expect(wb.sources[0].inspection != nil)
        #expect(wb.preview.isStale == false)
        #expect(wb.preview.pageImage?.pixelSize.width == width / 2)
        #expect(wb.job(jobId)?.validation?.errors.isEmpty == true)
        #expect(wb.inspectorIssues.allSatisfy { $0.code != JobIssue.missingCode })
    }

    @Test func bookmarkFollowsMoveAndRename() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let jobId = try await f.addJob()
        wb.setField(\.canvas.minMarginPx, 55)
        await wb.settle()
        let item = try #require(wb.sources.first)
        #expect(item.bookmark != nil && item.fingerprint != nil)

        let moved = f.root.appending(path: "NAS/2026/Renamed.jpg")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: item.source.fileURL, to: moved)
        await wb.checkSources()
        await wb.settle()

        let relinked = try #require(wb.sources.first)
        #expect(relinked.id == item.id)
        #expect(relinked.isMissing == false)
        #expect(relinked.source.fileURL == moved.standardizedFileURL)
        #expect(relinked.source.displayName == "Renamed.jpg")
        #expect(relinked.jobs.map(\.id) == [jobId])
        #expect(wb.job(jobId)?.preset.canvas.minMarginPx == 55)
        #expect(await f.service.sources().map(\.fileURL) == [moved.standardizedFileURL])
        // 不弹窗：右栏「警告」里一条灰色的说明。
        #expect(wb.alert == nil)
        let notice = try #require(wb.inspectorIssues.first { $0.code == JobIssue.relinkedCode })
        #expect(notice.isInfo && notice.message.contains("自动重新链接") && notice.message.contains(moved.path))
        #expect(wb.preview.isStale == false && wb.preview.pageImage != nil)
    }

    @Test func bookmarkDoesNotRelinkADifferentPhoto() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let url = try f.photo("Shot.jpg", properties: exif())
        await wb.addSources([url])
        await wb.settle()
        let moved = f.root.appending(path: "Moved/Shot.jpg")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: moved)
        // 移走之后被另一张照片覆盖（同一个文件，内容换了）：核对不一致，不自动重新链接。
        let other = try Data(contentsOf: try f.photo("Other.jpg", width: 300, properties: exif(time: "2026:10:17 09:00:00")))
        let handle = try FileHandle(forWritingTo: moved)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: other)
        try handle.close()
        await wb.checkSources()
        #expect(wb.sources[0].isMissing)
        #expect(wb.sources[0].source.fileURL == url)
    }

    @Test func relinkKeepsJobsAndFindsNearbyPhotos() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let a = try f.photo("A.jpg", properties: exif(time: "2026:10:16 08:00:00"))
        let b = try f.photo("B.jpg", properties: exif(time: "2026:10:16 08:01:00"))
        let c = try f.photo("C.jpg", properties: exif(time: "2026:10:16 08:02:00"))
        await wb.addSources([a, b, c])
        let ids = wb.sources.map(\.id)
        await wb.drop(.preset(f.presetId("Instagram Standard")), on: .source(ids[0]))
        await wb.settle()
        let jobId = try #require(wb.sources[0].jobs.first?.id)
        wb.setField(\.canvas.minMarginPx, 44)
        await wb.settle()

        let folder = f.root.appending(path: "Other", directoryHint: .isDirectory)
        let newA = try copyAway(a, to: folder)
        _ = try copyAway(c, to: folder)
        try FileManager.default.removeItem(at: b)
        // B 在新文件夹里的同名文件是另一张照片。
        _ = try copyAway(try f.photo("B.jpg", properties: exif(time: "2026:10:18 10:00:00")), to: folder)
        await wb.checkSources()
        #expect(wb.sources.allSatisfy { $0.isMissing })

        await wb.relink(ids[0], to: newA)
        await wb.settle()
        #expect(wb.relinkPrompt == nil)
        #expect(wb.sources.map(\.id) == ids)
        #expect(source(f, "A.jpg")?.isMissing == false)
        #expect(source(f, "C.jpg")?.isMissing == false)
        #expect(source(f, "C.jpg")?.source.fileURL == folder.appending(path: "C.jpg").standardizedFileURL)
        #expect(source(f, "B.jpg")?.isMissing == true)
        #expect(wb.alert?.title == "已重新链接 2 张原图")
        #expect(wb.alert?.message.contains("B.jpg") == true)
        // 任务和改动都在，并且按新位置重新校验。
        #expect(wb.sources[0].jobs.map(\.id) == [jobId])
        #expect(wb.job(jobId)?.preset.canvas.minMarginPx == 44)
        #expect(wb.job(jobId)?.validation?.errors.isEmpty == true)
        #expect(wb.sources[0].inspection?.fileURL == newA.standardizedFileURL)
    }

    @Test func relinkToDifferentPhotoAsksFirst() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let url = try f.photo("Shot.jpg", properties: exif())
        await wb.addSources([url])
        await wb.settle()
        let id = wb.sources[0].id
        try FileManager.default.removeItem(at: url)
        await wb.checkSources()
        let other = try copyAway(try f.photo("Edited.jpg", width: 320, properties: exif(model: "X-T5")), to: f.root.appending(path: "Edits"))

        await wb.relink(id, to: other)
        let prompt = try #require(wb.relinkPrompt)
        #expect(prompt.differences.map(\.field) == ["像素尺寸", "相机型号"])
        #expect(prompt.differences[0].text == "像素尺寸：原来 360 × 240，现在 320 × 240")
        #expect(wb.sources[0].isMissing)

        await wb.resolveRelink(false)
        #expect(wb.relinkPrompt == nil && wb.sources[0].isMissing)

        await wb.relink(id, to: other)
        await wb.resolveRelink(true)
        await wb.settle()
        #expect(wb.sources[0].isMissing == false)
        #expect(wb.sources[0].source.fileURL == other.standardizedFileURL)
        #expect(wb.sources[0].fingerprint?.model == "X-T5")
        #expect(wb.alert == nil)
    }

    @Test func relinkMergesTheSameFileDraggedInAgain() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let jobId = try await f.addJob("Badlands.jpg")
        let old = wb.sources[0]
        let moved = try copyAway(old.source.fileURL, to: f.root.appending(path: "Moved"))
        await wb.checkSources()
        // 用户先把移走的文件又拖了进来：多了一张没有任务的源图。
        await wb.addSources([moved])
        #expect(wb.sources.count == 2)

        await wb.relink(old.id, to: moved)
        await wb.settle()
        #expect(wb.sources.map(\.id) == [old.id])
        #expect(wb.sources[0].jobs.map(\.id) == [jobId])
        #expect(try await f.service.addSource(moved).sourceId == old.id)
    }

    @Test func failedJobRetriesAtTheRelinkedLocation() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let url = try f.photo("Q.jpg")
        let source = try await f.service.addSource(url)
        await wb.addSources([url])
        await wb.settle()
        let preset = try await f.service.resolvePreset(.library("Instagram Standard")).preset
        let moved = try copyAway(url, to: f.root.appending(path: "Moved"))
        let ids = try await f.service.submit(ExportRequest(
            sourceIds: [source.sourceId], presets: [preset], destination: ExportDestination(rootDirectory: f.exports)))
        await wb.resumeQueue()
        _ = await f.service.waitUntilFinished(ids)
        await wb.refreshJobs()
        #expect(wb.record(ids[0])?.status == .failed)

        await wb.checkSources()
        await wb.relink(source.sourceId, to: moved)
        #expect(wb.record(ids[0])?.spec.source.fileURL == moved.standardizedFileURL)
        #expect(wb.sources[0].notices.first?.hint?.contains("重试") == true)
        await wb.retry([ids[0]])
        _ = await f.service.waitUntilFinished(ids)
        await wb.refreshJobs()
        #expect(wb.record(ids[0])?.status == .completed)
    }

    @Test func startBatchOffersToSkipMissingOriginals() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let kept = try await f.addJob("Kept.jpg")
        let lost = try await f.addJob("Lost.jpg")
        let lostURL = try #require(source(f, "Lost.jpg")?.source.fileURL)
        try FileManager.default.removeItem(at: lostURL)

        await wb.startBatch()
        let prompt = try #require(wb.missingPrompt)
        #expect(wb.alert == nil)
        #expect(prompt.fileURLs == [lostURL] && prompt.skippedJobs == 1)
        #expect(source(f, "Lost.jpg")?.isMissing == true)

        await wb.resolveMissingSources(.cancel)
        #expect(wb.runJobIds.isEmpty && wb.job(kept) != nil)

        await wb.startBatch()
        await wb.resolveMissingSources(.skip)
        #expect(wb.runJobIds.count == 1)
        await f.waitForRun()
        #expect(wb.jobs.first?.status == .completed)
        // 跳过的任务留在「当前」里，源图标着不见了。
        #expect(wb.job(kept) == nil)
        #expect(wb.job(lost) != nil)
        #expect(wb.sources.map(\.source.displayName) == ["Lost.jpg"])
        #expect(wb.sources[0].isMissing)
    }
}
