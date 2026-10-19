# PhotoFrameApplication

任务队列、原子导出和 `PhotoFrameService`（规范 §9、§10.3、§11.1–11.2、§12.2）。
依赖 `PhotoFrameCore`、`PhotoFrameStorage`、`PhotoFrameRendering`（D-70：不另建组装包）。GUI、CLI、MCP 都用 `LocalPhotoFrameService.makeDefault()` 取服务。
队列只通过 `JobRenderer` 协议渲染、服务只通过 `ImageAnalyzer` 协议检查 / 预估 / 预览，正常实现是 `RenderingBackend`（用 PhotoFrameRendering）；
测试换成假的渲染器。

与渲染模块同名的类型在这里都加了 `Job` 前缀（`JobRenderRequest`、`JobRenderedOutput`、`JobRenderResult`、`JobRenderProgress`、
`JobOutputRole`、`JobRenderStage`），同时导入两个模块时不会冲突。

## 运行测试

```bash
swift test --scratch-path "$TMPDIR/PhotoFrameApplication-build"
```

仓库在 iCloud 同步目录下时必须加 `--scratch-path`，原因见 `PhotoFrameCore/README.md`。

## 模块一览

| 文件 | 内容 |
|---|---|
| `Model/Identifiers.swift` | `SourceID`、`JobID`、`AttemptID`（UUID，JSON 中是字符串） |
| `Model/JobStatus.swift` | 状态机：`queued → validating → decoding → rendering → encoding → writing → completed`，处理中可转 `failed` / `canceled`，`queued` 可转 `canceled` |
| `Model/JobRecord.swift` | `JobSpec`（源图 + 预设快照 + 目的地 + 单任务绑定）、`AttemptRecord`、`JobProgress`、`JobRecord`（Codable，D-13） |
| `Model/OutputManifest.swift` | `JobOutputRole`（封面 / 第 n 页切片，D-27）、输出清单：路径、像素尺寸、ICC、文件大小、可选 SHA-256、警告 |
| `Model/ApplicationError.swift` | `ApplicationError`（`code` + `message` + `hint`）、`ApplicationWarning`、`ApplicationErrorConvertible` |
| `Rendering/JobRenderer.swift` | 渲染协议 `JobRenderer`、`JobRenderRequest`、`JobRenderedOutput`、`JobRenderResult`、`JobRenderProgress` |
| `Rendering/RenderingBackend.swift` | 用 PhotoFrameRendering 实现 `JobRenderer` 与 `ImageAnalyzer`：类型转换、进度翻译、错误码，同步工作放到渲染线程（D-128） |
| `Export/OutputNaming.swift` | §9.2 目录与文件命名、版本后缀、文件名清理 |
| `Export/AtomicExporter.swift` | 临时目录、校验、原子发布、清理 |
| `Export/Overwrite.swift` | 显式覆盖（D-49）：发布标记、替换前检查、挪开 / 就位 / 恢复 |
| `Export/StagingCleanup.swift` | 清理超过 24 小时的残留临时目录（D-55） |
| `Export/OutputVerifier.swift` | 发布前的文件检查（默认看 JPEG / PNG 文件头） |
| `Queue/JobQueue.swift` | `actor JobQueue`：并发与内存限制、暂停、取消、重试、事件流、等待 |
| `Queue/QueueConfiguration.swift` | 并发数、内存预算、启动时是否暂停、平台配置、素材解析器 / 素材来源 |
| `Service/PhotoFrameService.swift` | `PhotoFrameService` 协议（§11.2 全部接口）、`ExportRequest`、进程内实现 `LocalPhotoFrameService` |
| `Service/PresetCatalog.swift` | `PresetReference`（预设库引用 / 文件）、`CatalogPreset`、`CatalogPresetSummary`、预设库与素材库操作的结果类型；`LocalLibrary` 作为素材来源 |
| `Service/Providers.swift` | 素材来源协议 `AssetProvider`（`LocalLibrary` 实现；`NoAssetLibrary` 表示没有素材）、`ImageAnalyzer` 与 `SourceInspection`、`ExportPlan`、`ExportPreview` 等 |
| `Service/Validation.swift` | `ValidationResult`；队列 `validating` 与服务 `validate` 共用的检查 |
| `Queue/JobEvent.swift` | 事件（Codable） |
| `Service/PresetContentService.swift` | GUI 用的新增接口（单独协议，不改 `PhotoFrameService`）：`savePreset`（存储为预设）、`replacePreset`（保存对预设本身的编辑）、`assetContentURL`（素材缩略图） |
| `Service/PhotoFrameService.swift` | `PhotoFrameService` 协议（任务相关部分）、`ExportRequest`、进程内实现 `LocalPhotoFrameService` |

