# 命令行工具 `photoframe`

> 对应规范 §10.3、§11.1–11.3、§12.2、§14.1（D-08：GUI 的每项操作都能通过 CLI 完成）。
> 代码在 `Tools/photoframe`：命令在 `PhotoFrameCLI` 库里，可执行文件只处理信号与退出码。
> 后端是 `Packages/PhotoFrameEngine` 组装的 `PhotoFrameService`，GUI 和以后的 MCP 用的是同一个服务。

## 构建

```bash
cd Tools/photoframe
swift build -c release
.build/release/photoframe --help
```

仓库在 iCloud 同步目录下时加 `--scratch-path "$TMPDIR/photoframe-build"`（原因见根 README）。

## 约定

- **stdout 只输出数据**：默认每行一个文件路径；加 `--json` 时是一个完整的 JSON 文档。进度、警告、错误都写到 stderr。
- **阻塞到结束**：`export` 一直等到所有任务结束才退出（§10.3）。
- **路径**：相对路径按当前目录解析，支持 `~`。
- **原图只读**：任何命令都不会写、移动或覆盖源图（§12.2）。
- **不加 `--overwrite` 就不覆盖**：已存在的作品目录自动加 `_v2`、`_v3`…（D-49）。
- **Ctrl-C**：取消所有未完成的任务，删除它们的临时目录，以 130 退出；已经发布的作品目录保持完整。
  再按一次 Ctrl-C 立即退出，残留的临时目录在下次导出到同一目录时清理（D-55）。

## 命令

```text
photoframe export <图片...> --preset <id|名称|文件> [--preset ...] --output <目录>
                  [--overwrite] [--dry-run] [--json] [--quiet] [--jobs <n>]
photoframe preview <图片> --preset <id|名称|文件> --output <目录>
                  [--max-edge <px>] [--page <n> ...] [--overwrite] [--json]
photoframe image inspect <图片> [--json]
photoframe preset list [--json]
photoframe --help | --version
```

`preset import` / `preset export`（等用户预设库）和 `mcp serve`（做 MCP 时）还没有实现，帮助里也不列出。

### 指定预设：`--preset <id|名称|文件>`

| 写法 | 例子 | 规则 |
|---|---|---|
| 文件 | `./Minimal.photoframe`、`~/presets/x.photoframe` | 以 `.photoframe` 结尾或含 `/` 的参数。只读取、不安装；导入检查与预设库相同（ZIP 上限、不认识的字段等） |
| presetId | `53EABC50-58DB-4F46-BC2E-A5A334C0B7E8` | 能解析成 UUID 的参数 |
| 名称 | `instagram-panorama`、`"XHS Standard"` | 其余参数。不区分大小写，空格、下划线、连字符等价；`preset list` 第一列就是可以直接用的短名称 |

现阶段可用的预设是 6 个内置预设（D-31、D-32）加上命令行直接给出的文件。

### `export`

每张图 × 每个预设生成一个任务（§3.1），输出到：

```text
<输出目录>/<平台>/<源文件名>_<Standard|Panorama>[_vN]/00_Cover.jpg
                                                    01_Slide.jpg …
```

平台目录是 `Instagram` / `Xiaohongshu` / `Douyin`，没有平台的预设是 `Custom`（D-46–D-48）。单图也叫 `00_Cover.jpg`。

| 选项 | 说明 |
|---|---|
| `--preset` | 可重复；重复的预设只算一次 |
| `-o, --output` | 输出根目录，不存在时创建 |
| `--overwrite` | 作品目录已存在时替换，而不是加版本后缀。只替换本软件之前导出的目录（目录上有扩展属性 `org.anotherphotoframe.published`，里面只有本软件命名的图片）；否则拒绝，退出码 5（D-49） |
| `--dry-run` | 只校验并列出将写出的文件，不渲染、不写任何文件（连输出目录都不创建） |
| `--json` | stdout 输出 JSON |
| `-q, --quiet` | 不在 stderr 显示进度 |
| `--jobs <n>` | 同时执行的任务数，默认性能核数的一半（1–4，D-53） |

