# 命令行工具 `photoframe`

> 对应规范 §10.3、§11.1–11.3、§12.2、§14.1（D-08：GUI 的每项操作都能通过 CLI 完成）。
> 代码在 `Tools/photoframe`：命令在 `PhotoFrameCLI` 库里，可执行文件只处理信号与退出码。
> 后端是 `LocalPhotoFrameService.makeDefault()`（`Packages/PhotoFrameApplication`，D-70），GUI 和以后的 MCP 用的是同一个服务。
> 本文涉及的决策：D-70～D-77、D-93～D-96（规范 §16），列表见文末「相关决策」。

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
- **本地库**：预设库、素材库和绑定在 App Group 共享容器里（D-78），GUI、CLI、MCP 用同一个库：
  `~/Library/Group Containers/group.org.anotherphotoframe/Library/Application Support/AnotherPhotoFrame/`
  （App Group ID 是占位值，签名时确定）。环境变量 `PHOTOFRAME_LIBRARY=<目录>` 改用别的库（脚本隔离、测试）。
  只有环境变量，没有命令行参数（D-96）。

## 命令

```text
photoframe export <图片...> --preset <id|名称|文件> [--preset ...] --output <目录>
                  [--assume-profile srgb|display-p3|adobe-rgb]
                  [--overwrite] [--dry-run] [--json] [--quiet] [--jobs <n>]
photoframe preview <图片> --preset <id|名称|文件> --output <目录>
                  [--assume-profile srgb|display-p3|adobe-rgb]
                  [--max-edge <px>] [--page <n> ...] [--overwrite] [--json]
photoframe image inspect <图片> [--json]

photoframe preset list [--json]
photoframe preset import <文件> [--replace] [--json]
photoframe preset export <预设> --output <文件|目录> [--overwrite] [--json]
photoframe preset duplicate <预设> [--name <名称>] [--json]
photoframe preset rename <预设> <新名称> [--json]
photoframe preset move <预设> --to user|imported [--json]
photoframe preset delete <预设> [--json]

photoframe asset list [--category signature|watermark|camera-badge] [--json]
photoframe asset import <文件> --category signature|watermark|camera-badge [--name <名称>] [--json]
photoframe asset rename <素材> <新名称> [--json]
photoframe asset set-category <素材> signature|watermark|camera-badge [--json]
photoframe asset delete <素材> [--json]
photoframe asset bind <素材> --slot <slotId> [--preset <预设>]
photoframe asset unbind --slot <slotId> [--preset <预设>]
photoframe asset bindings [--json]

photoframe --help | --version
```

`export` 和 `preview` 还接受 `--bind <slotId>=<素材>`（可重复），见「素材绑定」。

`mcp serve`（做 MCP 时）还没有实现，帮助里也不列出。预设的内容编辑（画布、图层等）是 GUI 的 Inspector 操作，逐项编辑的命令
和 MCP 一起设计（D-93）；现在可以用「导出 → 编辑 manifest → 导入 `--replace`」完成，见「待补」。

### 指定预设：`--preset <id|名称|文件>`（D-76）

| 写法 | 例子 | 规则 |
|---|---|---|
| 文件 | `./Minimal.photoframe`、`~/presets/x.photoframe` | 以 `.photoframe` 结尾或含 `/` 的参数。只读取、不放进预设库；导入检查与预设库相同（ZIP 上限、不认识的字段等）。只用于 `export` / `preview` |
| presetId | `53EABC50-58DB-4F46-BC2E-A5A334C0B7E8` | 能解析成 UUID 的参数 |
| 名称 | `"XHS Standard"` | 完整名称，不区分大小写 |
| 短名称 | `instagram-panorama` | 名称转小写、字母数字以外的连续字符换成 `-`；`preset list` 第一列就是它 |

除文件外都由预设库匹配（`PresetLibrary.find`，D-76）：内置、用户保存、导入三组一起找；匹配到多个报 `library.ambiguous_preset`，改用 presetId。