## 任务模型

```text
Source ──┬── Job（源图 × 预设快照）── Attempt 1（failed）
         │                         └─ Attempt 2（completed，清单）
         └── Job …
```

- 创建任务时复制预设（§8.3 快照语义），重试用同一份。
- 任务状态 = 最后一个 Attempt 的状态。重试只对 `failed` / `canceled`：追加新 Attempt（新 ID、`number + 1`），旧的原样保留。
- `validating` 与 `writing` 由队列执行；`decoding` / `rendering` / `encoding` 由渲染器报告。渲染器跳过的阶段由队列补上，
  倒退的报告忽略，所以历史总是完整的流水线前缀。
- 进度只有真实指标：当前阶段、计划输出数、已完成输出数、已发布字节数。没有百分比。

## 队列

- 按提交顺序派发，同时运行数 ≤ `maxConcurrentJobs`，且估算内存之和 ≤ `memoryBudgetBytes`。
  GUI 的设置、CLI 和 MCP 的 `--jobs` 经过服务时限制在 1…`QueueConfiguration.maxConcurrentJobsLimit`（最多 8，且不超过本机核数，D-128），
  默认值仍是 D-53 的性能核数的一半（1–4）。
  估算优先用 `JobRenderer.estimatedPeakMemoryBytes(for:)`，否则按源图像素 × 8 字节（RGBAh）+ 画布缓冲，
  源图尺寸未知时用 `fallbackJobMemoryBytes`（1 GiB）。超过整个预算的单个任务在没有其他任务运行时照样执行。
- **暂停**只停止派发新任务。`startsPaused: true` 给 GUI「先排队、再开始批处理」用。
- **取消**：排队中的直接 `canceled`；执行中的设取消标志并取消渲染所在 Task，删除本次执行的临时目录。
  最终改名发布完成之后不能再取消（任务照常 `completed`）。
- **线程**（D-128）：`RenderingBackend` 的渲染、预览、检查源图、预览编码和队列的发布都是同步的长时间工作，在 PhotoFrameRendering 的
  `RenderThread` 专用线程上做，不占 Swift 的协作线程池。同时执行的任务数 ≥ 核数时，预览、进度事件和界面上的其他异步工作照常进行。
  Task 被取消时由 `RenderCancellation` 通知渲染代码。
- 事件：`events()` 返回 `AsyncStream<JobEvent>`，每个订阅方一条流。`waitUntilFinished(_:)` / `waitUntilIdle()` 给 CLI 阻塞等待用。

## 原子导出

```text
<输出根目录>/
├── .photoframe-staging/<attemptId>/      本次执行独占
│   ├── render/                            渲染器写文件
│   └── <作品名>/                          校验后按最终文件名组装
└── <平台>/<作品名>[_vN]/00_Cover.jpg …    整个目录一次 renamex_np(RENAME_EXCL) 发布
```

1. 渲染器返回的每个文件：必须在 `render/` 内（字面路径和解析符号链接后都要在），是普通文件、链接数为 1（拒绝指向原图的硬链接），
   非空，文件头与输出格式一致；输出位置不能重复。任何一项不满足，整个任务失败，目的地什么都不会出现。
