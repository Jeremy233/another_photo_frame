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
13. **D-36 V1 只输出 JPEG 和 PNG**，`output.format` 已去掉 `heic`（以后可能重新评估）。
14. **D-37 隐私检查**保持当前的启发式规则。
15. **D-38 Core 允许依赖 Foundation**；「纯 Swift」指不依赖 UI 框架。
16. **D-39 presetId 冲突**：预览与导入结果的 `idConflictResolutions` 为 `[.saveAsCopy, .replace]`，第一项是默认；实际执行留给 Application 层。
