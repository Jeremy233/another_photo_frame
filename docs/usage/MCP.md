# 本地 MCP 服务器 `photoframe mcp serve`

> 对应规范 §10.3、§11.4、§12、AC-07。代码在 `Tools/photoframe/Sources/PhotoFrameCLI/MCP/`，是 CLI 的子命令（§11.3 写法，D-98），
> 后端与 GUI、CLI 是同一个 `PhotoFrameService`（D-13、D-70）。预设逐项修改的字段路径与 CLI `preset get` / `preset set` 相同（D-93、D-99）。

让支持 MCP 的 AI 客户端（Claude Desktop、Claude Code 等）在本机调用 AnotherPhotoFrame：查看预设、检查照片、校验、预览、导出。
不需要打开 GUI，不联网，不读取任何 token。

- **SDK**：官方 Swift SDK [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk) **0.12.1**（`Package.swift` 里 `exact:` 固定，D-97），
  支持 MCP 协议 `2025-11-25`（最新），向下兼容 `2025-06-18`、`2025-03-26`、`2024-11-05`，按客户端请求的版本协商。
- **传输**：stdio，每行一条 JSON-RPC 消息。stdout 只写协议消息（启动时把 fd 1 改指向 stderr，库里任何意外的输出都进 stderr）；日志写 stderr。

## 构建

```bash
cd Tools/photoframe
swift build -c release --scratch-path "$TMPDIR/photoframe-build"
```

可执行文件在 `$TMPDIR/photoframe-build/release/photoframe`。建议复制到固定位置（例如 `~/bin/photoframe` 或 `/usr/local/bin/photoframe`），
客户端配置里写**绝对路径**。复制时连同旁边的 `PhotoFrameStorage_PhotoFrameStorage.bundle` 一起复制到同一个文件夹
（只复制可执行文件，启动时找不到资源包会直接崩溃）。

## 配置目录白名单（D-100）

服务器只能读取「允许读取的目录」里的源图，只能把导出和预览写进「允许写入的目录」（含子目录）。**两者都没有配置时拒绝所有文件访问**
（`list_presets`、`get_preset`、`list_assets` 等不碰文件的工具照常可用）。

| 方式 | 写法 |
|---|---|
| 启动参数（推荐） | `--allow-read <目录>`、`--allow-write <目录>`，可重复 |
| 环境变量 | `PHOTOFRAME_MCP_ALLOW_READ`、`PHOTOFRAME_MCP_ALLOW_WRITE`，多个目录用 `:` 分隔 |

两种方式的目录合在一起生效。目录必须是已存在的目录（可以用 `~`），不能是 `/`；有一个不合法就拒绝启动（退出码 2，`mcp.invalid_root`）。
允许写入的目录不自动可读，反之亦然。只给 AI 需要的最小范围，例如「修好的成片」目录只读、「社交平台导出」目录可写。

其他启动参数（上限，D-101）：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--max-input-mb <n>` | 2048 | 单个输入文件的字节上限（D-18 不限制像素尺寸，这里只防止误传超大文件） |
| `--max-preview-edge <px>` | 2048 | `preview_export` 的 `maxEdge` 上限 |
| `--max-active-jobs <n>` | 16 | 同时未结束（排队或执行中）的导出任务上限 |
| `--max-output-mb <n>` | 20480 | 本次会话写出的文件总量上限（导出成品 + 预览文件），在每次写请求前检查 |
| `--jobs <n>` | 性能核数的一半（1–4，D-53） | 同时执行的任务数 |

本地库（预设、素材、绑定）与 GUI、CLI 共用，位置规则见 [CLI.md](CLI.md)「本地库」（D-78、D-124）；`PHOTOFRAME_LIBRARY=<目录>` 改用别的库（D-96）。

### Claude Desktop

编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`，然后重启 Claude Desktop：

```json
{
  "mcpServers": {
    "photoframe": {
      "command": "/Users/me/bin/photoframe",
      "args": [
        "mcp", "serve",
        "--allow-read", "/Users/me/Pictures/Edited",
        "--allow-write", "/Users/me/Pictures/Social Exports"
      ]
    }
  }
}
```

### Claude Code

