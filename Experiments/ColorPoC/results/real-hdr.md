# ColorPoC 运行结果

生成时间：2026-10-16T18:08:38Z；系统：Version 27.0.1 (Build 26A434)

## 7. 真实照片（9 个文件，目录不入库）

### 7.0 解码一致性（Core Image 缩放结果 vs ImageIO 缩略图）

两者都缩到长边 1032 后在 extended linear Rec.2020 中比较。坏像素 = G 通道差 > 0.2。正常值只有重采样差异（< 0.3%）。

| 文件 | 工作空间 | 送入 CI 的方式 | 平均绝对差 | 坏像素 |
|---|---|---|---|---|
| aurora1_hdr.jpg | extLinear2020 | 直接交给 CI | 0.0030 | 0.00% |
| aurora1_hdr.jpg | extLinearSRGB | 直接交给 CI | 0.0030 | 0.00% |
| aurora1_hdr.tif | extLinear2020 | 直接交给 CI | 0.0043 | 0.20% |
| aurora1_hdr.tif | extLinearSRGB | 直接交给 CI | 0.0043 | 0.20% |
| aurora1_hdr32.tif | extLinear2020 | 直接交给 CI | 0.0450 | 7.20% |
| aurora1_hdr32.tif | extLinearSRGB | 直接交给 CI | 0.0047 | 0.17% |
| aurora1_hdr32.tif | extLinear2020 | 先转 RGBAh | 0.0047 | 0.17% |
| aurora1_hdr32.tif | extLinearSRGB | 先转 RGBAh | 0.0047 | 0.17% |
| cannon_beach_hdr.jpg | extLinear2020 | 直接交给 CI | 0.0018 | 0.00% |
| cannon_beach_hdr.jpg | extLinearSRGB | 直接交给 CI | 0.0018 | 0.00% |
| cannon_beach_hdr.tif | extLinear2020 | 直接交给 CI | 0.0017 | 0.14% |
| cannon_beach_hdr.tif | extLinearSRGB | 直接交给 CI | 0.0017 | 0.14% |
| cannon_beach_hdr32.tif | extLinear2020 | 直接交给 CI | 0.0016 | 0.05% |
| cannon_beach_hdr32.tif | extLinearSRGB | 直接交给 CI | 0.0368 | 5.79% |
| cannon_beach_hdr32.tif | extLinear2020 | 先转 RGBAh | 0.0016 | 0.05% |
| cannon_beach_hdr32.tif | extLinearSRGB | 先转 RGBAh | 0.0016 | 0.05% |
| grand_teton_hdr.jpg | extLinear2020 | 直接交给 CI | 0.0032 | 0.00% |
| grand_teton_hdr.jpg | extLinearSRGB | 直接交给 CI | 0.0032 | 0.00% |
| grand_teton_hdr.tif | extLinear2020 | 直接交给 CI | 0.0040 | 0.04% |
| grand_teton_hdr.tif | extLinearSRGB | 直接交给 CI | 0.0039 | 0.04% |
| grand_teton_hdr32.tif | extLinear2020 | 直接交给 CI | 0.0286 | 2.82% |
| grand_teton_hdr32.tif | extLinearSRGB | 直接交给 CI | 0.0042 | 0.02% |
| grand_teton_hdr32.tif | extLinear2020 | 先转 RGBAh | 0.0042 | 0.02% |
| grand_teton_hdr32.tif | extLinearSRGB | 先转 RGBAh | 0.0042 | 0.02% |

### 7.1 文件识别