执行顺序：解析全部预设 → 登记全部源图 → **校验全部任务** → 提交 → 等待。校验阶段发现任何问题（源图读不了、预设无效、缺必需素材、
输出目录不可写、拒绝覆盖、`--overwrite` 时两个任务指向同一目录……）就什么都不写，直接退出。
校验通过后某个任务渲染或发布失败时，其余任务照常完成，退出码 6。

`--dry-run` 推算的目录名（版本后缀）按当时的磁盘状态计算；真正导出时如果别的程序同时写入，可能不同。

stderr 进度只有真实阶段和已完成的输出数，不估算百分比（§9.1）：

```text
[1/2] Badlands.tif × Instagram Panorama: validating
[1/2] Badlands.tif × Instagram Panorama: decoding
[1/2] Badlands.tif × Instagram Panorama: rendering
[1/2] Badlands.tif × Instagram Panorama: encoding
[1/2] Badlands.tif × Instagram Panorama: encoding 1/5
…
[1/2] Badlands.tif × Instagram Panorama: writing
[1/2] Badlands.tif × Instagram Panorama: completed → /…/Instagram/Badlands_Panorama
```

### `preview`

与 GUI 预览区相同的预览：同一条渲染管线，按预览尺寸缩小，写成 sRGB PNG。用于脚本或 AI 客户端查看版式；不是成品（不带 HDR、不带元数据）。

文件名 `<源文件名>_<Standard|Panorama>_preview_00_Cover.png`、`…_01_Slide.png`。任何一个目标文件已存在就什么都不写、退出码 5；`--overwrite` 时替换。

| 选项 | 说明 |
|---|---|
| `--max-edge <px>` | 预览页长边上限，默认 1200，不会大于导出尺寸 |
| `--page <n>` | 只预览这些轮播页（0 = 封面，切片 k 是 k + 1，D-27）。可重复；默认全部 |

### `image inspect`

读取源图的格式、尺寸、EXIF 方向、位深、ICC（是否真的嵌入、按什么解释）、HDR 判定（D-62）和图层文字可用的 EXIF 值。
**GPS、作者和版权只报告有无，不输出内容**（§12.3）。没有 ICC 时按 sRGB 解释并给出 `source.profile_missing` 警告（D-04）。

### `preset list`

列出内置预设。文本格式每行：短名称、名称、平台、画布、`standard`/`panorama`、presetId。

## 退出码

| 退出码 | 含义 | 典型错误码 |
|---|---|---|
| 0 | 成功（`--dry-run` 时表示校验通过） | |
| 1 | 内部错误，不应发生，请报告问题 | `service.unavailable`、`cli.internal` |
| 2 | 用法错误：参数缺失、未知选项或命令、取值不对 | （ArgumentParser 的信息，只写 stderr） |
| 3 | 找不到输入 | `source.not_found`、`preset.not_found`、`preset.file_not_found` |
| 4 | 输入无效 | `source.unsupported_format`、`render.unsupported_format`、`render.decode_failed`、`job.source_unreadable`、`job.invalid_preset`、`preset.ambiguous`、`slot.missing_required`、`archive.*`、`package.*`、`preset.*` 等其余错误码 |
| 5 | 输出不可用 | `job.destination_unavailable`、`job.destination_invalid`、`export.overwrite_refused`、`export.overwrite_contains_source`、`export.versions_exhausted`、`export.staging_failed`、`export.publish_failed`、`request.duplicate_output`、`preview.file_exists`、`preview.write_failed` |
| 6 | 校验通过后至少一个导出任务失败（其余任务照常完成） | 任务记录里的错误码，如 `render.*`、`export.*` |
| 130 | 被 Ctrl-C（SIGINT）或 SIGTERM 中断 | |

