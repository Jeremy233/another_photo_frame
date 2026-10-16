# PhotoFrameStorage

预设包 `.photoframe` 的读写与导入检查、素材绑定解析（Slot Resolver）、平台配置和内置预设。
预设的数据模型本身在 `PhotoFrameCore`（`Sources/PhotoFrameCore/Preset/`）。

## 运行测试

```bash
swift test --scratch-path "$TMPDIR/PhotoFrameStorage-build"
```

仓库在 iCloud 同步目录下时必须加 `--scratch-path`，原因见 `PhotoFrameCore/README.md`。

## 模块一览

| 文件 | 内容 |
|---|---|
| `PresetPackage.swift` | `export(_:)` / `export(_:to:)`、`preview(_:options:)`、`importPreset(_:options:)`、`readFile(at:)` |
| `PresetImportPreview.swift` | 导入前预览（§8.3）：尺寸、图层、slots、输出格式、schema 版本、所有问题；可直接 JSON 编码给 CLI / MCP |
| `Zip/` | 最小 ZIP 实现：stored + raw deflate（Compression 框架），无加密、无 ZIP64、单卷。写出的包是确定性的（固定时间戳） |
| `SlotResolver.swift` | `AssetBinding`、`AssetBindingTable`、`SlotResolver`（D-14） |
| `PlatformCatalogStore.swift` + `Resources/platforms.json` | 可更新的平台配置；用户目录中 `revision` 更大的覆盖文件优先 |
| `BuiltInPresets.swift` | 6 个内置预设，presetId 固定 |

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

## 待确认

以下是实现时遇到的规范歧义或需要拍板的地方，都**按下面的「当前实现」先做了**，规范未改动。

1. **素材几何放在哪里。** §8.1 示例把 `anchor`、`sizePx`、`opacity`、`visibleOn` 写在 `assetSlots[]` 上；
   §7.1 又把定位、尺寸、可见性定义为 `OverlayLayer` 的属性。当前实现：几何只在 `layers[]` 上，
   `asset` / `cameraBadge` 图层用 `slotId` 引用素材槽；`AssetSlot` 只有 `slotId`、`kind`、`required`、`label`、
   `acceptedFormats`。因此**规范示例原样导入会因不认识的字段被拒绝**（测试 `specExample` 记录了这一点）。
   是否改示例，或反过来让 slot 携带默认几何？
2. **规范示例之外新增的字段名**，请确认命名：顶层 `platform`、`layers`；`canvas.crop`（`aspectRatio: [w, h]`、
   `anchor: [x, y]`，对应 D-21）；`panorama.verticalMarginPx`（D-10）；`OverlayLayer` 的 `layerId`、`type`、`enabled`、
   `visibleOn`、`slides`、`anchor`、`reference`（`photo`/`canvas`，D-12）、`region`（`margin`/`photo`/`canvas`）、
   `offsetPx`、`sizePx`、`maxBoundsPx`、`opacity`、`zIndex`、`slotId`、`text`；`TextStyle` 的
   `content`、`template`、`fontFamily`、`fontSizePx`、`lineHeight`、`color`、`paddingPx`。
3. **不认识的非 `x-` 字段默认拒绝导入。** D-15 只规定 `x-` 字段原样保留；§8.3 说「不默默丢失字段」。
   当前：同一 schema 版本内出现未定义字段视为文件损坏或被手改，默认拒绝；`UnknownFieldPolicy.keep` 可保留并警告。
4. **`selectedSlides` 的页面编号**：当前 0 = 封面，k + 1 = 第 k 张切片（与 `PanoramaSlice.index` 差 1）。
5. **绑定失效时是否回退。** D-14 只给了优先级。当前：高优先级绑定指向已删除或格式不符的素材时，警告并回退到下一层；
   另一种做法是直接视为缺失，让用户修复。
6. **未被使用的必需 slot。** 当前只解析启用图层引用的 slot，所以 `required: true` 但没有图层（或图层被关闭）
   的 slot 不阻止输出。
7. **平台数值待核实**：轮播上限（含封面）Instagram 20、小红书 18、抖音 35；各平台是否接受 PNG；
   单文件体积上限（`maxFileSizeBytes` 暂未填写）。小红书、抖音的 HDR 状态是 `pendingVerification`，
   候选格式先填 gain map JPEG（D-17）。
8. **抖音 Panorama。** §2.2 只列了「抖音 Photo」，任务要求做 6 个内置预设，因此加了 `Douyin Panorama`
   （9:16 切片，3:1 全景会切成 6 张）。是否保留？
9. **内置预设命名**：§3 用 `Instagram Standard` / `XHS Standard`，§2.2 用 Photo。当前用 Standard / Panorama，
   平台名用英文（`XHS`、`Douyin`）。
10. **预设包中的额外文件**：§8.1 说将来可能 opt-in 附带授权素材。当前：额外文件计入大小与数量上限，
    但不解压、只警告（`package.ignored_entry`）。也可以改为直接拒绝。
11. **ZIP 上限默认值**（4 MiB / 32 条 / 单条 1 MiB / 总量 8 MiB）是拍脑袋的保守值。
12. **颜色**：只接受 `colorSpace: "sRGB"`，`hex` 允许 `#RRGGBB` 或 `#RRGGBBAA`。8 位 alpha 的合成语义未定义。
    输出 `colorSpace` 也只接受 `sRGB`；HDR 输出时它指 gain map JPEG 的 SDR 底图色彩空间。内部工作空间（D-03）不在预设里。
13. **HEIC 输出**：`output.format` 允许 `heic`（§6.8 列为待确认），但三个平台的 `outputFormats` 都没有它，
    所以平台检查会报错。
14. **导出时的隐私检查**是启发式的：只拦截以 `/Users/`、`/Volumes/`、`/private/`、`/home/`、`/var/`、`~/`、`file:`
    开头或含 `:\` 的字符串。
15. **PhotoFrameCore 现在 `import Foundation`**（`UUID`、`JSONDecoder`、`NSLock`）。§10.1 要求 Core 是跨 Apple 平台的纯 Swift；
    Foundation 满足跨平台，但如果「纯 Swift」指不依赖 Foundation，需要把编解码挪到别处。
16. **presetId 冲突**：预览只提示 `package.preset_id_exists`，「替换」还是「另存为副本（新 UUID）」留给 Application 层。
