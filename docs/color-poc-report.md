# 色彩 PoC 报告：D-03 工作色彩空间与像素格式

> 状态：**已完成**。包括合成样本、Lightroom HDR 真实样本（3 张 × 3 种格式）和 SDR 四色彩空间真实样本（2 张）。
> **D-03 已由用户确定（2026-10-16）：extended linear Rec.2020 + RGBAh**，并已写进规范 §6.4 和 §16。文中提到的其它规范问题（§9）仍然只列出，等待讨论，不改规范。

## 0. 结论摘要

- **推荐 D-03：工作空间用 extended linear Rec.2020（`kCGColorSpaceExtendedLinearITUR_2020`），像素格式用 `RGBAh`（半精度浮点，预乘 alpha）。**
- 三个候选在本管线里**数值上等价**：色卡 ΔE、背景值、透明边缘、方向、HDR 保留、gain map 读回、tone map 结果都相同或差异 ≤ 1 个 8-bit 码值。原因是管线里的操作（色彩矩阵、缩放、预乘合成）都是线性的，而 extended 浮点格式里没有任何一步截断。
- 所以选择要看**稳健性**：在 Rec.2020 里，sRGB、Display P3、Adobe RGB 以及 PQ/HLG HDR 内容都落在非负区间，只有 ProPhoto 的极端颜色才是负值；换成 extended linear sRGB，所有 P3 / Adobe RGB 饱和色都会变成负值。负值正是后面最容易出事的地方：非 extended 的 CG 上下文、ImageIO 编码器、Metal unorm 纹理都会截掉负值，自定义的非线性 kernel（tone curve、gain map 比值、色域压缩）遇到负值也会出错。
- **真实照片验证了同样的结论**（Lightroom 导出的 3 张 HDR × 3 种格式，以及 2 张 SDR × 6 种色彩空间/格式）：三个空间的 SDR 输出之间 ΔE 中位 0.00、P95 ≤ 0.51，没有截断。HDR 写出再读回，亮度误差 P95 ≤ 3.2%（§8）。
- **D-19：** 合成色卡在 sRGB 色域内的颜色远低于暂定阈值。最差的情况是 8-bit ProPhoto JPEG 输入、JPEG Q100 输出，中位数 0.44、P95 1.04；16-bit TIFF 输入、PNG 输出为 0.05 / 0.27。阈值只能对 sRGB 色域内的颜色定义，超出 sRGB 的颜色需要另定映射策略。真实照片（Lightroom 同一张照片导出四种色彩空间）同样达标：16 位 TIFF 的 ΔE 为 0.00，8 位 JPEG 最差的是 ProPhoto，中位 0.52、P95 1.76（§7）。
- 同时查到 20 个会悄悄改颜色或出错的坑（§5）。最重要的几个：ImageIO 写 sRGB JPEG **不嵌 ICC**；ImageIO 写 gain map 时如果 CGImage **没带 headroom，HDR 会被静默丢掉**；**Lanczos 缩放会在透明边缘和照片边缘振铃**；**CI 的自动 tone map 只在某些图结构下生效**；**CI 直接使用大尺寸 32 位浮点源图会渲染出错位图块**（Lightroom 32 位 TIFF 实测，需要先转 RGBAh）。

## 1. 环境与复现

| 项 | 值 |
|---|---|
| 机器 | Apple Silicon Mac |
| 系统 | macOS **27.0.1**（26A434）。注意：D-19 写的基线是 macOS 26，本机已经是 27 |
| 工具链 | Xcode 27.0（27A266a），Swift 6.4 |
| 代码 | `Experiments/ColorPoC/`（独立 Swift 命令行包，不属于 `Packages/`） |

```bash
cd Experiments/ColorPoC
swift run -c release colorpoc fixtures          # 重新生成 fixtures/（逐字节可复现）
swift run -c release colorpoc run               # 跑全部实验 → out/results.md / results.json
swift run -c release colorpoc run --real <目录>  # 额外跑本地真实照片（照片不入库）
```

`out/` 不入库。本次运行的完整表格快照在 [`Experiments/ColorPoC/results/synthetic.md`](../Experiments/ColorPoC/results/synthetic.md)。一次完整运行约 20 秒。

## 2. 测试方法

### 2.1 测试图（`Experiments/ColorPoC/fixtures/`，全部由程序生成）

| 文件 | 内容 | 目的 |
|---|---|---|
| `chart_{srgb,adobergb,p3,prophoto}.jpg` / `_16.tif` | 同一张 96 色块色卡（24 色 ColorChecker + 灰阶 + 饱和色 + 随机色，全部在 sRGB 色域内），分别编码进四种 ICC；8-bit JPEG Q100 与 16-bit TIFF 各一套 | ICC 转换 ΔE |
| `chart_noicc.png` / `.jpg`、`chart_p3values_noicc.png` | 无任何颜色描述：sRGB 数值，以及"P3 数值但丢了 ICC" | D-04 行为 |
| `wide_prophoto_16.tif`、`wide_p3_16.tif` | 在 ProPhoto / P3 中取 {0, .35, .7, 1}³ 立方体 + 32 色，很多超出 sRGB/P3/2020 | 中途截断 |
| `gradient_prophoto_16.tif`、`gradient_dark_srgb_16.tif` | 4096 px 16-bit 中性渐变（ProPhoto 0→1；sRGB 暗部 0→0.2） | 断层 |
| `watermark_alpha.png` | 直通 alpha，透明像素 RGB 故意为黑；含抗锯齿圆环、细条、50% 白块、50% 红块 | 黑边 / 白边、合成所在的域 |
| `orientation_{1,3,6,8}.jpg` | 四象限不同色，存储像素按方向反向旋转 | EXIF 方向 |
| `hdr_gainmap.jpg` | ISO 21496-1 gain map JPEG（ImageIO 编码，headroom 8） | HDR 输入 |
| `hdr_pq2020_203nit.png` | 16-bit PQ + Rec.2020，SDR 白 = 203 nits | HDR 输入 |
| `hdr_float_linear2020.tif` | 32-bit float，线性 Rec.2020，峰值 8.0 | HDR 输入 |