| 文件 | 尺寸 | 位深 | ImageIO ProfileName | 文件内颜色描述 | CIImage.colorSpace | gain map | contentHeadroom | EXIF 方向 | 判定 |
|---|---|---|---|---|---|---|---|---|---|
| aurora1_hdr.jpg | 8256×5504 | 8 | Display P3 | ICC | DisplayP3_PQ | ISO | 6.26 | 1 | HDR |
| aurora1_hdr.tif | 8256×5504 | 16 | Rec. 2020 PQ | ICC（Rec. 2020 PQ） | ICC(6604B, Rec. 2020 PQ) | – | 4.93 | 1 | HDR |
| aurora1_hdr32.tif | 8256×5504 | 32 float | Linear Rec. 2020 | ICC（Linear Rec. 2020） | ICC(496B, Linear Rec. 2020) | – | 0.00 | 1 | HDR |
| cannon_beach_hdr.jpg | 8211×5474 | 8 | Display P3 | ICC | DisplayP3_PQ | ISO | 7.43 | 1 | HDR |
| cannon_beach_hdr.tif | 8211×5474 | 16 | Rec. 2020 PQ | ICC（Rec. 2020 PQ） | ICC(6604B, Rec. 2020 PQ) | – | 4.93 | 1 | HDR |
| cannon_beach_hdr32.tif | 8211×5474 | 32 float | Linear Rec. 2020 | ICC（Linear Rec. 2020） | ICC(496B, Linear Rec. 2020) | – | 0.00 | 1 | HDR |
| grand_teton_hdr.jpg | 8256×5504 | 8 | Display P3 | ICC | DisplayP3_PQ | ISO | 3.28 | 1 | HDR |
| grand_teton_hdr.tif | 8256×5504 | 16 | Rec. 2020 PQ | ICC（Rec. 2020 PQ） | ICC(6604B, Rec. 2020 PQ) | – | 4.93 | 1 | HDR |
| grand_teton_hdr32.tif | 8256×5504 | 32 float | Linear Rec. 2020 | ICC（Linear Rec. 2020） | ICC(496B, Linear Rec. 2020) | – | 0.00 | 1 | HDR |

### 7.2 各工作空间：需要 extended 的像素比例与一致性

“与 2020 的 XYZ 最大差”：同一合成图在该空间渲染为 RGBAf 后换算到 XYZ，与 extLinear2020 结果的最大差（若某空间截断，这里会明显变大）。

| 文件 | 工作空间 | 分量 <0 的像素 | 分量 >1 的像素 | 与 2020 的 XYZ 最大差 | SDR 输出方法 | SDR 背景≠#FAFAF8 |
|---|---|---|---|---|---|---|
| aurora1_hdr.jpg | extLinear2020 | 0.27% | 8.47% | （基准） | gain map 底图 | 0 |
| aurora1_hdr.jpg | extLinearP3 | 0.31% | 10.08% | 0.00412 | gain map 底图 | 0 |
| aurora1_hdr.jpg | extLinearSRGB | 2.30% | 11.33% | 0.00366 | gain map 底图 | 0 |
| aurora1_hdr.tif | extLinear2020 | 0.27% | 8.45% | （基准） | CIToneMapHeadroom(4.93) | 0 |
| aurora1_hdr.tif | extLinearP3 | 0.32% | 10.06% | 0.00467 | CIToneMapHeadroom(4.93) | 0 |
| aurora1_hdr.tif | extLinearSRGB | 2.32% | 11.30% | 0.00436 | CIToneMapHeadroom(4.93) | 0 |
| aurora1_hdr32.tif | extLinear2020 | 0.27% | 8.45% | （基准） | CIToneMapHeadroom(3.98) | 0 |
| aurora1_hdr32.tif | extLinearP3 | 0.32% | 10.06% | 0.00509 | CIToneMapHeadroom(3.98) | 0 |
| aurora1_hdr32.tif | extLinearSRGB | 2.32% | 11.30% | 0.00478 | CIToneMapHeadroom(3.98) | 0 |
| cannon_beach_hdr.jpg | extLinear2020 | 0.23% | 1.94% | （基准） | gain map 底图 | 0 |
| cannon_beach_hdr.jpg | extLinearP3 | 0.25% | 2.85% | 0.00892 | gain map 底图 | 0 |
| cannon_beach_hdr.jpg | extLinearSRGB | 0.32% | 3.68% | 0.00460 | gain map 底图 | 0 |
| cannon_beach_hdr.tif | extLinear2020 | 0.23% | 1.93% | （基准） | CIToneMapHeadroom(4.93) | 0 |
| cannon_beach_hdr.tif | extLinearP3 | 0.25% | 2.83% | 0.00513 | CIToneMapHeadroom(4.93) | 0 |
| cannon_beach_hdr.tif | extLinearSRGB | 0.31% | 3.66% | 0.00541 | CIToneMapHeadroom(4.93) | 0 |
| cannon_beach_hdr32.tif | extLinear2020 | 0.23% | 1.94% | （基准） | CIToneMapHeadroom(4.21) | 0 |
| cannon_beach_hdr32.tif | extLinearP3 | 0.25% | 2.83% | 0.00477 | CIToneMapHeadroom(4.21) | 0 |
| cannon_beach_hdr32.tif | extLinearSRGB | 0.31% | 3.66% | 0.00661 | CIToneMapHeadroom(4.21) | 0 |
| grand_teton_hdr.jpg | extLinear2020 | 0.18% | 26.81% | （基准） | gain map 底图 | 0 |
| grand_teton_hdr.jpg | extLinearP3 | 0.24% | 27.06% | 0.00270 | gain map 底图 | 0 |
| grand_teton_hdr.jpg | extLinearSRGB | 0.33% | 27.45% | 0.00326 | gain map 底图 | 0 |
| grand_teton_hdr.tif | extLinear2020 | 0.19% | 26.79% | （基准） | CIToneMapHeadroom(4.93) | 0 |
| grand_teton_hdr.tif | extLinearP3 | 0.26% | 27.04% | 0.00292 | CIToneMapHeadroom(4.93) | 0 |
| grand_teton_hdr.tif | extLinearSRGB | 0.37% | 27.44% | 0.00290 | CIToneMapHeadroom(4.93) | 0 |
| grand_teton_hdr32.tif | extLinear2020 | 0.19% | 26.79% | （基准） | CIToneMapHeadroom(1.75) | 0 |
| grand_teton_hdr32.tif | extLinearP3 | 0.26% | 27.04% | 0.00282 | CIToneMapHeadroom(1.75) | 0 |
| grand_teton_hdr32.tif | extLinearSRGB | 0.37% | 27.44% | 0.00347 | CIToneMapHeadroom(1.75) | 0 |