退出码由错误码决定（`PhotoFrameExitCode(for:)`）；错误码本身同样稳定，脚本需要更细的区分时看 JSON 里的 `error.code`。

## JSON 格式

所有 `--json` 输出都是一个对象，外层字段固定：

| 字段 | 类型 | 说明 |
|---|---|---|
| `formatVersion` | int | 当前为 1。字段只增不改；不兼容的改动会递增 |
| `command` | string | `export`、`preview`、`image inspect`、`preset list` |
| `ok` | bool | 退出码为 0 时为 true |
| `exitCode` | int | 与进程退出码相同 |
| `error` | object? | `{code, message, hint?}`：导致命令失败的错误；`export` 部分失败时是第一个失败任务的错误 |

命令在拿到结果之前就失败（找不到文件、预设无效……）时只有外层字段：

```json
{
  "command" : "export",
  "error" : { "code" : "preset.not_found", "hint" : "用 `photoframe preset list` 查看可用的预设，或给出 .photoframe 文件路径", "message" : "找不到预设：tiktok" },
  "exitCode" : 3,
  "formatVersion" : 1,
  "ok" : false
}
```

用法错误（退出码 2）不输出 JSON。

### `export`

```json
{
  "command" : "export",
  "dryRun" : false,
  "exitCode" : 0,
  "formatVersion" : 1,
  "jobs" : [
    {
      "directory" : "/Users/me/Exports/Douyin/Badlands_Standard",
      "durationSeconds" : 0.412,
      "jobId" : "5C0F…",
      "outputs" : [
        {
          "bytes" : 412345,
          "colorProfile" : "sRGB IEC61966-2.1",
          "fileName" : "00_Cover.jpg",
          "height" : 1920,
          "path" : "/Users/me/Exports/Douyin/Badlands_Standard/00_Cover.jpg",
          "position" : 0,
          "role" : "cover",
          "width" : 1080
        }
      ],
      "preset" : { "name" : "Douyin Standard", "presetId" : "015CD1C9-90AF-4D3A-82B3-DD49BEDD3112" },
      "source" : "/Users/me/Photos/Badlands.jpg",
      "status" : "completed",
      "warnings" : [ ]
    }
  ],
  "ok" : true
}
```

- `jobs[].status`：`completed`、`failed`、`canceled`；失败时有 `error`，没有 `directory`、`durationSeconds`，`outputs` 为空。
- 值为空的可选字段不出现（而不是写 `null`），例如没有提示的错误没有 `hint`。
- `outputs[].role`：`cover` 或 `slide`；`position` 是轮播位置（0 = 封面，切片 k 为 k + 1，D-27）。
- `outputs[].sha256`：目前不计算，字段不出现（D-54）。
- `warnings[]`：`{code, message}`，例如 `source.profile_missing`、`panorama.not_wide_enough`、`export.replaced_previous`。

`--dry-run`（以及校验未通过时）：

```json
{
  "command" : "export",
  "dryRun" : true,
  "exitCode" : 0,
  "formatVersion" : 1,
  "jobs" : [
    {
      "directory" : "/Users/me/Exports/Xiaohongshu/Badlands_Panorama",
      "errors" : [ ],
      "outputs" : [
        { "fileName" : "00_Cover.jpg", "height" : 1080, "position" : 0, "role" : "cover", "width" : 1080 },
        { "fileName" : "01_Slide.jpg", "height" : 1080, "position" : 1, "role" : "slide", "width" : 1080 }
      ],
      "preset" : { "name" : "XHS Panorama", "presetId" : "16AE8FDA-85CA-4BBC-B4C2-9C1A47324EA1" },
      "source" : "/Users/me/Photos/Badlands.jpg",
      "warnings" : [ ]
    }
  ],
  "ok" : true,
  "valid" : true
}
```

校验未通过但不是 `--dry-run` 时格式相同，`dryRun` 为 false、`valid` 为 false，每个任务的问题在 `errors[]` 里。

### `preview`

