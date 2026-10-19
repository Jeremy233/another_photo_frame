import Foundation
import PhotoFrameApplication
import PhotoFrameCore

// 原图不见了（移走、改名、删除，或 NAS 断开）：参照 Lightroom Classic，标出来、留着预览和改动，
// 文件回来时自动恢复，移动或改名时用书签找回，也可以「重新链接…」到新位置（连同同一文件夹里的其他缺失原图）。

extension Workbench {
    // MARK: 检查

    /// 收到检查的信号（App 变为活跃，卷装上、推出、改名）就检查一遍批次里的原图，直到信号流结束。界面 `.task` 里调用。
    public func observeSourceAvailability<Triggers: AsyncSequence<Void, Never>>(_ triggers: Triggers) async {
        for await _ in triggers {
            await checkSources()
        }
    }

    /// 检查批次里每张原图还在不在：只 stat，在主线程之外，有时限。
    /// 不见了的标出来，然后用书签找移动或改名后的位置；原来不见了、现在又在原处的自动恢复。
    /// 检查期间又要求检查（几个信号挨着来）时，做完再查一次。
    public func checkSources() async {
        guard !isCheckingSources else {
            needsSourceCheck = true
            return
        }
        isCheckingSources = true
        defer { isCheckingSources = false }
        repeat {
            needsSourceCheck = false
            await checkSourcesOnce()
        } while needsSourceCheck
    }

    private func checkSourcesOnce() async {
        let checked = sources.map { (id: $0.id, url: $0.source.fileURL) }
        guard !checked.isEmpty else { return }
        let found = await SourceFiles.probe(checked.map(\.url), timeout: sourceProbeTimeout)
        var lost: [SourceID] = []
        var back: [SourceID] = []
        for entry in checked {
            // 检查期间移除或重新链接了的不管。
            guard let state = found[entry.url], let item = sourceItem(entry.id), item.source.fileURL == entry.url else { continue }
            if state != .present { lost.append(entry.id) } else if item.isMissing { back.append(entry.id) }
        }
        markMissing(lost)
        for id in back { recover(id) }
        await followBookmarks(lost)
    }

    /// 把这些源图标为缺失：源图行、任务行和右栏显示错误，预览留着上一次的画面。
    /// 不见了的源图的任务不再交给服务校验或预览（卷断开时服务读这些路径会卡住），回来或重新链接后再校验。
    func markMissing(_ ids: [SourceID]) {
        var marked = false
        for id in ids {
            guard let i = sources.firstIndex(where: { $0.id == id }), !sources[i].isMissing else { continue }
            sources[i].isMissing = true
            marked = true
        }
        if marked { refreshPreview() }
    }

    /// 任务行的错误和警告：原图不见了时是这一条错误（不再重复「源文件不存在或不可读」），再加上校验的结果。
    public func issues(for job: DraftJob) -> [JobIssue] {
        guard let item = sourceItem(job.sourceId), item.isMissing else { return job.issues }
        return item.missingIssues + job.issues.filter { !JobIssue.unreadableCodes.contains($0.code) }
    }

    /// 原图又在原处了（放回来、卷重新连上）：重新检查，按最新的参数重新渲染预览，重新校验任务。
    private func recover(_ id: SourceID) {
        guard let i = sources.firstIndex(where: { $0.id == id }), sources[i].isMissing else { return }
        sources[i].isMissing = false
        sources[i].inspectionError = nil
        inspect(id)
        scheduleValidation(sources[i].jobs.map(\.id))
        refreshPreview()
    }