HDR 场景：第 0 行中性色块线性亮度为 0.05 / 0.18 / 0.5 / 0.75 / **1.0** / 1.5 / 2 / 3 / 4 / 5 / 6 / 8（以 SDR 参考白为 1）；第 1 行是彩色高光（含 P3、Rec.2020 原色）；另有 SDR 色卡和 0→8 渐变。

**真值独立于被测框架。** 像素值和期望值都由 `ColorMath.swift` 的参考数学算出（原色矩阵、Bradford、TRC 按 Apple ICC 实际标签实现、CIEDE2000、PQ），不靠 Apple 框架自己验证自己。交叉验证：ColorSync（`CGColor.converted`）把四种 ICC 的色卡转到 sRGB，与参考数学的 ΔE 最大只有 0.013（P8）。

### 2.2 被测流程（每个候选空间跑同一条）

```text
ImageIO 解码（CIImage(contentsOf:, applyOrientationProperty, expandToHDR)）
 → CI 在渲染时把源 ICC 转入工作空间（CIContext.workingColorSpace = 候选，workingFormat = RGBAh）
 → clampedToExtent → CILanczosScaleTransform → 裁到整数尺寸 → 放进 1080×1350 画布（留白 90）
 → 合成到 #FAFAF8 背景（CIColor，sRGB）→ 叠加缩放 0.6 的透明水印
 → 输出：SDR sRGB 8-bit PNG / JPEG Q100；HDR：带 gain map 的 JPEG（CI 与 ImageIO 两条路线）
```

HDR 源输出 SDR 时，tone map 只作用于照片图层；背景和水印本来就是 SDR，按参考白放置。

### 2.3 测量

- **ΔE2000**：96 个色块内部像素对真值（D65 Lab），给出中位数 / P95 / 最大值。
- **两次转换**：（a）比较 ImageIO 解码出的像素与写入值，看解码是否改了像素；（b）关闭 CI 色彩管理做对照；（c）CI 直接渲染的 RGBA8 与写出的 PNG 文件逐字节比较，看编码器有没有再转一次；（d）ΔE 是否只剩量化误差。
- **截断**：在工作空间中渲染为 RGBAf，与真值比较。"需 extended"指真值超出 [0,1] 的像素；"被截断"指其中观测值被压回 [0,1] 的像素。测三处：解码后（S1）、合成后（S2）、CG 绘制后。
- **断层**：在不缩放的渐变行上统计码值级数、最大台阶和回退次数，并与理想值比较。8-bit 与 16-bit 输出都测。另做两个故意制造的 8-bit 中间结果作反例。
- **背景**：无损 PNG 中，照片和水印外扩 4 px 以外的所有像素是否都恰好等于 (250,250,248)。
- **透明边缘**：任一通道超出 [min(背景,前景), max(背景,前景)] ±1 的像素数及最大偏差；50% 块的实测值与"线性光合成 / gamma 空间合成"两种理想值对照。
- **HDR**：k 值（1.0 色块的实测 Y）、各级亮度比、截断数；gain map 写出后读回：headroom、各级比值、高光色度偏移 Δu′v′、SDR 回退底图的背景值，以及底图与期望 SDR 渲染的 ΔE。

## 3. 各候选结果

### 3.1 汇总

| 指标 | extLinearSRGB | extLinearP3 | extLinear2020 |
|---|---|---|---|
| 色卡 ΔE，16-bit TIFF → PNG（四种 ICC 中最差）中位 / P95 | 0.05 / 0.21 | 0.05 / 0.22 | 0.05 / 0.27 |
| 色卡 ΔE，8-bit JPEG → JPEG Q100（最差：ProPhoto）中位 / P95 / max | 0.44 / 1.04 / 1.94 | 0.44 / 1.04 / 3.05 | 0.44 / 1.04 / 3.05 |
| 编码器额外转换（CI 直出 vs PNG 文件最大差） | 0 | 0 | 0 |
| 无损 PNG 背景 ≠ (250,250,248) | 0 / 880,144 | 0 / 880,144 | 0 / 880,144 |
| ProPhoto 广色域图需 extended 的像素（S1） | 427,424（77%） | 410,096（74%） | 375,440（68%） |
| P3 广色域图需 extended 的像素（S1） | 329,232（59%） | **0** | **0** |
| 中途被截断像素（CI S1 / S2 / CG extended 上下文） | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| 渐变 8-bit 输出：级数 / 最大误差（RGBAh） | 256/256 / 1 | 256/256 / 1 | 256/256 / 1 |
| 渐变 16-bit 输出级数（RGBAh / RGBAf，理想 4095） | 3810 / 4095 | 3811 / 4095 | 3810 / 4095 |
| 透明边缘（Lanczos / 双线性）偏暗像素 | 1275 / 0 | 1275 / 0 | 1275 / 0 |
| 50% 白块叠在 (32,32,32) 上（线性光理想 189，gamma 理想 144） | 189 | 189 | 189 |
| EXIF 方向 1/3/6/8 | 全部正确 | 全部正确 | 全部正确 |
| HDR 解码 + 合成截断（PQ / float / gain map） | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| HDR→SDR tone map 结果与 extLinearSRGB 的差（ΔE 中位 / max） | — | 0.00 / ≤1.23 | 0.00 / ≤1.23 |
| gain map 写出→读回，headroom 内最大相对误差（CI 路线） | ≤ 1.5% | ≤ 2.3% | ≤ 2.3% |