2. 按轮播顺序改名为 `00_Cover.jpg`、`01_Slide.jpg`…，可选计算 SHA-256。
3. `<平台>/<作品名>` 已存在时依次试 `_v2`、`_v3`…；`RENAME_EXCL` 保证并发发布同名作品也不会覆盖。
4. 显式选择覆盖时按 D-49 的规则替换本软件之前发布的目录。
5. 成功或失败都删除 `<attemptId>` 目录；`.photoframe-staging` 空了也删除。
6. 原图只读：队列不会写、移动或覆盖源文件。

## 接入渲染模块

实现 `JobRenderer`：

```swift
struct Renderer: JobRenderer {
    func render(_ job: JobRenderRequest, outputDirectory: URL, progress: RenderProgressReporter) async throws -> JobRenderResult {
        // 调用前队列已进入 decoding
        await progress.report(.plannedOutputs(1 + slideCount))
        await progress.report(.stage(.rendering))
        // … 每写完一个文件：
        await progress.report(.stage(.encoding))
        await progress.report(.outputFinished(.slide(position: k + 1)))
        try Task.checkCancellation()   // 两张切片之间检查取消（同步的长时间工作放到协作线程池之外，见上文「线程」）
        return JobRenderResult(outputs: [...], warnings: [...])
    }
}
```

错误实现 `ApplicationErrorConvertible` 可以带稳定错误码，否则记为 `render.failed`。

PhotoFrameRendering 的适配器是 `RenderingBackend`，它同时实现 `ImageAnalyzer`：

| 应用层 | 渲染层 | 转换 |
|---|---|---|
| `JobRenderRequest` | `RenderJob` | 源图、预设快照、平台轮播上限、输入色彩空间覆盖；`slots` 经 `AssetProvider.fileURL(for:)` 换成素材文件 |
| `JobOutputRole` | `OutputRole` | `.single` / `.cover` → `.cover`；`.slide(k)` → `.slide(position: k + 1)`（D-27） |
| `JobRenderProgress`（async 事件） | `RenderProgress`（同步快照） | `ProgressTranslator`：阶段只前进；计划输出数出现或变化时报告一次；已写出数每加 1 报告一个 `.outputFinished`。事件按顺序放进一条流、逐条 `await` 报告，`render` 返回前全部报告完 |
| `ApplicationError` | `RenderError` | 同 code、message、hint；取消原样抛出 |

渲染层写 `00.<ext>`、`01.<ext>`…；`AtomicExporter` 发布时按角色改名为 `00_Cover.jpg`、`01_Slide.jpg`…（D-46–D-48）。

## 服务（§11.2）

| 接口 | 说明 |
|---|---|
| `listPresets()` | 预设库（内置、用户保存、导入）+ 本服务读过的 `.photoframe` 文件，加上读库时的警告 |
| `resolvePreset(_:)` | `PresetReference`：`.library(文本)` 交给 `PresetLibrary.find`（presetId、完整名称、短名，D-76）；`.file(URL)` 只读取、不放进库 |
| `importPreset` / `exportPreset` / `duplicatePreset` / `renamePreset` / `movePreset` / `deletePreset` | 预设库操作（D-39、D-79、D-80、D-84、D-37、D-94）；导出目标已存在时只有 `overwrite` 才替换（`preset.export_exists`）；内置预设不能移动、改名、删除（`library.builtin_read_only`） |
| `listAssets` / `resolveAsset` / `importAsset` / `renameAsset` / `setAssetCategory` / `deleteAsset` | 素材库操作（D-83、D-85、D-88、D-95）；素材引用是 assetId 或唯一的显示名称 |
| `bindAsset` / `listBindings` | 持久绑定：预设本地或用户默认（D-14、D-90）；`assetId` 为 nil 时清除 |
| `addSource(_:)` / `sources()` | 登记源图（只检查存在与扩展名，D-02） |
| `ExportRequest.sourceColorOverride` / `JobSpec.sourceColorOverride` | 没有 ICC 的源图按什么色彩空间解释（D-04、D-75）；源图自带 ICC 时渲染层忽略并警告 `source.override_ignored` |
| `inspectSource(_:)` | 格式、尺寸、方向、ICC、HDR 判定、EXIF 摘要；GPS 与作者只报告有无 |
| `validate(_:)` | 不渲染、不写文件：每个任务的源图、预设与平台、输出目录（不存在时只检查能否创建）、素材槽、预估输出（文件名与尺寸）、推算的作品目录（版本后缀；覆盖时检查能否替换、同一请求是否有两个任务指向同一目录 `request.duplicate_output`） |
| `renderPreview(_:)` | 与导出同一条管线，返回 sRGB PNG |
| `submit` / `status` / `cancel` / `retry` / `jobs` / `manifest` / `events` / `waitUntilFinished` | 任务 |