```bash
claude mcp add photoframe -- /Users/me/bin/photoframe mcp serve --allow-read /Users/me/Pictures/Edited --allow-write "/Users/me/Pictures/Social Exports"
```

或者在项目的 `.mcp.json` 里写（格式与 Claude Desktop 相同），也可以用环境变量：

```json
{
  "mcpServers": {
    "photoframe": {
      "command": "/Users/me/bin/photoframe",
      "args": ["mcp", "serve"],
      "env": {
        "PHOTOFRAME_MCP_ALLOW_READ": "/Users/me/Pictures/Edited",
        "PHOTOFRAME_MCP_ALLOW_WRITE": "/Users/me/Pictures/Social Exports"
      }
    }
  }
}
```

其他支持 stdio MCP 的客户端同理：命令是 `photoframe`，参数以 `mcp serve` 开头。服务器启动时在 stderr 打印允许的目录；客户端也可以读资源
`photoframe://access` 查看。

## 生命周期（§10.3）

- 服务器随客户端启动，客户端关闭连接（stdin 结束）或发 SIGINT / SIGTERM 时退出。客户端不再读 stdout 时，写入失败但进程不会被
  SIGPIPE 杀掉，stdin 结束后照常退出。
- **导出任务属于这个服务器进程**：`create_export_job` 立即返回 `jobId`，任务在后台执行；进程退出前取消本服务器创建的、尚未结束的任务
  （包括退出时正在提交的；退出开始后 `create_export_job` 报 `mcp.shutting_down`），
  并删除它们的临时目录（已经发布的作品目录保持完整）。所以客户端退出会中断正在进行的导出——要导出大批照片时请等任务结束。
- 不同进程（GUI、CLI、另一个 MCP 服务器）之间不共享队列（D-13）；`get_job_status`、`cancel_export_job` 只能看到、取消本服务器创建的任务。

## 工具

所有工具的结果都同时放在 `structuredContent` 和一个 `text` 内容里（同一份 JSON），外层有 `ok`；失败时 `isError: true`，并有
`error: {code, message, hint?}`。其余字段名与 CLI `--json`（[docs/usage/CLI.md](CLI.md)）一致，值为空的可选字段省略（D-77）。结果格式见 D-104。
所有路径参数都必须是**绝对路径**。

| 工具 | 类型 | 作用 |
|---|---|---|
| `list_presets` | 只读 | 预设摘要 |
| `get_preset` | 只读 | 预设完整内容或一个字段 |
| `update_preset` | 写预设库 | 逐项修改预设（D-93） |
| `inspect_image` | 只读 | 源图尺寸、ICC、HDR、EXIF 摘要 |
| `list_assets` | 只读 | 素材元信息（不含路径） |
| `validate_export` | 只读 | 校验导出、列出将写出的文件 |
| `preview_export` | 计算 | 预览图（直接返回或写文件） |
| `create_export_job` | 写文件 | 创建导出任务 |
| `get_job_status` | 只读 | 任务进度、文件清单 |
| `cancel_export_job` | 写 | 取消任务 |

### `list_presets`

参数：无。返回 `{presets: [...], warnings: [...]}`，`presets[]` 与 `photoframe preset list --json` 的每一项相同
（`presetId`、`name`、`slug`、`origin`、`readOnly`、`platform`、`canvas`、`mode`、`background`、`minMarginPx`、`panorama`、`format`、
`quality`、`dynamicRange`、`layerCount`、`slotIds`）。

### `get_preset`

| 参数 | 类型 | 说明 |
|---|---|---|
| `preset` | string，必填 | presetId、完整名称或短名称（`slug`）。只在预设库里找，**不会把它当文件路径读** |
| `path` | string | 字段路径（见下文「字段路径」）；省略时返回整份预设 |

返回 `{preset: {…摘要…}, path?, value}`。`value` 是整份 `manifest.json`（与 `.photoframe` 里的完全相同）或该字段的 JSON 值。

### `update_preset`

| 参数 | 类型 | 说明 |
|---|---|---|
| `preset` | string，必填 | 同 `get_preset` |
| `edits` | array，必填，1–100 项 | `{path, value}` 设置；`{path, remove: true}` 删除 |

