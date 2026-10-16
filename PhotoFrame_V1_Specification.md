# AnotherPhotoFrame — V1.0 产品与技术规范（Review Draft）

> **状态：供逐条审阅 · Draft 0.1**  
> **基线日期：2026-10-12**  
> **产品定位：** *Open-source Photography Publishing Toolkit for macOS*  
> **口号（暂定）：** *Create once. Export anywhere.*  
> **版本范围：** MVP → Alpha / Beta → V1.0；不包括未来的远程服务器、移动端客户端。  
> **标记约定：** **【已确定】** = 用户明确确认；**【建议】** = 当前技术方案、尚可调整；**【待确认】** = 开发前需拍板；**【V1 不做】** = 刻意排除。  
> **审阅方法：** 可直接在每节后添加 `Review:` 评论，或修改文末《待确认决策清单》。

---

## 目录

1. [产品愿景与原则](#1-产品愿景与原则)
2. [范围与版本边界](#2-范围与版本边界)
3. [典型工作流与用户故事](#3-典型工作流与用户故事)
4. [应用界面与交互规范](#4-应用界面与交互规范)
5. [画布、留白与全景无缝切片](#5-画布留白与全景无缝切片)
6. [摄影级色彩处理管线](#6-摄影级色彩处理管线)
7. [排版图层、水印、相机贴图与元数据](#7-排版图层水印相机贴图与元数据)
8. [预设与素材系统](#8-预设与素材系统)
9. [任务队列与导出](#9-任务队列与导出)
10. [系统架构与模块边界](#10-系统架构与模块边界)
11. [后端 API、CLI 与 MCP](#11-后端-apicli-与-mcp)
12. [性能、可靠性、安全与隐私](#12-性能可靠性安全与隐私)
13. [测试计划与验收标准](#13-测试计划与验收标准)
14. [发布、开源及开发里程碑](#14-发布开源及开发里程碑)
15. [风险与权衡](#15-风险与权衡)
16. [待确认决策清单](#16-待确认决策清单)
17. [V1.0 验收 Checklist](#17-v10-验收-checklist)

---

## 1. 产品愿景与原则

### 1.1 要解决的问题

摄影师通常已经在 Lightroom、Photoshop、Capture One、PixInsight 等软件中完成后期，但发布到不同社交平台时，还需要重复执行：建立不同画布、保留原图、添加统一留白、制作水印／器材信息、超宽幅切片、重命名文件和批量输出。PhotoFrame 只解决这段**「后期完成 → 发布成品」**的流程，不另造一个修图软件。

### 1.2 核心原则

| 原则 | 要求 | 状态 |
|---|---|---|
| macOS First | 优先追求原生 macOS 体验，使用 SwiftUI + AppKit | 【已确定】 |
| 免费、开源 | V1 免费，无订阅、账号或自建云服务依赖 | 【已确定】 |
| Local First | 原图、预设、素材和渲染结果默认仅在本地 | 【已确定】 |
| 前后端分离 | GUI 不包含排版或图像处理实现，调用统一后端服务接口 | 【已确定】 |
| GUI / CLI / MCP 三入口 | 三者共享同一套排版、渲染、预设与任务服务 | 【已确定】 |
| 非破坏式输出 | 不覆盖原始照片、不擅自改变画面比例与构图 | 【已确定】 |
| 色彩准确 | 保留并正确解释源文件色彩信息；预览与导出使用同一计算链路 | 【已确定：目标；具体方案见第 6 节】 |
| 预设可分享 | 排版预设独立于私有素材，可导入、导出、版本迁移 | 【已确定】 |
| 素材由用户掌控 | 预设通过占位符绑定用户本地素材，默认不打包素材 | 【已确定】 |
| 未来可扩展 | 后端可供 iOS/iPadOS、远程接口及社区第三方客户端复用 | 【已确定：架构方向】 |

### 1.3 不追求的目标

- 【V1 不做】RAW 传感器解码与去马赛克、调色、曲线、降噪、HDR 合成、全景拼接（stitching）。输入应是**已经处理好的图像**。
- 【V1 不做】自动直接发布到 Instagram / 小红书 / 抖音；只输出可上传的文件。
- 【V1 不做】统一账户体系、用户登录、PhotoFrame 托管云、在线预设商店。
- 【V1 不做】远程网络服务、Discord/Telegram Bot、手机网页远程渲染、自托管 HTTP API。
- 【V1 不做】Windows 原生版、iOS/iPadOS 原生版、iCloud 同步；仅为其保留架构扩展点。

---

## 2. 范围与版本边界

### 2.1 V1.0 目标功能（**交付范围**）

| ID | 功能 | V1 要求 | 状态 |
|---|---|---|---|
| FR-01 | macOS GUI | Compressor 风格三栏、自适应窗口、自由拖动分隔条 | 【已确定】 |
| FR-02 | 图像输入与预览 | JPG/PNG/TIFF（含 HDR 变体）；HEIC 放到 V2；正确方向、ICC、缩略图 | 【已确定：D-02】 |
| FR-03 | 画布引擎 | 任意目标尺寸、背景颜色、最小边距、Fit/居中；可选比例裁切模式 | 【已确定：D-21】 |
| FR-04 | 全景轮播 | 完整封面 + 无裁切、左右补底色的连续切片 | 【已确定】 |
| FR-05 | 平台预设 | Instagram、XHS、Douyin（用户可修改） | 【已确定】 |
| FR-06 | 排版图层 | 签名、水印、相机贴图、EXIF 信息等可选图层 | 【已确定】 |
| FR-07 | 素材库与 Slots | 本地自选素材、占位符、预设绑定、缺失处理 | 【已确定】 |
| FR-08 | 预设管理 | 创建、复制、编辑、导入、导出、分享、schema 版本 | 【已确定】 |
| FR-09 | 批处理 | 多原图、多预设、队列、进度、取消、重试 | 【已确定】 |
| FR-10 | 图像导出 | JPEG 必须；PNG/HEIC 等按格式矩阵逐项实现 | 【建议：分级交付】 |
| FR-11 | 视频导出 | V1、V2 不做；V2 考虑 Live Photo，V3 及以后再做视频 | 【V1 不做：D-16】 |
| FR-12 | CLI | 独立可执行文件、可脚本化、JSON 输出 | 【已确定】 |
| FR-13 | MCP | 本地 stdio MCP Server，供 AI 客户端调用 | 【已确定】 |
| FR-14 | 色彩管理 | 输入 ICC、色彩转换、正确合成与输出 ICC、可测试 | 【已确定】 |
| FR-15 | 隐私安全 | 本地数据、路径权限、默认剥离敏感位置元数据 | 【建议】 |

> **范围控制说明：** 表中 V1 指正式稳定版的目标集；并非第一天就同时实现。V1 的 HDR 输出、SVG、安全解析等复杂子项可以在 Alpha/Beta 阶段用能力开关逐项交付，但正式发布前应明确哪些已通过验收。

### 2.2 推荐默认值（用户个人风格，不应硬编码为唯一风格）

| 平台 / 模式 | 画布 | 背景 | 封面最小边距 | 图像策略 |
|---|---:|---|---:|---|
| Instagram Photo / Panorama | 1080 × 1440，3:4 | `#FAFAF8` | 60 px | 完整图等比居中；全景另输出连续切片 |
| 小红书 XHS Photo / Panorama | 1080 × 1080，1:1 | `#FAFAF8` | 60 px | 同上 |
| 抖音 Photo | 1080 × 1920，9:16 | `#FAFAF8` | 60 px | 完整图等比居中 |

- 【已确定】当前摄影风格为 **Modern Fine Art Landscape Photography**：中性暖白底、照片为主体、装饰克制。
- 【已确定】原图封面**完整嵌入**画布；不是自动裁切填满。比例裁切仅作为用户主动开启的可选模式（D-21）。
- 【已确定】“60 px”是**最小安全边距**，不是强制照片四周始终恰好 60 px。
- 【已确定】全景连续切片内部的接缝**不能**出现每页独立的 60 px 白边；轮播切片使用独立的全景版式规则。
- 【待确认】各平台允许的图片比例、轮播张数、文件大小、压缩策略会变化；需要把限制写在可更新平台配置中，而不是依赖永久固定的常数。上传前用户仍需检查平台实际预览。

---

## 3. 典型工作流与用户故事

### 3.1 普通照片

1. 用户把后期完成的 JPEG/TIFF 拖入 PhotoFrame。
2. 从左侧将 `Instagram Standard` 和 `XHS Standard` 预设拖到同一张源图上。
3. 中间生成两个独立任务；右侧预览 3:4 或 1:1 的完整画面。
4. 可按需修改背景、60 px 边距、文字或相机图标。
5. 执行队列，分别输出成品；原文件不变。

### 3.2 超宽幅照片（关键工作流）

1. 用户导入比例约 65:24、3:1 的完整全景图。
2. 应用 `Instagram Panorama` 或 `XHS Panorama`。
3. 生成**首页完整图**，等比放入背景画布；后续生成多张**横向连续**的放大细节切片。
4. 不裁掉原图任何左右／上下内容；如整体宽度不足，**仅在总长画布左右两端补 `#FAFAF8`**。
5. 切片之间不各自套边框，保证滑动时几何连续。
6. 如开启签名、EXIF 或相机贴图，默认只出现在封面；连续切片不重复叠加。

![图 1：同一张后期完成的原图应用多个预设，形成独立任务，分别输出完整封面或全景轮播切片。](docs/illustrations/01-publishing-workflow.png)

*图 1 · 发布工作流：同一原图可生成多种平台成品；每个任务保留自己的参数。风景为 AI 生成的示例素材。*

### 3.3 共享预设

A 用户分享 `.photoframe` 文件；B 用户导入后看到画布与图层布局，其中 `camera.badge`、`photographer.signature` 是**占位符**。B 从自己的本地 Asset Library 为占位符选择图片，或保留空白；不依赖 A 的本地路径，也不需要复制 A 的机型线稿。

### 3.4 自动化

- CLI：批量处理文件夹，读取某预设，输出到指定目录，返回 JSON 结果。
- MCP：AI 查询本地可用预设／源图属性，生成预览，经授权再执行导出。
- 【V1 不做】手机通过互联网访问 Mac。未来该能力通过新的 Remote Adapter 实现。

---

## 4. 应用界面与交互规范

### 4.1 三栏 Compressor 布局

![图 2：PhotoFrame 三栏工作台概念图，参照 Compressor：顶栏切换当前、活跃、已完成；左侧预设、位置、素材；中间上方预览、下方任务列表；右侧 Inspector 分画布、全景、图层、输出；A、B、C 标注可拖动分隔线。](docs/illustrations/02-three-column-workbench.png)

*图 2 · 界面概念示意：A / B 调整三栏宽度，C 调整预览与任务列表高度；示意不代表已实现界面。*

```text
┌───────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  [◧]             当前 | 活跃 | 已完成                             [◨]   │
├──────────────────┬────────────────────────────────┬───────────────────────────┤
│ 预设 | 位置 | 素材│ PREVIEW   [Cover] [1] ... [N]  │ 画布 | 全景 | 图层 | 输出 │
│                  │ ┌────────────────────────────┐ │                           │
│ 内置             │ │       photo preview        │ │ Width / Height / Ratio    │
│ ───────          │ └────────────────────────────┘ │ Fit / Crop                │
│ 用户保存         ├────────────────────────────────┤ Background / Margin       │
│ ───────          │ BATCH                          │ Align                     │
│ 导入             │ Badlands_panorama.tif          │                           │
│                  │   IG Panorama   4320×1440 ⚠    │                           │
│                  │   XHS Panorama  2925×1080      │                           │
│                  │ Aurora.tif                     │                           │
│                  │   IG Standard   1080×1440      │                           │
├──────────────────┴────────────────────────────────┴───────────────────────────┤
│ 添加图片   位置：~/Pictures/Social Exports    ▓▓▓▓░░ 42%          开始批处理 │
└───────────────────────────────────────────────────────────────────────────────┘
```

- 【已确定】整体参照 Compressor。顶栏中间切换「当前 | 活跃 | 已完成」三个界面；左右两端是侧栏开关。
- 【已确定】左侧 = **预设 | 位置 | 素材**三个标签；中间上方 = **预览**，中间下方 = **源图与任务列表**；右侧 = **Inspector**（画布 | 全景 | 图层 | 输出）。
- 【已确定】左、中、右分隔线可自由拖动；中间的预览与任务列表之间也可上下调整。
- 界面细节见《Another Photo Frame UI Design.md》。
- 【建议】双击分隔线恢复默认大小；允许隐藏侧栏，记住每个窗口最后布局；设置最小可用宽高。
- 【建议】双击照片预览打开大图；支持 Fit、100% 与手动缩放。
- 【建议】主控件可键盘操作，支持 VoiceOver、浅色和深色外观。
- 【建议】界面可以先用 SwiftUI，复杂分割视图优先封装 AppKit `NSSplitView`。

### 4.2 右侧 Inspector 结构

```text
画布   Width / Height / Ratio / Fit or Crop / Background / Margin / Align
全景   On / Auto or Manual Tiles / Vertical Margin / Preview Seam
图层   Watermark / Camera Badge / EXIF Text / Visible On / Asset Slot Binding
输出   Format / Quality / SDR or HDR / Metadata / Naming / Location
```

预览区（中间栏上方）可切换 `[Cover] [Slide 1] ... [Slide N]` 与全景长卷视图。

- 点击**源图**时显示原始信息与 EXIF；点击**任务**时显示该任务实际输出参数；点击多个任务时仅显示可批改的共同字段。
- 改动任务参数**不自动回写共享预设**；通过显式 `Save as Preset` 保存。
- 拖动预设至源图或多选源图即可创建导出任务；按钮操作是等价的非拖拽方式。
- 修改任意参数后通过后端渲染**可复现的低分辨率预览**，而不是另写一套 SwiftUI 假预览。

---

## 5. 画布、留白与全景无缝切片

### 5.1 坐标和输入规范

- 原图经过 EXIF Orientation 校正后，定义显示宽高为 `S_w`、`S_h`，长宽比 `R = S_w / S_h`。
- 输出画布为 `W × H`，坐标原点建议定义为**左上**，`x` 向右，`y` 向下；其他底层坐标系统在适配层转换。
- 背景 `#FAFAF8` 解释为 **sRGB 编码十六进制颜色**，而非未经定义的工作色域数值（详见第 6 节）。
- 图片变换保持比例，居中、无裁切；允许未来自定义其他 Anchor。

### 5.2 单页／封面 Fit 模式

最小边距 `m`，允许放置图像的内框：

```text
availableWidth  = W - 2m
availableHeight = H - 2m
scale = min(availableWidth / S_w, availableHeight / S_h)
imageWidth  = S_w × scale
imageHeight = S_h × scale
originX = (W - imageWidth) / 2
originY = (H - imageHeight) / 2
```

**栅格取整【已确定：D-22】——不动照片，只动 padding：**

```text
pixelWidth  = clamp(round(imageWidth),  1, availableWidth)    # .5 进位
pixelHeight = clamp(round(imageHeight), 1, availableHeight)
left = floor((W - pixelWidth)  / 2),  right  = W - pixelWidth  - left
top  = floor((H - pixelHeight) / 2),  bottom = H - pixelHeight - top
```

- 精确尺寸是整数时（如贴住内框的一边）原样使用，照片不做额外缩放；非整数时只取最近的整数。
- 剩余空间全部由留白吸收，两侧可能相差 1 px，多出的 1 px 固定在右／下。
- 因 `pixelWidth ≤ availableWidth`，两侧留白都 ≥ `m`，不会隐性裁切。

不同原图纵横比产生的剩余留白可大于 `m`。

![图 3：同一张完整全景照片居中放入 3:4、1:1、9:16 画布，虚线表示最小 60 px 边距内框，上下剩余留白随画布比例增加。](docs/illustrations/03-fit-and-minimum-margins.png)

*图 3 · 封面 Fit：照片等比完整嵌入，虚线是最小安全边距内框；说明标记不写入导出文件。*

### 5.3 全景模式：Cover + Seamless Slides

**核心规则【已确定】：**

- Slide 0 = 完整原图嵌入背景画布，执行普通封面 Fit。
- Slide 1…N = 从**同一张连续的全景总画布**中按固定 tile 宽度切出。
- **不裁切、不拉伸**全景；画面不足时只在总画布左右两端补背景色。
- 不给每一张切片单独添加左右边框，否则接缝不连续。
- 全景切片默认**铺满可用高度 `H`**（即不应用封面 60px 的上下边距）；用户可设置一个所有切片共用的上下边距 `v`（默认 0，D-10），此时以 `H - 2v` 代替下文的 `H` 作为渲染高度。
- 图片装饰（相机图标、签名、EXIF）默认只在 Cover 显示。

**默认算法【建议】：** 设 tile 为 `W × H`，全景按高度 `H` 等比缩放：

```text
renderHeight = H
renderWidth  = R × H
N = ceil(renderWidth / W)       # Auto slide count
stripWidth = N × W
padLeft = padRight = (stripWidth - renderWidth) / 2
```

1. 建立一张 `stripWidth × H` 的虚拟总画布，底色一致。
2. 将整张全景按 `renderHeight=H` 等比居中放入该画布。
3. 按全局坐标 `x = kW`，切出 `[kW, (k+1)W)` 区间，`k=0..N-1`。
4. 所有切片引用**相同的全局缩放、平移和颜色渲染参数**。为节省内存，实现时可以直接逐 tile 按全局变换渲染，无须真正分配超大 strip 位图。
5. 用户只能手动指定**大于或等于**自动值的 `N`（D-11）：更大的 `N` 只增加长卷两端的背景；小于自动值视为参数错误，不缩小全景，绝不裁切。
6. 栅格取整同 §5.2（D-22）：照片在长卷中只栅格化一次，`pixelWidth = round(renderWidth)`，`padLeft = floor((stripWidth - pixelWidth) / 2)`，`padRight` 取剩余；各切片按全局像素坐标 `[kW, (k+1)W)` 切开。

**默认数值验算：**

| 源图比例 | 目标 tile | N | 全景图缩放后宽度 | 左右补边 |
|---|---|---:|---:|---:|
| 3:1 | IG 1080×1440 | 4 | 4320px | 0 / 0 |
| 65:24 ≈ 2.7083:1 | IG 1080×1440 | 4 | 3900px | 210 / 210 |
| 3:1 | XHS 1080×1080 | 3 | 3240px | 0 / 0 |
| 65:24 ≈ 2.7083:1 | XHS 1080×1080 | 3 | 2925px | 157.5 / 157.5（栅格化为 157 / 158，D-22） |

![图 4：65:24 全景按高度缩放到 3900×1440，放入 4320×1440 的总画布，左右各补 210 px，再按全局坐标分成四张 1080×1440 切片；Cover 独立使用完整图 Fit。](docs/illustrations/04-seamless-panorama.png)

*图 4 · 65:24 → IG 数值算例：只有长卷最外侧补背景，内部接缝不加单页白边；虚线、尺寸线及文字仅用于说明。*

**关键边界：**

- `ceil()` 精度：接近整数边界时使用数值容差，避免本应 N=4 却由于浮点误差生成 N=5。
- 半像素偏移：用连续浮点全局坐标和一致采样规则，导出整数像素时明确取样位置。
- 极端全景：如 N 超过目标平台允许的轮播总张数（包括封面），应告警，并让用户改目标尺寸、分段、降低切片高度或更换模式；**不能无提示截掉照片**。
- 竖图、正方图或 `R` 很小：该模式未必有意义；默认禁用/提示，允许手动启用。判定：`R ≤ 1` 提示为竖图／方图；`R > 1` 但渲染宽度不超过 2 张切片宽（`R ≤ 2W / (H − 2v)`，即自动张数 ≤ 2）时也提示。
- 图片边界与接缝：PNG 无损测试须能按位重建输出像素意义上的虚拟长卷；JPEG 因独立编码会有有损差异，验收以接缝几何对齐、容差/视觉一致性为准。

### 5.4 平台轮播约束

【建议】定义平台能力描述（可更新，不把第三方规则作为不可变真理）：目标比例、最大项数、文件体积限制、图片格式与上传兼容性。上传平台可能自动重采样或统一轮播画幅；PhotoFrame 只能保证**本地导出文件**的几何连续，发布时仍须以平台实机预览验证。

---

## 6. 摄影级色彩处理管线

> **本节为 V1 高优先级技术规范。**目标是可复现的 **SDR + HDR 摄影发布工作流**（D-05），而非追求“看起来差不多”。涉及 ColorSync、ImageIO、Core Image / Core Graphics 的交界行为须通过带 ICC 的测试图实测确认。

### 6.1 核心不变量

1. **每个像素值都有颜色语义**：所有输入、背景、图层、预览、输出必须知道自身色彩空间。
2. **不重复转换 ICC**：每一步转换都明确输入空间、目标空间与责任组件，避免 ImageIO、Core Image、Core Graphics 隐性二次转换。
3. **预览 ≈ 导出**：Preview 和 Export 共用相同 Layout + Render Engine，仅采样分辨率、位深和输出编码器不同。
4. **所有缩放先解释颜色再处理**：不在错误 gamma 空间中盲目插值，透明边缘正确合成。
5. **宽色域源图不提前粗暴夹断到 sRGB**：尽可能保持高精度内部处理中间结果，只在指定输出阶段做明确映射。
6. **不把源图 ICC 当作输出 ICC 直接复制**：输出 ICC 必须真实对应已经转换的像素。
7. **跨格式、跨来源可追踪**：每个任务记录源色彩空间、缺失配置时的决策、工作空间、输出配置和警告信息。

### 6.2 输入支持与边界

| 输入类别 | V1 目标 | 约束与处理 |
|---|---|---|
| 8-bit JPEG / PNG | 必须 | ICC、EXIF Orientation、透明通道（PNG） |
| 16-bit TIFF | 必须 | 嵌入 ICC、高精度转换、避免 8-bit 中途量化 |
| HEIC / HEIF（含 iPhone HDR） | 【V1 不做，V2】（D-02） | V1 只处理后期软件导出的成片；V2 再支持，需正确识别 SDR/Wide Gamut/HDR gain map |
| 16-bit PNG | 建议 | 验证系统解码管线是否保留预期精度 |
| Adobe RGB / Display P3 / ProPhoto ICC | 必须测试 | 无提示色域失真不可接受 |
| 无 ICC 的图像 | 必须 | 明确默认假设、提示和人工覆盖途径 |
| 带 Alpha 图层的 PNG | 必须 | 不出现黑边、白晕及预乘错误 |
| HDR：gain map JPEG、PQ/HLG PNG、PQ/HLG/float TIFF | **必须**（D-05） | 保留 HDR 动态范围进入工作空间；按输出设置导出 HDR 或经 tone map 输出 SDR，不可简单剪裁/静默降级 |
| 相机 RAW（NEF/CR3/DNG 等） | 【V1 不做】 | 用户先在其他软件显影导出 TIFF/JPEG |

**无 ICC 策略【建议】：** 默认解释为 sRGB，并在 Inspector / 日志显示 `Source profile missing — assumed sRGB`；用户可针对**源文件或任务**显式选择另一个输入色彩空间。不得把“无 profile”默默标记为准确的 sRGB 摄影数据。扫描照片尤其需要人工检查。

### 6.3 推荐处理管线（具体 API 实现待验证）

```text
[Encoded Source: JPEG / TIFF / PNG / HEIC]
  ↓ (ImageIO: identify file, ICC, EXIF Orientation, alpha, bit depth, HDR flags)
[Decode & interpret source color space]
  ↓ (Normalize orientation ONCE; remember source profile and user override)
[High-precision working image / pixel buffers]
  ↓ (ColorSync / Core Image managed conversion into a defined working space)
[Layout: FIT / scale / pan / virtual panorama coordinates]
  ↓ (Image resampling with deterministic global transform)
[Composite: background + user-owned assets + glyphs / metadata]
  ↓ (linear-light alpha compositing; high precision; avoid early clipping)
[Output color transform: working → requested output profile]
  ↓ (e.g. sRGB IEC 61966-2-1; deliberate gamut mapping & quantization)
[Encoder: JPEG / PNG / HEIC or SDR video]
  ↓ (Embed CORRECT output ICC and sanitized metadata)
[File + structured rendering report]
```

![图 5：从源 ICC 解码、高精度工作空间、排版与线性光合成，到输出颜色转换、预览和编码的共享管线；背景与素材进入同一工作空间，HDR 需受控映射或拒绝。](docs/illustrations/05-managed-color-pipeline.png)

*图 5 · 建议色彩管线：预览与导出共用排版和颜色策略，输出文件嵌入与实际像素匹配的颜色描述；工作空间见 D-03，HDR→SDR 的具体策略仍待确定。*

**建议的后端显式类型：**

- `SourceColorDescription`: embedded ICC, source model, bit depth, alpha, HDR transfer, profileOverride, warnings。
- `WorkingColorPolicy`: internal linear-light extended working space, precision and gamut policy。
- `OutputColorPolicy`: destination ICC (`sRGB` V1 default), rendering intent policy, 8/16-bit mode (where supported), metadata policy。
- `RenderDiagnostics`: source/working/output profile IDs, transform steps, clipping/tone-map warnings。

### 6.4 工作色域、位深、混合

**【已确定：D-03】** 工作色彩空间为 **extended linear Rec.2020**（`kCGColorSpaceExtendedLinearITUR_2020`），像素格式为 **`RGBAh`**（半精度浮点，预乘 alpha）。V1 的输出都是 8-bit，RGBAh 的精度足够；以后如果增加 16-bit 输出，可以按任务改用 `RGBAf`。实测依据见[色彩 PoC 报告](docs/color-poc-report.md)。

- 所有中间结果（Core Image 中间缓冲、自建的 CGImage / CGContext、缓存）都必须是 extended 浮点，不得使用 8-bit 或非 extended 的格式；PoC 实测非 extended 的 CG 上下文会截断广色域。
- 输入 16-bit TIFF 后不得在渲染前无理由转换为 8-bit；JPEG 最终量化到 8-bit 是输出格式本身的正常限制。
- 透明图片与水印：内部定义 premultiplied/unpremultiplied alpha 边界，在**线性光域**以明确规则合成，预防发灰、黑边、彩色边缘。
- 缩放：高质量滤波、统一坐标与采样；预览允许不同采样尺度，但不能采用不同的颜色计算规则。
- 文本／矢量图层：先将指定文字颜色、线稿颜色转换到同一工作空间后合成。

### 6.5 背景色与白边的精确定义

默认背景 `#FAFAF8` 含义：**sRGB 编码的 RGB=(250,250,248)**。不是“Display P3 数值 250/255”，也不是线性 RGB=(0.980,0.980,0.973)。

1. 从 Hex 解析为 sRGB 编码颜色。
2. 通过受管理的色彩转换进入工作空间（含 sRGB EOTF / 转移函数处理）。
3. 与照片在同一工作空间内合成。
4. 输出到 sRGB JPEG 时，在可承受的误差范围内恢复预期 `#FAFAF8` 背景。

【建议】以输出无损 PNG 检验背景 RGB 是否精确为 `(250,250,248)`；JPEG 在高压缩和边缘附近可能出现小偏差，**不要用“所有像素逐点完全相等”作为 JPEG 验收条件**。

### 6.6 预览与显示器

- 预览窗口使用系统管理的显示颜色路径，正确处理显示器 ICC 与 SDR 显示目标。
- 不直接将源图当成无色彩空间的 bitmap 丢进 SwiftUI；预览必须来自已定义颜色管理的 Render Engine。
- 对不同 macOS 显示器（sRGB 外屏、P3 MacBook 屏）进行视觉/数值测试；同一输出文件可能在不同物理显示器视觉略异，不能承诺物理观感绝对一致。
- 软件应提供“输出预览”模式，默认以**最终输出色彩空间 sRGB**软打样或等效显示结果，而不是仅显示原始广色域输入。

### 6.7 SDR / HDR 边界

**【已确定：D-05】V1 支持 HDR 输入与输出。**

- 输入：在文件识别阶段检测 gain map、PQ/HLG 转移函数、float 数据等 HDR 指示，标记 `isHDR` 与 headroom，全程以 extended-range 浮点保留高光，不在 `[0,1]` 截断。
- 输出：HDR 是**可选导出项**。平台配置（§5.4）声明该平台支持的 HDR 输出格式（例如带 ISO 21496-1 gain map 的 JPEG，SDR 底图 + gain map，不支持 HDR 的设备自动退回 SDR）；用户选择 HDR 时按平台配置导出对应格式。
- SDR 输出：HDR 源选择 SDR 输出时，使用选定并记录参数的 tone mapping 算法，**不能无声地把高亮直接 clip 到白色**。
- 合成：背景、水印、文字等 SDR 元素在 HDR 输出中按参考白（SDR 白点）放置，不随 headroom 一起变亮。
- 视频：V1 不做视频输出（D-16）。

### 6.8 输出与元数据

| 输出类型 | 色彩/编码默认 | Metadata |
|---|---|---|
| JPEG | sRGB，8-bit，最高质量 Q100（D-06）；可选 HDR gain map | 嵌入正确 ICC；EXIF 默认全部不写出，可选「保留拍摄参数」「保留 GPS（带隐私警告）」 |
| PNG | sRGB + ICC 或等价标准颜色描述；支持透明输出配置 | 不传播与实际渲染不符的旧 ICC |
| HEIC | 【待确认】8-bit/10-bit 模式与 ICC 支持测试 | 由系统编码器能力决定 |

**EXIF Orientation：** 输出像素统一为正确方向，写出 Orientation=1 或不写该字段，防止社交平台再次旋转。对源图的镜头、焦距、光圈、快门等展示用参数，应与**是否复制到输出元数据**分别控制。输出元数据默认全部不写出；「保留拍摄参数」与「保留 GPS」为独立可选项，「保留 GPS」旁显示隐私警告（D-06）。

### 6.9 色彩管理验收测试（必做）

- [ ] 使用同一图像的 sRGB、Adobe RGB、Display P3、ProPhoto（正确嵌入 ICC）版本输出 sRGB，结果在容许色差范围内一致；针对超出目标色域的区域有明确的映射策略。
- [ ] 有 ICC 的输入绝不被强制当作 sRGB；缺 ICC 时显示提示且可覆盖。
- [ ] 16-bit TIFF 的渐变测试无明显额外色阶断层；对照验证中间运算不是 8-bit。
- [ ] PNG 透明图层在暗／亮背景下无黑色／白色 halo。
- [ ] 白边 `#FAFAF8` 的无损输出 RGB 数值符合定义。
- [ ] EXIF Orientation 1、3、6、8 的内容方向与尺寸正确且不重复旋转。
- [ ] 预览与导出的像素／颜色计算保持一致；明确允许预览缩放及 JPEG 编码误差。
- [ ] 对 P3 屏幕与普通 sRGB 显示器观察同一 sRGB 输出，行为符合 macOS 色彩管理预期。
- [ ] HDR 源（gain map JPEG、PQ/HLG PNG、float TIFF）保留动态范围；HDR 输出在 HDR 屏幕正确显示、在 SDR 设备正确回退；SDR 输出经 tone map，不发生无提示高光剪裁。
- [ ] 输出 JPEG 嵌入 sRGB ICC，文件再次在 Photoshop/Preview 中打开不出现系统性色偏。

> **【待确认】** 色差门槛（如 CIEDE2000 的样本分位数阈值）、对照标准图集、不同系统版本基线、HDR→SDR 策略；须在核心 PoC 阶段确定，不宜在没有样本的情况下声称具体数值已可达成。

---

## 7. 排版图层、水印、相机贴图与元数据

### 7.1 统一 Overlay 模型

每个排版元素是可选 `OverlayLayer`，包含：

- 类型：`text`、`asset`、`metadataText`、`cameraBadge`（具体可扩展）。
- 可见性与适用页面：`coverOnly`（默认）、`allSlides`、`selectedSlides`。
- Anchor：九宫格定位，默认相对**照片边缘**（D-12），也可选相对画布；offset 使用 px。
- Size / Max bounds、Opacity、Z-Index、文本字体与行距、颜色、必要的内边距。
- 渲染空间：相对画布、可用留白或照片（默认**留白区域，不遮挡照片**）。

**不应在 Inspector 中直接写绘制逻辑**。用户拖动图层时修改的是后端可序列化的布局参数。

### 7.2 水印 / 相机贴图 / EXIF

- Watermark：文字签名、用户自己的 PNG/矢量素材，可关闭；用处主要是署名，**不能视为可靠防盗手段**。
- Camera Badge：建议支持极简相机线稿（Minimal Outline）、技术线稿、剪影等布局样式，但**不内置没有明确再分发权利的品牌贴图**。
- Metadata：相机／镜头／焦距／光圈／快门／ISO，可从 EXIF 读取，也可手动覆盖；胶片扫描可人工指定相机档案。
- 智能匹配：EXIF camera model → 用户自建 `Camera Profile` → 本地 asset slot，不能匹配时使用空状态或手动选择。
- 【建议】避免默认把署名、日期、器材信息写到所有切片；Panorama 默认封面可见、细节页隐藏。

### 7.3 素材格式与版权

- 【已确定】素材由用户自己本地导入；预设导出**默认不包含具体 Logo、签名或相机图**。
- 【已确定：D-09】V1 支持 PNG 与受限 SVG：SVG 只解析基本图形与路径，禁止脚本、外部引用与远程资源。
- 对外分发的素材须由提供者自行确认授权；软件使用开源许可证**不等于**能分发 Nikon/Ricoh/Mamiya 等品牌素材。

---

## 8. 预设与素材系统

### 8.1 结构与文件格式

**【已确定】** 预设可导入、导出、用户互相分享；素材与预设分离。

**【建议】** 使用可版本化、结构化的 `.photoframe` 预设文件：

```text
My Landscape.photoframe   # ZIP container, versioned
└── manifest.json             # 默认只有 schema 和布局，不包含私人素材
```

将来如开放包含原创且已获授权资源的分享包，必须显式 opt-in，并标注素材授权与来源；默认模式始终只导出占位符。

**概念 Schema（示例，并非冻结的最终 JSON Schema）：**

```json
{
  "schemaVersion": 1,
  "presetId": "7C9E6679-7425-40DE-944B-E07FC1F90AE7",
  "name": "Instagram Panorama — Gallery",
  "canvas": {
    "width": 1080,
    "height": 1440,
    "background": {"colorSpace": "sRGB", "hex": "#FAFAF8"},
    "minMarginPx": 60,
    "mode": "fit"
  },
  "panorama": {
    "enabled": true,
    "cover": true,
    "tileCount": "auto",
    "cropPolicy": "never",
    "fitHeight": true,
    "padColor": "canvasBackground"
  },
  "assetSlots": [
    {
      "slotId": "camera.badge",
      "kind": "image",
      "required": false,
      "anchor": "bottomRight",
      "sizePx": [48, 48],
      "opacity": 1.0,
      "visibleOn": "coverOnly"
    }
  ],
  "output": {
    "format": "jpeg",
    "quality": 100,
    "colorSpace": "sRGB",
    "dynamicRange": "sdr",
    "metadata": {"keepShootingInfo": false, "keepGps": false}
  }
}
```

`presetId` 不表示资产路径；同一个预设可在不同设备绑定不同的相机线稿。`schemaVersion` 支持升级与兼容检查。品牌和第三方平台名称用于识别目标，不代表品牌方背书。

### 8.2 本地 Asset Library 与 Slot Resolver

```text
Preset.assetSlots[]  --slotId-->  AssetBinding (user/this job/device)
                                          │
                                          ▼
                                Local Asset Library
                                          │
                                          ▼
                                     Renderer
```

- Asset Slot 定义作用、位置、尺寸、是否必需；**不包含用户本地绝对路径**。
- Asset Binding 定义某一用户或任务把 slot 绑定到哪个本地 asset ID；文件真实路径由 Asset Library 管理。
- 找不到素材：`required=false` 时给出可见警告、跳过该图层；`required=true` 时阻止输出并给出可修复错误。
- 安全导入：验证类型、大小、尺寸、编码有效性；导出和分享时不泄露机器用户名、隐私路径、云令牌。
- 用户可选择「本任务绑定」「保存到此预设的本地绑定」「设为本用户默认绑定」。

![图 6：可分享预设只保存布局和 Slot，本地 Binding 把 Slot 绑定到 Asset Library 中的素材，再供 Renderer 使用；可选素材缺失时警告并跳过，必需素材缺失时阻止输出。](docs/illustrations/06-preset-and-local-assets.png)

*图 6 · 预设与素材分离：布局可以分享，私人素材和真实本地路径留在接收者自己的环境中。*

### 8.3 导入／导出／兼容

- 导入前预览预设内容：尺寸、图层、slots、目标格式、schema 版本及可能不可用的能力。
- 不执行任何预设内的代码、命令或脚本；所有字段均为纯数据。
- 检查 ZIP 解压体积、条目数量、路径穿越、资源名冲突与重复 ID。
- 预设修改对现有任务采用**快照**语义：已经排队的任务在创建时绑定具体配置版本，避免排队过程中参数悄然变化。【建议】
- 不兼容的较新 schema：提示升级，不默默丢失字段。

### 8.4 未来 iCloud 策略（非 V1）

- 【已确定：愿景】macOS / iPadOS / iOS 可在未来通过 iCloud 同步个人预设。
- 【V1 不做】CloudKit 实装。
- 预设同步、私有素材同步（可选）、设备本地 Binding 是不同数据层；无绝对路径依赖。
- 不要求注册 PhotoFrame 账号；没有 iCloud 时同样支持手动导入导出。

---

## 9. 任务队列与导出

### 9.1 任务实体与状态

```text
Source (原图)
 ├── Job: IG Standard
 ├── Job: IG Panorama → Cover + Slide_01 ... Slide_0N
 └── Job: XHS Panorama → Cover + Slide_01 ... Slide_0N
```

建议 `JobStatus`：

`queued → validating → decoding → rendering → encoding → writing → completed`

在任意处理中间状态可转至 `failed` 或 `canceled`。重试生成新 Attempt ID，保留原 Job 的历史状态。

- 任务进度以**阶段 / 已完成输出项 / 字节等真实指标**报告，不伪造匀速百分比。
- 支持取消与重试；取消应停止后续编码、删除**自己的临时文件**，不能清理用户原始文件。
- 保存输出清单（路径、尺寸、ICC、文件大小、hash（可选）、警告），可由 GUI/CLI/MCP 读取。

### 9.2 导出目录与命名

```text
~/Pictures/Social Exports/
├── Instagram/
│   └── Badlands_Panorama/
│       ├── 00_Cover.jpg
│       ├── 01_Slide.jpg
│       └── ...
├── Xiaohongshu/
│   └── Badlands_Panorama/
└── Douyin/
    └── Badlands_Panorama/
```

**【建议】** 永不覆盖原图；输出冲突默认自动加版本后缀（或由用户显式确认覆盖）；先写临时文件、校验成功后原子移动到目的地，降低半成品风险。

![图 7：任务从 queued 依次进入 validating、decoding、rendering、encoding、writing 和 completed；处理中可以失败或取消，失败重试创建新 Attempt，写出经过临时目录、校验、原子发布和结果清单。](docs/illustrations/07-job-lifecycle-and-atomic-export.png)

*图 7 · 任务与落盘：处理中可失败或取消；重试保留历史，取消只清理本任务临时文件，成品校验成功后再发布。*

### 9.3 视频与 Live Photo（V1 不做）

- 【已确定：D-16】V1、V2 都不做视频输出。V2 考虑支持 Live Photo；V3 或以后再做视频（如 9:16 完整展示、全景横向平移 MP4）。
- 架构上不为视频预留专门实现，但 Rendering 模块的接口不应假设输出只能是静态图片文件。

---

## 10. 系统架构与模块边界

### 10.1 Frontend / Backend 分离

```text
                              CLIENTS
      ┌────────────────────────┼────────────────────────┐
      │                        │                        │
 macOS App (SwiftUI/AppKit) CLI (photoframe)     MCP (local stdio)
      └────────────────────────┼────────────────────────┘
                               │ Stable API / protocols
                   ┌───────────▼───────────┐
                   │ PhotoFrameApplication │
                   │ ExportService / Jobs  │
                   │ Presets / Asset Slots │
                   └───────────┬───────────┘
                               │
             ┌─────────────────┼─────────────────┐
             │                 │                 │
       PhotoFrameCore   PhotoFrameRendering   Adapters
       Models / Layout  Color / Image          Files / Metadata
             └─────────────────┼─────────────────┘
                               │
                         Local Storage
```

- **GUI 不包含业务核心计算**；所有工具共用统一服务协议。
- `PhotoFrameCore` 尽可能使用跨 Apple 平台可用的纯 Swift 数学、几何和 schema；不依赖 SwiftUI/AppKit。
- `PhotoFrameRendering` 可以利用 ColorSync、ImageIO、Core Image、Core Graphics。封装平台实现，避免它们渗入 Core。
- `PhotoFrameApplication` 管理预设快照、任务、取消、进度、输出清单、权限策略。
- GUI 的实时预览通过**同一 Renderer** 的 preview mode 完成。
- 【建议】每个功能提供独立可测试 Swift Package；错误类型使用稳定 code + human-readable message + recoverable hint。

![图 8：macOS GUI、CLI 和本地 stdio MCP 通过稳定接口调用 PhotoFrameApplication，后者使用 Core、Rendering 和 Adapters 模块及本地存储。](docs/illustrations/08-shared-backend-architecture.png)

*图 8 · 共享后端模块：三入口复用核心服务与渲染实现；这不表示 V1 已要求跨进程共享实时队列。*

### 10.2 建议目录

```text
PhotoFrame/
├── Apps/
│   └── PhotoFrameMac/          # SwiftUI + AppKit
├── Tools/
│   ├── photoframe/            # CLI executable
│   └── photoframe-mcp/        # or `photoframe mcp serve`
├── Packages/
│   ├── PhotoFrameCore/        # Models, geometry, layout, schema
│   ├── PhotoFrameApplication/ # Services, jobs, orchestration
│   ├── PhotoFrameRendering/   # Managed image/video rendering
│   ├── PhotoFrameStorage/     # Presets, local assets, outputs
│   └── PhotoFrameInterfaces/  # Shared API / DTOs
├── Tests/
│   ├── Unit/
│   ├── Integration/
│   ├── GoldenImages/
│   └── ColorManagement/
├── Examples/
│   ├── Presets/
│   └── CLIScripts/
├── Docs/
│   ├── PresetSchema.md
│   ├── RenderingPipeline.md
│   ├── CLI.md
│   └── MCP.md
├── README.md
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE
```

### 10.3 并发与持久化边界

**【建议】V1 不引入常驻守护进程作为先决条件。** GUI、CLI、MCP 各自调用相同的共享 Application/Engine 模块，但不保证在不同进程间共享一个实时任务队列。

- GUI 的队列由 GUI 宿主服务负责；CLI 默认阻塞到当前任务结束或返回机器可读结果；MCP 可在自身进程存活期间管理异步 jobs。
- 如果某个 MCP 客户端关闭并终止 MCP 子进程，正在执行的 job 可能随之取消。用户界面必须说明这个边界。
- **【已确定：D-13】** V1 不做跨进程共享队列。为保留以后升级为「CLI 操控运行中的 GUI」或「共享后台服务」的空间：GUI 不含业务逻辑，所有操作都通过 `PhotoFrameService`；`JobRecord` 等任务状态可序列化，不依赖具体界面或进程。升级时只需新增一层实现同一接口的进程间通信适配器。

---

## 11. 后端 API、CLI 与 MCP

### 11.1 统一数据模型

| 模型 | 关键字段 |
|---|---|
| `PhotoSource` | `sourceId`, file reference, size, orientation, ICC description, metadata |
| `ExportPreset` | `presetId`, `schemaVersion`, canvas, panorama, overlay, format, color policy |
| `AssetSlot` | `slotId`, `kind`, geometry, required, binding intent |
| `AssetBinding` | user-local `assetId`, scoped slot, resolution policy |
| `ExportRequest` | source(s), preset snapshot(s), overrides, destination, confirmation policy |
| `JobRecord` | `jobId`, state, progress stages, attempt, errors, result manifest |
| `ExportResult` | generated file list, output ICC info, dimensions, warnings, duration |

后端 API 尽量以业务语义命名，不与具体 GUI View 或 HTTP 路径绑定。

### 11.2 服务接口（概念）

```swift
protocol PhotoFrameService {
    func listPresets() async throws -> [PresetSummary]
    func inspectSource(_ source: SourceReference) async throws -> SourceInspection
    func validate(_ request: ExportRequest) async throws -> ValidationResult
    func renderPreview(_ request: PreviewRequest) async throws -> PreviewResult
    func submit(_ request: ExportRequest) async throws -> JobIdentifier
    func status(_ job: JobIdentifier) async throws -> JobSnapshot
    func cancel(_ job: JobIdentifier) async throws
}
```

此处仅示意接口边界，实际 `Sendable`、取消语义、事件流和性能要在 Swift 实现阶段定型。

### 11.3 CLI

```bash
# 输出单一平台
photoframe export photo.tif --preset instagram-panorama --output ./exports

# 多个预设
photoframe export photo.tif \
  --preset instagram-panorama \
  --preset xhs-panorama \
  --output ./exports

# 预设管理
photoframe preset list --json
photoframe preset import ./Minimal.photoframe
photoframe preset export my-landscape --output ./My-Landscape.photoframe

# 诊断
photoframe image inspect photo.tif --json
photoframe export photo.tif --preset xhs-standard --dry-run --json

# 让 AI 客户端以 stdio 连接本地服务
photoframe mcp serve
```

- 【已确定】必须支持 CLI，允许脚本调用。
- 【建议】`--json` 输出结构化结果；错误码稳定、stderr 日志与 stdout 数据分离；支持 `--dry-run` 用于校验权限、素材和平台限制。
- 【建议】命令参数优先稳定的短字符串与显式路径；所有非默认文件覆盖需显式标志。

### 11.4 MCP（本地，不对公网）

**【已确定】** V1 提供 stdio MCP，让支持 MCP 的 AI 客户端发现并调用能力，不要求 PhotoFrame GUI 启动。MCP SDK/版本应以实施时官方稳定版本为准。

| Tool | 类型 | 作用 |
|---|---|---|
| `list_presets` | Read | 枚举预设和摘要 |
| `inspect_image` | Read | 读取显式输入图像尺寸、ICC、EXIF 和提示 |
| `list_assets` | Read | 枚举用户授权素材的元信息，不返回未经请求的敏感文件内容 |
| `validate_export` | Read | 校验参数、缺素材、权限、估算成品列表 |
| `preview_export` | Compute | 生成受限的预览文件 |
| `create_export_job` | Write | 在授权目录创建导出任务 |
| `get_job_status` | Read | 查看进度、文件清单、诊断信息 |
| `cancel_export_job` | Write | 取消对应当前服务器拥有的 Job |

**MCP Resources（建议）：** 预设 schema 说明、平台能力表、只读预设摘要；Resources 不应默认暴露任意本地磁盘内容。

**安全规则：**

- 用户通过 MCP 客户端显式配置**允许读取的输入目录**和**允许写入的输出目录**；拒绝其他路径，含符号链接逃逸、相对路径 `..`、硬链接／权限边界等风险。
- 启动参数中不得使用明文写入代码仓库的凭据；V1 无需网络 token。
- AI 发起覆盖、删除、批量写文件必须有显式授权；正常导出默认创建新文件而非覆盖。
- 限制单文件尺寸、处理队列、预览内存、输出总量；对恶意输入文件或预设失败后返回安全错误。
- MCP 协议 stdout 只能写协议消息，调试日志输出 stderr。
- **本地 MCP ≠ 云端 AI 完全隐私保证**：若 AI 客户端会向外部模型发送文件内容，那由客户端策略决定；PhotoFrame 自身不主动上传照片。

---

## 12. 性能、可靠性、安全与隐私

### 12.1 面向高像素摄影

目标数据包括 Nikon Z8 约 45MP 成片、16-bit TIFF、大于 100MP 的接片、超宽幅 65:24 / 3:1 图像。【已确定：D-18】不设输入尺寸上限：输出总会缩放到平台分辨率，内存占用应主要取决于输出尺寸而非输入尺寸。

- 浏览和预览使用降采样解码与缩略图缓存；超过一定分辨率时不按全分辨率渲染预览。
- 导出时尽量直接按输出所需尺寸降采样解码（JPEG 可在解码时缩小；非分块 TIFF 可能需要一次完整解码，是峰值内存的主要来源）。
- 导出使用按需解码、复用颜色变换、tile-based 处理；避免构造数十亿像素的一整张常驻 strip。
- 按像素数估算每个任务的内存需求，根据可用内存决定并行数量；内存不足时改为排队执行。
- 进度、取消、错误由后台执行，不阻塞主线程。
- 处理大图时优先控制峰值内存，并在失败时给出可重试的诊断。

### 12.2 文件与原子性

- 原图只读；默认禁止覆盖，避免输出目录与原始输入相同导致意外覆盖。
- 中间文件使用独立临时目录；写完校验后再原子发布成品。
- 沙盒权限：原生 GUI 使用系统选择器/书签获取授权；CLI/MCP 使用明确的路径授权策略。
- 图像解码、字体文件、SVG/ZIP 等视为不可信输入；防止压缩炸弹、异常维度、内存耗尽和路径穿越。

### 12.3 隐私默认值

- 无账户、无隐性上传、默认不启用分析追踪或远程请求。
- 输出元数据默认全部不写出；拍摄参数与 GPS 为独立可选项，GPS 选项旁显示隐私警告（D-06）。
- 预设导出默认不包含私人签名源文件、相机贴图、本地路径、用户身份信息。
- 程序应提供明确的「导出前元数据预览」或隐私说明。

### 12.4 平台与兼容

- 【已确定：D-01】最低系统 macOS 26，仅支持 Apple Silicon；UI 采用 macOS 26 的系统设计语言。
- 深色/浅色、不同显示器 DPI、不同 locale、中文与英文 UI、键盘操作、VoiceOver。
- CI 在受支持 macOS / Swift 工具链上运行；签名与 Apple 公证可能需要付费开发者账号，**免费开源 ≠ 一定能免费完成 Apple 公证**。

---

## 13. 测试计划与验收标准

### 13.1 单元测试

- Fit 几何：各种横图、竖图、方图，60px minMargin 恒成立、无裁切、居中可复现。
- Panorama：3:1、65:24、比值略大/小于整数边界、手工指定 tile N。
- 素材：slot 存在／缺失／必需／可选、绑定覆盖优先级。
- Preset：序列化 round-trip、schema 兼容／迁移、非法字段、ZIP 攻击输入。
- CLI JSON 和 MCP 工具参数校验、稳定错误码与路径权限。

### 13.2 Golden Image 对照

建议创建授权可再分发的测试图集：

1. 纯色块 + sRGB/Adobe RGB/P3/ProPhoto ICC 版本。
2. 高精度渐变、细线棋盘格、透明 PNG、灰阶图。
3. EXIF 方向 1/3/6/8 的图片。
4. 3:1、65:24、超宽幅及高像素合成图。
5. 无 ICC、错误 ICC、异常 EXIF 和 HDR 源边界测试。

黄金结果应包括：尺寸、排版坐标、色彩转换参考输出、背景 RGB、元数据策略与 warning 列表；文件编码导致的微小差异使用恰当的容差，不把编码字节相同当作跨系统版本唯一成功标准。

### 13.3 性能与压力测试

- 图片队列：1 / 10 / 100 源图、多预设任务，测内存峰值、吞吐、主线程响应。
- 典型文件：45MP JPEG、16-bit TIFF、100MP+ 全景 TIFF；若超过可承诺资源上限，应明确产品限制。
- 导出中取消 / 重试 / 磁盘写满 / 目录不可写 / 输入删除 / 无效图像。
- 中途修改预设、关闭窗口、CLI/MCP 子进程退出时的任务语义一致。

### 13.4 功能验收示例

**AC-01：全景 3:1 到 IG**：输入 3000×1000，输出 1080×1440 的 Cover + 4 张 1080×1440 无缝切片；切片间无单独白边；无裁切。

**AC-02：全景 65:24 到 IG**：输出 Cover + 4 张 1080×1440；总画布 4320×1440，图片长 3900，左右各 210 px `#FAFAF8`（允许亚像素设计→最终边缘采样误差在声明范围内）。

**AC-03：全景 65:24 到 XHS**：输出 Cover + 3 张 1080×1080；照片宽 2925 px，左右 padding 精确值 157.5 px，按 D-22 栅格化为左 157、右 158，以全局像素坐标统一栅格化，无裁切。

**AC-04：缺少 Camera Badge**：导入他人预设时提示空 slot；用户选择本地 PNG 后预览正常；导出的 `.photoframe` 不含该 PNG。

**AC-05：色彩**：带不同 ICC 的输入经管理链路输出 sRGB JPEG，嵌入正确输出 ICC；Preview 采用相同变换策略；没有明显可复现的错误偏色。

**AC-06：CLI/MCP 一致性**：同一源图、预设快照和素材绑定，经 GUI/CLI/MCP 提交时得到**相同布局、输出尺寸、颜色策略和元素位置**；允许因编码器非确定性产生压缩字节差异。

**AC-07：安全**：从 MCP 请求未经授权的任意文件或写出到未授权目录被拒绝；恶意 ZIP 和资源文件不能读取任意其他路径、执行脚本或耗尽不受控资源。

---

## 14. 发布、开源及开发里程碑

### 14.1 推荐里程碑（逐步交付）

| 阶段 | 交付范围 | 主要完成条件 |
|---|---|---|
| **MVP / 0.1** | 基础 Core + CLI、JPEG/ICC/画布、简单 GUI | 单图→IG/XHS 封面，颜色与几何可测 |
| **Alpha 2** | Panorama、跨预设批量、预览共享核心 | 65:24 & 3:1 可无裁切连续切片 |
| **Alpha 3** | 三栏可缩放 UI、任务进度、取消与重试 | GUI 能完成完整批量工作流 |
| **Alpha 4** | 预设 schema、导入导出、Asset Library、Slots、Overlays | 用户可分享布局且不携带私有素材 |
| **Beta 1** | MCP 本地 stdio、CLI 稳定参数、文档 | AI 能校验、预览和安全导出 |
| **Beta 2** | 各平台 HDR 输出、性能、颜色回归、安全审查 | HDR 输出实测通过，大 TIFF 达标 |
| **V1.0** | 跨入口一致性、文档、安装包、许可证、测试 | 本文 V1 Checklist 全部完成或经公开版本说明明确取舍 |

> 【已确定：D-08】CLI 与 GUI 同时开发；GUI 的每项操作都必须能通过 CLI 完成，以便脚本与 AI 调用。GUI 基本参照 Compressor 界面。

### 14.2 开源与发布

- 【已确定】代码公开、应用免费，不以在线服务为使用前提。
- 【建议】GitHub 仓库 + Issues/PR + GitHub Releases + 示例预设 + 可运行自动测试。
- 【已确定：D-20】许可证：Apache-2.0；第三方依赖须与之兼容。README 可放自愿打赏渠道。
- 【待确认】项目正式名称、Bundle Identifier、默认语言和国际化范围。最低系统已定为 macOS 26（D-01）；签名：Alpha/Beta 不签名，V1.0 前决定是否公证（D-20）。
- 附 `README`、`CONTRIBUTING`、`SECURITY`、`LICENSE`，明确第三方用户素材的版权责任。

---

## 15. 风险与权衡

| 风险 | 影响 | 缓解建议 |
|---|---|---|
| Core Image / ColorSync 自动处理不透明 | 色偏、重复转换 | 最先建立 ICC PoC 与 Golden Images；每一步记录 profile |
| 16-bit / HDR 格式差异 | 暗部损失、高光剪裁 | SDR 边界写清；高精度中间链路；HDR 不支持就拒绝 |
| 不同平台的上传行为变化 | 轮播裁切、非预期压缩 | 平台限制可更新；提示上传检查，不夸大保证 |
| 超大接片瞬时内存 | OOM、无响应 | 按 tile 渲染、解码降采样、受控并发 |
| 素材与预设混用版权 | 无授权素材再分发 | 默认只导出 Slots；不随软件附带品牌线稿 |
| UI/CLI/MCP 实现不一致 | 预览与成品不符 | 后端只有一套 Layout + Renderer；跨入口 Golden Tests |
| 免费开源但发布签名成本 | 普通用户安装门槛 | 已有 Apple Developer 账号；Alpha/Beta 发布未公证版本并支持源码构建，V1.0 前决定是否公证（D-20） |
| V1 范围过大 | 发布拖延 | Alpha 分阶段，先保核心闭环；视频已移出 V1（D-16），HDR 输出等依测试成熟度验收 |
| 无常驻进程的 MCP 长任务 | 客户端退出任务中断 | 明确 session 生命周期；未来单独加入 Agent |

---

## 16. 待确认决策清单

> 以下为**真正尚未拍板**或需要技术验证的内容，不代表已确认采用；建议按优先级逐项讨论。

### P0 — 开始编码前

- [x] **D-01** 最低系统版本：**macOS 26+，仅 Apple Silicon**（使用最新系统 UI 设计语言）。【已确定 2026-10-16】
- [x] **D-02** 首批输入格式：**JPEG / PNG / TIFF**；三种格式的 HDR 变体须在首版支持（见 D-05）。**HEIC/HEIF（含 iPhone HDR 照片）放到 V2**：V1 只处理在后期软件里修完、导出后的成片，不处理手机直出照片。【已确定 2026-10-16】
- [x] **D-03** 工作色域与高精度像素格式：**extended linear Rec.2020（`kCGColorSpaceExtendedLinearITUR_2020`）+ `RGBAh`（半精度浮点，预乘 alpha）**，全程不在 `[0,1]` 截断。色彩 PoC 实测三个候选（extended linear sRGB / Display P3 / Rec.2020）数值等价；Rec.2020 下 sRGB、P3、Adobe RGB 与 PQ/HLG 内容都没有负分量，对后续的非线性处理最稳健。详见[色彩 PoC 报告](docs/color-poc-report.md)。【已确定 2026-10-16】
- [x] **D-04** 无源 ICC：**默认假设 sRGB，显示警告，允许按源图或任务覆盖**。【已确定 2026-10-16】
- [x] **D-05** HDR：**V1 支持 HDR 输入与输出**。输入支持所有受支持格式中的 HDR 形式（如 gain map JPEG、PQ/HLG PNG、float/PQ TIFF）；HDR 输出作为可选导出项，由**平台配置决定对应的 HDR 输出格式**（例如带 gain map 的 JPEG），并始终可选择 SDR 输出。【已确定 2026-10-16；具体格式矩阵见 D-17】
- [x] **D-06** 输出默认：**sRGB JPEG，最高质量（Q100）**。EXIF 输出为可选项：「保留拍摄参数」「保留 GPS」，**默认全部隐藏（不写出）**；「保留 GPS」旁显示隐私警告。【已确定 2026-10-16】
- [x] **D-07** 预设包格式：**ZIP `.photoframe` + `manifest.json`**。【已确定 2026-10-16】
- [x] **D-08** 开发顺序：**CLI 与 GUI 同时开发**；GUI 的所有操作都必须能通过 CLI 完成，以便 AI 调用；GUI 基本参照 Compressor 界面。【已确定 2026-10-16】
- [x] **D-21** 裁切：**默认 Fit 完整嵌入，不裁切**；按比例裁切作为用户主动开启的可选模式，预览中须显示裁切范围。全景切片模式始终不裁切。【已确定 2026-10-16】
- [x] **D-22** 栅格取整：**不动照片，只动 padding**。照片像素尺寸取精确值最近的整数（.5 进位，不超过内框），左／上留白取 floor，右／下取剩余，两侧可相差 1 px；Fit 与全景长卷共用（§5.2、§5.3）。【已确定 2026-10-16】

### P1 — Alpha 期间

- [x] **D-09** 素材格式：**PNG + 受限 SVG**。SVG 只支持基本图形与路径，禁止脚本、外部引用与远程资源。【已确定 2026-10-16】
- [x] **D-10** 全景切片上下边距：**支持一个所有切片统一的上下边距，默认 0（铺满高度）**；切片张数随边距重新计算，接缝仍须连续。【已确定 2026-10-16】
- [x] **D-11** 切片张数：**默认自动取最少张数，只允许手动改多**。改多：两端补更多底色；少于自动张数视为参数错误（不缩小照片）；任何情况都不裁切。【已确定 2026-10-16】
- [x] **D-12** 装饰图层默认**以照片边缘为参照**定位（如「照片右下角下方 16 px」），图层跟随照片位置变化。【已确定 2026-10-16】
- [x] **D-13** 任务进程模型：**V1 各入口独立运行**，CLI/MCP 直接调用后端完成导出，不需要 GUI，也不进入 GUI 队列。以后可升级为「CLI 操控运行中的 GUI」或「共享后台服务」，为此须守住两条约束：GUI 不含业务逻辑，所有操作都走 `PhotoFrameService`；任务状态与记录可序列化，不依赖具体界面或进程。【已确定 2026-10-16】
- [x] **D-14** 素材绑定优先级：**单任务 > 预设本地绑定 > 用户全局绑定**。【已确定 2026-10-16】
- [x] **D-15** 预设版本与 ID：**整数 `schemaVersion`**，旧版本自动迁移，较新版本提示升级；**`presetId` 使用 UUID**；自定义字段以 `x-` 开头，程序不识别时原样保留。【已确定 2026-10-16】

### P2 — Beta / 发布前

- [x] **D-16** 视频：**V1、V2 都不做视频**；V2 考虑 Live Photo；V3 或以后再做视频。【已确定 2026-10-16】
- [x] **D-17** 格式矩阵：**所有平台都提供 HDR 输出选项**，并都可导出 SDR（8-bit sRGB JPEG / PNG）。Instagram 的 HDR 用带 gain map 的 JPEG；小红书、抖音的 HDR 上传效果由用户实测确认后写入平台配置。【已确定 2026-10-16；XHS/抖音待实测】
- [x] **D-18** 产品限制：**不设输入尺寸上限**。输出始终缩放到平台支持且不会被二次压缩的最大分辨率，因此任意大小的输入都可接受。实现要求：
  - 预览：超过某一分辨率时不按全分辨率渲染，按需降采样解码。
  - 导出：尽量按输出所需尺寸降采样解码；按像素数估算每个任务的内存，根据可用内存决定并行数量，内存不足时改为排队执行。
  - 轮播张数上限仍写在平台配置中，超出时警告（§5.3）。【已确定 2026-10-16】
- [x] **D-19** 色彩验收阈值：**暂定 ΔE2000 中位数 ≤ 1、95 分位 ≤ 2**；基线为开发者本机 Apple Silicon Mac + macOS 26。色彩 PoC 用真实样本验证后定稿。【暂定 2026-10-16】
- [x] **D-20** 发布与开源：
  - 许可证：【已确定】**Apache-2.0**。允许接受自愿打赏；不妨碍以后上架 Mac App Store（GPL-3.0 与其条款冲突，故未选）。
  - 签名：【已确定】Alpha/Beta 先不签名；已有 Apple Developer 账号，V1.0 前再决定是否公证。
  - 素材贡献：【已确定】V1 不接受任何素材贡献，仓库只放代码与预设。

---

## 17. V1.0 验收 Checklist

### 用户体验

- [ ] macOS GUI 三栏可拖动调整，预览区与设置区可调高度；关闭重开恢复布局。
- [ ] 导入多张图片，拖放或按钮应用多个预设，任务状态可见。
- [ ] 输入图像方向正确，缩略图与最终导出内容一致。
- [ ] 画布颜色、边距、对齐、导出格式在 Inspector 中可编辑并持久化。

### 输出几何

- [ ] IG 3:4 / XHS 1:1 / Douyin 9:16 默认预设可正常导出。
- [ ] 普通封面不裁切，最小边距遵守规则。
- [ ] 3:1 和 65:24 全景输出完整封面与对应连续切片。
- [ ] 细节页无独立左右白边；总画布不足部分只在最外侧补背景。
- [ ] 图片与装饰文字在预览和导出中位置一致。

### 色彩管线

- [ ] 识别输入 ICC、EXIF Orientation、位深和 Alpha。
- [ ] 无 ICC 时给出警告，并允许用户覆盖输入色彩空间假设。
- [ ] 广色域与 16-bit TIFF 处理有明确、可验证的颜色语义。
- [ ] `#FAFAF8` 在受控 sRGB 输出下数值正确。
- [ ] sRGB JPEG 嵌入正确 ICC，输出无系统性色偏。
- [ ] 色彩/Alpha Golden Tests 完成；HDR 输入不静默错误处理。
- [ ] 各平台 HDR 输出在 HDR 屏幕正确显示，上传后效果经实测确认。

### 预设与素材

- [ ] 预设可创建、复制、编辑、导入、导出、分享。
- [ ] `.photoframe` 不携带个人素材、绝对路径或秘密字段。
- [ ] Asset Library 可本地导入；Slots 支持绑定与缺失处理。
- [ ] 水印、相机图标、EXIF 参数可选；全景切片默认不重复装饰。
- [ ] 旧 schema 可以按规则迁移；不兼容新版预设有明确提示。

### CLI / MCP / 后端

- [ ] CLI 独立执行时不依赖 GUI，支持 `--json` 与 `--dry-run`。
- [ ] 本地 stdio MCP 能发现预设、检查图像、校验、预览与导出。
- [ ] GUI、CLI、MCP 使用相同核心，跨入口回归结果一致。
- [ ] 任务取消、失败、重试和输出记录行为清晰。
- [ ] MCP 不能越权访问任意目录，不能无提示覆盖用户文件。

### 发布质量

- [ ] 大像素 TIFF 和批量测试无未受控 OOM／主线程卡死。
- [ ] 输出文件夹、失败提示、日志和文档可用于用户排查问题。
- [ ] 开源许可证、构建指南、贡献指南和安全报告渠道完善。
- [ ] 无账户、无远程服务、离线可完成全部 V1 核心处理工作。

---

## 附录 A：已确认与未来规划的最终边界（速查）

**已确定：** Mac 原生优先、免费开源、前后端模块分离、Compressor 三栏可缩放、照片完整嵌入、IG 3:4 / XHS 1:1 / Douyin 9:16、默认 `#FAFAF8` 和 60px 最小封面边距、无裁切全景连续切片、可选水印/相机贴图/EXIF、本地素材与 Slot、可分享预设、批量任务、CLI、本地 stdio MCP、摄影级色彩管理。

**已确定（2026-10-16 P0 审阅）：** macOS 26+ / Apple Silicon、JPEG/PNG/TIFF 输入、HDR 输入与可选 HDR 输出、无 ICC 假设 sRGB 并警告、JPEG Q100 且元数据默认不写出、ZIP `.photoframe`、CLI 与 GUI 同步开发、默认不裁切（裁切可选）。

**已确定（2026-10-16 P1/P2 审阅）：** PNG + 受限 SVG 素材、切片统一上下边距、自动切片张数只可手动改多、图层以照片为参照、各入口独立进程（可升级）、绑定优先级、UUID 预设 ID、所有平台提供 HDR 选项、不设输入尺寸上限（按内存调度）、暂定 ΔE2000 阈值、暂不签名、V1 不收素材贡献。

**已确定（2026-10-16 色彩 PoC）：** 工作空间 extended linear Rec.2020 + `RGBAh`（D-03）。

**尚待技术定稿：** 小红书/抖音 HDR 实测结果、色彩阈值定稿（D-19）。许可证已定为 Apache-2.0（D-20）。

**V1 不做：** Discord/Telegram Bot、对公网 HTTP API、Remote Render/Web Remote、官方云服务、iCloud Sync、Windows、iOS/iPadOS 原生版、RAW 显影与全景拼接、社交平台直接发布、HEIC/HEIF 输入（含 iPhone HDR，放到 V2）、视频输出（V2 考虑 Live Photo，V3 及以后再做视频）。

**未来方向（独立设计，不进入 V1 的实现依赖）：** 用户自托管 Remote Service / 网络配置、Mac 渲染节点、Shortcuts / Discord、CloudKit 预设同步、iPadOS/iOS 共享 Core、Windows 由社区或其他技术栈接入。

---

*文档结束。建议下一轮审阅先从 §6「色彩管线」和 §16「P0 待确认决策」开始。*
