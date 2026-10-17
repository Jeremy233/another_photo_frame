# PhotoFrameMac

macOS GUI（SwiftUI + AppKit），界面参照 Apple Compressor 的三栏布局（规范 §4、UI 设计文档）。
所有业务操作都通过 `PhotoFrameService`（PhotoFrameApplication）完成，界面里不写业务逻辑（D-13）。

> 视觉细节（配色、图标、控件样式）还没有定稿，等 Compressor 截图后再调；现在只确定了区域划分、信息层级和交互。

## 结构

```text
Apps/PhotoFrameMac/
├── project.yml                  XcodeGen 配置（源）
├── PhotoFrameMac.xcodeproj      由 project.yml 生成并提交，CI 和贡献者不需要装 XcodeGen
├── App/                         .app 外壳：@main、Info.plist、entitlements
├── Config/Signing.xcconfig      签名设置（默认本地签名，D-20）
└── PhotoFrameMacKit/            Swift 包：全部界面与状态代码
    ├── Sources/PhotoFrameMacModel   状态与 view model（不依赖 SwiftUI，可测试）
    ├── Sources/PhotoFrameMacUI      SwiftUI / AppKit 界面
    └── Tests/PhotoFrameMacModelTests
```

为什么这样分：`.app` 需要 Xcode 工程（Info.plist、entitlements、签名、App Group），而界面和状态代码放在 Swift 包里，
可以像其他包一样 `swift test`，CI 也不需要 Xcode 工程就能跑测试。工程文件用 XcodeGen 生成，`project.yml` 是唯一需要手改的地方。

## Build 与运行

```bash
xcodebuild -project Apps/PhotoFrameMac/PhotoFrameMac.xcodeproj -scheme PhotoFrameMac build
```

或用 Xcode 打开 `PhotoFrameMac.xcodeproj`。改了 `project.yml` 之后运行 `xcodegen generate` 并提交生成的工程。

测试（仓库在 iCloud 目录下时必须加 `--scratch-path`）：

```bash
cd Apps/PhotoFrameMac/PhotoFrameMacKit
swift test --scratch-path "$TMPDIR/PhotoFrameMacKit-build"
```

测试用真实的服务和渲染、临时目录里的本地库，图片全部由代码合成。

## 签名与本地库

- 默认本地签名（Sign to Run Locally），不带 entitlements，不开沙盒，任何人都能直接 build（D-20：Alpha / Beta 不签名）。
- 本地库按 D-78 放在 App Group 共享容器。没有 App Group entitlement 时，`LibraryLocation.groupContainerRoot()`
  退回按路径计算的 `~/Library/Group Containers/<App Group ID>/…`，与 CLI / MCP 仍是同一个库。
- 有开发者账号时，把 `Config/Signing.local.xcconfig.example` 复制为 `Config/Signing.local.xcconfig`（不提交）并填入 Team ID，
  就会用 `App/PhotoFrameMac.entitlements` 里的 App Group 签名。App Group ID 现在是占位值 `group.org.anotherphotoframe`。

## 状态模型

| 文件 | 内容 |
|---|---|
| `Workbench.swift` | 主窗口状态：三个界面、左栏标签、选择、右栏显示什么（源图 / 任务 / 多个任务 / 预设）、字段读写（多选时「多个值」） |
| `Workbench+Library.swift` | 预设（新建、复制、重命名、删除、导入、导出、在分组间移动、编辑后存储）、素材、位置 |
| `Workbench+Batch.swift` | 源图、任务草稿、拖放、素材绑定、存储为预设、校验、开始批处理与覆盖确认（D-49） |
| `Workbench+Layers.swift` | 添加 / 删除 / 修改图层 |
| `Workbench+Jobs.swift` | 任务事件、活跃 / 已完成、暂停、取消、重试、重新导出、底栏进度 |
| `PreviewModel.swift` | 预览：封面 / 切片 / 全景长卷、缩放、原图 / 成品、SDR / HDR；图像全部来自 `renderPreview` |
| `ExportLocation.swift` | 左栏「位置」：名称 + 目录，存在 UserDefaults |
| `DragPayload.swift` | 应用内拖放的内容（预设、位置、素材） |

「当前」界面里的任务是草稿（`DraftJob`：源图 + 预设副本 + 位置 + 单任务绑定）。改参数只改副本（§4.2），
点「开始批处理」才校验并交给服务创建任务；提交后的任务离开「当前」，在「活跃」「已完成」里看。