### 素材绑定

图层引用素材槽（slot），素材槽解析到素材库里的素材，优先级（D-14）：

1. **单任务**：`export` / `preview` 的 `--bind <slotId>=<素材>`，只对这次命令生效；
2. **预设本地**：`asset bind <素材> --slot <slotId> --preset <预设>`，保存在本机，不随预设导出；
3. **用户默认**：`asset bind <素材> --slot <slotId>`，按 slotId 对所有预设生效（D-90）。

素材引用是 assetId，或显示名称（不区分大小写，必须唯一）。绑定指向的素材已删除或格式不被接受时警告并回退到下一级（D-28）；
必需素材都找不到时校验失败（`slot.missing_required`，退出码 4），没有被启用图层用到的必需槽不影响（D-29）。

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
| `--assume-profile` | 没有 ICC 的源图按什么色彩空间解释：`srgb`、`display-p3`、`adobe-rgb`。见下文「输入色彩空间」 |
| `--bind <slotId>=<素材>` | 单任务素材绑定，可重复。见「素材绑定」 |
| `--overwrite` | 作品目录已存在时替换，而不是加版本后缀。只替换本软件之前导出的目录（目录上有扩展属性 `org.anotherphotoframe.published`，里面只有本软件命名的图片）；否则拒绝，退出码 5（D-49） |
| `--dry-run` | 只校验并列出将写出的文件，不渲染、不写任何文件（连输出目录都不创建） |
| `--json` | stdout 输出 JSON |
| `-q, --quiet` | 不在 stderr 显示进度 |
| `--jobs <n>` | 同时执行的任务数，默认性能核数的一半（1–4，D-53） |

执行顺序：解析全部预设 → 登记全部源图 → **校验全部任务** → 提交 → 等待。校验阶段发现任何问题（源图读不了、预设无效、缺必需素材、
输出目录不可写、拒绝覆盖、`--overwrite` 时两个任务指向同一目录……）就什么都不写，直接退出（D-72）。`--overwrite` 时同一请求里两个任务指向同一个作品目录（例如两张同名源图）在校验时报
`request.duplicate_output`（D-73）。校验通过后某个任务渲染或发布失败时，其余任务照常完成，退出码 6（D-72）。

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

### `preview`（D-74）

与 GUI 预览区相同的预览：同一条渲染管线，按预览尺寸缩小，写成 sRGB PNG。用于脚本或 AI 客户端查看版式；不是成品（不带 HDR、不带元数据）。

文件名 `<源文件名>_<Standard|Panorama>_preview_00_Cover.png`、`…_01_Slide.png`。任何一个目标文件已存在就什么都不写、退出码 5；`--overwrite` 时替换。

| 选项 | 说明 |
|---|---|
| `--assume-profile`、`--bind` | 同 `export` |
| `--max-edge <px>` | 预览页长边上限，默认 1200，不会大于导出尺寸 |
| `--page <n>` | 只预览这些轮播页（0 = 封面，切片 k 是 k + 1，D-27）。可重复；默认全部 |

### 输入色彩空间：`--assume-profile`（D-75）

D-04、§6.2「无 ICC 策略」：源图没有颜色描述时默认按 sRGB 解释，并警告 `source.profile_missing`；用户可以按任务指定另一个色彩空间
（例如丢了 ICC 的 Display P3 扫描图）。

- 只对**没有 ICC** 的源图生效。源图自带 ICC 时以文件为准，忽略这个选项，并警告 `source.override_ignored`（一次导出多张图时，
  有 ICC 的那几张照常按自己的 ICC 处理）。
- 作用于本次命令的所有任务，记录在任务里（`JobSpec.sourceColorOverride`），重试也沿用。
- 用 `image inspect` 先看 `colorProfile.origin`：`assumedSRGB` 表示没有 ICC。

### `image inspect`