8-bit JPEG 色卡 max 一列在不同空间间有差别（1.94 / 3.05），来自 JPEG 编码在个别像素上的差异。中位数和 P95 完全相同，不算系统差异。

### 3.2 结果要点

- **ICC 转换正确，且只转两次。** 四种 ICC 的 16-bit 输入输出后 ΔE 中位都只有 0.05，等于 8-bit 量化本身的误差。ImageIO 解码不改像素（P1：16-bit 最大差 0.5 码值，只有取整误差；float 完全一致）。关闭 CI 色彩管理后，ProPhoto 的 ΔE 从 0.05 跳到 7.97（P5），说明转换由 CI 完成。编码器没有再转一次（CI 直出与 PNG 文件逐字节相同）。所以整条管线只有两次必要的转换：源→工作空间、工作空间→输出。
- **无 ICC 的输入按 sRGB 处理。** sRGB 数值的文件 ΔE 正常；"P3 数值丢了 ICC"的文件 ΔE 为 2.37 / 4.11。这正是 D-04 需要警告的情形。
- **广色域与 HDR：三个候选都没有中途截断。** 前提是全程 extended + 浮点。
- **超出 sRGB 的颜色在 SDR 输出时被逐通道截断。** CI 不做感知映射：ProPhoto 极端色 ΔE 中位 11、最大 28；P3 色 ΔE 中位 3.3、最大 9.2。三个候选完全相同。§6.9 要求的"明确的映射策略"目前还不存在，需要另做色域压缩（§6）。
- **精度：** 8-bit 输出下 RGBAh 与 RGBAf 无可见差别（级数都是 256/256，最大误差 1 / 0 码值）。16-bit 输出下 RGBAh 只有理想级数的 93%，最大误差 20/65535。反例"8-bit sRGB CGImage 中转"让 16-bit 输出只剩 256 级，说明检测有效。

## 4. 各框架在哪一步做了隐式转换

| 步骤 | 组件 | 改像素吗 | 实测要点 |
|---|---|---|---|
| 读文件、解码 | ImageIO | **否** | 原值加颜色空间标签（P1）。无 ICC 的 PNG/JPEG 一律标成 sRGB（P2） |
| 降采样解码（缩略图 API，D-18） | ImageIO | 只缩放 | 保留原颜色空间和位深（16-bit、32-bit float 都保留）；gain map 加 `DecodeToHDR` 时返回 10-bit PQ（P3） |
| HDR 展开 | CI `expandToHDR` | 是 | gain map JPEG 展开成 `DisplayP3_PQ` 的 CIImage；PQ 203 nits 解码为线性 1.0（k = 1.000） |
| 源 → 工作空间 | **CI**（渲染时自动插入） | 是，1 次 | 按 ICC 矩阵 / TRC 计算，与 ColorSync 及参考数学一致（ΔE ≤ 0.013） |
| 背景色 | CI（`CIColor`） | 是，1 次 | `CIColor(red:green:blue:)` 默认就是 sRGB，三种写法都得到精确的 (250,250,248)（P4） |
| 缩放、合成 | CI | 否（线性运算） | 预乘、线性光合成；结果与工作空间无关 |
| 工作空间 → 输出 | **CI** render / write | 是，1 次 | 超出目标色域时逐通道截断 |
| 编码 | ImageIO | **否，前提是交给它 sRGB 8-bit CGImage** | 交给它 float 或 extended 的 CGImage 时会自作主张转换（P6，见坑 3） |
| CG 绘制 | CG / ColorSync | 是 | 画入时转到上下文的颜色空间；非 extended 的上下文会截断（P7） |
| HDR 编码（ImageIO 路线） | ImageIO | 是 | 自己做 tone map 生成底图，底图强制为 Display P3（P10） |

## 5. 发现的坑

