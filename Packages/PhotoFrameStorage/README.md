# PhotoFrameStorage

预设包 `.photoframe` 的读写与导入检查、素材绑定解析（Slot Resolver）、平台配置和内置预设，
以及本机的用户预设库、素材库和绑定持久化（`Library/`）。
预设的数据模型本身在 `PhotoFrameCore`（`Sources/PhotoFrameCore/Preset/`）。

## 运行测试

```bash
swift test --scratch-path "$TMPDIR/PhotoFrameStorage-build"
```

仓库在 iCloud 同步目录下时必须加 `--scratch-path`，原因见 `PhotoFrameCore/README.md`。

## 模块一览

| 文件 | 内容 |
|---|---|
| `PresetPackage.swift` | `export(_:)` / `export(_:to:)`、`preview(_:options:)`、`importPreset(_:options:)`、`readFile(at:)`、`validateManifest(_:options:)`（对不打包的 manifest 做与导入相同的检查） |
| `PresetImportPreview.swift` | 导入前预览（§8.3）：尺寸、图层、slots、输出格式、schema 版本、所有问题；可直接 JSON 编码给 CLI / MCP |
| `Zip/` | 最小 ZIP 实现：stored + raw deflate（Compression 框架），无加密、无 ZIP64、单卷。写出的包是确定性的（固定时间戳） |
| `SlotResolver.swift` | `AssetBinding`、`AssetBindingTable`、`SlotResolver`（D-14） |
| `PlatformCatalogStore.swift` + `Resources/platforms.json` | 可更新的平台配置；用户目录中 `revision` 更大的覆盖文件优先 |
| `BuiltInPresets.swift` | 6 个内置预设，presetId 固定 |
| `Library/LocalLibrary.swift` | 入口：`presets` + `assets` + `bindings`，以及跨两部分的操作和素材槽解析 |
| `Library/PresetLibrary.swift` | 用户预设库：列出（内置 / 用户保存 / 导入）、新建、复制、重命名、保存、逐项修改（`edit`，D-93：改完走导入检查再原子写入）、删除、导入（D-39）、导出（D-37） |
| `Library/AssetLibrary.swift` + `AssetValidator.swift` | 本地素材库：PNG / 受限 SVG 导入校验、分组、重命名、删除、元信息列表 |
| `Library/AssetBindingStore.swift` | 预设本地绑定与用户默认绑定的持久化（D-14 的后两级） |
| `Library/LibraryFiles.swift`、`LibraryError.swift` | 目录布局、原子写、文件锁；错误码与警告 |

## 预设 JSON（PhotoFrameCore）

- `PresetSchema.decode(_:)`：解析 → 检查 `schemaVersion` → 逐步迁移 → 解码，同时登记不认识的字段路径。
- `PresetSchema.encode(_:)`：`sortedKeys` + 缩进，输出稳定。
- **迁移**在未定型的 JSON（`[String: JSONValue]`）上进行：新增版本时在 `PresetSchema.standardMigrator` 里加一步
  `PresetMigration(from: n) { manifest in … }`，迁移器负责更新 `schemaVersion`。缺少某一步或版本低于下限时报
  `preset.unsupported_schema_version`；比当前版本新时报 `preset.newer_schema_version`（带「请升级」提示）。
- **扩展字段**：每个对象都有 `extensions`，保存该层所有不认识的键。`x-` 开头的静默保留；其他的同样保留，
  但会登记到 `DecodedPreset.unknownFieldPaths`，由导入策略决定拒绝或警告。扩展字段不能覆盖同名正式字段。
- `ExportPreset.validate()` 检查取值与引用：ID 格式与重复、图层引用的 slot 是否存在、颜色、边距、张数、质量等。
- `PlatformProfile.check(_:)` 检查平台能力：输出格式是否支持、HDR 是否已验证。

## 导入检查

`ArchiveLimits.presetPackage` 默认值：压缩包 ≤ 4 MiB、条目 ≤ 32、单条解压 ≤ 1 MiB、解压总量 ≤ 8 MiB。

