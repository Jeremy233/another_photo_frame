import MCP

/// MCP 只读资源（§11.4「Resources（建议）」）：说明文字、平台能力表、预设摘要与内容、访问范围。
/// 不提供任何本地文件内容。
enum MCPResources {
    static let access = "photoframe://access"
    static let presetSchema = "photoframe://docs/preset-schema"
    static let platforms = "photoframe://platforms"
    static let presets = "photoframe://presets"
    static let presetPrefix = "photoframe://presets/"

    static let list: [Resource] = [
        Resource(name: "access", uri: access, title: "访问范围",
                 description: "允许读取、写入的目录和资源上限", mimeType: "application/json"),
        Resource(name: "preset-schema", uri: presetSchema, title: "预设字段说明",
                 description: "预设（manifest.json）的字段和逐项修改的字段路径写法", mimeType: "text/markdown"),
        Resource(name: "platforms", uri: platforms, title: "平台能力表",
                 description: "各平台的画布、轮播上限、输出格式与 HDR 支持", mimeType: "application/json"),
        Resource(name: "presets", uri: presets, title: "预设摘要",
                 description: "与 list_presets 相同的只读摘要", mimeType: "application/json"),
    ]

    static let templates: [Resource.Template] = [
        Resource.Template(uriTemplate: presetPrefix + "{presetId}", name: "preset", title: "预设内容",
                          description: "一个预设的完整内容（与 .photoframe 里的 manifest.json 相同），只读",
                          mimeType: "application/json"),
    ]

    static let presetSchemaText = """
        # AnotherPhotoFrame 预设（schemaVersion 1）

        预设就是 `.photoframe` 里的 `manifest.json`。`get_preset` 返回它，`update_preset` 按字段路径修改它。

        ## 顶层
        - `schemaVersion`（只读）、`presetId`（只读，UUID）、`name`、`platform`（`instagram` / `xiaohongshu` / `douyin`，可省略）
        - `canvas`：`width`、`height`、`background`（`{"colorSpace": "sRGB", "hex": "#RRGGBB"}`）、`minMarginPx`、
          `mode`（`fit` 默认 / `crop`），`crop`（`{"aspectRatio": [4, 5], "anchor": [0.5, 0.5]}`，可省略）
        - `panorama`：`enabled`、`cover`、`tileCount`（`"auto"` 或整数，只能比自动张数多）、`cropPolicy`（`never`）、
          `fitHeight`、`padColor`（`"canvasBackground"` 或颜色）、`verticalMarginPx`（所有切片共用的上下边距）、
          `autoVerticalMargin`（`true` 时自动算上下边距，使它等于长卷端部的底色宽度，忽略 `verticalMarginPx`，默认 `false`）、
          `alignment`（照片在长卷里的位置：`left` / `center` 默认 / `right`，靠左／靠右时照片贴边）
        - `layers[]`：`layerId`、`type`（`text` / `metadataText` / `asset` / `cameraBadge`）、`enabled`、
          `visibleOn`（`coverOnly` / `allSlides` / `selectedSlides`，后者配 `slides: [0, 2]`，0 = 封面）、
          `anchor`（`topLeft`、`top`、`topRight`、`left`、`center`、`right`、`bottomLeft`、`bottom`、`bottomRight`）、`reference`（`photo` / `canvas`）、`side`（`inside` / `outside`，
          只用于 `photo`）、`offsetPx: [x, y]`、`sizePx`、`maxBoundsPx`、`opacity`（0…1）、`zIndex`、`slotId`（素材图层）、
          `cameraMatch`（素材图层，按 EXIF 相机选槽：`[{"make": "FUJIFILM", "model": "X100VI", "slotId": "camera.x100"}]`，
          品牌按包含、型号按相等匹配，型号规则优先，匹配不到或没有素材时用 `slotId`）、
          `text`（`content` 或 `template`，`fontFamily`、`fontWeight`（`ultraLight` … `regular` … `black`）、`italic`、
          `fontSizePx`、`letterSpacingPx`、`lineHeight`、`color`、`paddingPx`）
        - `assetSlots[]`：`slotId`、`kind`、`required`、`label`、`acceptedFormats`（`png` / `svg`）；不含位置和本地路径
        - `output`：`format`（`jpeg` / `png`）、`quality`（1…100）、`colorSpace`、`dynamicRange`（`auto` 跟随源图：源图是 HDR 且格式是 JPEG 时输出 HDR，否则 SDR，新建和内置预设的默认值；`sdr` / `hdr` 强制，D-125）、
          `metadata`（`keepShootingInfo`、`keepAuthorAndCopyright`、`keepGps`，默认都是 false）
        - 颜色只接受 `#RRGGBB`；任何对象都可以带 `x-` 开头的自定义字段。

        EXIF 模板可用的键：`camera`、`make`、`model`、`lens`、`focalLength`、`focalLength35`、`aperture`、`shutter`、`iso`、`date`。

        ## 字段路径（D-93，CLI `preset get` / `preset set` 用同一种写法）
        | 写法 | 含义 |
        |---|---|
        | `canvas.minMarginPx` | 对象字段 |
        | `layers[0].opacity` | 数组下标，从 0 开始 |
        | `layers[exif].text.fontSizePx` | 方括号里不是纯数字时，按 `layerId` / `slotId` 找元素 |
        | `layers[+]` | 在数组末尾追加（只能用于设置） |

        规则：
        - 一次 `update_preset` 的全部修改按顺序应用，改完的整份预设必须通过与导入 `.photoframe` 相同的检查
          （不认识的字段、取值范围、图层引用的素材槽、平台能力）才原子写入；任何一项不通过都不修改。
        - 字段不存在时可以新增（拼错的字段名会被当作不认识的字段拒绝）；中间的对象必须已存在，否则先设置整个对象。
        - `remove: true` 删除字段或数组元素；删除不存在的字段报 `preset.path_not_found`。
        - 内置预设只读（`library.builtin_read_only`），先用 CLI `photoframe preset duplicate` 复制。
        """
}