1. **ImageIO 无法区分"无 ICC"和"sRGB"。** 无 ICC 的 JPEG，`kCGImagePropertyProfileName` 仍然返回 `"sRGB IEC61966-2.1"`；无 ICC 的 PNG 返回 nil。两者解码后的 CGImage 和 CIImage 颜色空间都是 sRGB。要实现 D-04 的警告，必须自己解析文件：JPEG 的 APP2 ICC_PROFILE，PNG 的 iCCP / sRGB / cICP，TIFF 的 34675 标签。
2. **ImageIO 写 sRGB JPEG 时不嵌 ICC。** 只写 EXIF `ColorSpace=1`。用 ICC 数据重建的 `CGColorSpace` 也一样；P3 则会正常嵌入。CI 写 PNG 时用的是 `gAMA + cHRM`（sRGB 的近似描述），ImageIO 写 PNG 时用 `sRGB` 块。§6.8 要求"嵌入正确 ICC"。如果坚持这一条，JPEG 需要在编码后自己插入 APP2 ICC 段。**这件事需要用户决定。**
3. **ImageIO 编码器会自作主张转换。** 把 extended linear sRGB 的 half-float CGImage 交给 JPEG 编码器，写出的是 8-bit **线性** sRGB ICC 的 JPEG（暗部断层）。交给 PNG 编码器时，它按内容选择 8-bit LinearSRGB 或 16-bit Display P3。TIFF 则保留 float。规则：编码前必须由 CI 明确渲染到目标空间和位深（sRGB RGBA8）。
4. **ImageIO 写 gain map 依赖 CGImage 的 headroom。** extended 线性 CGImage 如果没用 `CGImageCreateCopyWithContentHeadroom` 标 headroom，会被当成 SDR 写出：读回时 headroom 显示 4.93，像素却都 ≤ 1，HDR 被静默丢弃。PQ CGImage 的 headroom 固定为 4.93（即 1000 nits），更亮的部分被截断。`kCGImageDestinationEncodeBaseColorSpace = sRGB` 被忽略，底图永远是 Display P3。它还会把背景一起 tone map：SDR 底图的背景偏差 89 码值，违反 §6.7"SDR 元素按参考白放置"。gain map 只有半分辨率。**结论：不用 ImageIO 路线。**
5. **CI 写 gain map（`writeJPEGRepresentation` + `.hdrImage`）是可用的路线。** 底图 sRGB 并嵌 ICC；底图与我们自己的 SDR 渲染 ΔE 中位 0.00；背景偏差 ±1–2（JPEG 误差）；HDR 读回误差 ≤ 2.3%；gain map 全分辨率、8-bit 单通道。加 `.hdrGainMapAsRGB` 改成 RGB gain map 后，PQ 源的高光色度误差 P95 从 0.0236 降到 0.0173。真实照片上还必须显式标 headroom（坑 17）。
6. **tone map 有好几种，结果差异很大（P11）。** `CIToneMapHeadroom`、`CISystemToneMap`、ImageIO `DecodeToSDR` 用的是同一条曲线：headroom 4.93 时参考白映射到 188/255，headroom 8 时映射到 160/255，SDR 内容整体变暗（ΔE 12–17）。CI 还会**隐式** tone map：直接把带 headroom 元数据的 HDR CIImage 渲染到 SDR 时，用一条软肩曲线（1.0 → 229）。但图像合成之后 headroom 元数据丢失，就变成硬截断。这意味着"单张预览"和"合成后导出"可能不一致。`.toneMapHDRtoSDR` 选项等于这条软肩曲线。ImageIO `DecodeToSDR` 用在 float TIFF 上直接输出全黑。float TIFF 的 `contentHeadroom` 为 0，需要自己用 `calculateHDRStats` 计算。
7. **Lanczos 振铃。** 照片直接用 Lanczos 缩放（边外为透明）时，照片内沿 3 px 振铃，最大偏差 21 码值；先 `clampedToExtent`、缩放后再裁到整数尺寸，降到 1。透明水印用 Lanczos 缩放时，在深色背景上出现黑圈，最大偏差 32 码值（直接到 0）；在浅色背景上出现白边，最大 5 码值；用双线性则都是 0。CG 的高质量插值也有同样的问题（274 像素）。透明素材不要用 Lanczos。
8. **CG 的两个陷阱（P7、§4 表）。** 非 extended 的线性上下文（`linearSRGB`、`linearITUR_2020`）会截断广色域：ProPhoto 测试图分别截断 410,096 和 277,248 像素；extended 上下文为 0。8-bit sRGB 上下文在 gamma 空间合成：50% 白块叠在深色上得到 144，线性光应为 189。用 CG 画文字或矢量水印时，必须画进 extended 浮点上下文。
9. **CI 的 `workingFormat` 往往不起作用。** 没有中间缓冲时，CI 把整条链合成一个 kernel，工作格式根本不参与；设成 RGBA8 也测不出 8-bit 断层。真正的精度风险在我们自己创建的中间 CGImage、CVPixelBuffer 和缓存。
10. **HDR 参考白。** Apple 把 PQ 203 nits 映射为线性 1.0（BT.2408）。PQ/HLG 默认 headroom 4.93（1000 nits）。`CIColor`、背景和水印的值 ≤ 1，正好落在参考白，不会随 headroom 一起变亮（实测合成后背景线性 Y = 0.9547，等于期望值）。
11. **超出 sRGB 的颜色在 SDR 输出时被逐通道截断**（§3.2）。真实照片里饱和的天空和花卉会受影响。需要一个显式的色域压缩步骤；它是非线性运算，放在 Rec.2020 里做最省心，因为没有负值。
12. **Apple 的 ROMM（ProPhoto）ICC 曲线和标准不同。** 它用 parametric type 3，g = 1.8、c = 1/16、d = 1/512，在 1/512 处不连续，与 ROMM 标准的线性段定义不一样。只影响 16-bit 码值 128 以下的极暗部，可以忽略。参考数学已经按 Apple 的实际曲线实现。
13. **输出元数据。** CI 写 JPEG 时带 Exif（ColorSpace、尺寸、版本、SceneCaptureType）和 TIFF（分辨率；HDR 文件还有 Orientation=1），不带相机参数或 GPS。D-06 说"默认全部不写出"，这些结构性字段算不算，**需要用户决定**。
14. **JPEG Q100 的 ImageIO 实现是 4:4:4，量化表全为 1。** 背景附近仍有最多 4 码值的 JPEG 误差，所以背景精确性应该用 PNG 验收，规范 §6.5 也是这么写的。

以下四条是用 Lightroom 真实样本才发现的：