按顺序应用全部修改，改完的整份预设走一遍**与导入 `.photoframe` 完全相同的检查**（schema、不认识的字段、取值范围、引用、平台能力、
1 MiB 上限）后原子写入；任何一项不通过都不修改。返回 `{preset: {…修改后的摘要…}, changed: [路径…], warnings}`。

- 内置预设只读：`library.builtin_read_only`，先用 `photoframe preset duplicate` 复制。
- `presetId`、`schemaVersion` 不能改：`preset.field_read_only`。
- 预设的分组和创建时间不变（D-81）。

### `inspect_image`

| 参数 | 类型 | 说明 |
|---|---|---|
| `path` | string，必填 | 源图（JPEG / PNG / TIFF），在允许读取的目录内 |

返回 `{image: {…}}`，与 `photoframe image inspect --json` 的 `image` 相同。GPS、作者和版权只报告有无（`hasGPS`、`hasAuthorOrCopyright`），不输出内容。

### `list_assets`

| 参数 | 类型 | 说明 |
|---|---|---|
| `category` | `signature` / `watermark` / `camera-badge` | 只列这一组 |

返回 `{assets: [...], warnings}`，与 `photoframe asset list --json` 相同：名称、分组、格式、尺寸、字节数、sha256、导入时间。
**不含文件路径和文件内容**（§11.4）。MCP 不提供导入素材（那需要读任意文件），请在 GUI 或 CLI 里导入（D-103）。

### `validate_export` / `create_export_job`

两者参数相同：

| 参数 | 类型 | 说明 |
|---|---|---|
| `images` | string[]，必填，最多 64 | 源图，都在允许读取的目录内 |
| `presets` | string[]，必填，最多 64 | 预设引用；每张图 × 每个预设一个任务 |
| `outputDirectory` | string，必填 | 输出根目录，在允许写入的目录内；不存在时创建 |
| `overwrite` | bool，默认 false | 显式允许覆盖（D-49），见「覆盖」 |
| `assumeProfile` | `srgb` / `display-p3` / `adobe-rgb` | 没有 ICC 的源图按什么解释（D-75） |
| `bindings` | object | 单任务素材绑定 `{slotId: assetId 或素材名称}`（D-14 最高优先级） |

输出位置与 CLI 相同：`<outputDirectory>/<平台>/<源文件名>_<Standard|Panorama>[_vN]/00_Cover.jpg、01_Slide.jpg…`。

- `validate_export` 不渲染、不写任何文件（连目录都不建）。返回 `{valid, jobs: [...]}`，`jobs[]` 与 CLI `export --dry-run --json` 相同
  （`source`、`preset`、`directory`、`outputs[]`、`warnings[]`、`errors[]`）。工具本身成功时 `ok` 为 true，能否导出看 `valid`（D-104）。
- `create_export_job` 先做同样的校验，**有任何问题就什么都不写**（D-72），返回 `isError`、`valid: false` 和每个任务的 `errors`；
  通过后提交任务并立即返回 `{valid: true, jobs: [{jobId, status: "queued", …}]}`。

### `get_job_status`

| 参数 | 类型 | 说明 |
|---|---|---|
| `jobId` | string | 省略时列出本服务器创建的全部任务 |

返回 `{job: {...}}` 或 `{jobs: [...]}`。每个任务与 CLI `export --json` 的 `jobs[]` 相同（`jobId`、`source`、`preset`、`status`、`directory`、
`outputs[]`、`warnings[]`、`error`、`durationSeconds`），另有 `progress: {stage, completedOutputs, plannedOutputs?, bytesWritten}`——
只有真实阶段和已完成的输出数，不估算百分比（§9.1）。`status`：`queued`、`validating`、`decoding`、`rendering`、`encoding`、`writing`、
`completed`、`failed`、`canceled`。

### `cancel_export_job`

| 参数 | 类型 | 说明 |
|---|---|---|
| `jobId` | string，必填 | 本服务器创建的任务 |

等任务停下后返回 `{job: {...}}`（`status: "canceled"`）。已取消的再取消什么也不做；已完成或失败的报 `job.not_cancelable`；
别的进程的任务和不存在的任务一样报 `job.unknown`。

### `preview_export`