读取源图的格式、尺寸、EXIF 方向、位深、ICC（是否真的嵌入、按什么解释）、HDR 判定（D-62）和图层文字可用的 EXIF 值。
**GPS、作者和版权只报告有无，不输出内容**（§12.3）。没有 ICC 时按 sRGB 解释并给出 `source.profile_missing` 警告（D-04）。

### `preset …`：预设库

| 命令 | 说明 | stdout（文本） |
|---|---|---|
| `preset list` | 列出内置、用户保存、导入三组（D-81、D-82 的顺序）。读库时跳过的损坏文件等作为警告写到 stderr | 每行：短名称、名称、来源（`builtIn`/`user`/`imported`）、平台、画布、`standard`/`panorama`、presetId |
| `preset import <文件>` | 把 `.photoframe` 导入「导入」组。presetId 与已有预设相同时默认**另存为副本**（新 ID，名称加 ` Copy`，D-39、D-80），`--replace` 时替换同 ID 的预设（内置预设不能替换） | `presetId  名称` |
| `preset export <预设> -o <文件或目录>` | 导出为 `.photoframe`：只含布局，素材只以 slot 出现，拒绝带本地路径的预设（D-37）。内置预设也能导出。`-o` 是已存在的目录时文件名取预设名称；目标文件已存在时要 `--overwrite`（否则 `preset.export_exists`，退出码 5） | 写出的文件路径 |
| `preset duplicate <预设> [--name]` | 复制到「用户保存」组，默认名称「原名 Copy」（D-79），本地绑定一起复制（D-84）。内置预设也能复制 | `presetId  名称` |
| `preset rename <预设> <新名称>` | 内置预设不能改（`library.builtin_read_only`，退出码 4） | `presetId  名称` |
| `preset move <预设> --to user\|imported` | 在「用户保存」和「导入」两组之间移动（D-81、D-94），内容、ID 和时间不变；已经在目标组时什么也不做。内置预设不能移动（`library.builtin_read_only`，退出码 4）；`.photoframe` 文件不在库里（`library.preset_not_in_library`，退出码 4） | `presetId  名称` |
| `preset delete <预设>` | 删除库里的预设和它的本地绑定；内置预设不能删 | `presetId  名称` |

### `asset …`：素材库与绑定

| 命令 | 说明 | stdout（文本） |
|---|---|---|
| `asset list [--category]` | 列出素材，**不输出文件路径**（§11.4） | 每行：assetId、名称、分组、格式、尺寸 |
| `asset import <文件> --category <分组>` | 校验后复制进库：只接受 PNG 和受限 SVG（D-09），按内容校验，上限见 D-85，动画 PNG 拒绝（D-86）。分组只用于整理，不限制能绑定到哪个槽（D-89）。内容与已有素材相同时仍然导入，在 stderr 提示（D-88） | 新素材的 assetId |
| `asset rename <素材> <新名称>` | | `assetId  名称` |
| `asset set-category <素材> <分组>` | 改分组（D-95）。分组只用于整理，不影响能绑定到哪个槽，也不改动已有绑定（D-89） | `assetId  名称  分组` |
| `asset delete <素材>` | 删除素材；指向它的绑定**保留**（D-83），导出时按 D-28 警告并回退。这些绑定以 `binding.asset_deleted` 警告写到 stderr | assetId |
| `asset bind <素材> --slot <slotId> [--preset <预设>]` | 有 `--preset`：预设本地绑定（检查预设里有这个槽、格式被接受）；没有：用户默认绑定 | （无） |
| `asset unbind --slot <slotId> [--preset <预设>]` | 清除对应的绑定 | （无） |
| `asset bindings` | 列出保存的绑定 | 每行：`preset`/`default`、presetId（默认绑定为 `-`）、slotId、assetId |

分组的命令行写法：`signature`、`watermark`、`camera-badge`。

## 退出码（D-71）

