import Foundation
import ImageIO
import PhotoFrameApplication
import PhotoFrameCore
@testable import PhotoFrameMacModel
import Testing

@MainActor @Suite struct WorkbenchTests {
    @Test func dragPayloadRoundTrip() {
        let id = UUID()
        for payload in [DragPayload.preset(id), .location(id), .asset(id)] {
            #expect(DragPayload(string: payload.string) == payload)
        }
        #expect(DragPayload(string: "photoframe:other:\(id)") == nil)
        #expect(DragPayload(string: "/Users/x/a.jpg") == nil)
    }

    @Test func locationsPersist() throws {
        let f = try Fixture()
        let wb = f.workbench
        wb.addLocation(URL(filePath: "/tmp/Second"), name: "Second")
        let second = try #require(wb.locations.locations.last)
        wb.setDefaultLocation(second.id)
        wb.renameLocation(second.id, to: "B")
        #expect(f.store.load()?.defaultLocation?.name == "B")
        wb.removeLocation(second.id)
        #expect(f.store.load()?.defaultLocation?.name == "Exports")
        #expect(LocationList.initial(home: URL(filePath: "/Users/x")).defaultLocation?.url.path == "/Users/x/Pictures/Social Exports")
    }

    @Test func addSourcesInspectsAndRejectsUnsupported() async throws {
        let f = try Fixture()
        let wb = f.workbench
        let text = f.root.appending(path: "notes.txt")
        try Data("x".utf8).write(to: text)
        #expect(await wb.dropFiles([text]) == false)
        let added = await wb.addSources([try f.photo("A.jpg"), text])
        await wb.settle()
        #expect(added.count == 1)
        #expect(wb.alert != nil)
        #expect(wb.sources.first?.inspection?.pixelSize == PixelSize(width: 360, height: 240))
    }