| 参数 | 类型 | 说明 |
|---|---|---|
| `image` | string，必填 | 源图 |
| `preset` | string，必填 | 预设引用 |
| `maxEdge` | int，默认 1200（`--max-preview-edge` 更小时取它） | 预览页长边，16…`--max-preview-edge`；不会大于导出尺寸 |
| `pages` | int[] | 只预览这些轮播页（0 = 封面，切片 k 为 k + 1，D-27），最多 12 页；默认前 12 页 |
| `dynamicRange` | string，默认 `sdr` | `hdr` 时，导出实际写 HDR 的页是带 gain map 的 JPEG（D-106），见下 |
| `outputDirectory` | string | 给了就写成文件（在允许写入的目录内）；省略时以图片内容直接返回（D-102） |
| `overwrite` | bool，默认 false | 替换已存在的同名预览文件；否则 `preview.file_exists`，什么都不写 |
| `assumeProfile`、`bindings` | | 同导出 |

与导出同一条渲染管线，按预览尺寸缩小，写成 sRGB PNG（不带元数据，D-74）。`dynamicRange: "hdr"` 时，导出实际写 HDR 的页改为带 gain map 的
JPEG（与 HDR 导出同一种编码，底图就是 SDR 预览，所以模型看到的是 SDR 版本）；其余页仍是 PNG；没有一页是 HDR 时警告 `preview.output_sdr` 并说明原因（预设输出 SDR，或预设跟随源图（`auto`，D-125）而源图不是 HDR、格式是 PNG）。
返回 `{source, preset, files: [...], positions, warnings}`：
`files[]` 是 `{role, position, width, height, exportWidth, exportHeight, dynamicRange, hdrHeadroom?, path?}`，写文件时有 `path`；
`positions` 是导出会写出的全部轮播位置。
直接返回时，每页一个 `image/png`（HDR 页 `image/jpeg`）内容块，总量不超过 8 MiB（超过时报 `mcp.limit_exceeded`，减小 `maxEdge`、`pages`，或改写文件，上限见 D-101）。

### 字段路径（D-93、D-99）

`get_preset`、`update_preset` 与 CLI `photoframe preset get` / `preset set` 用同一种写法，直接用 `manifest.json` 的字段名：

| 写法 | 含义 |
|---|---|
| `canvas.minMarginPx` | 对象字段（`.` 分隔） |
| `layers[0].opacity` | 数组下标，从 0 开始 |
| `layers[exif].text.fontSizePx` | 方括号里不是纯数字时，按 `layerId` / `slotId` 找元素 |
| `layers[+]` | 在数组末尾追加（只能用于设置，只能是最后一段） |

- 字段名：字母开头，之后是字母、数字、`_`、`-`（`x-` 扩展字段可以直接写）；路径最长 256 个字符。
- 设置不存在的字段即新增；拼错的字段名会被当作不认识的字段拒绝（与导入相同，D-26）。中间的对象必须已存在，否则先设置整个对象
  （例如先设 `canvas.crop` 为 `{"aspectRatio": [4, 5]}`）。
- 删除不存在的字段或元素报 `preset.path_not_found`，不会悄悄「成功」。
- 字段说明见资源 `photoframe://docs/preset-schema` 和规范 §8.1。

例：

```json
{"preset": "My IG", "edits": [
  {"path": "canvas.minMarginPx", "value": 80},
  {"path": "canvas.background.hex", "value": "#FFFFFF"},
  {"path": "layers[exif].text.template", "value": "{camera} · {lens} · {aperture}"},
  {"path": "layers[signature]", "remove": true}
]}
```

## 资源

| URI | 类型 | 内容 |
|---|---|---|
| `photoframe://access` | JSON | 允许读取 / 写入的目录（真实路径）和各项上限 |
| `photoframe://docs/preset-schema` | Markdown | 预设字段说明和字段路径写法 |
| `photoframe://platforms` | JSON | 平台能力表（画布、轮播上限、输出格式、HDR） |
| `photoframe://presets` | JSON | 与 `list_presets` 相同的只读摘要 |
| `photoframe://presets/{presetId}` | JSON | 一个预设的完整内容（模板；也接受名称和短名称） |

资源不暴露任何本地文件内容；`file://` 等其他 URI 一律报错。

## 安全边界（D-100、D-103）