15. **Core Image 直接使用大尺寸 RGB 32 位浮点源图时，会渲染出错位的图块。** 这类源图每像素 96 bit、无 alpha，Lightroom 的 32 位 HDR TIFF 就是这种。缩放后部分区域会出现其它位置的内容或纯白块，坏像素 7–27%。是否出错取决于图的结构（`clampedToExtent`、双线性还是 Lanczos）和工作空间，但对同一种写法结果是固定的、可复现的。用程序生成的 8256×5504 浮点图同样能复现；4128×2752 时只在个别组合下出现。解码后先用 CG 转成 RGBAh 再交给 CI，或者用 ImageIO 缩略图 API 降采样解码，都能完全避开。16 位 TIFF 和 JPEG 没有这个问题。PoC 现在对 32 位浮点源一律先转 RGBAh。
16. **32 位浮点 TIFF 没有 headroom 元数据。** 它的颜色空间 `isHDR() == false`，`contentHeadroom` 为 0，CI 的 `calculateHDRStats` 也只返回 1。如果直接把 headroom 交给 tone map，等于不压缩，高光被硬截断。需要自己根据画面内容估算。
17. **照片合成之后，CI 写 gain map 时会自己推断出偏低的 headroom。** 合成后的图丢失了 `contentHeadroom`：grand_teton 源 headroom 是 3.28，CI 推成 1.68，导致高光读回误差中位 11%。在写出前用 `settingContentHeadroom` 显式标上源 headroom，并改用 RGB gain map（`.hdrGainMapAsRGB`）后，高光误差降到 0.4%，Δu′v′ 降为约 1/10。
18. **读过属性后，`CGImageSourceGetType` 会把 Lightroom 的 gain map JPEG 报成 `public.heic`。** 先调用 `CGImageSourceGetType` 再读属性，才能拿到正确的 `public.jpeg`。正式代码判断输入格式时要么最先取类型，要么自己看文件头。
19. **Lightroom 勾选 Maximize Compatibility 导出的 HDR TIFF，Apple 只读得到 SDR，HDR 被静默丢掉。** 这种 TIFF 的主图（IFD0）是 Lightroom 的 SDR 版本，gain map 放在 SubIFD 里：Photometric 用了 Apple 不认识的值 52553，元数据在私有标签 52557 里，按 ISO 21496-1 二进制格式解析得到 alternate headroom 2.64、RGB 三通道，和同一张照片 JPEG 里的 gain map 一致。ImageIO 和 CI 都忽略这个 SubIFD：`contentHeadroom` 为 1，也不报告 gain map。要支持这种文件，必须自己检测 SubIFD，否则至少要提示"HDR 部分未读取"。
20. **Apple 会把 Lightroom 16 位 SDR "Rec. 2020" TIFF 解得偏暗。** 这份 ICC（v4，504 B）的 TRC 是 BT.709/2020 OETF 的逆曲线（para type 3，g = 2.222），和像素的实际编码完全吻合（误差 0.1%）。但 CG/ColorSync 和 CI 实际都按 γ2.4 解码：线性值只有正确值的 84%，比 Lightroom 自己的 SDR 版本暗 8.8 个 L*。同样设置导出的 32 位线性 TIFF 不受影响，与 JPEG 的 SDR 底图 ΔE 中位 0.00。 **有两种已验证的绕开办法，都能把线性值还原到真值的 99.97%：** 一是取 ImageIO 解出的原始码值（解码不改像素），自己按逆 OETF 线性化，再标成线性 Rec.2020；二是把 ICC 里的参数曲线改写成 4096 点采样曲线（`curv`）后，再交给 Apple 解码。第二种不用自己处理像素，可以作为通用的预处理：凡是带参数曲线的 ICC 都先改写一遍。

## 6. D-03 推荐与理由

**推荐：extended linear Rec.2020 + RGBAh（预乘）。**

1. **三者实测等价。** 本管线里没有一项指标能把三个候选区分开（§3.1），所以决策依据是对后续开发的稳健性，而不是当前数值。
2. **非负覆盖面最大。** sRGB、Display P3、Adobe RGB、PQ/HLG（BT.2100 本身就是 Rec.2020）在 Rec.2020 里都没有负分量，只有 ProPhoto 的极端颜色是负值。extended linear sRGB 下，P3 测试图有 59% 的像素需要负值或大于 1 的值；Rec.2020 下为 0。真实照片里，extended linear sRGB 下有 0.3–4.0% 的像素需要负分量，Rec.2020 下只有 0.1–0.9%，而且几乎全是边缘振铃。
3. **负值是后续最可能出问题的地方。** 坑 3、坑 8：编码器和非 extended 的 CG 上下文会截掉负值。还有要新写的非线性步骤：色域压缩（坑 11）、HDR→SDR tone curve（坑 6）、gain map 比值。它们在负值上要么出错，要么需要额外处理。
4. **和 HDR 输入天然对齐。** PQ/HLG 是 Rec.2020，Lightroom 的 HDR 导出也提供 Rec.2020 选项。
5. **代价：** 实测没有性能或精度差异。需要注意：CI 的默认工作空间是 extended linear sRGB，所以必须显式设置 `workingColorSpace`；某些 CI 内置滤镜（例如饱和度、亮度类）的亮度系数可能按 sRGB 原色写死，改用 2020 后行为会略有不同。本管线用到的滤镜（Lanczos、合成、`CIToneMapHeadroom`）已经验证与工作空间无关，以后新增滤镜时需要逐个验证。

**像素格式 RGBAh 的理由。** V1 的输出全是 8-bit（JPEG / PNG，加 8-bit gain map），这种情况下 RGBAh 与 RGBAf 无可见差别。half 的数值范围（±65504）远超 HDR 需要。内存是 RGBAf 的一半，对 D-18 的内存估算和并行很重要。以后如果加 16-bit TIFF/PNG 输出，再按任务切换到 RGBAf。

**候选的备选顺序：** extended linear Display P3 第二。它与 Mac 屏幕和 Apple 的 gain map 展开空间一致，但 Rec.2020 内容和 ProPhoto 内容会出现负值。extended linear sRGB 第三。

**配套实现规则**（建议写进实现约定，属于 D-03 的一部分，最终由用户决定）：