| 检查 | 错误码 |
|---|---|
| 不是 ZIP / 被截断 / 结构越界 | `archive.not_zip`、`archive.corrupted` |
| 文件、条目数、单条、总量超限（读中央目录时就拒绝，不解压） | `archive.too_large`、`archive.too_many_entries`、`archive.entry_too_large`、`archive.total_size_too_large` |
| 谎报解压大小的 ZIP 炸弹（输出缓冲区只按声明大小 + 1 分配） | `archive.size_mismatch` |
| 绝对路径、`..`、`.`、空段、反斜杠、`:`、控制字符 | `archive.unsafe_path` |
| 符号链接 | `archive.symbolic_link` |
| 重复条目（大小写不敏感、Unicode 规范化后比较） | `archive.duplicate_entry` |
| CRC 不符、本地头与中央目录文件名不一致 | `archive.checksum_mismatch`、`archive.corrupted` |
| 加密、ZIP64、分卷、未知压缩方式 | `archive.unsupported_feature` |
| 根目录没有 `manifest.json` | `package.missing_manifest` |
| 重复的 layerId / slotId | `preset.duplicate_layer_id`、`preset.duplicate_slot_id` |
| 不认识的字段（非 `x-`） | `package.unknown_field`（默认 error，`.keep` 策略下 warning） |
| 已安装同 ID 的预设 | `package.preset_id_exists`（warning） |
| 包里有 manifest 以外的文件 | `package.ignored_entry`（warning，不解压） |

整个过程只在内存中进行，不往磁盘解压任何文件。导出时拒绝疑似包含本地路径（`/Users/`、`/Volumes/`、`file:` 等）的字符串字段。

## 素材绑定（D-14）

`SlotResolver(library:bindings:).resolve(preset, jobBindings:)`：

1. 只解析被**启用的** `asset` / `cameraBadge` 图层引用的 slot。
2. 依次尝试 单任务 → 预设本地 → 用户全局。某一层的绑定指向已删除的素材（`slot.stale_binding`）或格式不被接受
   （`slot.incompatible_format`）时给出警告，继续尝试下一层。
3. 都找不到：可选 slot → `slot.optional_missing` 警告并把相关图层列入 `skippedLayerIds`；
   必需 slot → 抛出 `SlotResolutionError`（`slot.missing_required`），一次列出所有缺失的 slot 和已有警告。

`AssetBindingTable` 只存在本机，不写入 `.photoframe`。

**相机图标按 EXIF 自动匹配（D-111）**：`resolve(preset, jobBindings:, camera:)` 传入源图的 EXIF Make / Model 时，
素材图层按 `OverlayLayer.slotCandidates(for:)` 依次尝试候选槽：写了型号的 `cameraMatch` 规则 → 只写品牌的规则 → 图层自己的 `slotId`。
每个候选槽照常按上面 1–2 解析，用第一个有素材的，结果在 `layerSlots`（layerId → slotId），渲染前用 `applied(to:)` 换掉图层的 `slotId`。

- 匹配到的槽没有可用素材：`slot.camera_match_unbound`，退到下一个候选；它的 `required` 不起作用，从不阻止输出。
- 全部候选都没有素材：按图层自己的 `slotId` 处理（可选 → 跳过，必需 → `slot.missing_required`）；没有 `slotId` 时跳过并警告 `slot.camera_no_match`。
- 源图没有相机信息：`slot.camera_unknown`，只用默认素材。`camera` 为 nil（调用方不匹配）时行为与以前完全相同。

## 已确定（P3 实现细节，2026-10-16）

原来列在「待确认」里的问题已由用户决定，写入规范 §16「P3」（D-23～D-45），并按决定实现：

1. **D-24 几何只在图层上**：`AssetSlot` 只有 `slotId`、`kind`、`required`、`label`、`acceptedFormats`。规范 §8.1 示例已改写；
   `specExample`（Core）和 `specExampleImports`（Storage）两个测试直接从规范文件里取示例 JSON，保证它能被导入。