| 规则 | 做法 | 错误码 |
|---|---|---|
| 未配置目录时拒绝 | 没有 `--allow-read` 就不读任何文件，没有 `--allow-write` 就不写任何文件 | `mcp.no_read_access`、`mcp.no_write_access` |
| 只接受绝对路径 | 相对路径、空路径、控制字符、`.` / `..` 段都拒绝（不做规范化后再接受） | `mcp.invalid_path` |
| 目录白名单 | 先按字面判断在不在白名单内，不在就**不碰文件系统**（不泄露文件是否存在）；再解析全部符号链接，真实路径也必须在白名单内。`/a/in-evil` 不算 `/a/in` 的子目录 | `mcp.path_not_allowed` |
| 符号链接逃逸 | 文件链接、目录链接、悬空链接都按真实路径判断（输入不存在时按最深的已存在上级目录判断，与存在时报同样的错）；输出目录中已存在的部分（包括平台子目录、要覆盖的作品目录、临时目录 `.photoframe-staging`）在写入前再查一次 | `mcp.path_not_allowed` |
| 硬链接 | 输入文件必须是普通文件且只有一个硬链接——另一个链接可能在白名单外，无法判断 | `mcp.hard_link_refused` |
| 覆盖 | 默认绝不覆盖（作品目录加 `_v2`…，预览文件拒绝）。只有工具参数 `overwrite: true` 才覆盖；覆盖只替换本软件之前发布的作品目录（D-49 的全部检查照常进行），而且目标同样必须在允许写入的目录内 | `export.overwrite_refused`、`preview.file_exists` |
| 资源上限 | 单文件大小、预览尺寸 / 页数 / 内联字节、未结束任务数、本次会话输出总量（见「配置」） | `mcp.file_too_large`、`mcp.limit_exceeded`、`mcp.queue_full`、`mcp.output_quota_exceeded` |
| 安全错误信息 | 返回给客户端的所有字符串（错误、警告、结果）都经过过滤：白名单以外的绝对路径换成 `<路径已隐藏>`。名字含空格时路径在哪里结束只能估计：白名单目录本身含空格、括号也整个保留；白名单以外的路径连同后面直到标点的词一起隐藏（宁可多藏） | |
| 不返回素材路径 | `list_assets` 只有元信息 | |
| 预设引用 | `preset` 参数只在预设库里按 ID / 名称查找，从不当作文件路径 | |
| 预设库写入 | `update_preset` 只改库里已有的非内置预设，改完必须通过导入检查；MCP 不提供导入预设、导入素材、删除等操作 | |
| 网络与凭据 | 不联网、不读取任何 token；启动参数里只有目录和数字，不需要凭据 | |
| 恶意输入 | 源图、SVG 素材、预设都按不可信输入处理（解码失败、ZIP 攻击等返回稳定错误码，§8.3、§12.2） | `render.*`、`archive.*`、`package.*` |

已知边界：

- 路径检查与实际读写之间存在时间差（TOCTOU）。如果有别的程序在这段时间里把白名单内的目录换成指向外面的符号链接，检查无法发现。
  威胁模型是「AI 客户端只能通过工具访问文件」，不防御本机上同时运行的恶意程序。
- `update_preset` 写的是本地库（D-78、D-124），不在 `--allow-write` 范围内；它只能修改预设内容，不能写任意文件。
- stdio 传输是本项目自己实现的（`MCPStdioTransport`：阻塞读写、不改文件描述符的模式；SDK 自带的会把 stdin / stdout 设成非阻塞并每 10 ms 轮询，
  空闲时也占 CPU），协议由 SDK 处理；客户端本身是用户启动的可信进程。

### 本地 MCP ≠ 云端 AI 的完全隐私保证（§11.4）

PhotoFrame 自己**不上传任何照片或数据**，MCP 服务器也只在本机运行。但工具的结果（例如 `inspect_image` 的 EXIF 摘要、
`preview_export` 直接返回的预览图、文件路径）会交给 AI 客户端；客户端是否把这些内容发给云端模型，由客户端和它所用模型服务的策略决定，
不在 PhotoFrame 的控制范围内。不想让预览图离开本机时，给 `preview_export` 传 `outputDirectory` 写成文件，而不是直接返回图片（D-102）。

## 错误码