注入点：

- **本地库** `LocalLibrary`（PhotoFrameStorage）：预设、素材、绑定。`makeDefault(.init(libraryRoot:))` 默认按 `LibraryLocation.defaultRoot()` 选根目录（D-78、D-124，
  GUI、CLI、MCP 同一套规则），测试传临时目录；直接 `init(renderer:…)` 不传库时用系统临时目录里一个新的空库。
- **素材来源** `AssetProvider`（`QueueConfiguration.assets`，默认就是本地库）：每次校验任务时取一次 `slotResolver()`，
  渲染时用 `fileURL(for:)` 找素材文件。`NoAssetLibrary` 表示没有素材：必需素材缺失照常报 `slot.missing_required`。

## 已确定（2026-10-16）

规范 §16 中的编号：

- **D-46** 作品目录名默认 `{source}_{variant}`（源文件名 + `Standard` / `Panorama`），模板可改（`OutputNaming.workNameTemplate`）。
- **D-47** 单图预设也输出 `00_Cover.jpg`。
- **D-48** 平台目录名用英文：`Instagram`、`Xiaohongshu`、`Douyin`（与 §9.2 一致）；预设没有平台时用 `Custom`。
- **D-49** 文件冲突：默认加版本后缀 `_v2`、`_v3`…（`ConflictPolicy.versionSuffix`）；可选覆盖（`ConflictPolicy.overwrite`，
  在 `ExportDestination` 上按任务 / 提交指定，以后 GUI 弹确认、CLI 用 `--overwrite`）。覆盖的安全规则：
  - 新作品目录先在临时目录里完整校验、组装好；
  - 只替换本软件发布的目录：发布时在作品目录上写扩展属性 `org.anotherphotoframe.published`，没有这个标记的目录拒绝覆盖；
    目标是符号链接、或目录里有本软件命名（`NN_Cover/Slide.jpg|png`）和 `.DS_Store` 以外的东西，也拒绝；
  - 目录里含有本任务或队列中任何任务的源文件（按路径，也按设备 + inode 识别硬链接）时拒绝，错误码 `export.overwrite_contains_source`；
  - 步骤：旧目录改名挪进本次执行的临时目录 → 新目录改名就位 → 删除旧目录；新目录就位失败时把旧目录改名挪回原处；
  - 成功时清单里有 `export.replaced_previous` 警告。
- **D-50** 临时目录放在输出根目录下的 `.photoframe-staging/<attemptId>/`。
- **D-51** 暂停只停止派发新任务，不中断正在执行的任务。
- **D-52** 只有 `failed` / `canceled` 可以重试；已完成的任务想再导出就新建任务。
- **D-53** 调度：默认并发 = 性能核数一半（1…4），内存预算 = 物理内存一半，按提交顺序派发、不插队。调用方可以在
  `QueueConfiguration` 里设置，运行中用 `setMaxConcurrentJobs(_:)` / `setMemoryBudget(_:)` 修改并立即生效
  （调低时正在执行的任务继续做完）。
- **D-54** 清单只保存在 `JobRecord` 里，不在作品目录写 `manifest.json`；hash 默认不算（`computeHashes`）。
- **D-55** 清理残留临时目录：只删除 `.photoframe-staging` 下名字是 AttemptID、目录树中最新修改时间超过 24 小时、
  且不在本队列执行中的目录；之后 `.photoframe-staging` 空了就删除，其他文件不碰。队列第一次使用某个输出根目录时自动清理，
  应用启动时也可以对已知的输出目录调用 `removeStaleStaging(in:)`。