- 所有中间结果都是 extended 浮点：CIImage 中间缓冲、我们自己的 CGImage、CGContext 和缓存都用工作空间 + RGBAh。禁止使用 8-bit 或非 extended 的中间格式。
- 编码前由 CI 显式渲染到 sRGB RGBA8 再交给编码器；HDR 只走 CI 的 `.hdrImage` 路线，并且要显式标上 headroom、使用 RGB gain map（坑 17）。
- 32 位浮点源先转 RGBAh 再交给 CI（坑 15）；headroom 未知时根据画面内容估算（坑 16）。
- 照片缩放：先 `clampedToExtent`，再缩放，最后裁到整数尺寸。透明素材不用 Lanczos。
- 自己解析文件判断有没有 ICC（坑 1）。

## 7. D-19 结论

**合成色卡**（真值由参考数学给出）：

| 场景 | ΔE 中位 / P95 | 是否满足暂定阈值（≤1 / ≤2） |
|---|---|---|
| 16-bit TIFF（四种 ICC）→ 8-bit PNG | 0.05 / 0.21–0.27 | ✅ 余量很大 |
| 8-bit JPEG Q100（四种 ICC）→ 8-bit PNG | 0.18–0.28 / 0.59–0.97 | ✅ |
| 8-bit JPEG Q100（四种 ICC）→ JPEG Q100 | 0.29–0.44 / 0.79–1.04 | ✅ |
| 无 ICC、实为 P3 数值的文件（按 sRGB 解释） | 2.37 / 4.11 | ❌（预期内，属于 D-04 警告场景） |
| 超出 sRGB 的颜色 → sRGB（逐通道截断） | 3.3–11 / 最大 28 | 不适用：需要另定映射策略和验收方法 |

**真实照片**（Lightroom 把同一张照片导出为四种色彩空间。以 sRGB 版本经本管线的输出为基准，统计其它版本输出的 ΔE；两张照片，三个工作空间结果相同）：

| 输入 | sRGB 域内 中位 / P95 | 超出 sRGB 的像素（占 1.3–2.5%）中位 / P95 / max | D-19 |
|---|---|---|---|
| 16 位 TIFF，ProPhoto vs sRGB | 0.00 / 0.00 | 0.00 / 0.40–0.45 / 3.2–7.0 | ✅ |
| 8 位 JPEG Q100，Adobe RGB vs sRGB | 0.41–0.45 / 1.26–1.30 | 0.00–0.09 / 0.50–0.79 / 3.7–5.3 | ✅ |
| 8 位 JPEG Q100，Display P3 vs sRGB | 0.35–0.43 / 1.17–1.24 | 0.00–0.09 / 0.55–0.77 / 2.4–4.6 | ✅ |
| 8 位 JPEG Q100，ProPhoto vs sRGB | 0.51–0.52 / 1.65–1.76 | 0.00–0.15 / 0.58–1.08 / 3.1–6.1 | ✅（余量最小） |

**结论：暂定阈值（中位 ≤ 1、P95 ≤ 2）在合成样本和真实样本上都能达到。**

- 16 位 TIFF：本管线的 ProPhoto→sRGB 结果与 Lightroom 自己导出的 sRGB 版本完全一致（ΔE 0.00）。
- 8 位 JPEG 的误差来自不同编码下的 8 位量化和 JPEG 压缩。ProPhoto 8 位 JPEG 的 P95 为 1.76，离 2 只剩 0.24 余量；8 位 ProPhoto 本来就不推荐，Lightroom 也会提示。
- 超出 sRGB 的像素：Lightroom 导出 sRGB 时的结果和本管线的逐通道截断几乎一样（中位约 0、P95 ≤ 1.08），个别像素最大到 7。也就是说，现在的截断至少不比 Lightroom 差。是否还要做更柔和的色域压缩，是另一个问题（坑 11）。

建议定稿时写明四点：

1. 阈值只统计源图在 sRGB 色域内的像素。
2. 超出 sRGB 的像素按选定的色域映射策略另行验收；以 Lightroom 的 sRGB 导出为参照时，可以暂定 P95 ≤ 2。
3. 8 位 ProPhoto 输入不纳入阈值，或者单独放宽。
4. HDR→SDR 不适用 ΔE 阈值，按 tone map 规格验收。

另外，基线系统应从 macOS 26 改为本机实际的 macOS 27，或者在 26 上补测一次。这一点需要用户决定。

## 8. 真实照片（Lightroom Classic 15.5.1 导出）

样本放在仓库外的 `another_photo_frame_assets/D-03_HDR/`，不入库。本次运行的完整表格快照在 [`Experiments/ColorPoC/results/real-hdr.md`](../Experiments/ColorPoC/results/real-hdr.md)。

### 8.1 HDR 样本与 Lightroom 实际写出的格式

3 张 Nikon Z 8 成片（约 45MP），每张导出 3 份：gain map JPEG（HDR P3）、16 位 TIFF（HDR Rec.2020）、32 位 TIFF。

| 照片 | headroom（gain map 元数据） | 亮于 SDR 白的像素 | 最亮 | 超出 sRGB / P3 |
|---|---|---|---|---|
| aurora1（极光） | 6.26 | 6.3% | 3.8× | 0.6% / 0 |
| cannon_beach（日落） | 7.43 | 0.55% | 4.2× | 0.03% / 0 |
| grand_teton | 3.28 | 0.09% | 1.8× | 0 / 0 |

| 导出格式 | ImageIO / CI 看到的内容 | headroom |
|---|---|---|
| JPEG，HDR P3 | Display P3 ICC 底图 + ISO 21496-1 gain map（全分辨率、RGB）+ Adobe hdrgm XMP；4:4:4。展开后为 `DisplayP3_PQ` | 来自元数据（3.28–7.43） |
| TIFF 16 位，HDR Rec.2020 | "Rec. 2020 PQ" ICC（6604 B）；CG/CI 识别为 HDR | **固定 4.93（默认值，不是画面实际峰值）** |
| TIFF 32 位 | "Linear Rec. 2020" ICC，extended range；**不被识别为 HDR** | 0（未知），需要自己估算（坑 16） |

