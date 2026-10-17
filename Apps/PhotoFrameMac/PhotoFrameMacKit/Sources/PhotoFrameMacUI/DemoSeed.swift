#if DEBUG
import AppKit
import PhotoFrameMacModel

/// 只在 Debug 版本里：用环境变量准备演示内容，方便检查界面（截图）。
///
/// - `PHOTOFRAME_UI_DEMO=<目录>`：加入目录里的图片，给第一张加 Instagram Standard 和 XHS Standard，
///   给名字含 Panorama 的图加 Instagram Panorama，并选中第一个任务。
/// - `PHOTOFRAME_UI_TAB=canvas|panorama|layers|output`：右栏标签。
/// - `PHOTOFRAME_UI_MODE=active|paused|completed` 与 `PHOTOFRAME_UI_EXPORTS=<目录>`：导出到这个目录后显示「活跃」或「已完成」。
///   只改这些任务的目录，不改位置列表。
/// - `PHOTOFRAME_UI_TOGGLE=<n>`：把左栏和 Inspector 各收起、展开 n 次（检查栏宽是否保持不变），
///   间隔 `PHOTOFRAME_UI_TOGGLE_MS` 毫秒；`PHOTOFRAME_UI_COLLAPSE=1` 时最后停在收起状态；
///   `PHOTOFRAME_UI_TOGGLE_SIDE=leading|trailing` 只切换一侧；`PHOTOFRAME_UI_WINDOW_WIDTH=<pt>` 先把窗口改成这个宽度。
extension Workbench {
    func loadDemoIfRequested() async {
        // 空值等于没设置（避免把空路径当成当前目录导出）。
        let env = ProcessInfo.processInfo.environment.filter { !$0.value.isEmpty }
        if let width = env["PHOTOFRAME_UI_WINDOW_WIDTH"].flatMap(Double.init), let window = NSApp.windows.first(where: \.isVisible) {
            window.setContentSize(NSSize(width: width, height: window.contentLayoutRect.height))
        }
        if let count = env["PHOTOFRAME_UI_TOGGLE"].flatMap(Int.init) {
            let side = env["PHOTOFRAME_UI_TOGGLE_SIDE"]
            for _ in 0..<count * 2 {
                try? await Task.sleep(for: .milliseconds(Int(env["PHOTOFRAME_UI_TOGGLE_MS"] ?? "250") ?? 250))
                if side != "trailing" { showsSidebar.toggle() }
                if side != "leading" { showsInspector.toggle() }
            }
            if env["PHOTOFRAME_UI_COLLAPSE"] != nil {
                if side != "trailing" { showsSidebar = false }
                if side != "leading" { showsInspector = false }
            }
        }
        // `PHOTOFRAME_UI_SHOW=current|active|completed` 切到某个界面；`PHOTOFRAME_UI_NO_INSPECTOR=1` 收起 Inspector。
        if env["PHOTOFRAME_UI_NO_INSPECTOR"] != nil { showsInspector = false }
        if let show = env["PHOTOFRAME_UI_SHOW"].flatMap(WorkbenchMode.init(rawValue:)) { mode = show }
        guard let dir = env["PHOTOFRAME_UI_DEMO"] else { return }
        let exports = env["PHOTOFRAME_UI_EXPORTS"].flatMap { $0.hasPrefix("/") ? $0 : nil }.map { URL(filePath: $0, directoryHint: .isDirectory) }

        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(filePath: dir), includingPropertiesForKeys: nil)) ?? []
        let ids = await addSources(urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
        func preset(_ name: String) -> UUID? { presets.first { $0.name == name }?.presetId }
        for (index, id) in ids.enumerated() {
            let panorama = sourceItem(id)?.source.displayName.contains("Panorama") == true
            // `PHOTOFRAME_UI_MANY=1`：每张图都加全部内置预设（任务多，便于看「活跃」里排队的样子）。
            let names = env["PHOTOFRAME_UI_MANY"] != nil ? presets.filter { $0.origin == .builtIn }.map(\.name)
                : panorama ? ["Instagram Panorama"] : index == 0 ? ["Instagram Standard", "XHS Standard"] : ["Douyin Standard"]
            for name in names {
                if let p = preset(name) { await addJobs(preset: p, to: [id]) }
            }
            // 直接改任务的目录，不写进位置列表（不留下任何偏好设置）。
            if let exports { setDestination(exports, for: .source(id)) }
        }
        if let first = sources.first?.jobs.first { selection = [.job(first.id)] }
        if let tab = env["PHOTOFRAME_UI_TAB"], let value = InspectorTab(rawValue: tab) { inspectorTab = value }
        // 预览：`PHOTOFRAME_UI_ZOOM=fit|<比例>`、`PHOTOFRAME_UI_PAGE=strip|<页码>`、`PHOTOFRAME_UI_ORIGINAL=1`、`PHOTOFRAME_UI_RANGE=hdr`；
        // `PHOTOFRAME_UI_SELECT=<第几个任务>` 选别的任务（例如全景）。
        if let n = env["PHOTOFRAME_UI_SELECT"].flatMap(Int.init), case let jobs = sources.flatMap(\.jobs), jobs.indices.contains(n) { selection = [.job(jobs[n].id)] }
        if let zoom = env["PHOTOFRAME_UI_ZOOM"] { preview.zoom = Double(zoom).map(PreviewZoom.scale) ?? .fit }
        if env["PHOTOFRAME_UI_ORIGINAL"] != nil { preview.showsOriginal = true }
        if env["PHOTOFRAME_UI_RANGE"] == "hdr" { preview.range = .hdr }
        if let page = env["PHOTOFRAME_UI_PAGE"] {
            await settle()
            preview.page = page == "strip" ? .strip : .page(Int(page) ?? 0)
        }
        if inspectorTab == .layers {
            addLayer(.signature)
            addLayer(.exifText)
        }
        if exports != nil, let mode = env["PHOTOFRAME_UI_MODE"] {
            await startBatch()
            if mode == "paused" { await pauseQueue() }
            if mode == "completed" {
                while !activeJobs.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                self.mode = .completed
                if let first = finishedJobs.first { jobSelection = [first.jobId] }
            }
        }
    }
}
#endif