| 退出码 | 含义 | 典型错误码 |
|---|---|---|
| 0 | 成功（`--dry-run` 时表示校验通过） | |
| 1 | 内部错误，不应发生，请报告问题 | `service.unavailable`、`cli.internal` |
| 2 | 用法错误：参数缺失、未知选项或命令、取值不对 | （ArgumentParser 的信息，只写 stderr） |
| 3 | 找不到输入 | `source.not_found`、`preset.file_not_found`、`library.preset_not_found`、`asset.not_found`、`asset.file_not_found` |
| 4 | 输入无效 | `source.unsupported_format`、`render.unsupported_format`、`render.decode_failed`、`render.svg_rejected`、`job.source_unreadable`、`job.invalid_preset`、`slot.missing_required`、`library.ambiguous_preset`、`library.builtin_read_only`、`library.invalid_name`、`library.preset_not_in_library`、`asset.ambiguous`、`asset.svg_rejected`、`asset.type_mismatch`、`asset.too_large`、`binding.*`、`archive.*`、`package.*`、`preset.*` 等其余错误码 |
| 5 | 输出不可用 | `job.destination_unavailable`、`job.destination_invalid`、`export.overwrite_refused`、`export.overwrite_contains_source`、`export.versions_exhausted`、`export.staging_failed`、`export.publish_failed`、`request.duplicate_output`、`preview.file_exists`、`preview.write_failed`、`preset.export_exists`、`library.io` |
| 6 | 校验通过后至少一个导出任务失败（其余任务照常完成） | 任务记录里的错误码，如 `render.*`、`export.*` |
| 130 | 被 Ctrl-C（SIGINT）或 SIGTERM 中断 | |

退出码由错误码决定（`PhotoFrameExitCode(for:)`）；错误码本身同样稳定，脚本需要更细的区分时看 JSON 里的 `error.code`。

## JSON 格式（D-77：值为空的可选字段省略）

所有 `--json` 输出都是一个对象，外层字段固定：

| 字段 | 类型 | 说明 |
|---|---|---|
| `formatVersion` | int | 当前为 1。字段只增不改；不兼容的改动会递增 |
| `command` | string | 命令名，例如 `export`、`preview`、`image inspect`、`preset list`、`preset import`、`asset list` |
| `ok` | bool | 退出码为 0 时为 true |
| `exitCode` | int | 与进程退出码相同 |
| `error` | object? | `{code, message, hint?}`：导致命令失败的错误；`export` 部分失败时是第一个失败任务的错误 |

命令在拿到结果之前就失败（找不到文件、预设无效……）时只有外层字段：

```json
{
  "command" : "export",
  "error" : { "code" : "library.preset_not_found", "message" : "找不到预设「tiktok」" },
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
      "readOnly" : true,
      "slotIds" : [ ],
      "slug" : "xhs-panorama"
    }
  ],
  "warnings" : [ ]
}
```

`panorama` 只在全景预设上出现；`panorama.slideCount` 只在固定张数时出现（自动张数时没有这个字段，D-11）。
`origin`：`builtIn`、`user`、`imported`、`file`（本次命令直接读的文件）。`readOnly`：内置预设和文件为 true。

### `preset import` / `duplicate` / `rename` / `move`

```json
{ "command" : "preset import", "conflictResolution" : "saveAsCopy", "exitCode" : 0, "formatVersion" : 1, "ok" : true,
  "preset" : { …与 preset list 的一项相同… }, "warnings" : [ ] }
```

`conflictResolution` 只在 `preset import` 且 presetId 冲突时出现：`saveAsCopy` 或 `replace`。

### `preset export` / `delete`

```json
{ "command" : "preset export", "exitCode" : 0, "formatVersion" : 1, "ok" : true,
  "path" : "/Users/me/Signed Portrait.photoframe", "preset" : { "name" : "Signed Portrait", "presetId" : "…" } }
```

`preset delete` 没有 `path`。

