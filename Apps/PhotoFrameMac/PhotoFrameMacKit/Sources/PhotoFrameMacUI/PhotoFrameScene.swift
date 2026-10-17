import PhotoFrameApplication
import PhotoFrameMacModel
import PhotoFrameStorage
import SwiftUI

/// 应用的全部场景。`.app` 外壳（Xcode 工程）只需要 `@main` 里返回它。
public struct PhotoFrameScene: Scene {
    @State private var workbench: Result<Workbench, ApplicationError>

    @MainActor
    public init() {
        // 本地库放在 App Group 共享容器（D-78），与 CLI / MCP 共用；GUI 先排队、点「开始批处理」才派发。
        do throws(ApplicationError) {
            let service = try LocalPhotoFrameService.makeDefault(
                .init(startsPaused: true, libraryRoot: LibraryLocation.groupContainerRoot()))
            _workbench = State(initialValue: .success(Workbench(service: service)))
        } catch {
            _workbench = State(initialValue: .failure(error))
        }
    }

    public var body: some Scene {
        Window("AnotherPhotoFrame", id: "main") {
            switch workbench {
            case .success(let workbench):
                WorkbenchView(workbench: workbench)
            case .failure(let error):
                ContentUnavailableView("无法启动", systemImage: "exclamationmark.triangle", description: Text(error.message))
            }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            SidebarCommands()
            if case .success(let workbench) = workbench {
                WorkbenchCommands(workbench: workbench)
            }
        }
    }
}

/// 菜单与快捷键：添加图片 ⌘O、开始批处理 ⌘↩、三个界面 ⌘1…3。侧栏 ⌃⌘S（系统命令）、Inspector ⌥⌘I。
struct WorkbenchCommands: Commands {
    let workbench: Workbench

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("添加图片…") { workbench.isAddingImages = true }
                .keyboardShortcut("o")
            Button("开始批处理") { Task { await workbench.startBatch() } }
                .keyboardShortcut(.return)
        }
        CommandGroup(before: .sidebar) {
            Button(workbench.showsInspector ? "隐藏 Inspector" : "显示 Inspector") { workbench.showsInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            ForEach(Array(WorkbenchMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { workbench.mode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
        }
    }
}
