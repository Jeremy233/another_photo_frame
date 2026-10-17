# PhotoFrameMac

macOS GUI（SwiftUI + AppKit），界面参照 Apple Compressor 的三栏布局（规范 §4、UI 设计文档）。
所有业务操作都通过 `PhotoFrameService`（PhotoFrameApplication）完成，界面里不写业务逻辑（D-13）。

## 视觉

布局与交互参照 Apple Compressor 5.4 的实际界面（截图只作参考，不进仓库）；图标、控件全部用 macOS 26 系统样式，
不复制 Compressor 的图标或配色。

**界面固定深色**（用户决定，2026-10-16）：与 Compressor 一样不跟随系统外观，弹窗和文件面板也是深色
（`PhotoFrameAppDelegate` 启动时设置 `NSApp.appearance`）。各栏背景用中性灰（`Palette`，明度参照 Compressor 取样），
不随桌面壁纸染色，避免影响对照片颜色的判断。

| 参照 Compressor | 遵循 macOS 26 系统规范 |
|---|---|
| 顶栏没有窗口标题；正中「当前 \| 活跃 \| 已完成」，有任务时显示「活跃 (N)」；左右两端是侧栏开关 | 工具栏、分段控件、侧栏开关都是系统控件；强调色跟随系统设置（不用 Compressor 的紫色）；背景是中性灰，不用系统随壁纸染色的材质 |
| 每栏顶部一行小号分段控件（左栏「预设 \| 位置 \| 素材」、右栏「画布 \| 全景 \| 图层 \| 输出」，选中源图 / 位置时改为标题） | 侧栏列表用 `.sidebar` 样式、小号行高；分组标题可折叠 |
| 左栏一行一项、名称过长截断、悬停显示完整信息；底部 + / 齿轮 | SF Symbols 通用图标（不是 Compressor 的设备图标） |
| 批处理列表：顶部一行全部源图 + 「添加」；每张源图一组（缩略图头部 + 列标题 + 任务）；选中任务右端红色「移除」；拖放悬停时高亮源图头部；作品目录已存在时带提示图标 | 列表、选中高亮用系统 `List`；分组底色用中性灰 |
| Inspector：顶部信息卡（图标 + 粗体名称 + 灰色摘要，源图带 SDR / HDR 标记），下面分节标题 + 圆角分组框，表单右对齐标签 + 小号控件 | `Form(.columns)`、系统复选框 / 弹出菜单 / 滑块 |
| 预览：上方标题「源图 - 预设」+ 右侧缩放 % 与「显示」菜单；下方一行（Compressor 是时间轴）换成翻页 | — |
| 预览约占中栏 45%；底栏每栏一段，「开始批处理」在中栏右下 | 分隔线是 AppKit `NSSplitView`，位置自动记住，双击恢复默认 |
| 「活跃」「已完成」时左栏自动收起，中栏全宽表格：名称 / 状态（强调色文字）/ 已用时间 / 进度，行尾取消或重新导出按钮；历史按「今天」等日期分组 | 系统 `Table`、`ProgressView` |
| 提交批处理后切到「活跃」 | — |

与 Compressor 不同、按我们规范做的地方：多选任务时 Compressor 显示「Nothing to Inspect」，我们按 UI 设计文档第 6 节显示可批量修改的共同字段；
目标目录已存在时 Compressor 只警告，我们按 D-49 询问「保留两者 / 覆盖」。

### 检查界面（Debug）

Debug 版本可以用环境变量准备演示内容（图片自己用代码合成，见 `DemoSeed.swift`）：

```bash
PHOTOFRAME_UI_DEMO=/path/to/synthetic-images PHOTOFRAME_UI_TAB=layers \
  AnotherPhotoFrame.app/Contents/MacOS/AnotherPhotoFrame -ApplePersistenceIgnoreState YES
```

### 已知限制

- 窗口最小宽度 1120 pt：比三栏最小宽度之和更窄时，SwiftUI 的 NavigationSplitView + inspector 会反复调整约束而崩溃。
  同理，不要在分栏内容上加 `minWidth`，也不要用 SwiftUI `VSplitView`（改用 `VerticalSplit`）。

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
| `PreviewModel.swift` | 预览：封面 / 切片 / 全景长卷、缩放、原图 / 成品、SDR / HDR；图像全部来自 `renderPreview`。HDR 时导出写 HDR 的页是 gain map JPEG，按 HDR 解码、以 EDR 显示（D-106） |
| `ExportLocation.swift` | 左栏「位置」：名称 + 目录，存在 UserDefaults |
| `DragPayload.swift` | 应用内拖放的内容（预设、位置、素材） |

把图片拖到 Dock 图标或用「打开方式」打开，会直接加入当前批次（`PhotoFrameAppDelegate`）。

「当前」界面里的任务是草稿（`DraftJob`：源图 + 预设副本 + 位置 + 单任务绑定）。改参数只改副本（§4.2），
点「开始批处理」才校验并交给服务创建任务；提交后的任务离开「当前」，在「活跃」「已完成」里看。
