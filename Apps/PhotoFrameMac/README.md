# PhotoFrameMac

macOS GUI（SwiftUI + AppKit），界面参照 Apple Compressor 的三栏布局（规范 §4、UI 设计文档）。
所有业务操作都通过 `PhotoFrameService`（PhotoFrameApplication）完成，界面里不写业务逻辑（D-13）。

## 视觉

布局与交互参照 Apple Compressor 5.4 的实际界面（截图只作参考，不进仓库）；图标、控件全部用 macOS 26 系统样式，
不复制 Compressor 的图标或配色。

**界面固定深色**（用户决定，2026-10-16）：与 Compressor 一样不跟随系统外观，弹窗和文件面板也是深色
（`PhotoFrameAppDelegate` 启动时设置 `NSApp.appearance`）。各栏背景用中性灰（`Palette`，明度参照 Compressor 取样），
不随桌面壁纸染色，避免影响对照片颜色的判断。所有分隔线（工具栏下、栏间、预览与任务列表之间、每栏顶部标题行下和底部操作栏上）
都是纯黑、1 个物理像素（`Hairline`、`HairlineSplitView`），与 Compressor 一样；可拖动的分隔线拖动范围向两侧各放宽 3 pt。

| 参照 Compressor | 遵循 macOS 26 系统规范 |
|---|---|
| 整个窗口一条顶栏（不按栏分段），没有窗口标题；正中「当前 \| 活跃 \| 已完成」，有任务时显示「活跃 (N)」；左右两端是侧栏开关 | 工具栏、分段控件、侧栏开关都是系统控件；强调色跟随系统设置（不用 Compressor 的紫色）；背景是中性灰，不用系统随壁纸染色的材质 |
| 每栏顶部一行小号分段控件（与预览标题栏的「成品 \| 原图」同尺寸；左栏「预设 \| 位置 \| 素材」、右栏「画布 \| 全景 \| 图层 \| 输出」，选中源图 / 位置时改为标题） | 左栏是树形列表，三角常驻：内置 ▸ 平台（Instagram / 小红书 / 抖音）▸ 预设；用户保存、导入各一组 |
| 左栏一行一项、名称过长截断、悬停显示完整信息；底部 + / 齿轮 | SF Symbols 通用图标（不是 Compressor 的设备图标） |
| 批处理列表：顶部一行全部源图 + 「添加」；每张源图一组（缩略图头部 + 列标题 + 任务），头部左端的三角可把任务折起来；选中任务右端红色「移除」；拖放悬停时高亮源图头部；作品目录已存在时带提示图标 | 列表、选中高亮用系统 `List`；分组底色用中性灰 |
| Inspector：最上面是信息卡（图标 + 粗体名称 + 灰色摘要，源图带 SDR / HDR 标记），紧接着是「警告」，再下面可折叠的分节（三角常驻，折叠状态按分节种类记住）+ 圆角分组框；任务警告和预览提示都在「警告」里，表单右对齐标签 + 常规尺寸控件（比 Compressor 大一号，行高 32 pt） | `Form(.columns)`、系统复选框 / 弹出菜单 / 滑块 |
| 预览：上方左边源图文件名、正中预设名（放不下时中间省略）+ 右侧缩放 % 与「显示」菜单；下方一行（Compressor 是时间轴）换成翻页 | — |
| 预览约占中栏 45%；底栏每栏一段，「开始批处理」在中栏右下 | 三栏和上下分隔都是自己封装的 AppKit `NSSplitView`（`ColumnSplit`、`VerticalSplit`），宽度自动记住 |
| 「活跃」「已完成」时左栏自动收起，中栏全宽表格：名称 / 状态（强调色文字）/ 已用时间 / 进度，行尾取消或重新导出按钮；历史按「今天」等日期分组 | 系统 `Table`、`ProgressView` |
| 提交批处理后切到「活跃」（设置里可关，D-114） | — |
| ⌘, 设置：顶部「通用 \| 高级」工具栏标签，右对齐标签的表单 | 系统 `Settings` 场景、`TabView`、`Form(.columns)` |

与 Compressor 不同、按我们规范做的地方：多选任务时 Compressor 显示「Nothing to Inspect」，我们按 UI 设计文档第 6 节显示可批量修改的共同字段；
目标目录已存在时 Compressor 只警告，我们按 D-49 询问「保留两者 / 覆盖」。

### 检查界面（Debug）

Debug 版本可以用环境变量准备演示内容（图片自己用代码合成，见 `DemoSeed.swift`）：

```bash
PHOTOFRAME_UI_DEMO=/path/to/synthetic-images PHOTOFRAME_UI_TAB=layers \
  AnotherPhotoFrame.app/Contents/MacOS/AnotherPhotoFrame -ApplePersistenceIgnoreState YES
```

### 已知限制