### `asset list` / `import` / `rename` / `set-category`

```json
{
  "assets" : [
    {
      "assetId" : "…", "bytes" : 1234, "category" : "signature", "format" : "png", "height" : 40, "width" : 120,
      "importWarnings" : [ ], "importedAt" : "2026-10-16T09:00:00Z", "name" : "My Signature", "sha256" : "…"
    }
  ],
  "command" : "asset list", "exitCode" : 0, "formatVersion" : 1, "ok" : true, "warnings" : [ ]
}
```

`asset import` / `rename` / `set-category` 输出 `{"asset": {…}}`；`asset import` 另有 `duplicateOf`（内容相同的已有素材的 assetId）和 `warnings`。
素材的 JSON 不含文件路径。

### `asset delete` / `bindings`

```json
{ "assetId" : "…", "bindings" : [ { "assetId" : "…", "presetId" : "…", "scope" : "preset", "slotId" : "signature" } ],
  "command" : "asset delete", "exitCode" : 0, "formatVersion" : 1, "ok" : true }
```

`bindings[].scope`：`preset`（预设本地，有 `presetId`）或 `default`（用户默认）。`asset delete` 的 `bindings` 是仍指向被删素材的绑定；
`asset bindings` 输出全部保存的绑定和 `warnings`。

## 待补

- **预设内容编辑（D-93）**：GUI 的 Inspector 能改画布、图层、输出设置等；命令行没有逐项修改的命令，和 MCP 一起设计。
  现在可以「`preset export` → 编辑 `manifest.json` → `preset import --replace`」。
- `mcp serve`：做 MCP 时再加。

## 相关决策

| 编号 | 内容 |
|---|---|
| D-70 | 不单独建组装包：渲染适配器和 `makeDefault()` 在 PhotoFrameApplication 里，Application 依赖 Rendering；保留 `JobRenderer` 协议给测试用 |
| D-71 | 退出码表：0 / 1 / 2 / 3 / 4 / 5 / 6 / 130（见「退出码」） |
| D-72 | `export` 先校验全部任务，有问题就什么都不写；校验通过后个别任务失败时其余照常完成，退出码 6 |
| D-73 | `--overwrite` 时同一请求两个任务指向同一作品目录，校验时报 `request.duplicate_output` |
| D-74 | 保留 `preview` 命令（预览 PNG） |
| D-75 | `--assume-profile`：只对没有 ICC 的源图生效，有 ICC 时忽略并警告 `source.override_ignored`（D-04） |
| D-76 | `--preset` 匹配：文件路径，否则由 `PresetLibrary.find` 按 presetId、完整名称、短名称匹配 |
| D-77 | JSON 里值为空的可选字段省略，不写 `null` |
| D-93 | 预设内容逐项编辑的命令和 MCP 一起设计 |
| D-94 | `preset move <预设> --to user\|imported`；内置预设不能移动（`library.builtin_read_only`） |
| D-95 | `asset set-category <素材> <分组>` |
| D-96 | 库目录只用环境变量 `PHOTOFRAME_LIBRARY` 指定，不加命令行参数 |

## 测试

```bash
cd Tools/photoframe
swift test --scratch-path "$TMPDIR/photoframe-build"
```

测试只用代码合成的图片，写在系统临时目录里：参数解析与退出码、各命令的 JSON 输出、从命令行一路导出到真实文件（校验尺寸、
sRGB ICC、文件名、没有残留临时目录）、`--overwrite` 与版本后缀、Ctrl-C 取消、预设库与素材库命令、导入素材 → 绑定 → 导出后
成品里确实画出了图层，以及以子进程运行可执行文件（stdout / stderr 分离、SIGINT）。测试的本地库都在临时目录里，不碰真实的 App Group 库。子进程测试需要 `swift test` 构建出的 `photoframe`，也可以用环境变量 `PHOTOFRAME_EXECUTABLE` 指定。