    /// 不见了的原图用书签找现在的位置（不弹窗、不装载卷）。找到的文件与原图一致（``SourceFingerprint``）时自动重新链接，
    /// 在右栏「警告」里说明；不一致或找不到的仍然标为缺失，等用户「重新链接…」。
    private func followBookmarks(_ ids: [SourceID]) async {
        let timeout = sourceProbeTimeout
        for id in ids {
            guard let item = sourceItem(id), item.isMissing, let bookmark = item.bookmark, let fingerprint = item.fingerprint else { continue }
            let old = item.source.fileURL
            guard let found = await SourceFiles.resolve(bookmark, timeout: timeout), found != old,
                  await SourceFiles.exists(found, timeout: timeout),
                  let current = await SourceFiles.fingerprint(found, timeout: timeout),
                  fingerprint.differences(to: current).isEmpty
            else { continue }
            // 等待期间用户可能已经重新链接或移除了它。
            guard let now = sourceItem(id), now.isMissing, now.source.fileURL == old else { continue }
            await completeRelink(id, to: found, fingerprint: current, automatically: true)
        }
    }

    // MARK: 加入时记下的信息

    /// 加入源图时在后台记下识别信息和书签（重新链接时核对、移动后找回）。
    func capture(_ id: SourceID) {
        guard let url = sourceItem(id)?.source.fileURL else { return }
        let timeout = sourceProbeTimeout
        background("capture-\(id)") { [self] in
            async let fingerprint = SourceFiles.fingerprint(url, timeout: timeout)
            async let bookmark = SourceFiles.bookmark(url, timeout: timeout)
            let (print, mark) = await (fingerprint, bookmark)
            guard let i = sources.firstIndex(where: { $0.id == id }), sources[i].source.fileURL == url else { return }
            sources[i].fingerprint = print ?? sources[i].fingerprint
            sources[i].bookmark = mark ?? sources[i].bookmark
        }
    }

    // MARK: 重新链接

    /// 右栏或预览只涉及一张源图、而且它不见了时，是哪一张（显示「重新链接…」）。
    public var inspectedMissingSource: SourceID? {
        let id: SourceID? = switch inspected() {
        case (.source(let id), _): id
        case (.jobs, let jobs) where Set(jobs.map(\.sourceId)).count == 1: jobs.first?.sourceId
        default: preview.subject?.sourceId
        }
        guard let id, sourceItem(id)?.isMissing == true else { return nil }
        return id
    }

    /// 「重新链接…」：用户选了源图现在的位置。新文件与原图的像素尺寸、拍摄时间、相机厂商和型号都相同时直接重新链接；
    /// 有不同（或没有原图的信息可以核对）时先询问（``relinkPrompt``）。
    public func relink(_ id: SourceID, to url: URL) async {
        guard let item = sourceItem(id) else { return }
        let url = url.standardizedFileURL
        guard let current = await SourceFiles.fingerprint(url, timeout: sourceProbeTimeout) else {
            alert = WorkbenchAlert(title: "无法重新链接", message: "读不出这个文件：\(url.path)。")
            return
        }
        let differences = item.fingerprint?.differences(to: current)
        guard differences?.isEmpty == true else {
            relinkPrompt = RelinkPrompt(sourceId: id, fileURL: url, differences: differences ?? [])
            return
        }
        await relinkAndFindNearby(id, to: url, fingerprint: current)
    }

    /// 用户对「不是同一张照片」询问的回答。
    public func resolveRelink(_ confirm: Bool) async {
        guard let prompt = relinkPrompt else { return }
        relinkPrompt = nil
        guard confirm, sourceItem(prompt.sourceId) != nil else { return }
        guard let current = await SourceFiles.fingerprint(prompt.fileURL, timeout: sourceProbeTimeout) else {
            alert = WorkbenchAlert(title: "无法重新链接", message: "读不出这个文件：\(prompt.fileURL.path)。")
            return
        }
        await relinkAndFindNearby(prompt.sourceId, to: prompt.fileURL, fingerprint: current)
    }

