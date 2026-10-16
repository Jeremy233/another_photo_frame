# PhotoFrameApplication

任务队列、原子导出和 `PhotoFrameService` 骨架（规范 §9、§10.3、§11.1–11.2、§12.2）。
依赖 `PhotoFrameCore`、`PhotoFrameStorage`；**不依赖** `PhotoFrameRendering`，渲染通过 `JobRenderer` 协议接入。

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
| `Model/OutputManifest.swift` | `OutputRole`（封面 / 第 n 页切片，D-27）、输出清单：路径、像素尺寸、ICC、文件大小、可选 SHA-256、警告 |
| `Model/ApplicationError.swift` | `ApplicationError`（`code` + `message` + `hint`）、`ApplicationWarning`、`ApplicationErrorConvertible` |
| `Rendering/JobRenderer.swift` | 渲染协议 `JobRenderer`、`RenderJob`、`RenderedOutput`、`RenderResult`、`RenderProgress` |
| `Export/OutputNaming.swift` | §9.2 目录与文件命名、版本后缀、文件名清理 |
| `Export/AtomicExporter.swift` | 临时目录、校验、原子发布、清理 |
| `Export/OutputVerifier.swift` | 发布前的文件检查（默认看 JPEG / PNG 文件头） |
| `Queue/JobQueue.swift` | `actor JobQueue`：并发与内存限制、暂停、取消、重试、事件流、等待 |
| `Queue/QueueConfiguration.swift` | 并发数、内存预算、启动时是否暂停、平台配置、素材解析器 |
| `Queue/JobEvent.swift` | 事件（Codable） |
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
  估算优先用 `JobRenderer.estimatedPeakMemoryBytes(for:)`，否则按源图像素 × 8 字节（RGBAh）+ 画布缓冲，
  源图尺寸未知时用 `fallbackJobMemoryBytes`（1 GiB）。超过整个预算的单个任务在没有其他任务运行时照样执行。
- **暂停**只停止派发新任务。`startsPaused: true` 给 GUI「先排队、再开始批处理」用。
- **取消**：排队中的直接 `canceled`；执行中的设取消标志并取消渲染所在 Task，删除本次执行的临时目录。
  最终改名发布完成之后不能再取消（任务照常 `completed`）。
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
4. 成功或失败都删除 `<attemptId>` 目录；`.photoframe-staging` 空了也删除。
5. 原图只读：队列不会写、移动或覆盖源文件。

## 接入渲染模块

实现 `JobRenderer`：

```swift
struct Renderer: JobRenderer {
    func render(_ job: RenderJob, outputDirectory: URL, progress: RenderProgressReporter) async throws -> RenderResult {
        // 调用前队列已进入 decoding
        await progress.report(.plannedOutputs(1 + slideCount))
        await progress.report(.stage(.rendering))
        // … 每写完一个文件：
        await progress.report(.stage(.encoding))
        await progress.report(.outputFinished(.slide(position: k + 1)))
        try Task.checkCancellation()   // 两张切片之间检查取消
        return RenderResult(outputs: [...], warnings: [...])
    }
}
```

错误实现 `ApplicationErrorConvertible` 可以带稳定错误码，否则记为 `render.failed`。

## 待确认

以下是规范没写清楚、这里先按默认做法实现的地方，见本次提交的汇报。确认后应写进规范 §16。

1. 作品名默认 `{source}_{variant}`（源文件名 + Standard / Panorama）。
2. 单图预设也输出 `00_Cover.jpg`。
3. 平台目录名：`Instagram`、`Xiaohongshu`、`Douyin`（与 §9.2 一致），无平台时 `Custom`。
4. 冲突时给作品目录加 `_v2`、`_v3`…；V1 不提供「确认覆盖」。
5. 临时目录放在输出根目录下的 `.photoframe-staging/`。
6. 暂停只停止派发，不中断正在执行的任务。
7. 只有 `failed` / `canceled` 可以重试；已完成的任务想再导出就新建任务。
8. 默认并发 = 性能核数一半（1…4），内存预算 = 物理内存一半；按提交顺序派发，不插队。
9. 清单只保存在 `JobRecord` 里，不在作品目录写 `manifest.json`；hash 默认不算。
10. 进程崩溃后残留的 `.photoframe-staging/<attemptId>` 目前不自动清理。