```json
{
  "command" : "preview",
  "exitCode" : 0,
  "files" : [
    { "exportHeight" : 1440, "exportWidth" : 1080, "height" : 400, "path" : "/…/Badlands_Panorama_preview_00_Cover.png", "position" : 0, "role" : "cover", "width" : 300 }
  ],
  "formatVersion" : 1,
  "ok" : true,
  "positions" : [ 0, 1, 2 ],
  "preset" : { "name" : "Instagram Panorama", "presetId" : "53EABC50-58DB-4F46-BC2E-A5A334C0B7E8" },
  "source" : "/…/Badlands.jpg",
  "warnings" : [ ]
}
```

`positions` 是导出会写出的全部轮播位置；`files` 只有请求的页。

### `image inspect`

```json
{
  "command" : "image inspect",
  "exitCode" : 0,
  "formatVersion" : 1,
  "image" : {
    "bitDepth" : 16,
    "colorProfile" : { "description" : "Adobe RGB (1998)", "embedded" : true, "origin" : "embedded" },
    "displaySize" : { "height" : 400, "width" : 640 },
    "fileSizeBytes" : 1536512,
    "format" : "tiff",
    "hasAlpha" : false,
    "hasAuthorOrCopyright" : false,
    "hasGPS" : false,
    "hdr" : { "kind" : "none" },
    "isFloat" : false,
    "metadata" : { "aperture" : "f/8", "camera" : "NIKON Z 8" },
    "orientation" : 1,
    "path" : "/…/Scan.tif",
    "pixelSize" : { "height" : 400, "width" : 640 },
    "warnings" : [ ]
  },
  "ok" : true
}
```

- `colorProfile.origin`：`embedded`、`assumedSRGB`（没有 ICC，D-04）、`override`。
- `hdr.kind`：`none`、`gainMap`、`gainMapTIFF`、`transferFunction`（PQ / HLG）、`floatLinear`（D-62）；HDR 时有 `headroom`。
  PQ / HLG / 浮点源的 headroom 是在小尺寸解码上测得的估计值。
- `metadata`：图层文字模板可用的值，键见 `docs/RenderingPipeline.md`（`camera`、`make`、`model`、`lens`、`focalLength`、`focalLength35`、`aperture`、`shutter`、`iso`、`date`）。

### `preset list`

```json
{
  "command" : "preset list",
  "exitCode" : 0,
  "formatVersion" : 1,
  "ok" : true,
  "presets" : [
    {
      "background" : "#FAFAF8",
      "canvas" : { "height" : 1080, "width" : 1080 },
      "dynamicRange" : "sdr",
      "format" : "jpeg",
      "layerCount" : 0,
      "minMarginPx" : 60,
      "mode" : "fit",
      "name" : "XHS Panorama",
      "origin" : "builtIn",
      "panorama" : { "cover" : true, "verticalMarginPx" : 0 },
      "platform" : "xiaohongshu",
      "platformName" : "小红书",
      "presetId" : "16AE8FDA-85CA-4BBC-B4C2-9C1A47324EA1",
      "quality" : 100,
      "slotIds" : [ ],
      "slug" : "xhs-panorama"
    }
  ]
}
```

`panorama` 只在全景预设上出现；`panorama.slideCount` 只在固定张数时出现（自动张数时没有这个字段，D-11）。`origin`：`builtIn`、`file`、`library`。

## 测试

```bash
cd Tools/photoframe
swift test --scratch-path "$TMPDIR/photoframe-build"
```

测试只用代码合成的图片，写在系统临时目录里：参数解析与退出码、各命令的 JSON 输出、从命令行一路导出到真实文件（校验尺寸、
sRGB ICC、文件名、没有残留临时目录）、`--overwrite` 与版本后缀、Ctrl-C 取消，以及以子进程运行可执行文件（stdout / stderr 分离、
SIGINT）。子进程测试需要 `swift test` 构建出的 `photoframe`，也可以用环境变量 `PHOTOFRAME_EXECUTABLE` 指定。