2. **D-25 字段名**：接受新增字段名，写入 §8.1 示例。图层的 `region` 已按 D-41 换成 `side`。
3. **D-26 不认识的非 `x-` 字段默认拒绝**，错误信息写明字段路径；`UnknownFieldPolicy.keep` 保留并警告。
4. **D-27 页码**：0 = 封面，切片 k 是第 k + 1 页。
5. **D-28 失效绑定回退**：警告后回退到下一优先级。
6. **D-29 未被启用图层用到的必需 slot** 不阻止导出。
7. **D-30 平台数值暂定**：IG 20、小红书 18、抖音 35（含封面）；PNG 是否接受、单文件大小上限待用户实测（`platforms.json` 的 `notes` 已注明）。
8. **D-31 保留 Douyin Panorama**。
9. **D-32 命名**：Standard / Panorama，平台名用英文。
10. **D-33 额外文件**：不解压，只警告。
11. **D-34 ZIP 上限**：4 MiB / 32 条 / 单条 1 MiB / 总量 8 MiB。
12. **D-35 颜色只允许 `#RRGGBB`**，透明度统一用图层的 `opacity`。
13. **D-36 V1 只输出 JPEG 和 PNG**，`output.format` 已去掉 `heic`。
14. **D-37 隐私检查**保持当前的启发式规则。
15. **D-38 Core 允许依赖 Foundation**；「纯 Swift」指不依赖 UI 框架。
16. **D-39 presetId 冲突**：预览与导入结果的 `idConflictResolutions` 为 `[.saveAsCopy, .replace]`，第一项是默认；实际执行留给 Application 层。

## 本地库（预设库 / 素材库 / 绑定）

### 目录布局

```text
<root>/                         默认 ~/Library/Group Containers/<App Group>/Library/Application Support/AnotherPhotoFrame/
├── Presets/<presetId>.json     每个用户预设一个文件
├── Assets/<assetId>/           每个素材一个目录：asset.json（元信息）+ content.png | content.svg
├── Assets/.staging/            导入中的素材；完成后整个目录一次改名到位
├── bindings.json               预设本地绑定 + 用户默认绑定
└── .lock                       修改 bindings.json 时的跨进程文件锁
```

**根目录（D-78）**：放在 App Group 共享容器里，沙盒 GUI 与不在沙盒里的 CLI / MCP 读写同一个库。

- App Group ID 是常量 `LibraryLocation.appGroupIdentifier`，目前是占位值 `group.org.anotherphotoframe`；
  真实值依赖开发者 Team ID，签名时一并确定。
- CLI / MCP：`LibraryLocation.defaultRoot()` 直接按路径计算
  `~/Library/Group Containers/<App Group ID>/Library/Application Support/AnotherPhotoFrame/`，不调用容器 API；
  `~` 取当前用户真实的主目录（`getpwuid`），不受沙盒容器影响。`LocalLibrary(platforms:)` 默认用它。
- GUI：`LibraryLocation.groupContainerRoot()` 先用 `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`；
  返回 nil（未签名、未配置 App Group）时退回上面按路径计算的结果。
- 根目录始终可以注入：`LocalLibrary(root:platforms:)`（测试、自定义位置）。

- 预设文件：`{"storageFormat": 1, "origin": "user"|"imported", "createdAt", "modifiedAt", "preset": {manifest}}`。
  `preset` 与 `.photoframe` 的 `manifest.json` 完全相同，用 `PresetSchema` 读写，迁移和扩展字段规则都适用。
- 所有写入都是「同目录临时文件 → fsync → rename」；崩溃只会留下以 `.` 开头的临时文件，读取时忽略。
- 不缓存：每次调用都读盘，GUI、CLI、MCP 多个进程同时用同一个库也能看到彼此的修改。
- 一个文件坏了只影响它自己：
  - 预设文件损坏、`schemaVersion` 或 `storageFormat` 比程序新、文件名与 presetId 不符：跳过并在 `PresetListing.warnings`
    里说明，**不改、不删**该文件；它的 ID 仍算「已占用」，导入同 ID 的预设时默认另存为副本。可以 `delete` 掉。
  - 预设文件里有不认识的字段：照常读取并警告，保存时原样写回。内容校验不通过：照常列出并警告（用户可以在 GUI 里修好）。
  - 素材的 `asset.json` 损坏、内容文件丢失或大小与记录不符：不出现在列表里并警告，查找时视为不存在（绑定按 D-28 回退）。
  - `bindings.json` 损坏：当作空表并警告；下一次修改前把坏文件改名为 `bindings.corrupt-<时间>.json` 留底。
    格式版本比程序新：当作空表并警告，**拒绝修改**。
- 错误消息和警告里只出现文件名和 ID，不出现绝对路径。

### 给 PhotoFrameService / CLI / GUI 的接口