    /// 重新链接这一张，再找同一个旧文件夹里其他缺失的原图：新文件夹里有同名文件、核对一致的一起重新链接
    /// （Lightroom 的「查找附近缺失的照片」）。找到了别的时报告一共重新链接了几张。
    private func relinkAndFindNearby(_ id: SourceID, to url: URL, fingerprint: SourceFingerprint) async {
        guard let oldFolder = sourceItem(id)?.source.fileURL.deletingLastPathComponent().standardizedFileURL else { return }
        guard await completeRelink(id, to: url, fingerprint: fingerprint, automatically: false) else { return }
        let newFolder = url.deletingLastPathComponent()
        guard newFolder != oldFolder else { return }
        let timeout = sourceProbeTimeout
        var relinked = 0
        var mismatched: [String] = []
        let nearby = sources.filter { $0.isMissing && $0.source.fileURL.deletingLastPathComponent().standardizedFileURL == oldFolder }
        for item in nearby {
            let old = item.source.fileURL
            let candidate = newFolder.appending(path: old.lastPathComponent)
            guard await SourceFiles.exists(candidate, timeout: timeout) else { continue }
            guard let current = await SourceFiles.fingerprint(candidate, timeout: timeout),
                  let known = item.fingerprint, known.differences(to: current).isEmpty
            else {
                mismatched.append(old.lastPathComponent)
                continue
            }
            guard let now = sourceItem(item.id), now.isMissing, now.source.fileURL == old else { continue }
            if await completeRelink(item.id, to: candidate, fingerprint: current, automatically: false) { relinked += 1 }
        }
        guard relinked > 0 || !mismatched.isEmpty else { return }
        var lines: [String] = []
        if relinked > 0 { lines.append("「\(newFolder.lastPathComponent)」里还找到了同一文件夹的另外 \(relinked) 张缺失的原图，也一起重新链接了") }
        if !mismatched.isEmpty {
            lines.append("这些同名文件与原来的照片不一致，没有重新链接：\(mismatched.joined(separator: "、"))")
            lines.append("建议：需要时分别选中它们，用「重新链接…」确认")
        }
        alert = WorkbenchAlert(title: "已重新链接 \(relinked + 1) 张原图", message: WorkbenchAlert.paragraph(lines))
    }

    /// 让服务改用新位置（sourceId、任务和改动都不变），然后丢掉旧位置的缓存、重新检查、重新校验、按最新的参数重新渲染预览。
    /// 批次里另有一张就是这个文件、还没有任务的源图（把移走的文件又拖进来过）时，把它并进来。
    @discardableResult
    private func completeRelink(_ id: SourceID, to url: URL, fingerprint: SourceFingerprint, automatically: Bool) async -> Bool {
        let relinked: PhotoSource
        do throws(ApplicationError) {
            relinked = try await service.relinkSource(id, to: url)
        } catch {
            alert = WorkbenchAlert(error, title: "无法重新链接")
            return false
        }
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return false }
        let retries = jobs.contains { $0.spec.source.sourceId == id && ($0.status == .failed || $0.status == .canceled) }
        sources[i].source = relinked
        sources[i].isMissing = false
        sources[i].inspection = nil
        sources[i].inspectionError = nil
        sources[i].fingerprint = fingerprint
        sources[i].bookmark = nil
        sources[i].notices = [JobIssue.relinked(to: relinked.fileURL, automatically: automatically, retries: retries)]
        let jobIds = sources[i].jobs.map(\.id)
        let duplicates = Set(sources.filter { $0.id != id && $0.source.fileURL == relinked.fileURL && $0.jobs.isEmpty }.map(\.id))
        if !duplicates.isEmpty {
            sources.removeAll { duplicates.contains($0.id) }
            selection = selection.filter { if case .source(let s) = $0 { !duplicates.contains(s) } else { true } }
        }
        // 旧位置的渲染结果、原图解码和缩略图都不再用（新位置是新的键）。
        preview.removeRenders(for: id)
        sourcesDidLeave()
        inspect(id)
        capture(id)
        scheduleValidation(jobIds)
        refreshPreview()
        // 服务已经让还没执行的任务改读新位置：同步「活跃」「已完成」里的记录。
        await refreshJobs()
        return true
    }
}