    @Test func dropPresetCreatesValidatedJob() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let jobId = try await f.addJob()
        let wb = f.workbench
        #expect(wb.selection == [.job(jobId)])
        #expect(wb.inspectorSubject == .jobs([jobId]))
        let job = try #require(wb.job(jobId))
        #expect(job.destination == f.exports)
        #expect(job.validation?.outputs.first?.fileName == "00_Cover.jpg")
        #expect(job.validation?.errors.isEmpty == true)
        #expect(!job.isModified)
    }

    @Test func multiSelectionShowsMixedValuesAndEditsAll() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let a = try await f.addJob("A.jpg", preset: "Instagram Standard")
        let b = try await f.addJob("B.jpg", preset: "XHS Standard")
        let wb = f.workbench
        wb.selection = [.job(a), .job(b)]
        #expect(wb.inspectorSubject == .jobs([a, b]))
        #expect(wb.editedPreset == nil)
        #expect(wb.field(\.canvas.minMarginPx) == .single(60))
        #expect(wb.field(\.platform) == .mixed)
        wb.setField(\.canvas.minMarginPx, 90)
        #expect(wb.job(a)?.preset.canvas.minMarginPx == 90 && wb.job(b)?.preset.canvas.minMarginPx == 90)
        #expect(wb.job(a)?.isModified == true)
        // 任务的改动不写回库里的预设（§4.2）。
        let builtIn = try await f.service.resolvePreset(.library("Instagram Standard")).preset
        #expect(builtIn.canvas.minMarginPx == 60)
    }

    @Test func selectingSourceOrPresetChangesInspector() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let jobId = try await f.addJob()
        let wb = f.workbench
        let sourceId = try #require(wb.job(jobId)?.sourceId)
        wb.selection = [.source(sourceId)]
        #expect(wb.inspectorSubject == .source(sourceId))
        #expect(!wb.isInspectorEditable)

        wb.selectedPresetId = f.presetId("Instagram Standard")
        await wb.settle()
        #expect(wb.inspectorSubject == .preset(f.presetId("Instagram Standard")))
        #expect(wb.presetEditor?.isReadOnly == true)
        wb.setField(\.canvas.minMarginPx, 10)
        #expect(wb.presetEditor?.isDirty == false)

        // 再点任务列表，右栏回到任务。
        wb.selection = [.job(jobId)]
        #expect(wb.inspectorSubject == .jobs([jobId]))
    }

    @Test func editAndSaveUserPreset() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        await wb.duplicatePreset(f.presetId("Instagram Standard"))
        await wb.settle()
        let copy = try #require(wb.presetEditor)
        #expect(!copy.isReadOnly && copy.entry.origin == .user)
        wb.setField(\.canvas.minMarginPx, 72)
        #expect(wb.presetEditor?.isDirty == true)
        await wb.savePresetEdits()
        await wb.settle()
        #expect(wb.presetEditor?.isDirty == false)
        #expect(wb.preset(copy.entry.preset.presetId)?.minMarginPx == 72)

        await wb.renamePreset(copy.entry.preset.presetId, to: "Mine")
        await wb.movePreset(copy.entry.preset.presetId, to: .imported)
        #expect(wb.presets(in: .imported).map(\.name) == ["Mine"])
        await wb.deletePreset(copy.entry.preset.presetId)
        #expect(wb.preset(copy.entry.preset.presetId) == nil && wb.selectedPresetId == nil)
    }

    @Test func newPresetGetsUniqueName() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        await wb.newPreset()
        await wb.newPreset()
        #expect(wb.presets(in: .user).map(\.name).sorted() == ["新预设", "新预设 2"])
    }

    @Test func saveJobAsPreset() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let jobId = try await f.addJob()
        let wb = f.workbench
        wb.setField(\.canvas.minMarginPx, 100)
        await wb.saveSelectedJobAsPreset(name: "Wide Margin")
        let saved = try #require(wb.presets.first { $0.name == "Wide Margin" })
        #expect(saved.origin == .user && saved.minMarginPx == 100)
        #expect(wb.job(jobId)?.isModified == false)
        #expect(wb.job(jobId)?.basePreset.presetId == saved.presetId)
    }

    @Test func dropLocationOnJob() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let jobId = try await f.addJob()
        let wb = f.workbench
        wb.addLocation(f.root.appending(path: "Other", directoryHint: .isDirectory), name: "Other")
        let other = try #require(wb.locations.locations.last)
        #expect(await wb.drop(.location(other.id), on: .job(jobId)))
        #expect(wb.job(jobId)?.destination == other.url)
        #expect(wb.locationName(for: other.url) == "Other")
        #expect(await wb.drop(.asset(UUID()), on: .job(jobId)) == false)
    }

    @Test func layersAndAssetBinding() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        await wb.importAssets([try f.assetPNG("sig.png")], category: .signature)
        let asset = try #require(wb.assets(in: .signature).first)
        let jobId = try await f.addJob()

        wb.addLayer(.signature)
        wb.addLayer(.signature)
        #expect(wb.editedPreset?.layers.map(\.layerId) == ["signature", "signature-2"])
        wb.removeLayer("signature-2")
        #expect(wb.editedPreset?.assetSlots.map(\.slotId) == ["signature"])
        wb.updateLayer("signature") { $0.opacity = 0.5 }
        #expect(wb.editedPreset?.layers.first?.opacity == 0.5)

        await wb.bindAsset(asset.assetId, slotId: "signature")
        await wb.settle()
        #expect(wb.binding(for: "signature")?.assetId == asset.assetId)
        #expect(wb.binding(for: "signature")?.level == .job)
        #expect(wb.job(jobId)?.validation?.errors.isEmpty == true)

        // 编辑预设时，绑定保存为预设本地绑定。
        await wb.duplicatePreset(f.presetId("Instagram Standard"))
        await wb.settle()
        wb.addLayer(.watermark)
        await wb.savePresetEdits()
        await wb.settle()
        await wb.bindAsset(asset.assetId, slotId: "watermark")
        #expect(wb.binding(for: "watermark")?.level == .preset)

        await wb.deleteAsset(asset.assetId)
        #expect(wb.alert?.title == "素材已删除")
    }

    @Test func cameraRulesAndTextStyle() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        let url = try f.photo("Fuji.jpg", properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X100VI"],
        ])
        let ids = await wb.addSources([url])
        let sourceId = try #require(ids.first)
        await wb.drop(.preset(f.presetId("Instagram Standard")), on: .source(sourceId))
        await wb.settle()
        let jobId = try #require(wb.sourceItem(sourceId)?.jobs.first?.id)
        wb.selection = [.job(jobId)]
        #expect(wb.previewCamera == CameraIdentity(make: "FUJIFILM", model: "X100VI"))

        // 规则预填当前源图的相机，并有自己的素材槽；删除规则时槽一起删除。
        wb.addLayer(.cameraBadge)
        wb.addCameraRule("cameraBadge")
        let layer = try #require(wb.editedPreset?.layers.first { $0.layerId == "cameraBadge" })
        #expect(layer.cameraMatch == [CameraMatchRule(make: "FUJIFILM", model: "X100VI", slotId: "cameraBadge.camera-1")])
        #expect(wb.editedPreset?.assetSlots.map(\.slotId) == ["cameraBadge", "cameraBadge.camera-1"])
        #expect(wb.editedPreset?.validate().errors.isEmpty == true)
        wb.addCameraRule("cameraBadge")
        wb.removeCameraRule("cameraBadge", at: 0)
        #expect(wb.editedPreset?.assetSlots.map(\.slotId) == ["cameraBadge", "cameraBadge.camera-2"])
        wb.removeLayer("cameraBadge")
        #expect(wb.editedPreset?.assetSlots.isEmpty == true)

        // 文字样式改的是任务里的预设副本。
        wb.addLayer(.exifText)
        wb.updateLayer("exifText") { $0.text?.fontWeight = .semibold; $0.text?.letterSpacingPx = 1 }
        #expect(wb.job(jobId)?.preset.layers.first { $0.layerId == "exifText" }?.text?.fontWeight == .semibold)
    }

    @Test func settingsPersistAndControlSwitchToActive() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        #expect(wb.settings == AppSettings())
        #expect(wb.settings.effectiveMaxConcurrentJobs == QueueConfiguration.defaultMaxConcurrentJobs)

        wb.settings.maxConcurrentJobs = 2
        wb.settings.memoryBudgetGiB = 4
        wb.settings.switchesToActiveAfterStart = false
        await wb.settle()
        #expect(f.settingsStore.load() == AppSettings(switchesToActiveAfterStart: false, maxConcurrentJobs: 2, memoryBudgetGiB: 4))
        #expect(wb.settings.effectiveMemoryBudgetBytes == 4 << 30)

        // 不切到「活跃」：提交的任务照样离开「当前」，界面留在「当前」。
        try await f.addJob()
        await wb.startBatch()
        await f.waitForRun()
        #expect(wb.mode == .current)
        #expect(wb.sources.isEmpty)
        #expect(wb.jobs.allSatisfy { $0.status == .completed })

        // 设置在下次启动时读回。
        let again = Workbench(service: f.service, locationStore: f.store, settingsStore: f.settingsStore, debounce: .zero)
        #expect(again.settings.maxConcurrentJobs == 2)
    }

    @Test func startBatchExportsAndClearsCurrent() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let jobId = try await f.addJob()
        let wb = f.workbench
        await wb.startBatch()
        #expect(wb.overwritePrompt == nil && wb.alert == nil)
        #expect(wb.job(jobId) == nil && wb.sources.isEmpty)
        #expect(!wb.isQueuePaused)
        // 与 Compressor 一致：提交后切到「活跃」。
        #expect(wb.mode == .active)
        await f.waitForRun()
        #expect(wb.batchProgress?.fraction == 1)
        let finished = try #require(wb.finishedJobs.first)
        #expect(finished.status == .completed)
        let outputs = wb.outputURLs([finished.jobId])
        #expect(outputs.map(\.lastPathComponent) == ["00_Cover.jpg"])
        #expect(outputs.first?.path.hasSuffix("Instagram/Badlands_Standard/00_Cover.jpg") == true)
    }

    @Test func warningsAreListedAndAskedBeforeStart() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let wb = f.workbench
        // 3:2 的照片做全景：「照片不够宽」警告，带修改建议。
        let jobId = try await f.addJob(preset: "Instagram Panorama")
        let issues = try #require(wb.job(jobId)?.issues)
        let issue = try #require(issues.first { $0.code == "panorama.not_wide_enough" }, "\(issues)")
        #expect(!issue.isError && issue.hint != nil)

        // 开始前先询问；「查看」不开始，选中带警告的任务。
        await wb.startBatch()
        let prompt = try #require(wb.warningPrompt)
        #expect(prompt.jobIds == [jobId] && prompt.warningCount >= 1)
        #expect(wb.job(jobId) != nil)
        await wb.resolveWarnings(.review)
        #expect(wb.warningPrompt == nil && wb.selection == [.job(jobId)] && wb.job(jobId) != nil)

        // 「继续」+「不再询问」：开始批处理，以后不再询问。
        await wb.startBatch()
        await wb.resolveWarnings(.proceed, dontAskAgain: true)
        #expect(wb.job(jobId) == nil && !wb.settings.reviewsWarningsBeforeStart)
        await f.waitForRun()
    }

    @Test func existingOutputAsksBeforeOverwrite() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let wb = f.workbench
        try await f.addJob()
        await wb.startBatch()
        await f.waitForRun()

        // 同一张图再导出一次：先问用户。
        try await f.addJob()
        await wb.startBatch()
        let prompt = try #require(wb.overwritePrompt)
        #expect(prompt.conflicts.first?.directory.lastPathComponent == "Badlands_Standard")
        await wb.resolveOverwrite(.keepBoth)
        await f.waitForRun()
        #expect(wb.finishedJobs.first?.manifest?.directory.lastPathComponent == "Badlands_Standard_v2")

        try await f.addJob()
        await wb.startBatch()
        await wb.resolveOverwrite(.overwrite)
        await f.waitForRun()
        let replaced = try #require(wb.finishedJobs.first?.manifest)
        #expect(replaced.directory.lastPathComponent == "Badlands_Standard")
        #expect(replaced.warnings.contains { $0.code == "export.replaced_previous" })

        try await f.addJob()
        await wb.startBatch()
        await wb.resolveOverwrite(.cancel)
        #expect(wb.allJobs.count == 1)
    }

    @Test func invalidJobBlocksBatch() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let jobId = try await f.addJob()
        let wb = f.workbench
        let url = try #require(wb.sources.first?.source.fileURL)
        try FileManager.default.removeItem(at: url)
        await wb.startBatch()
        #expect(wb.alert?.title == "无法开始批处理")
        #expect(wb.job(jobId) != nil && wb.runJobIds.isEmpty)
    }

    @Test func cancelRetryAndReexport() async throws {
        let f = try Fixture()
        let wb = f.workbench
        await wb.load()
        // 直接通过服务提交，队列仍是暂停的：任务停在 queued。
        let source = try await f.service.addSource(try f.photo("Q.jpg"))
        let preset = try await f.service.resolvePreset(.library("Instagram Standard")).preset
        let ids = try await f.service.submit(ExportRequest(
            sourceIds: [source.sourceId], presets: [preset], destination: ExportDestination(rootDirectory: f.exports)))
        await wb.refreshJobs()
        #expect(wb.activeJobs.map(\.jobId) == ids)

        await wb.cancel(Set(ids))
        #expect(wb.record(ids[0])?.status == .canceled)
        #expect(wb.canRetry(ids[0]))
        await wb.retry(Set(ids))
        await f.waitForRun()
        #expect(wb.record(ids[0])?.status == .completed)
        #expect(wb.record(ids[0])?.attempts.count == 2)
        #expect(!wb.canRetry(ids[0]))

        await wb.reexport(Set(ids))
        await f.waitForRun()
        #expect(wb.finishedJobs.count == 2)
        #expect(wb.finishedJobs.first?.manifest?.directory.lastPathComponent == "Q_Standard_v2")
    }

    @Test func pauseToggle() async throws {
        let f = try Fixture()
        let wb = f.workbench
        #expect(wb.isQueuePaused)
        // 队列启动时就是暂停的，但没有任务时不显示「继续」。
        #expect(!wb.showsQueueControls)
        await wb.toggleQueuePaused()
        #expect(!wb.isQueuePaused)
        await wb.toggleQueuePaused()
        #expect(wb.isQueuePaused)
    }

    @Test func removeAndDuplicateSelection() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let jobId = try await f.addJob()
        let wb = f.workbench
        wb.duplicateSelectedJobs()
        #expect(wb.allJobs.count == 2)
        #expect(!wb.selection.contains(.job(jobId)))
        wb.removeSelection()
        #expect(wb.allJobs.map(\.id) == [jobId])
        wb.selection = [.source(try #require(wb.sources.first?.id))]
        wb.removeSelection()
        #expect(wb.sources.isEmpty)
    }

    @Test func selectingLocationShowsLocationInspector() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let jobId = try await f.addJob()
        let wb = f.workbench
        let location = try #require(wb.locations.locations.first)
        wb.selectedLocationId = location.id
        #expect(wb.inspectorSubject == .location(location.id))
        #expect(!wb.isInspectorEditable && wb.editedPresets.isEmpty)
        wb.selection = [.job(jobId), .source(try #require(wb.job(jobId)?.sourceId))]
        #expect(wb.inspectorSubject == .jobs([jobId]))
    }

    @Test func activeCountTracksUnfinishedJobs() async throws {
        let f = try Fixture()
        await f.workbench.load()
        let source = try await f.service.addSource(try f.photo("C.jpg"))
        let preset = try await f.service.resolvePreset(.library("XHS Standard")).preset
        _ = try await f.service.submit(ExportRequest(
            sourceIds: [source.sourceId], presets: [preset], destination: ExportDestination(rootDirectory: f.exports)))
        await f.workbench.refreshJobs()
        #expect(f.workbench.activeCount == 1)
        #expect(f.workbench.showsQueueControls)
    }
}