```swift
let catalog = try PlatformCatalogStore.builtIn()
let library = LocalLibrary(platforms: catalog)            // CLI / MCP；测试：LocalLibrary(root: tmp, platforms: catalog)
let guiLibrary = LocalLibrary(root: LibraryLocation.groupContainerRoot(), platforms: catalog)   // GUI

// 预设（UI 设计文档第 7 节；CLI preset list/import/export）
let listing = library.presets.list()                      // .builtIn / .user / .imported / .warnings
let items = listing.all.map(PresetListItem.init)          // 可直接 JSON 编码给 `preset list --json`、MCP list_presets
let entry = try library.presets.find("instagram-panorama")// UUID、完整名称（不分大小写）或短名
let mine = try library.presets.create(name: "My Landscape", from: entry.preset)
let copy = try library.duplicatePreset(entry.presetId)   // 内置预设也能复制；默认连同本地绑定一起复制
try library.presets.rename(copy.presetId, to: "Gallery")
try library.presets.update(editedPreset)                  // 内置预设 → library.builtin_read_only；分组不变
try library.presets.move(id, to: .user)                   // 「用户保存」⇄「导入」，GUI 拖放用（D-81）
try library.deletePreset(copy.presetId)                   // 同时删除它的本地绑定

let preview = try library.presets.previewImport(data)     // §8.3；preview.idConflictResolutions == [.saveAsCopy, .replace]
let imported = try library.presets.importPackage(data)    // 默认 .saveAsCopy（D-39，副本名加 Copy，D-80），也可 onConflict: .replace
try library.presets.exportPackage(id, to: url)            // 校验 + 隐私检查（D-37）+ 原子写
PresetLibrary.suggestedFileName(for: entry.name)          // "My Landscape.photoframe"

// 素材（§8.2）
let result = try library.assets.importAsset(fileAt: url, category: .signature)   // 校验后复制进库
result.duplicateOf                                         // 库里内容相同的素材
library.assets.list(category: .cameraBadge).assets         // [AssetInfo]：不含路径，可直接给 MCP list_assets
try library.assets.rename(id, to: "Nikon Z8")
try library.assets.setCategory(id, to: .watermark)
let affected = try library.deleteAsset(id)                 // 返回仍指向它的绑定，供界面提示

// 绑定（D-14）：单任务绑定随任务传入，不持久化
try library.bindForPreset(presetId, slotId: "camera.badge", assetId: assetId)   // 「保存到此预设的本地绑定」；nil 清除
try library.bindByDefault(slotId: "camera.badge", assetId: assetId)             // 「设为本用户默认绑定」；nil 清除

// 解析：给渲染器
let resolved = try library.resolveSlots(for: preset, jobBindings: ["signature": someAssetId])
resolved.resolution        // SlotResolution（含 D-28 回退警告、skippedLayerIds）
resolved.files             // slotId → (url, format)，只给渲染器，不要返回给 MCP
// 或者交给任务队列 / 渲染模块：
let (resolver, warnings) = library.makeSlotResolver()      // 快照；QueueConfiguration(slotResolver:)
RenderJob.assets(from: resolution, fileURL: library.assets.contentURL(for:))    // PhotoFrameRendering
```

`PresetLibrary`、`AssetLibrary`、`AssetBindingStore` 都是值类型（`Sendable`），可以单独构造（`init(directory:…)`）。
`InMemoryAssetLibrary` 仍可用于 dry-run 和测试。

### 素材导入检查（`AssetValidator`）

按扩展名确定期望格式（只接受 `png`、`svg`），再按**内容**校验，扩展名与内容不符时拒绝。默认上限
（`AssetImportLimits.default`，D-85）：PNG ≤ 64 MiB、SVG ≤ 8 MiB、单边 ≤ 16384 px、总像素 ≤ 64 MP、SVG ≤ 50000 个元素、嵌套 ≤ 64 层。

| 检查 | 错误码 |
|---|---|
| 扩展名不是 png / svg | `asset.unsupported_type` |
| 内容与扩展名不符（例如 SVG 文本改名成 .png） | `asset.type_mismatch` |
| 文件超过大小上限（读入内存之前就检查） | `asset.too_large` |
| PNG：IHDR 尺寸为 0、单边或总像素超限（**不解压**就拒绝） | `asset.invalid_dimensions` |
| PNG：逐块检查结构与 CRC、IHDR 字段、调色板；流式解压 IDAT 并只计数，解出的字节数必须与 IHDR 推算的完全一致（防压缩炸弹、防截断）；最后交给 ImageIO 解码一次 | `asset.corrupted` |
| 动画 PNG（acTL / fcTL / fdAT） | `asset.unsupported_type` |
| PNG：IEND 之后的多余数据 | 去掉后保存，给出提示 |
| SVG：非 UTF-8、DOCTYPE / ENTITY、处理指令（如 `xml-stylesheet`）、`script`、`style`、`foreignObject`、`image`、`use`、`a`、动画元素、任何 `*href`、`on*` 属性、`url(`、`javascript:`、`data:`、根元素不是 `<svg>`、没有可用的尺寸、元素或嵌套超限 | `asset.svg_rejected` |
| SVG：渲染时会跳过的元素（文字、渐变、滤镜…）、没有可绘制图形 | 提示，记在 `AssetInfo.importWarnings` |

