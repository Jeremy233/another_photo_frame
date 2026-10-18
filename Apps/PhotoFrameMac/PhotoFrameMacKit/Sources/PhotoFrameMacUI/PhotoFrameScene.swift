import AppKit
import PhotoFrameApplication
import PhotoFrameMacModel
import SwiftUI

/// 应用的全部场景。`.app` 外壳（Xcode 工程）只需要 `@main` 里返回它。
public struct PhotoFrameScene: Scene {
    @State private var workbench: Result<Workbench, ApplicationError>

    @MainActor
    public init() {
        // 本地库与 CLI / MCP 按同一套规则选位置（D-78、D-124）；GUI 先排队、点「开始批处理」才派发。
        do throws(ApplicationError) {
            let service = try LocalPhotoFrameService.makeDefault(.init(startsPaused: true))
            let workbench = Workbench(service: service)
            // 源图离开批次后，丢掉其他原图的解码缓存。
            workbench.onSourcesRemoved = { OriginalImageStore.shared.retain(urls: $0) }
            _workbench = State(initialValue: .success(workbench))
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
                // 与其他空状态同一种样式，背景是中性灰（不透出壁纸色）。
                EmptyState(title: "无法启动", symbol: "xmark.octagon.fill", description: error.displayText)
                    .filling(Palette.panel)
                    .frame(minWidth: 480, minHeight: 320)
            }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
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

/// 菜单与快捷键：添加图片 ⌘O、开始批处理 ⌘↩、复制 ⌘D、三个界面 ⌘1…3。左栏 ⌃⌘S、右栏 ⌥⌘I；
/// 预览缩放 ⌘+ / ⌘- / ⌘0（100%）/ ⌘9（适合窗口）。每个命令的可用规则与界面上对应的按钮相同。
struct WorkbenchCommands: Commands {
    let workbench: Workbench

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // 图片加进「当前」：在别的界面里先切回「当前」，看得到加进来的图。
            Button("添加图片…") {
                workbench.mode = .current
                workbench.isAddingImages = true
            }
            .keyboardShortcut("o")
            Button("开始批处理") { startBatch(workbench) }
                .keyboardShortcut(.return)
                .disabled(!workbench.isPreviewVisible || !workbench.canStartBatch)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("复制") { Task { await workbench.duplicateFocused() } }
                .keyboardShortcut("d")
                .disabled(!workbench.canDuplicate)
        }
        // 与预览的缩放菜单同名、同顺序；看不到预览（「活跃」「已完成」）时不可用。
        CommandGroup(after: .toolbar) {
            Group {
                Button("放大预览") { workbench.preview.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("缩小预览") { workbench.preview.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("实际大小（100%）") { workbench.preview.zoom = .actualSize }
                    .keyboardShortcut("0", modifiers: .command)
                Button("适合窗口") { workbench.preview.zoom = .fit }
                    .keyboardShortcut("9", modifiers: .command)
            }
            .disabled(!workbench.isPreviewVisible)
            Divider()
        }
        CommandGroup(before: .sidebar) {
            // 「活跃」「已完成」时左栏总是收起，开关不可用（与工具栏按钮一致）。
            Button(workbench.showsSidebar ? "隐藏左栏" : "显示左栏") { workbench.showsSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(!workbench.canToggleSidebar)
            Button(workbench.showsInspector ? "隐藏右栏" : "显示右栏") { workbench.showsInspector.toggle() }
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