### 7.3 SDR 输出随工作空间的差异（ΔE2000）

| 文件 | 比较 | 中位 | P95 | max |
|---|---|---|---|---|
| aurora1_hdr.jpg | extLinearSRGB vs extLinear2020 | 0.00 | 0.29 | 1.66 |
| aurora1_hdr.jpg | extLinearP3 vs extLinear2020 | 0.00 | 0.27 | 1.44 |
| aurora1_hdr.tif | extLinearSRGB vs extLinear2020 | 0.00 | 0.25 | 1.58 |
| aurora1_hdr.tif | extLinearP3 vs extLinear2020 | 0.00 | 0.23 | 1.61 |
| aurora1_hdr32.tif | extLinearSRGB vs extLinear2020 | 0.00 | 0.26 | 1.48 |
| aurora1_hdr32.tif | extLinearP3 vs extLinear2020 | 0.00 | 0.28 | 1.55 |
| cannon_beach_hdr.jpg | extLinearSRGB vs extLinear2020 | 0.00 | 0.37 | 1.19 |
| cannon_beach_hdr.jpg | extLinearP3 vs extLinear2020 | 0.00 | 0.36 | 1.15 |
| cannon_beach_hdr.tif | extLinearSRGB vs extLinear2020 | 0.00 | 0.38 | 1.29 |
| cannon_beach_hdr.tif | extLinearP3 vs extLinear2020 | 0.00 | 0.37 | 1.42 |
| cannon_beach_hdr32.tif | extLinearSRGB vs extLinear2020 | 0.00 | 0.38 | 1.15 |
| cannon_beach_hdr32.tif | extLinearP3 vs extLinear2020 | 0.00 | 0.35 | 1.14 |
| grand_teton_hdr.jpg | extLinearSRGB vs extLinear2020 | 0.00 | 0.28 | 1.75 |
| grand_teton_hdr.jpg | extLinearP3 vs extLinear2020 | 0.00 | 0.28 | 1.63 |
| grand_teton_hdr.tif | extLinearSRGB vs extLinear2020 | 0.00 | 0.27 | 1.53 |
| grand_teton_hdr.tif | extLinearP3 vs extLinear2020 | 0.00 | 0.26 | 1.50 |
| grand_teton_hdr32.tif | extLinearSRGB vs extLinear2020 | 0.00 | 0.28 | 1.66 |
| grand_teton_hdr32.tif | extLinearP3 vs extLinear2020 | 0.00 | 0.27 | 1.66 |

### 7.4 HDR 输出（CI，gain map JPEG）写出 → 读回

相对误差 = |读回 Y / 写出前合成 Y − 1|。SDR 底图 ΔE = 读回底图 vs 我们的 SDR 渲染。

