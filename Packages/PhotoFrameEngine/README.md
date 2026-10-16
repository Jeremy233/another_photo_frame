# PhotoFrameEngine

组装层（规范 §10.1、§10.2、§10.3「共享 Application/Engine 模块」）：用 `PhotoFrameRendering` 实现 `PhotoFrameApplication`
的 `JobRenderer` 和 `ImageAnalyzer`，并创建配置好的 `PhotoFrameService`。GUI、CLI（`Tools/photoframe`）和以后的 MCP 都从这里取服务。

```text
Tools/photoframe ─┐
GUI（以后）      ├─► PhotoFrameEngine ─► PhotoFrameApplication（队列、导出、服务）
MCP（以后）      ┘          │                    │
                            └─► PhotoFrameRendering ─► PhotoFrameCore / PhotoFrameStorage
```

依赖方向：Application 不依赖 Rendering（队列和服务可以用假的渲染器测试）；Engine 同时依赖两者，只做适配和组装。

## 用法

```swift
let service = try PhotoFrameEngine.makeService(.init(
    startsPaused: false,          // GUI 先排队再开始时为 true
    presets: nil,                 // 用户预设库做好后从这里接入（PresetProvider）
    assets: nil))                 // 素材库做好后从这里接入（AssetProvider）
```

## 适配要点（`RenderingBackend.swift`）

| 应用层 | 渲染层 | 转换 |
|---|---|---|
| `JobRenderRequest` | `RenderJob` | 源图、预设快照、平台轮播上限；`slots`（`SlotResolution`）经 `AssetProvider.fileURL(for:)` 换成素材文件 |
| `JobOutputRole` | `OutputRole` | `.single` / `.cover` → `.cover`；`.slide(k)` → `.slide(position: k + 1)`（D-27） |
| `JobRenderProgress`（async 事件） | `RenderProgress`（同步快照） | 见下 |
| `ApplicationError` | `RenderError` | 同 code、message、hint；取消原样抛出 |
| `ApplicationWarning` | `RenderWarning` | 页码、图层附在 message 后 |

**进度**：渲染层在同步闭包里报告快照（阶段 + 已写出数 + 总数），应用层要 `await` 逐条报告事件。`ProgressTranslator` 在同步闭包里把快照翻译成事件：
阶段只前进（倒退和重复的不报告，队列已处于 `decoding`，所以从 `rendering` 起）、计划输出数出现或变化时报告一次、已写出数每加 1 报告一个
`.outputFinished`（角色按轮播顺序推算；预设没有封面时第一页是第 1 张切片）。事件按产生顺序放进一条 `AsyncStream`，由一个消费者依次
`await` 报告；`render` 返回前等消费者报告完，所以队列看到的顺序和渲染器产生的顺序完全一致，且都在任务进入 `writing` 之前。

**文件名**：渲染层写 `00.<ext>`、`01.<ext>`…；`AtomicExporter` 发布时按角色改名为 `00_Cover.jpg`、`01_Slide.jpg`…，目录按 D-46–D-48。

## 运行测试

```bash
swift test --scratch-path "$TMPDIR/PhotoFrameEngine-build"
```

测试用代码合成的图片走完真实渲染：阶段历史完整、进度与文件一一对应、文件名与目录、尺寸、sRGB ICC、临时目录清理、渲染错误码、取消，
以及检查 / 预估 / 预览。
