#if DEBUG
import Foundation
import PhotoFrameMacModel

/// 只在 Debug 版本里：用环境变量准备演示内容，方便检查界面（截图）。
///
/// - `PHOTOFRAME_UI_DEMO=<目录>`：加入目录里的图片，给第一张加 Instagram Standard 和 XHS Standard，
///   给名字含 Panorama 的图加 Instagram Panorama，并选中第一个任务。
/// - `PHOTOFRAME_UI_TAB=canvas|panorama|layers|output`：右栏标签。
/// - `PHOTOFRAME_UI_MODE=active|completed` 与 `PHOTOFRAME_UI_EXPORTS=<目录>`：导出到这个目录后显示「活跃」或「已完成」。
///   只改这些任务的目录，不改位置列表。
extension Workbench {
    func loadDemoIfRequested() async {
        // 空值等于没设置（避免把空路径当成当前目录导出）。
        let env = ProcessInfo.processInfo.environment.filter { !$0.value.isEmpty }
        guard let dir = env["PHOTOFRAME_UI_DEMO"] else { return }
        let exports = env["PHOTOFRAME_UI_EXPORTS"].flatMap { $0.hasPrefix("/") ? $0 : nil }.map { URL(filePath: $0, directoryHint: .isDirectory) }

        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(filePath: dir), includingPropertiesForKeys: nil)) ?? []
        let ids = await addSources(urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
        func preset(_ name: String) -> UUID? { presets.first { $0.name == name }?.presetId }
        for (index, id) in ids.enumerated() {
            let panorama = sourceItem(id)?.source.displayName.contains("Panorama") == true
            let names = panorama ? ["Instagram Panorama"] : index == 0 ? ["Instagram Standard", "XHS Standard"] : ["Douyin Standard"]
            for name in names {
                if let p = preset(name) { await addJobs(preset: p, to: [id]) }
            }
            // 直接改任务的目录，不写进位置列表（不留下任何偏好设置）。
            if let exports { setDestination(exports, for: .source(id)) }
        }
        if let first = sources.first?.jobs.first { selection = [.job(first.id)] }
        if let tab = env["PHOTOFRAME_UI_TAB"], let value = InspectorTab(rawValue: tab) { inspectorTab = value }
        if inspectorTab == .layers {
            addLayer(.signature)
            addLayer(.exifText)
        }
        if exports != nil, let mode = env["PHOTOFRAME_UI_MODE"] {
            await startBatch()
            if mode == "completed" {
                while !activeJobs.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                self.mode = .completed
                if let first = finishedJobs.first { jobSelection = [first.jobId] }
            }
        }
    }
}
#endif