同一张照片的三种导出，解码后亮度的中位数、P95 和最大值都在 0.01 以内一致。这说明 Apple 对 Lightroom 的 gain map、PQ ICC 和线性浮点 ICC 的解释是一致的，参考白都对应线性 1.0。

### 8.2 结果

- **解码一致性**（CI 缩放结果对比 ImageIO 缩略图）：JPEG 和 16 位 TIFF 的坏像素为 0–0.20%，只是重采样差异。32 位 TIFF 直接交给 CI 时，在部分工作空间下坏像素 2.8–7.2%；先转 RGBAh 后降到 0.02–0.17%（坑 15）。
- **需要 extended 的像素：** 分量 < 0 的像素占比，extended linear sRGB 为 0.31–2.32%，P3 为 0.24–0.32%，Rec.2020 为 0.18–0.27%。2020 剩下的这部分来自 Lanczos 在高反差边缘的振铃，不是色域问题。这些照片真正超出 sRGB 的颜色很少（0–0.75%），没有超出 P3 的。
- **三个候选仍然等价：** 同一合成图在各空间渲染后换算到 XYZ，最大差 ≤ 0.009；SDR 输出之间的 ΔE 中位 0.00、P95 ≤ 0.38、最大 ≤ 1.75。没有截断。
- **HDR 写出再读回（CI、RGB gain map、显式 headroom）：** 全部像素的亮度相对误差中位 ≤ 0.7%、P95 ≤ 3.2%；高光误差中位 ≤ 1.5%；Δu′v′ 中位 ≤ 0.0024。例外是 grand_teton 的 TIFF：高光 P95 为 14–18%，但它只有 53 个高光采样点。如果用 CI 默认写法，headroom 会被推低（aurora 2.89 / 6.26，cannon_beach 3.96 / 7.43，grand_teton 1.68 / 3.28），高光误差最高 11.5%，色度误差约大 10 倍（坑 17）。
- **SDR 回退底图：** 背景最大偏差 2–4（JPEG 误差）。底图与我们自己的 SDR 渲染相比，ΔE 中位 0.36–0.51、P95 1.21–1.53。合成样本上是 0.00，这里的差异来自细节丰富的照片经过 JPEG Q100 压缩。
- **SDR tone map：** TIFF 源没有 Lightroom 的 SDR 版本，只能自己 tone map。用 `CIToneMapHeadroom` 配合 PQ 默认 headroom 4.93 时，结果明显比 Lightroom 的 SDR 底图暗；cannon_beach 的前景几乎全黑。grand_teton 实际峰值只有 1.77，却按 4.93 压缩。这进一步说明：gain map 源应直接用 Lightroom 的 SDR 底图；PQ / float 源需要更合适的曲线，并且 headroom 要按画面实际估算。
- **内存与性能：** PoC 为了测量，故意全分辨率解码 45MP 原图，同时开 3 个工作空间，每张写多份输出，也没做任何内存控制。9 个文件共用 112 秒，进程峰值内存 21.5 GB。按正式软件的做法另测了一次单任务导出：用 ImageIO 按输出所需尺寸降采样解码（长边 2700）→ CI 合成 → 写 HDR gain map JPEG。每张峰值内存 330 MB（16 位 TIFF）、490 MB（gain map JPEG）、690 MB（32 位 TIFF），耗时 0.6–1.2 秒。所以 D-18 的降采样解码必须做，做了之后内存就在正常范围。

### 8.3 SDR 四色彩空间样本（D-19）

2 张 SDR 成片：glacier_np（3209×4813）和 glacier_np_person（8245×5497）。每张导出 sRGB、Adobe RGB、Display P3、ProPhoto 四种 JPEG Q100，以及 sRGB 和 ProPhoto 两种 16 位 TIFF。超出 sRGB 的像素占 1.3–2.5%（冰川湖的青绿色），没有超出 P3 的。完整表格见 [`Experiments/ColorPoC/results/real-sdr.md`](../Experiments/ColorPoC/results/real-sdr.md)，结论见 §7。

- Lightroom 的 ProPhoto ICC 是 Adobe 自己的 "ProPhoto RGB"（940 B），不是 Apple 的 ROMM 配置文件；CI 能正确处理。
- 三个工作空间的 SDR 输出之间 ΔE 中位 0.00、P95 ≤ 0.51，与 HDR 样本的结论一致。需要负分量的像素：extended linear sRGB 为 0.3–4.0%，Rec.2020 为 0.1–0.9%（主要是边缘振铃）。
- 加上逐张释放内存之后，12 个文件共用 38 秒，进程峰值内存 4.5 GB（之前 HDR 那次是 21.5 GB）。

### 8.4 需要在 HDR 屏幕上目视检查的文件

在 MacBook Pro XDR 屏或其它 HDR 显示器上，用"预览"或"照片"打开。下表路径都相对于 `Experiments/ColorPoC/out/`，运行一次 `colorpoc run` 就会生成。