- 不用 SwiftUI 的 NavigationSplitView + inspector：系统会把顶栏按栏切成三段，而且窗口比三栏最小宽度之和窄时会反复调整约束而崩溃。
  也不要用 SwiftUI `VSplitView`（改用 `VerticalSplit`）。
- 三栏的收起 / 展开用 `NSSplitViewItem.isCollapsed`，不做动画；栏宽自己保存（只在拖完分隔线时记录），不用 NSSplitView 的 autosave。
  直接隐藏子视图会留下分隔线；动画中途再切换、或 autosave 恢复「已收起」，都会让展开后的栏越来越窄。测试见 `PhotoFrameMacUITests`。

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
- 本地库的位置由 `LibraryLocation.defaultRoot()` 决定（D-78、D-124），与 CLI / MCP 同一套规则、同一个库：
  `PHOTOFRAME_LIBRARY` > 带 App Group entitlement 时的 App Group 容器 > `~/Library/Group Containers/<App Group ID>/` 已存在时用它 >
  `~/Library/Application Support/AnotherPhotoFrame/`。未签名的应用没有 entitlement，macOS 不允许它在 Group Containers 下建目录，
  所以默认用最后一个。
- 以后签名并带上 App Group 时，新版会改用 App Group 容器，原来 Application Support 里的预设和素材需要迁移（复制到容器里的库目录）。
  迁移还没有实现，签名时一并处理。
- 有开发者账号时，把 `Config/Signing.local.xcconfig.example` 复制为 `Config/Signing.local.xcconfig`（不提交）并填入 Team ID，
  就会用 `App/PhotoFrameMac.entitlements` 里的 App Group 签名。App Group ID 现在是占位值 `group.org.anotherphotoframe`。

## 状态模型

| 文件 | 内容 |
|---|---|
| `Workbench.swift` | 主窗口状态：三个界面、左栏标签、选择、右栏显示什么（源图 / 任务 / 多个任务 / 预设）、字段读写（多选时「多个值」） |
| `Workbench+Library.swift` | 预设（新建、复制、重命名、删除、导入、导出、在分组间移动、编辑后存储）、素材、位置 |
| `Workbench+Batch.swift` | 源图、任务草稿、拖放、素材绑定、存储为预设、校验、开始批处理与覆盖确认（D-49）；有警告时开始前先询问（继续 / 查看 / 取消 + 不再询问，参照 Compressor） |
| `JobIssues.swift` | 任务的错误和警告（`DraftJob.issues`）及常见警告的一句话修改建议；任务行的 ⚠ 点按弹出完整列表，选中任务时 Inspector 顶部显示「警告」 |
| `Workbench+Layers.swift` | 添加 / 删除 / 修改图层 |
| `Workbench+Jobs.swift` | 任务事件、活跃 / 已完成、暂停、取消、重试、重新导出、底栏进度 |
| `PreviewModel.swift` | 预览：封面 / 切片 / 全景长卷、缩放、原图 / 成品、SDR / HDR；图像全部来自 `renderPreview`。HDR 时导出写 HDR 的页是 gain map JPEG，按 HDR 解码、以 EDR 显示（D-106）。「输出」标签的动态范围默认「跟随源图」（D-125），下面显示这张源图实际会导出成什么（`autoRangeResult`） |
| `PreviewPane.swift`、`OriginalImageStore.swift` | 预览画布：超出显示区域时可拖动平移，滚动 / 拖动 / 捏合时右上角显示小地图（点按或拖动小地图跳转），停下 1 秒后隐藏（显示、隐藏都不做动画，小地图是一块不透明的 SDR 层，避免半透明层在 HDR 画面上过渡）。原图先显示 512 px 快图，后台解码 3072 px 清晰版，放大到超过它时才解码全分辨率（100% 为真实像素，缩回后释放）；按 URL、档位、SDR/HDR 做 LRU 缓存（600 MB）。成品预览按内容（任务、源图修改时间、页、动态范围）缓存最近的渲染结果（256 MB），切回看过的任务不再请求后端 |
| `AppSettings.swift` | ⌘, 设置（D-114）：提交后是否切到「活跃」、有警告时是否先询问、并发数、内存预算（D-53，自动 = 队列默认值），存在 UserDefaults，调度参数改了立即交给队列 |
| `ExportLocation.swift` | 左栏「位置」：名称 + 目录，存在 UserDefaults |
| `DragPayload.swift` | 应用内拖放的内容（预设、位置、素材） |

把图片拖到 Dock 图标或用「打开方式」打开，会直接加入当前批次（`PhotoFrameAppDelegate`）。

「当前」界面里的任务是草稿（`DraftJob`：源图 + 预设副本 + 位置 + 单任务绑定）。改参数只改副本（§4.2），
点「开始批处理」才校验并交给服务创建任务；提交后的任务离开「当前」，在「活跃」「已完成」里看。