除上表的 `mcp.*` 外，其余错误码与 CLI 相同（[docs/usage/CLI.md](CLI.md)「退出码」一节列出了全部错误码及其分类）。MCP 特有的：

| 错误码 | 含义 |
|---|---|
| `mcp.invalid_arguments` | 参数缺失、类型不对，或有 schema 以外的参数 |
| `mcp.invalid_root` | 启动参数里的目录不存在、不是目录、是相对路径或 `/`（启动失败，退出码 2） |
| `mcp.shutting_down` | 服务器正在退出（stdin 已结束或收到 SIGINT / SIGTERM），不再创建导出任务 |
| `preset.invalid_path`、`preset.path_not_found`、`preset.field_read_only`、`preset.invalid_edit` | 字段路径（D-93，CLI 同样使用） |

未知工具名是协议错误（JSON-RPC `-32602`），不是工具结果。

## 测试

```bash
cd Tools/photoframe
swift test --scratch-path "$TMPDIR/photoframe-build" --filter "MCP|Preset"
```

- `MCPToolTests`：进程内 MCP 客户端（SDK 的内存传输）调用每个工具的正常和错误路径，以及资源。
- `MCPSecurityTests`：白名单、未配置目录、相对路径与 `..`、符号链接（文件、目录、悬空、平台子目录、临时目录）、硬链接、覆盖授权、各项上限、
  错误信息过滤（包括目录名、文件名含空格和括号）。
- `MCPProcessTests`：子进程启动 `photoframe mcp serve`，通过真实 stdio 完成 initialize → tools/list → list_presets → create_export_job →
  get_job_status → 文件落盘，检查 stdout 只有协议消息、关闭 stdin 后正常退出。`MCPStdioTests`：空闲时不占 CPU、不把 stdin / stdout
  改成非阻塞；客户端不再读输出时不被 SIGPIPE 杀掉。
- 测试图片全部用代码合成，写在系统临时目录里；测试的本地库也在临时目录里，不碰真实的 App Group 库。

## 相关决策

| 编号 | 内容 |
|---|---|
| D-13 | 各入口独立运行；MCP 管理自己进程内的异步任务，进程退出时取消 |
| D-49 | 覆盖只替换本软件发布的作品目录；MCP 必须显式传 `overwrite: true` |
| D-70 | MCP 直接用 PhotoFrameApplication 的服务 |
| D-72 | 先校验全部任务，有问题就什么都不写 |
| D-74 | 预览写成 sRGB PNG（MCP 也可以直接返回图片） |
| D-77 | 值为空的字段省略 |
| D-93 | 逐项修改预设：CLI 与 MCP 共用字段路径 |
| D-97 | 官方 Swift MCP SDK 0.12.1，精确固定版本 |
| D-98 | 入口是 CLI 子命令 `photoframe mcp serve`，不单独做 `photoframe-mcp` |
| D-99 | 字段路径写法（manifest 字段名、`[n]` / `[id]` / `[+]`）；CLI 值先按 JSON 解析，否则当字符串；先应用设置再应用 `--unset` |
| D-100 | 安全规则：目录白名单、未配置时拒绝、只收绝对路径、拒绝 `.` / `..`、按真实路径防符号链接逃逸、拒绝多硬链接输入、显式覆盖、路径过滤 |
| D-101 | 默认上限：单文件 2 GiB、预览长边 2048、每次 12 页、内联 8 MiB、未结束任务 16 个、会话输出 20 GiB（软上限） |
| D-102 | `preview_export` 默认直接返回图片，传 `outputDirectory` 时写文件 |
| D-103 | MCP 不提供预设导入、素材导入和删除；`update_preset` 只改库里已有的非内置预设 |
| D-104 | 结果只有 `ok` + `error` 外层，不带 CLI 的 `formatVersion` / `command` / `exitCode`；`validate_export` 用 `valid` 表示能否导出 |
| D-106 | `preview_export` 的 `dynamicRange: "hdr"`：HDR 页返回 gain map JPEG |
| D-124 | 本地库位置规则，与 GUI、CLI 相同（见 CLI.md「本地库」） |
| D-125 | 预设 `output.dynamicRange` 增加 `auto`（跟随源图）；`preview_export` 的 `dynamicRange` 仍只有 `sdr` / `hdr` |