| 文件 | 看什么 |
|---|---|
| `real/extLinear2020/cannon_beach_hdr_jpg_hdr_rgb.jpg` 与 Lightroom 原片 `cannon_beach_hdr.jpg` 并排 | 太阳和水面反光的亮度、日落颜色的饱和度应和原片一致；**背景 #FAFAF8 和水印不应发光** |
| 同目录 `cannon_beach_hdr_jpg_hdr.jpg`（CI 默认写法）与上一张对比 | 默认写法的 headroom 被推低，太阳应明显不如 `_rgb` 版亮 |
| `real/extLinear2020/cannon_beach_hdr_jpg_sdr.jpg` 与 `cannon_beach_hdr_tif_sdr.jpg` | 前者用 Lightroom 的 SDR 底图，后者是 `CIToneMapHeadroom` 的结果；后者偏暗多少、能不能接受 |
| `real/extLinear2020/aurora1_hdr_jpg_hdr_rgb.jpg` | 极光的绿色和红色高光有没有发灰或偏色 |
| `extLinear2020/hdr/hdr_pq2020_203nit_hdr_gainmap_CI.jpg` | 合成图：第一行灰块从第 5 块起应逐级变亮；背景不发光 |
| `extLinear2020/hdr/hdr_pq2020_203nit_hdr_gainmap_ImageIO.jpg` | 对照：ImageIO 路线的 SDR 底图里背景偏暗（坑 4） |

### 8.5 HDR→SDR tone map 对比（三张 16 位 PQ TIFF）

用 `colorpoc tonemap` 生成。参照是同一张照片的 Lightroom SDR 底图，也就是摄影师认可的 SDR 版本。对比图在 `Experiments/ColorPoC/out/tonemap/<名字>_compare.jpg`，完整指标见 [`results/tonemap.md`](../Experiments/ColorPoC/results/tonemap.md)。所有方法的峰值都按画面估算：取 sRGB 线性分量最大值的 P99.95，不用 PQ 元数据的默认值 4.93。

| 方法 | 与 Lightroom SDR 底图的 ΔE 中位 / P95（cannon_beach · aurora1 · grand_teton） | 有通道截断到 255 的像素 |
|---|---|---|
| 直接截断 | 6.5 / 12.5 · 3.4 / 15.6 · 2.4 / 14.8 | 3.7% · 11.4% · 27.6% |
| `CIToneMapHeadroom`（headroom = 画面峰值） | **1.7 / 8.0 · 2.1 / 8.2 · 2.2 / 6.3** | **0.2% · 0.7% · 7.3%** |
| Apple 软肩（`.toneMapHDRtoSDR`） | 6.5 / 12.1 · 3.4 / 13.9 · 2.4 / 11.1 | 3.3% · 6.4% · 26.8% |
| BT.2390 EETF（maxRGB） | 6.5 / 11.0 · 3.4 / 13.8 · 2.4 / 9.3 | 2.9% · 7.7% · 26.2% |
| Reinhard（亮度） | 3.7 / 6.5 · 2.3 / 7.2 · 2.4 / 6.0 | 0.2% · 0.8% · 16.4% |

- 按画面峰值设置 headroom 后，`CIToneMapHeadroom` 在三张照片上都最接近 Lightroom 的 SDR 版本，截断也最少，只是暗部比 Lightroom 暗约 2 个 L*。坑 6 里"太暗"的问题，原因是用了 PQ 默认 headroom 4.93，而不是曲线本身。
- Apple 软肩和 BT.2390 都基本不动中间调，所以比 Lightroom 的 SDR 版本亮（中间调 ΔL* 约 +5 到 +11），高光截断也多。
- 没有任何全局曲线能完全复现 Lightroom 的 SDR 版本（P95 仍有 6–8）。Lightroom 的 SDR 底图是单独调过的。

### 8.6 Lightroom 勾选 Maximize Compatibility 导出的 HDR TIFF

aurora1 用 TIFF、HDR Rec.2020、勾选 Maximize Compatibility 又导出了 16 位和 32 位两份（`aurora1_hdr_com.tif`、`aurora1_hdr_com32.tif`）。

| | 主图（IFD0） | SubIFD | Apple 读到的内容 | 与 JPEG 里 Lightroom SDR 底图的 ΔE |
|---|---|---|---|---|
| 16 位 | SDR 版本，16 位，"Rec. 2020" ICC（逆 OETF 曲线） | ISO 21496-1 RGB gain map（Photometric 52553） | 只有 SDR；按 γ2.4 解码，偏暗（坑 20） | 中位 8.31，ΔL* −8.8 |
| 32 位 | SDR 版本，32 位线性浮点，"Linear Rec. 2020" | 同上（16 位） | 只有 SDR | **中位 0.00，P95 0.68** |

结论：这种 TIFF 里确实带着 Lightroom 的 SDR 版本，但 Apple 框架读不出其中的 HDR（坑 19）。16 位那份的 SDR 还会被解暗（坑 20）。要做到"TIFF 也用 Lightroom 的 SDR、同时保留 HDR"，需要自己解析 SubIFD 里的 gain map。

## 9. 对规范其它部分的影响（只列出，不改）

- §6.7 / D-05：HDR→SDR 的 tone map 需要选定并记录。建议：gain map 源直接用它自带的 SDR 底图（摄影师在 Lightroom 里的 SDR 版本）；PQ/HLG/float 源用显式选定的曲线（候选见坑 6）。
- §6.8：sRGB JPEG 是否必须嵌入 ICC（坑 2）；默认写出的结构性 Exif / TIFF 字段算不算"元数据"（坑 13）。
- §6.9："超出目标色域时的映射策略"目前没有实现，需要新增色域压缩步骤（坑 11）。
- D-18：降采样解码可以放心用 ImageIO 缩略图 API，颜色空间和位深都会保留（§4），还能顺带避开坑 15。PoC 全分辨率处理 45MP 浮点图时，进程峰值内存达 21.5 GB。
- D-05 / D-02：32 位浮点 TIFF 可以支持，不需要拒绝：读入后转成 RGBAh，或者降采样解码（坑 15）。Lightroom 16 位 HDR TIFF 的 headroom 只是 PQ 默认值 4.93，tone map 前应按画面实际估算。
- D-19：基线系统版本（macOS 26 还是 27）。