| 文件 | 工作空间 | 写法 | gain map | 底图 ICC | 源 headroom | 读回 headroom | 全部像素相对误差 中位/P95 | >1 高光相对误差 中位/P95 | 高光 Δu′v′ 中位/P95 | SDR 底图背景最大偏差 | SDR 底图 ΔE 中位/P95 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| aurora1_hdr.jpg | extLinear2020 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 6.26 | 2.89 | 0.009 / 0.034 | 0.010 / 0.027（3767 点） | 0.0076 / 0.0128 | 4 | 0.50 / 1.49 |
| aurora1_hdr.jpg | extLinear2020 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 6.26 | 6.26 | 0.007 / 0.027 | 0.004 / 0.013（3767 点） | 0.0005 / 0.0014 | 4 | 0.50 / 1.49 |
| aurora1_hdr.jpg | extLinearP3 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 6.26 | 2.89 | 0.009 / 0.034 | 0.010 / 0.028（3767 点） | 0.0076 / 0.0128 | 4 | 0.50 / 1.50 |
| aurora1_hdr.jpg | extLinearP3 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 6.26 | 6.26 | 0.007 / 0.027 | 0.004 / 0.013（3767 点） | 0.0005 / 0.0014 | 4 | 0.50 / 1.50 |
| aurora1_hdr.jpg | extLinearSRGB | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 6.26 | 2.89 | 0.009 / 0.034 | 0.010 / 0.027（3769 点） | 0.0076 / 0.0128 | 4 | 0.50 / 1.50 |
| aurora1_hdr.jpg | extLinearSRGB | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 6.26 | 6.26 | 0.007 / 0.027 | 0.004 / 0.013（3769 点） | 0.0005 / 0.0014 | 4 | 0.50 / 1.50 |
| aurora1_hdr.tif | extLinear2020 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 2.89 | 0.007 / 0.032 | 0.003 / 0.011（3764 点） | 0.0004 / 0.0013 | 4 | 0.51 / 1.53 |
| aurora1_hdr.tif | extLinear2020 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 4.93 | 0.007 / 0.032 | 0.003 / 0.011（3764 点） | 0.0004 / 0.0013 | 4 | 0.51 / 1.53 |
| aurora1_hdr.tif | extLinearP3 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 2.89 | 0.007 / 0.031 | 0.003 / 0.011（3761 点） | 0.0004 / 0.0013 | 4 | 0.51 / 1.52 |
| aurora1_hdr.tif | extLinearP3 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 4.93 | 0.007 / 0.031 | 0.003 / 0.011（3761 点） | 0.0004 / 0.0013 | 4 | 0.51 / 1.52 |
| aurora1_hdr.tif | extLinearSRGB | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 2.89 | 0.007 / 0.032 | 0.003 / 0.011（3762 点） | 0.0004 / 0.0013 | 4 | 0.51 / 1.53 |
| aurora1_hdr.tif | extLinearSRGB | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 4.93 | 0.007 / 0.031 | 0.004 / 0.011（3762 点） | 0.0004 / 0.0013 | 4 | 0.51 / 1.53 |
| aurora1_hdr32.tif | extLinear2020 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 3.98 | 2.89 | 0.007 / 0.030 | 0.003 / 0.011（3764 点） | 0.0004 / 0.0012 | 4 | 0.50 / 1.52 |
| aurora1_hdr32.tif | extLinear2020 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 3.98 | 3.98 | 0.007 / 0.031 | 0.003 / 0.011（3764 点） | 0.0004 / 0.0012 | 4 | 0.50 / 1.52 |
| aurora1_hdr32.tif | extLinearP3 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 3.98 | 2.89 | 0.007 / 0.030 | 0.003 / 0.011（3761 点） | 0.0004 / 0.0012 | 4 | 0.50 / 1.53 |
| aurora1_hdr32.tif | extLinearP3 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 3.98 | 3.98 | 0.007 / 0.031 | 0.003 / 0.011（3761 点） | 0.0004 / 0.0012 | 4 | 0.50 / 1.53 |
| aurora1_hdr32.tif | extLinearSRGB | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 3.98 | 2.89 | 0.007 / 0.031 | 0.003 / 0.011（3763 点） | 0.0004 / 0.0012 | 4 | 0.51 / 1.52 |
| aurora1_hdr32.tif | extLinearSRGB | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 3.98 | 3.98 | 0.007 / 0.031 | 0.003 / 0.011（3763 点） | 0.0004 / 0.0012 | 4 | 0.51 / 1.52 |
| cannon_beach_hdr.jpg | extLinear2020 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 7.43 | 3.96 | 0.014 / 0.061 | 0.032 / 0.095（336 点） | 0.0060 / 0.0155 | 3 | 0.48 / 1.24 |
| cannon_beach_hdr.jpg | extLinear2020 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 7.43 | 7.43 | 0.006 / 0.023 | 0.005 / 0.015（336 点） | 0.0008 / 0.0021 | 3 | 0.48 / 1.24 |
| cannon_beach_hdr.jpg | extLinearP3 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 7.43 | 3.96 | 0.014 / 0.060 | 0.030 / 0.099（336 点） | 0.0059 / 0.0152 | 3 | 0.48 / 1.24 |
| cannon_beach_hdr.jpg | extLinearP3 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 7.43 | 7.43 | 0.006 / 0.023 | 0.004 / 0.016（336 点） | 0.0007 / 0.0020 | 3 | 0.48 / 1.24 |
| cannon_beach_hdr.jpg | extLinearSRGB | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 7.43 | 3.97 | 0.014 / 0.060 | 0.031 / 0.101（336 点） | 0.0059 / 0.0153 | 3 | 0.48 / 1.24 |
| cannon_beach_hdr.jpg | extLinearSRGB | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 7.43 | 7.43 | 0.006 / 0.023 | 0.004 / 0.014（336 点） | 0.0007 / 0.0020 | 3 | 0.48 / 1.24 |
| cannon_beach_hdr.tif | extLinear2020 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 3.96 | 0.006 / 0.026 | 0.004 / 0.014（337 点） | 0.0005 / 0.0016 | 3 | 0.50 / 1.22 |
| cannon_beach_hdr.tif | extLinear2020 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 4.93 | 0.006 / 0.026 | 0.004 / 0.014（337 点） | 0.0005 / 0.0015 | 3 | 0.50 / 1.22 |
| cannon_beach_hdr.tif | extLinearP3 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 3.96 | 0.006 / 0.026 | 0.004 / 0.013（337 点） | 0.0005 / 0.0015 | 3 | 0.50 / 1.22 |
| cannon_beach_hdr.tif | extLinearP3 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 4.93 | 0.006 / 0.026 | 0.003 / 0.011（337 点） | 0.0005 / 0.0014 | 3 | 0.50 / 1.22 |
| cannon_beach_hdr.tif | extLinearSRGB | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 3.96 | 0.006 / 0.026 | 0.003 / 0.012（337 点） | 0.0005 / 0.0015 | 3 | 0.50 / 1.21 |
| cannon_beach_hdr.tif | extLinearSRGB | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 4.93 | 0.006 / 0.026 | 0.003 / 0.012（337 点） | 0.0005 / 0.0014 | 3 | 0.50 / 1.21 |
| cannon_beach_hdr32.tif | extLinear2020 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 4.21 | 3.96 | 0.006 / 0.026 | 0.004 / 0.028（337 点） | 0.0005 / 0.0022 | 3 | 0.50 / 1.24 |
| cannon_beach_hdr32.tif | extLinear2020 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 4.21 | 4.21 | 0.006 / 0.026 | 0.003 / 0.013（337 点） | 0.0005 / 0.0014 | 3 | 0.50 / 1.24 |
| cannon_beach_hdr32.tif | extLinearP3 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 4.21 | 3.96 | 0.006 / 0.026 | 0.004 / 0.026（337 点） | 0.0005 / 0.0021 | 3 | 0.49 / 1.24 |
| cannon_beach_hdr32.tif | extLinearP3 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 4.21 | 4.21 | 0.006 / 0.025 | 0.004 / 0.013（337 点） | 0.0005 / 0.0013 | 3 | 0.49 / 1.24 |
| cannon_beach_hdr32.tif | extLinearSRGB | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 4.21 | 3.96 | 0.006 / 0.026 | 0.004 / 0.028（336 点） | 0.0005 / 0.0022 | 3 | 0.49 / 1.24 |
| cannon_beach_hdr32.tif | extLinearSRGB | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 4.21 | 4.21 | 0.006 / 0.025 | 0.004 / 0.013（336 点） | 0.0005 / 0.0014 | 3 | 0.49 / 1.24 |
| grand_teton_hdr.jpg | extLinear2020 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 3.28 | 1.68 | 0.030 / 0.141 | 0.115 / 0.164（53 点） | 0.0105 / 0.0198 | 3 | 0.39 / 1.26 |
| grand_teton_hdr.jpg | extLinear2020 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 3.28 | 3.28 | 0.007 / 0.031 | 0.004 / 0.013（53 点） | 0.0008 / 0.0022 | 3 | 0.39 / 1.26 |
| grand_teton_hdr.jpg | extLinearP3 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 3.28 | 1.68 | 0.029 / 0.141 | 0.114 / 0.162（53 点） | 0.0104 / 0.0196 | 3 | 0.39 / 1.26 |
| grand_teton_hdr.jpg | extLinearP3 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 3.28 | 3.28 | 0.007 / 0.031 | 0.004 / 0.012（53 点） | 0.0008 / 0.0028 | 3 | 0.39 / 1.26 |
| grand_teton_hdr.jpg | extLinearSRGB | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 3.28 | 1.69 | 0.029 / 0.141 | 0.114 / 0.158（53 点） | 0.0106 / 0.0197 | 3 | 0.39 / 1.25 |
| grand_teton_hdr.jpg | extLinearSRGB | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 3.28 | 3.28 | 0.007 / 0.031 | 0.004 / 0.014（53 点） | 0.0009 / 0.0028 | 3 | 0.39 / 1.25 |
| grand_teton_hdr.tif | extLinear2020 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 1.68 | 0.007 / 0.032 | 0.007 / 0.137（53 点） | 0.0007 / 0.0022 | 3 | 0.40 / 1.32 |
| grand_teton_hdr.tif | extLinear2020 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 4.93 | 0.007 / 0.032 | 0.007 / 0.137（53 点） | 0.0007 / 0.0022 | 3 | 0.40 / 1.32 |
| grand_teton_hdr.tif | extLinearP3 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 1.68 | 0.007 / 0.032 | 0.007 / 0.137（53 点） | 0.0007 / 0.0021 | 3 | 0.40 / 1.33 |
| grand_teton_hdr.tif | extLinearP3 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 4.93 | 0.007 / 0.032 | 0.007 / 0.137（53 点） | 0.0007 / 0.0021 | 3 | 0.40 / 1.33 |
| grand_teton_hdr.tif | extLinearSRGB | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 1.68 | 0.007 / 0.032 | 0.009 / 0.137（53 点） | 0.0007 / 0.0020 | 2 | 0.40 / 1.32 |
| grand_teton_hdr.tif | extLinearSRGB | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 4.93 | 4.93 | 0.007 / 0.032 | 0.010 / 0.137（53 点） | 0.0007 / 0.0020 | 2 | 0.40 / 1.32 |
| grand_teton_hdr32.tif | extLinear2020 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 1.75 | 1.68 | 0.008 / 0.032 | 0.098 / 0.181（53 点） | 0.0123 / 0.0191 | 3 | 0.36 / 1.26 |
| grand_teton_hdr32.tif | extLinear2020 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 1.75 | 1.75 | 0.006 / 0.028 | 0.010 / 0.181（53 点） | 0.0021 / 0.0162 | 3 | 0.36 / 1.26 |
| grand_teton_hdr32.tif | extLinearP3 | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 1.75 | 1.68 | 0.008 / 0.032 | 0.099 / 0.181（53 点） | 0.0123 / 0.0191 | 3 | 0.36 / 1.26 |
| grand_teton_hdr32.tif | extLinearP3 | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 1.75 | 1.75 | 0.006 / 0.028 | 0.015 / 0.181（53 点） | 0.0024 / 0.0155 | 3 | 0.36 / 1.26 |
| grand_teton_hdr32.tif | extLinearSRGB | 默认 | ISO ✅ | sRGB IEC61966-2.1 | 1.75 | 1.68 | 0.008 / 0.032 | 0.097 / 0.183（53 点） | 0.0123 / 0.0199 | 3 | 0.36 / 1.26 |
| grand_teton_hdr32.tif | extLinearSRGB | RGB + 显式 headroom | ISO ✅ | sRGB IEC61966-2.1 | 1.75 | 1.75 | 0.006 / 0.029 | 0.008 / 0.181（53 点） | 0.0021 / 0.0160 | 3 | 0.36 / 1.26 |