受限 SVG 规则（`AssetValidator.SVGPolicy`）与 PhotoFrameRendering 的 `RestrictedSVG` 保持一致：导入时通过的，渲染时也能解析；
导入时额外拒绝动画元素和处理指令。

### 本地库的错误码

`library.preset_not_found`、`library.ambiguous_preset`、`library.builtin_read_only`、`library.preset_exists`、`library.invalid_name`、
`library.invalid_preset`、`library.unreadable_item`、`library.newer_storage_format`、`library.io`、`asset.not_found`、
`binding.unknown_slot`、`binding.incompatible_format`，以及透传的 `package.*` / `archive.*` / `preset.*`。
读库时的警告：`library.unreadable_preset`、`library.newer_schema_version`、`library.newer_storage_format`、`library.id_mismatch`、
`library.unexpected_file`、`library.shadows_builtin`、`library.unknown_fields`、`library.migrated`、`library.invalid_preset`、
`asset.unreadable_metadata`、`asset.missing_file`、`asset.size_mismatch`、`binding.unreadable`。

### 本地库：已确定（2026-10-16）

1. **D-78 根目录**：App Group 共享容器，规则见上面「根目录」。
2. **D-79 副本命名**：存储层默认「原名 Copy」「原名 Copy 2」…（英文）；GUI 可以传入本地化名称（`duplicate(_:name:)`）。
3. **D-80 导入另存为副本**：留在「导入」组，名称按复制预设的规则加后缀（「原名 Copy」「原名 Copy 2」…）。
4. **D-81 分组**：预设留在原来的组，除非用户自己拖动或移动。导入的预设编辑后仍在「导入」组；
   `PresetLibrary.move(_:to:)` 在「用户保存」和「导入」之间移动（内容和时间不变），内置预设不能移动。
5. **D-82 组内排序**：按名称（Finder 式自然排序），同名按 ID。
6. **D-83 删除素材时保留指向它的绑定**：解析时按 D-28 警告并回退；`deleteAsset` 返回这些绑定供界面提示重新绑定。
7. **D-84 复制预设默认连同本地绑定一起复制**；删除预设时删除它的本地绑定；导入「替换」保留原 ID 的本地绑定。
8. **D-85 素材上限**：PNG 64 MiB、SVG 8 MiB、单边 16384 px、总像素 64 MP、SVG 50000 个元素 / 64 层。
9. **D-86 动画 PNG 拒绝**；PNG 在 IEND 之后的数据被去掉（防止拼接的 ZIP 等夹带内容）。
10. **D-87 SVG 规则只保留一份**：以 `AssetValidator.SVGPolicy` 为准，渲染模块的 `RestrictedSVG` 直接使用它和 `AssetImportLimits.default`。
    导入比渲染更严：额外拒绝动画元素（`SVGPolicy.animationElements`，渲染时跳过）和处理指令；渲染也拒绝的是
    `SVGPolicy.renderingForbiddenElements`。不支持的元素只警告。
11. **D-88 重复内容仍然导入**为新素材，只通过 `duplicateOf` 提示。
12. **D-89 素材分组只用于整理**，不限制能绑定到哪个 slot；slot 只按格式限制（`acceptedFormats`）。
13. **D-90 用户默认绑定按 slotId 全局生效**：不同预设里同名的 slot 共用一个默认素材。
14. **D-91 内容校验不通过的已存预设仍然列出**（带警告），方便用户在 GUI 里修好。
15. **D-76 CLI 引用预设**：UUID、完整名称（不区分大小写）或短名（`Instagram Panorama` → `instagram-panorama`），
    匹配到多个时报 `library.ambiguous_preset`；与 CLI 的匹配规则合并为 D-76，CLI 以后改用 `PresetLibrary.find(_:)`。
16. **D-92 预设在库里的存储格式**是 JSON 封装（来源、时间 + manifest），而不是 `.photoframe` ZIP。
