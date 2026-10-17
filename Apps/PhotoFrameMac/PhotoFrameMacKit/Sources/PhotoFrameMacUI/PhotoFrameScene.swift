import AppKit
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
        Settings {
            if case .success(let workbench) = workbench {
                SettingsView(workbench: workbench)
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

/// 应用级事件：固定深色外观；把图片拖到 Dock 图标或用「打开方式」打开时，直接加入当前批次（与 Compressor 一致，不带预设）。
@MainActor
public final class PhotoFrameAppDelegate: NSObject, NSApplicationDelegate {
    static weak var workbench: Workbench?
    private static var pending: [URL] = []

    /// 界面固定深色（与 Compressor 一样，不跟随系统外观），弹窗和文件面板也一样。
    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        if let workbench = Self.workbench {
            Task { await workbench.addSources(urls) }
        } else {
            Self.pending += urls
        }
    }

    /// 窗口出现后登记，把启动时就收到的文件加进去。
    static func register(_ workbench: Workbench) async {
        self.workbench = workbench
        let urls = pending
        pending = []
        if !urls.isEmpty { await workbench.addSources(urls) }
    }
}
