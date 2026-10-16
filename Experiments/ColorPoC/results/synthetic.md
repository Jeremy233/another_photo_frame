# ColorPoC 运行结果

生成时间：2026-10-16T17:34:48Z；系统：Version 27.0.1 (Build 26A434)

## 1. 色卡：四种 ICC 输入 → sRGB 输出的 ΔE2000

画布 1080×1350，留白 90，色卡 960×640 Lanczos 缩放到 0.9375，背景 #FAFAF8，叠加水印。ΔE 为 96 个色块内部像素对真值（色块定义的 sRGB 值）。

| 工作空间 | 输入 | 文件 ICC（ImageIO） | CIImage.colorSpace | PNG ΔE 中位 | PNG ΔE P95 | PNG ΔE max | JPEG ΔE 中位 | JPEG ΔE P95 | PNG 背景≠(250,250,248) | JPEG 背景最大偏差 | CI 直出 vs PNG 文件最大差 | 输出标签 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| extLinearSRGB | chart_srgb.jpg | sRGB IEC61966-2.1 | SRGB | 0.18 | 0.59 | 0.73 | 0.29 | 0.79 | 0/880144 | 4 | 0 | SRGB |
| extLinearSRGB | chart_adobergb.jpg | Adobe RGB (1998) | AdobeRGB1998 | 0.21 | 0.78 | 1.15 | 0.35 | 1.01 | 0/880144 | 4 | 0 | SRGB |
| extLinearSRGB | chart_p3.jpg | Display P3 | DisplayP3 | 0.20 | 0.61 | 1.35 | 0.36 | 0.93 | 0/880144 | 4 | 0 | SRGB |
| extLinearSRGB | chart_prophoto.jpg | ROMM RGB: ISO 22028-2:2013 | ROMMRGB | 0.28 | 0.97 | 1.30 | 0.44 | 1.04 | 0/880144 | 4 | 0 | SRGB |
| extLinearSRGB | chart_srgb_16.tif | sRGB IEC61966-2.1 | SRGB | 0.05 | 0.21 | 0.40 | 0.30 | 0.82 | 0/880144 | 4 | 0 | SRGB |
| extLinearSRGB | chart_adobergb_16.tif | Adobe RGB (1998) | AdobeRGB1998 | 0.05 | 0.21 | 0.50 | 0.30 | 0.82 | 0/880144 | 4 | 0 | SRGB |
| extLinearSRGB | chart_p3_16.tif | Display P3 | DisplayP3 | 0.05 | 0.21 | 0.40 | 0.30 | 0.82 | 0/880144 | 4 | 0 | SRGB |
| extLinearSRGB | chart_prophoto_16.tif | ROMM RGB: ISO 22028-2:2013 | ROMMRGB | 0.05 | 0.21 | 0.40 | 0.30 | 0.82 | 0/880144 | 4 | 0 | SRGB |
| extLinearSRGB | chart_noicc.png | 无 | SRGB | 0.05 | 0.18 | 0.29 | 0.33 | 0.82 | 0/880144 | 4 | 0 | SRGB |
| extLinearSRGB | chart_noicc.jpg | sRGB IEC61966-2.1 | SRGB | 0.18 | 0.59 | 0.73 | 0.29 | 0.79 | 0/880144 | 4 | 0 | SRGB |
| extLinearSRGB | chart_p3values_noicc.png | 无 | SRGB | 2.37 | 4.11 | 4.29 | 2.50 | 4.13 | 0/880144 | 4 | 0 | SRGB |
| extLinearP3 | chart_srgb.jpg | sRGB IEC61966-2.1 | SRGB | 0.18 | 0.59 | 0.73 | 0.30 | 0.79 | 0/880144 | 4 | 0 | SRGB |
| extLinearP3 | chart_adobergb.jpg | Adobe RGB (1998) | AdobeRGB1998 | 0.21 | 0.78 | 1.15 | 0.35 | 1.01 | 0/880144 | 4 | 0 | SRGB |
| extLinearP3 | chart_p3.jpg | Display P3 | DisplayP3 | 0.20 | 0.62 | 1.35 | 0.36 | 0.93 | 0/880144 | 4 | 0 | SRGB |
| extLinearP3 | chart_prophoto.jpg | ROMM RGB: ISO 22028-2:2013 | ROMMRGB | 0.28 | 0.97 | 1.30 | 0.44 | 1.04 | 0/880144 | 4 | 0 | SRGB |
| extLinearP3 | chart_srgb_16.tif | sRGB IEC61966-2.1 | SRGB | 0.05 | 0.21 | 0.40 | 0.30 | 0.90 | 0/880144 | 4 | 0 | SRGB |
| extLinearP3 | chart_adobergb_16.tif | Adobe RGB (1998) | AdobeRGB1998 | 0.05 | 0.22 | 0.50 | 0.30 | 0.91 | 0/880144 | 4 | 0 | SRGB |
| extLinearP3 | chart_p3_16.tif | Display P3 | DisplayP3 | 0.05 | 0.21 | 0.40 | 0.30 | 0.90 | 0/880144 | 4 | 0 | SRGB |
| extLinearP3 | chart_prophoto_16.tif | ROMM RGB: ISO 22028-2:2013 | ROMMRGB | 0.05 | 0.21 | 0.40 | 0.30 | 0.90 | 0/880144 | 4 | 0 | SRGB |
| extLinearP3 | chart_noicc.png | 无 | SRGB | 0.05 | 0.18 | 0.29 | 0.33 | 0.90 | 0/880144 | 4 | 0 | SRGB |
| extLinearP3 | chart_noicc.jpg | sRGB IEC61966-2.1 | SRGB | 0.18 | 0.59 | 0.73 | 0.30 | 0.79 | 0/880144 | 4 | 0 | SRGB |
| extLinearP3 | chart_p3values_noicc.png | 无 | SRGB | 2.37 | 4.11 | 4.29 | 2.50 | 4.13 | 0/880144 | 4 | 0 | SRGB |
| extLinear2020 | chart_srgb.jpg | sRGB IEC61966-2.1 | SRGB | 0.18 | 0.59 | 0.73 | 0.29 | 0.79 | 0/880144 | 4 | 0 | SRGB |
| extLinear2020 | chart_adobergb.jpg | Adobe RGB (1998) | AdobeRGB1998 | 0.21 | 0.78 | 1.15 | 0.35 | 1.01 | 0/880144 | 4 | 0 | SRGB |
| extLinear2020 | chart_p3.jpg | Display P3 | DisplayP3 | 0.20 | 0.61 | 1.35 | 0.36 | 0.93 | 0/880144 | 4 | 0 | SRGB |
| extLinear2020 | chart_prophoto.jpg | ROMM RGB: ISO 22028-2:2013 | ROMMRGB | 0.28 | 0.97 | 1.30 | 0.44 | 1.04 | 0/880144 | 4 | 0 | SRGB |
| extLinear2020 | chart_srgb_16.tif | sRGB IEC61966-2.1 | SRGB | 0.05 | 0.21 | 0.50 | 0.30 | 0.82 | 0/880144 | 4 | 0 | SRGB |
| extLinear2020 | chart_adobergb_16.tif | Adobe RGB (1998) | AdobeRGB1998 | 0.05 | 0.27 | 0.50 | 0.31 | 0.90 | 0/880144 | 4 | 0 | SRGB |
| extLinear2020 | chart_p3_16.tif | Display P3 | DisplayP3 | 0.05 | 0.21 | 0.50 | 0.30 | 0.82 | 0/880144 | 4 | 0 | SRGB |
| extLinear2020 | chart_prophoto_16.tif | ROMM RGB: ISO 22028-2:2013 | ROMMRGB | 0.05 | 0.21 | 0.40 | 0.30 | 0.82 | 0/880144 | 4 | 0 | SRGB |
| extLinear2020 | chart_noicc.png | 无 | SRGB | 0.05 | 0.18 | 0.29 | 0.32 | 0.82 | 0/880144 | 4 | 0 | SRGB |
| extLinear2020 | chart_noicc.jpg | sRGB IEC61966-2.1 | SRGB | 0.18 | 0.59 | 0.73 | 0.29 | 0.79 | 0/880144 | 4 | 0 | SRGB |
| extLinear2020 | chart_p3values_noicc.png | 无 | SRGB | 2.37 | 4.11 | 4.29 | 2.50 | 4.13 | 0/880144 | 4 | 0 | SRGB |

### 1.1 照片与背景交界：缩放前是否 clampedToExtent

外沿 = 照片外 3px 背景带相对 (250,250,248) 的最大码值偏差；内沿 = 照片内 3px 相对向内 8px 处像素的最大码值偏差（色卡边缘色块为纯色，理想为 0）。

| 工作空间 | 缩放写法 | 照片尺寸 | 外沿 / 内沿 最大偏差 |
|---|---|---|---|
| extLinearSRGB | 直接 Lanczos（边外为透明） | 900×600 | 0 / 21 |
| extLinearSRGB | clampedToExtent → Lanczos → 裁到整数尺寸 | 900×600 | 0 / 1 |
| extLinearP3 | 直接 Lanczos（边外为透明） | 900×600 | 0 / 21 |
| extLinearP3 | clampedToExtent → Lanczos → 裁到整数尺寸 | 900×600 | 0 / 1 |
| extLinear2020 | 直接 Lanczos（边外为透明） | 900×600 | 0 / 21 |
| extLinear2020 | clampedToExtent → Lanczos → 裁到整数尺寸 | 900×600 | 0 / 1 |

## 2. 广色域与中途截断

统计色块内部像素：真值在该空间里超出 [0,1]（需要 extended range）的像素数，以及其中被压回 [0,1] 的像素数（= 被截断）。
S1 = 解码后直接渲染到工作空间 RGBAf；S2 = 缩放 + 合成后的画布；CG = ImageIO 解码的 CGImage 画进工作空间 half-float CGContext。

| 输入 | 工作空间 | S1 需 extended 像素 | S1 被截断 | S2 需 extended 像素 | S2 被截断 | CG 被截断 | S1 域内最大误差 | sRGB 输出·域内色块数: ΔE 中位/max | sRGB 输出·域外色块数: ΔE 中位/max |
|---|---|---|---|---|---|---|---|---|---|
| wide_prophoto_16.tif | extLinearSRGB | 427424 | 0 | 293706 | 0 | 0 | 0.0000 | 22: 0.08 / 0.16 | 74: 11.11 / 28.66 |
| wide_prophoto_16.tif | extLinearP3 | 410096 | 0 | 281799 | 0 | 0 | 0.0001 | 22: 0.08 / 0.16 | 74: 11.11 / 28.66 |
| wide_prophoto_16.tif | extLinear2020 | 375440 | 0 | 257985 | 0 | 0 | 0.0001 | 22: 0.08 / 0.16 | 74: 11.11 / 28.66 |
| wide_p3_16.tif | extLinearSRGB | 329232 | 0 | 226233 | 0 | 0 | 0.0000 | 38: 0.09 / 0.28 | 58: 3.29 / 9.18 |
| wide_p3_16.tif | extLinearP3 | 0 | 0 | 0 | 0 | 0 | 0.0000 | 38: 0.09 / 0.25 | 58: 3.29 / 9.18 |
| wide_p3_16.tif | extLinear2020 | 0 | 0 | 0 | 0 | 0 | 0.0000 | 38: 0.09 / 0.25 | 58: 3.29 / 9.18 |

## 3. 16-bit 渐变断层

渐变 4096 px 宽，不缩放（scale = 1），取中间一行。理想值由参考数学直接从源值算到 sRGB。
解码并转入工作空间后用 insertingIntermediate() 强制落一次中间缓冲，这样工作格式（RGBAh/RGBAf）才真正参与（否则 CI 会把整条链合成一个 kernel，不落中间缓冲）。
“级数”= 输出中不同码值的个数；8-bit 中间格式会让 16-bit 输出的级数掉到 ≤256。带“反例”的行是故意制造的 8-bit 中间结果，用来证明检测有效。

| 输入 | 工作空间 | 中间格式 | 8-bit 级数 实/理想 | 8-bit 最大台阶 | 8-bit 最大误差 | 8-bit 回退 | 16-bit 级数 实/理想 | 16-bit 最大台阶 | 16-bit 最大误差 | 16-bit 回退 |
|---|---|---|---|---|---|---|---|---|---|---|
| gradient_prophoto_16.tif | extLinearSRGB | RGBAh | 256/256 | 1 | 1 | 0 | 3810/4095 | 30 | 20 | 1 |
| gradient_prophoto_16.tif | extLinearSRGB | RGBAf | 256/256 | 1 | 0 | 0 | 4095/4095 | 29 | 1 | 1 |
| gradient_prophoto_16.tif | extLinearP3 | RGBAh | 256/256 | 1 | 1 | 0 | 3811/4095 | 30 | 20 | 2 |
| gradient_prophoto_16.tif | extLinearP3 | RGBAf | 256/256 | 1 | 0 | 0 | 4095/4095 | 29 | 1 | 1 |
| gradient_prophoto_16.tif | extLinear2020 | RGBAh | 256/256 | 1 | 1 | 0 | 3810/4095 | 30 | 20 | 2 |
| gradient_prophoto_16.tif | extLinear2020 | RGBAf | 256/256 | 1 | 0 | 0 | 4095/4095 | 29 | 1 | 1 |
| gradient_prophoto_16.tif | extLinearSRGB | RGBA8 线性中间缓冲（反例） | 256/256 | 1 | 1 | 0 | 3810/4095 | 30 | 20 | 1 |
| gradient_prophoto_16.tif | extLinearSRGB | 8-bit sRGB CGImage 中转（反例） | 256/256 | 1 | 1 | 0 | 256/4095 | 257 | 143 | 0 |
| gradient_dark_srgb_16.tif | extLinearSRGB | RGBAh | 52/52 | 1 | 1 | 0 | 3728/4096 | 8 | 7 | 0 |
| gradient_dark_srgb_16.tif | extLinearSRGB | RGBAf | 52/52 | 1 | 0 | 0 | 4096/4096 | 4 | 0 | 0 |
| gradient_dark_srgb_16.tif | extLinearP3 | RGBAh | 52/52 | 1 | 1 | 0 | 3728/4096 | 8 | 7 | 0 |
| gradient_dark_srgb_16.tif | extLinearP3 | RGBAf | 52/52 | 1 | 0 | 0 | 4096/4096 | 4 | 0 | 0 |
| gradient_dark_srgb_16.tif | extLinear2020 | RGBAh | 52/52 | 1 | 1 | 0 | 3728/4096 | 8 | 7 | 0 |
| gradient_dark_srgb_16.tif | extLinear2020 | RGBAf | 52/52 | 1 | 0 | 0 | 4096/4096 | 4 | 0 | 0 |
| gradient_dark_srgb_16.tif | extLinearSRGB | RGBA8 线性中间缓冲（反例） | 52/52 | 1 | 1 | 0 | 3728/4096 | 8 | 7 | 0 |
| gradient_dark_srgb_16.tif | extLinearSRGB | 8-bit sRGB CGImage 中转（反例） | 52/52 | 1 | 1 | 0 | 52/4096 | 257 | 132 | 0 |

## 4. 透明边缘（黑边 / 白边）与合成所在的域

水印 PNG 为直通 alpha，透明像素 RGB 故意为黑色（最容易出黑边）。缩放 0.73 后叠到深色 (32,32,32) 与 #FAFAF8 背景。
“黑边/白边像素”= 任一通道超出 [min(背景,前景), max(背景,前景)] ±1 的像素。50% 白块的理想值：线性光合成 vs gamma 空间合成。

| 背景 | 路径 | 偏暗像素（最大码值） | 偏亮像素（最大码值） | 检查像素 | 50% 白块实测 R | 50% 红块实测 RGB | 白块理想 线性/gamma | 红块理想 线性/gamma |
|---|---|---|---|---|---|---|---|---|
| (32,32,32) | CI · extLinearSRGB · Lanczos | 1275 (≤32) | 0 (≤0) | 35816 | 189 | (148, 31, 31) | 189 / 144 | (148, 31, 31) / (116, 31, 31) |
| (32,32,32) | CI · extLinearSRGB · 双线性 | 0 (≤0) | 0 (≤0) | 35816 | 189 | (148, 31, 31) | 189 / 144 | (148, 31, 31) / (116, 31, 31) |
| (32,32,32) | CI · extLinearP3 · Lanczos | 1275 (≤32) | 0 (≤0) | 35816 | 189 | (148, 31, 31) | 189 / 144 | (148, 31, 31) / (116, 31, 31) |
| (32,32,32) | CI · extLinearP3 · 双线性 | 0 (≤0) | 0 (≤0) | 35816 | 189 | (148, 31, 31) | 189 / 144 | (148, 31, 31) / (116, 31, 31) |
| (32,32,32) | CI · extLinear2020 · Lanczos | 1275 (≤32) | 0 (≤0) | 35816 | 189 | (148, 31, 31) | 189 / 144 | (148, 31, 31) / (116, 31, 31) |
| (32,32,32) | CI · extLinear2020 · 双线性 | 0 (≤0) | 0 (≤0) | 35816 | 189 | (148, 31, 31) | 189 / 144 | (148, 31, 31) / (116, 31, 31) |
| (32,32,32) | CG · sRGB 8-bit 上下文 | 0 (≤0) | 0 (≤0) | 35816 | 144 | (116, 31, 31) | 189 / 144 | (148, 31, 31) / (116, 31, 31) |
| (32,32,32) | CG · extLinearSRGB half 上下文 | 274 (≤32) | 0 (≤0) | 35816 | 189 | (148, 31, 31) | 189 / 144 | (148, 31, 31) / (116, 31, 31) |
| (250,250,248) | CI · extLinearSRGB · Lanczos | 0 (≤0) | 238 (≤5) | 35816 | 253 | (227, 185, 183) | 253 / 253 | (227, 185, 183) / (225, 140, 139) |
| (250,250,248) | CI · extLinearSRGB · 双线性 | 0 (≤0) | 0 (≤0) | 35816 | 253 | (227, 185, 183) | 253 / 253 | (227, 185, 183) / (225, 140, 139) |
| (250,250,248) | CI · extLinearP3 · Lanczos | 0 (≤0) | 238 (≤5) | 35816 | 253 | (227, 185, 183) | 253 / 253 | (227, 185, 183) / (225, 140, 139) |
| (250,250,248) | CI · extLinearP3 · 双线性 | 0 (≤0) | 0 (≤0) | 35816 | 253 | (227, 185, 183) | 253 / 253 | (227, 185, 183) / (225, 140, 139) |
| (250,250,248) | CI · extLinear2020 · Lanczos | 0 (≤0) | 238 (≤5) | 35816 | 253 | (227, 185, 183) | 253 / 253 | (227, 185, 183) / (225, 140, 139) |
| (250,250,248) | CI · extLinear2020 · 双线性 | 0 (≤0) | 0 (≤0) | 35816 | 253 | (227, 185, 183) | 253 / 253 | (227, 185, 183) / (225, 140, 139) |
| (250,250,248) | CG · sRGB 8-bit 上下文 | 0 (≤0) | 0 (≤0) | 35816 | 253 | (225, 140, 139) | 253 / 253 | (227, 185, 183) / (225, 140, 139) |
| (250,250,248) | CG · extLinearSRGB half 上下文 | 145 (≤5) | 0 (≤0) | 35816 | 253 | (227, 185, 183) | 253 / 253 | (227, 185, 183) / (225, 140, 139) |

## 5. EXIF 方向

| 工作空间 | EXIF 方向 | 输出照片尺寸 | 四象限最大 ΔE | 结果 |
|---|---|---|---|---|
| extLinearSRGB | 1 | 300×200 | 0.29 | ✅ |
| extLinearSRGB | 3 | 300×200 | 0.29 | ✅ |
| extLinearSRGB | 6 | 300×200 | 0.29 | ✅ |
| extLinearSRGB | 8 | 300×200 | 0.29 | ✅ |
| extLinearP3 | 1 | 300×200 | 0.29 | ✅ |
| extLinearP3 | 3 | 300×200 | 0.29 | ✅ |
| extLinearP3 | 6 | 300×200 | 0.29 | ✅ |
| extLinearP3 | 8 | 300×200 | 0.29 | ✅ |
| extLinear2020 | 1 | 300×200 | 0.29 | ✅ |
| extLinear2020 | 3 | 300×200 | 0.29 | ✅ |
| extLinear2020 | 6 | 300×200 | 0.29 | ✅ |
| extLinear2020 | 8 | 300×200 | 0.29 | ✅ |

ImageIO 缩略图（kCGImageSourceCreateThumbnailWithTransform）交叉验证：方向 1: 缩略图 300×200，左上象限 ≈ (220,40,41)；方向 3: 缩略图 300×200，左上象限 ≈ (220,40,41)；方向 6: 缩略图 300×200，左上象限 ≈ (220,40,41)；方向 8: 缩略图 300×200，左上象限 ≈ (220,40,41)

## 6. HDR

场景：第 0 行中性色块线性亮度 0.05, 0.18, 0.50, 0.75, 1.00, 1.50, 2.00, 3.00, 4.00, 5.00, 6.00, 8.00（相对 SDR 参考白）；第 1 行彩色高光（含 P3 / Rec.2020 原色）；底部 0→8 渐变。
k = 解码后 1.0 色块的实测 Y：Apple 把多少当作 SDR 参考白。

### 6.1 解码进入工作空间（S1）与合成后（S2）

| 输入 | 工作空间 | CIImage.colorSpace | contentHeadroom | k（1.0 色块实测 Y） | 中性色块 Y/k | S1 需 extended/被截断 | S2 需 extended/被截断 | 合成后背景线性 Y |
|---|---|---|---|---|---|---|---|---|
| hdr_gainmap.jpg | extLinearSRGB | DisplayP3_PQ | 8.00 | 0.998 | 0.05 0.18 0.50 0.75 1.00 1.50 1.99 3.01 3.99 5.00 6.02 8.01 | 256880/323 | 66139/0 | 0.9547 (期望 0.9547) |
| hdr_gainmap.jpg | extLinearP3 | DisplayP3_PQ | 8.00 | 0.998 | 0.05 0.18 0.50 0.75 1.00 1.50 1.99 3.01 3.99 5.00 6.02 8.01 | 255840/243 | 66139/0 | 0.9547 (期望 0.9547) |
| hdr_gainmap.jpg | extLinear2020 | DisplayP3_PQ | 8.00 | 0.998 | 0.05 0.18 0.50 0.75 1.00 1.50 1.99 3.01 3.99 5.00 6.02 8.01 | 241280/163 | 59177/0 | 0.9547 (期望 0.9547) |
| hdr_pq2020_203nit.png | extLinearSRGB | ITUR_2100_PQ | 4.93 | 1.000 | 0.05 0.18 0.50 0.75 1.00 1.50 2.00 3.00 4.00 5.00 6.00 8.00 | 256960/0 | 66139/0 | 0.9547 (期望 0.9547) |
| hdr_pq2020_203nit.png | extLinearP3 | ITUR_2100_PQ | 4.93 | 1.000 | 0.05 0.18 0.50 0.75 1.00 1.50 2.00 3.00 4.00 5.00 6.00 8.00 | 255840/0 | 66139/0 | 0.9547 (期望 0.9547) |
| hdr_pq2020_203nit.png | extLinear2020 | ITUR_2100_PQ | 4.93 | 1.000 | 0.05 0.18 0.50 0.75 1.00 1.50 2.00 3.00 4.00 5.00 6.00 8.00 | 241280/0 | 59177/0 | 0.9547 (期望 0.9547) |
| hdr_float_linear2020.tif | extLinearSRGB | ICC(580B, Rec. ITU-R BT.2020-1 Linear) | 0.00 | 1.000 | 0.05 0.18 0.50 0.75 1.00 1.50 2.00 3.00 4.00 5.00 6.00 8.00 | 256960/0 | 66139/0 | 0.9547 (期望 0.9547) |
| hdr_float_linear2020.tif | extLinearP3 | ICC(580B, Rec. ITU-R BT.2020-1 Linear) | 0.00 | 1.000 | 0.05 0.18 0.50 0.75 1.00 1.50 2.00 3.00 4.00 5.00 6.00 8.00 | 255840/0 | 66139/0 | 0.9547 (期望 0.9547) |
| hdr_float_linear2020.tif | extLinear2020 | ICC(580B, Rec. ITU-R BT.2020-1 Linear) | 0.00 | 1.000 | 0.05 0.18 0.50 0.75 1.00 1.50 2.00 3.00 4.00 5.00 6.00 8.00 | 241280/0 | 59177/0 | 0.9547 (期望 0.9547) |

### 6.2 SDR 输出：直接截断 / CIToneMapHeadroom / gain map 底图

| 输入 | 工作空间 | SDR 方法 | 中性色块码值（0.05 … 8.0） | 照片内 255 像素 | SDR 色卡 ΔE 中位 | 背景≠#FAFAF8 |
|---|---|---|---|---|---|---|
| hdr_gainmap.jpg | extLinearSRGB | 直接截断 | 63 118 187 225 255 255 255 255 255 255 255 255 | 227813 | 0.94 | 0 |
| hdr_gainmap.jpg | extLinearSRGB | CIToneMapHeadroom | 42 77 120 142 160 183 197 216 228 237 244 255 | 25134 | 17.10 | 0 |
| hdr_gainmap.jpg | extLinearSRGB | gain map 底图 | 43 84 130 151 166 187 202 223 237 248 255 255 | 61443 | 14.51 | 0 |
| hdr_gainmap.jpg | extLinearP3 | 直接截断 | 63 118 187 225 255 255 255 255 255 255 255 255 | 227813 | 0.94 | 0 |
| hdr_gainmap.jpg | extLinearP3 | CIToneMapHeadroom | 42 77 120 142 160 183 197 216 228 237 244 255 | 25126 | 17.01 | 0 |
| hdr_gainmap.jpg | extLinearP3 | gain map 底图 | 43 84 130 151 166 187 202 223 237 248 255 255 | 61435 | 14.51 | 0 |
| hdr_gainmap.jpg | extLinear2020 | 直接截断 | 63 118 187 225 255 255 255 255 255 255 255 255 | 227813 | 0.94 | 0 |
| hdr_gainmap.jpg | extLinear2020 | CIToneMapHeadroom | 42 77 120 142 160 183 197 216 228 237 244 255 | 25129 | 17.10 | 0 |
| hdr_gainmap.jpg | extLinear2020 | gain map 底图 | 43 84 130 151 166 187 202 223 237 248 255 255 | 61435 | 14.51 | 0 |
| hdr_pq2020_203nit.png | extLinearSRGB | 直接截断 | 63 118 188 225 255 255 255 255 255 255 255 255 | 228057 | 0.00 | 0 |
| hdr_pq2020_203nit.png | extLinearSRGB | CIToneMapHeadroom | 50 90 141 167 188 211 224 239 249 255 255 255 | 116639 | 12.30 | 0 |
| hdr_pq2020_203nit.png | extLinearP3 | 直接截断 | 63 118 188 225 255 255 255 255 255 255 255 255 | 228057 | 0.00 | 0 |
| hdr_pq2020_203nit.png | extLinearP3 | CIToneMapHeadroom | 50 90 141 167 188 211 224 239 249 255 255 255 | 116638 | 12.30 | 0 |
| hdr_pq2020_203nit.png | extLinear2020 | 直接截断 | 63 118 188 225 255 255 255 255 255 255 255 255 | 228057 | 0.00 | 0 |
| hdr_pq2020_203nit.png | extLinear2020 | CIToneMapHeadroom | 50 90 141 167 188 211 224 239 249 255 255 255 | 116643 | 12.30 | 0 |
| hdr_float_linear2020.tif | extLinearSRGB | 直接截断 | 63 118 188 225 255 255 255 255 255 255 255 255 | 228057 | 0.00 | 0 |
| hdr_float_linear2020.tif | extLinearSRGB | CIToneMapHeadroom | 42 77 120 142 160 183 197 216 228 237 244 255 | 36141 | 17.23 | 0 |
| hdr_float_linear2020.tif | extLinearP3 | 直接截断 | 63 118 188 225 255 255 255 255 255 255 255 255 | 228057 | 0.00 | 0 |
| hdr_float_linear2020.tif | extLinearP3 | CIToneMapHeadroom | 42 77 120 142 160 183 197 216 228 237 244 255 | 36166 | 17.23 | 0 |
| hdr_float_linear2020.tif | extLinear2020 | 直接截断 | 63 118 188 225 255 255 255 255 255 255 255 255 | 228057 | 0.00 | 0 |
| hdr_float_linear2020.tif | extLinear2020 | CIToneMapHeadroom | 42 77 120 142 160 183 197 216 228 237 244 255 | 36167 | 17.23 | 0 |

tone map 结果随工作空间的差异（8-bit 输出，照片区域 ΔE2000）：

| 输入 | 比较 | 中位 | P95 | max |
|---|---|---|---|---|
| hdr_gainmap.jpg | extLinearSRGB vs extLinearP3 | 0.00 | 0.00 | 1.23 |
| hdr_gainmap.jpg | extLinearSRGB vs extLinear2020 | 0.00 | 0.00 | 1.23 |
| hdr_pq2020_203nit.png | extLinearSRGB vs extLinearP3 | 0.00 | 0.00 | 0.59 |
| hdr_pq2020_203nit.png | extLinearSRGB vs extLinear2020 | 0.00 | 0.00 | 0.61 |
| hdr_float_linear2020.tif | extLinearSRGB vs extLinearP3 | 0.00 | 0.00 | 0.66 |
| hdr_float_linear2020.tif | extLinearSRGB vs extLinear2020 | 0.00 | 0.00 | 0.66 |

### 6.3 HDR 输出（gain map JPEG）写出 → 读回

“HDR 读回比值”= 读回展开后的中性色块 Y ÷ 写出前合成图的 Y；只在 headroom 以内的级别统计最大相对误差。SDR 回退 = 不展开 gain map 的底图。

| 输入 | 工作空间 | 路线 | gain map | 底图 ICC | 读回 headroom | HDR 读回比值（各级） | headroom 内最大相对误差 | SDR 底图背景最大偏差 | SDR 底图中性色块码值 | SDR 底图 vs 期望 SDR 渲染 ΔE 中位/P95 | HDR 读回背景线性 Y | 高光 Δu′v′ 中位/P95 | gain map 尺寸/格式 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| hdr_gainmap.jpg | extLinearSRGB | CI·tonemap 底图 | ISO ✅ | sRGB IEC61966-2.1 | 8.00 | 1.00 0.99 1.01 1.00 1.01 1.00 1.00 1.00 1.00 1.00 1.01 1.00 | 0.007 | 1 | 42 77 120 142 160 183 197 216 228 237 244 255 | 0.00 / 0.49 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 L008 |
| hdr_gainmap.jpg | extLinearSRGB | CI·原 gain map 底图 | ISO ✅ | sRGB IEC61966-2.1 | 8.00 | 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.001 | 1 | 43 84 130 151 166 187 202 223 237 248 255 255 | 0.00 / 0.46 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 L008 |
| hdr_gainmap.jpg | extLinearSRGB | CI·tonemap 底图·RGB gain map | ISO ✅ | sRGB IEC61966-2.1 | 8.00 | 1.00 0.99 1.01 1.00 1.01 1.00 1.00 1.00 1.00 1.00 1.01 1.00 | 0.007 | 1 | 42 77 120 142 160 183 197 216 228 237 244 255 | 0.00 / 0.49 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 444f |
| hdr_gainmap.jpg | extLinearSRGB | ImageIO | ISO ✅ | Display P3 | 8.00 | 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.001 | 89 | 43 84 130 151 166 187 202 223 237 248 255 255 | 2.85 / 8.05 | 0.9511 | 0.0000 / 0.0238 | 540×675 L008 |
| hdr_gainmap.jpg | extLinearP3 | CI·tonemap 底图 | ISO ✅ | sRGB IEC61966-2.1 | 8.00 | 1.00 0.99 1.01 1.00 1.01 1.00 1.00 1.00 1.00 1.00 1.01 1.00 | 0.007 | 1 | 42 77 120 142 160 183 197 216 228 237 244 255 | 0.00 / 0.45 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 L008 |
| hdr_gainmap.jpg | extLinearP3 | CI·原 gain map 底图 | ISO ✅ | sRGB IEC61966-2.1 | 8.00 | 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.001 | 1 | 43 84 130 151 166 187 202 223 237 248 255 255 | 0.00 / 0.45 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 L008 |
| hdr_gainmap.jpg | extLinearP3 | CI·tonemap 底图·RGB gain map | ISO ✅ | sRGB IEC61966-2.1 | 8.00 | 1.00 0.99 1.01 1.00 1.01 1.00 1.00 1.00 1.00 1.00 1.01 1.00 | 0.007 | 1 | 42 77 120 142 160 183 197 216 228 237 244 255 | 0.00 / 0.45 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 444f |
| hdr_gainmap.jpg | extLinearP3 | ImageIO | ISO ✅ | Display P3 | 8.00 | 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.001 | 89 | 43 84 130 151 166 187 202 223 237 248 255 255 | 2.85 / 8.67 | 0.9511 | 0.0000 / 0.0270 | 540×675 L008 |
| hdr_gainmap.jpg | extLinear2020 | CI·tonemap 底图 | ISO ✅ | sRGB IEC61966-2.1 | 8.00 | 1.00 0.99 1.01 1.00 1.01 1.00 1.00 1.00 1.00 1.00 1.01 1.00 | 0.007 | 1 | 42 77 120 142 160 183 197 216 228 237 244 255 | 0.00 / 0.48 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 L008 |
| hdr_gainmap.jpg | extLinear2020 | CI·原 gain map 底图 | ISO ✅ | sRGB IEC61966-2.1 | 8.00 | 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.001 | 1 | 43 84 130 151 166 187 202 223 237 248 255 255 | 0.00 / 0.45 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 L008 |
| hdr_gainmap.jpg | extLinear2020 | CI·tonemap 底图·RGB gain map | ISO ✅ | sRGB IEC61966-2.1 | 8.00 | 1.00 0.99 1.01 1.00 1.01 1.00 1.00 1.00 1.00 1.00 1.01 1.00 | 0.007 | 1 | 42 77 120 142 160 183 197 216 228 237 244 255 | 0.00 / 0.48 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 444f |
| hdr_gainmap.jpg | extLinear2020 | ImageIO | ISO ✅ | Display P3 | 8.00 | 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.001 | 89 | 43 84 130 151 166 187 202 223 237 248 255 255 | 3.00 / 8.53 | 0.9511 | 0.0000 / 0.0283 | 540×675 L008 |
| hdr_pq2020_203nit.png | extLinearSRGB | CI·tonemap 底图 | ISO ✅ | sRGB IEC61966-2.1 | 8.89 | 1.01 0.99 1.00 1.01 1.01 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.014 | 1 | 50 90 141 167 188 211 224 239 249 255 255 255 | 0.00 / 0.47 | 0.9570 | 0.0000 / 0.0236 | 1080×1350 L008 |
| hdr_pq2020_203nit.png | extLinearSRGB | CI·tonemap 底图·RGB gain map | ISO ✅ | sRGB IEC61966-2.1 | 8.89 | 1.01 0.99 1.00 1.01 1.01 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.014 | 1 | 50 90 141 167 188 211 224 239 249 255 255 255 | 0.00 / 0.47 | 0.9570 | 0.0000 / 0.0173 | 1080×1350 444f |
| hdr_pq2020_203nit.png | extLinearSRGB | ImageIO | ISO ✅ | Display P3 | 4.93 | 0.98 1.01 0.99 1.00 1.00 1.00 1.00 1.00 1.00 0.93 0.82 0.62 | 0.018 | 89 | 43 84 130 151 166 187 202 223 237 248 255 255 | 3.61 / 9.20 | 0.9476 | 0.0000 / 0.0505 | 540×675 L008 |
| hdr_pq2020_203nit.png | extLinearP3 | CI·tonemap 底图 | ISO ✅ | sRGB IEC61966-2.1 | 8.89 | 1.01 0.99 1.00 1.01 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.014 | 1 | 50 90 141 167 188 211 224 239 249 255 255 255 | 0.00 / 0.47 | 0.9570 | 0.0000 / 0.0236 | 1080×1350 L008 |
| hdr_pq2020_203nit.png | extLinearP3 | CI·tonemap 底图·RGB gain map | ISO ✅ | sRGB IEC61966-2.1 | 8.89 | 1.01 0.99 1.00 1.01 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.014 | 1 | 50 90 141 167 188 211 224 239 249 255 255 255 | 0.00 / 0.47 | 0.9570 | 0.0000 / 0.0173 | 1080×1350 444f |
| hdr_pq2020_203nit.png | extLinearP3 | ImageIO | ISO ✅ | Display P3 | 4.93 | 0.98 1.01 0.99 1.00 1.00 1.00 1.00 1.00 1.00 0.93 0.82 0.62 | 0.018 | 89 | 43 84 130 151 166 187 202 223 237 248 255 255 | 3.59 / 8.14 | 0.9476 | 0.0000 / 0.0493 | 540×675 L008 |
| hdr_pq2020_203nit.png | extLinear2020 | CI·tonemap 底图 | ISO ✅ | sRGB IEC61966-2.1 | 8.89 | 1.01 0.99 1.00 1.01 1.01 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.014 | 1 | 50 90 141 167 188 211 224 239 249 255 255 255 | 0.00 / 0.47 | 0.9570 | 0.0000 / 0.0236 | 1080×1350 L008 |
| hdr_pq2020_203nit.png | extLinear2020 | CI·tonemap 底图·RGB gain map | ISO ✅ | sRGB IEC61966-2.1 | 8.89 | 1.01 0.99 1.00 1.01 1.01 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.014 | 1 | 50 90 141 167 188 211 224 239 249 255 255 255 | 0.00 / 0.47 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 444f |
| hdr_pq2020_203nit.png | extLinear2020 | ImageIO | ISO ✅ | Display P3 | 4.93 | 0.98 1.01 0.99 1.00 1.00 1.00 1.00 1.00 1.00 0.93 0.82 0.62 | 0.018 | 89 | 43 84 130 151 166 187 202 223 237 248 255 255 | 3.59 / 7.54 | 0.9476 | 0.0000 / 0.0510 | 540×675 L008 |
| hdr_float_linear2020.tif | extLinearSRGB | CI·tonemap 底图 | ISO ✅ | sRGB IEC61966-2.1 | 8.89 | 0.99 0.99 1.00 1.00 1.01 1.00 0.99 1.00 1.00 1.00 0.99 1.00 | 0.015 | 2 | 42 77 120 142 160 183 197 216 228 237 244 255 | 0.00 / 0.59 | 0.9570 | 0.0000 / 0.0173 | 1080×1350 L008 |
| hdr_float_linear2020.tif | extLinearSRGB | CI·tonemap 底图·RGB gain map | ISO ✅ | sRGB IEC61966-2.1 | 8.89 | 0.99 0.99 1.00 1.00 1.01 1.00 0.99 1.00 1.00 1.00 0.99 1.00 | 0.015 | 2 | 42 77 120 142 160 183 197 216 228 237 244 255 | 0.00 / 0.59 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 444f |
| hdr_float_linear2020.tif | extLinearSRGB | ImageIO | ISO ✅ | Display P3 | 8.00 | 0.98 1.00 0.99 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.015 | 89 | 43 84 130 151 166 187 202 223 237 248 255 255 | 2.62 / 12.95 | 0.9511 | 0.0000 / 0.0505 | 540×675 L008 |
| hdr_float_linear2020.tif | extLinearP3 | CI·tonemap 底图 | ISO ✅ | sRGB IEC61966-2.1 | 8.89 | 0.98 0.99 1.00 1.00 1.00 1.00 0.99 1.00 1.00 1.00 0.99 1.00 | 0.023 | 2 | 42 77 120 142 160 183 197 216 228 237 244 255 | 0.00 / 0.60 | 0.9570 | 0.0000 / 0.0173 | 1080×1350 L008 |
| hdr_float_linear2020.tif | extLinearP3 | CI·tonemap 底图·RGB gain map | ISO ✅ | sRGB IEC61966-2.1 | 8.89 | 0.98 0.99 1.00 1.00 1.00 1.00 0.99 1.00 1.00 1.00 0.99 1.00 | 0.023 | 2 | 42 77 120 142 160 183 197 216 228 237 244 255 | 0.00 / 0.60 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 444f |
| hdr_float_linear2020.tif | extLinearP3 | ImageIO | ISO ✅ | Display P3 | 8.00 | 0.98 1.00 0.99 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.015 | 89 | 43 84 130 151 166 187 202 223 237 248 255 255 | 2.77 / 11.56 | 0.9511 | 0.0000 / 0.0493 | 540×675 L008 |
| hdr_float_linear2020.tif | extLinear2020 | CI·tonemap 底图 | ISO ✅ | sRGB IEC61966-2.1 | 8.89 | 0.98 0.99 1.00 1.00 1.00 1.00 0.99 1.00 1.00 1.00 0.99 1.00 | 0.023 | 1 | 42 77 120 142 160 183 197 216 228 237 244 255 | 0.00 / 0.60 | 0.9570 | 0.0000 / 0.0173 | 1080×1350 L008 |
| hdr_float_linear2020.tif | extLinear2020 | CI·tonemap 底图·RGB gain map | ISO ✅ | sRGB IEC61966-2.1 | 8.89 | 0.98 0.99 1.00 1.00 1.00 1.00 0.99 1.00 1.00 1.00 0.99 1.00 | 0.023 | 1 | 42 77 120 142 160 183 197 216 228 237 244 255 | 0.00 / 0.60 | 0.9570 | 0.0000 / 0.0172 | 1080×1350 444f |
| hdr_float_linear2020.tif | extLinear2020 | ImageIO | ISO ✅ | Display P3 | 8.00 | 0.98 1.00 0.99 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 1.00 | 0.015 | 89 | 43 84 130 151 166 187 202 223 237 248 255 255 | 3.00 / 11.30 | 0.9511 | 0.0000 / 0.0510 | 540×675 L008 |

## 8. 隐式转换探针（P1–P11）

### P1 ImageIO 解码是否改动像素

| 文件 | 解码位深 | alpha | CGImage 颜色空间 | 与写入值最大差（码值；float 为绝对值） | 最大分量值 |
|---|---|---|---|---|---|
| chart_prophoto_16.tif | 16 | none | ROMMRGB | 0.50 | 1.00 |
| chart_p3_16.tif | 16 | none | DisplayP3 | 0.50 | 1.00 |
| chart_adobergb.jpg | 8 | noneSkipLast | AdobeRGB1998 | 1.47 | 1.00 |
| watermark_alpha.png | 8 | last | SRGB | 0.47 | 1.00 |
| hdr_float_linear2020.tif | 32 float | none | ICC(580B, Rec. ITU-R BT.2020-1 Linear) | 0.0000 | 8.00 |
| hdr_pq2020_203nit.png | 16 | none | ITUR_2100_PQ | 0.50 | 0.80 |

### P2 无 ICC 文件在各层的表现

| 文件 | ImageIO ProfileName | 解码 CGImage 颜色空间 | CIImage.colorSpace | 文件里实际有颜色描述块 |
|---|---|---|---|---|
| chart_noicc.png | nil | SRGB | SRGB | 无 |
| chart_noicc.jpg | sRGB IEC61966-2.1 | SRGB | SRGB | 无 |
| chart_srgb.jpg | sRGB IEC61966-2.1 | SRGB | SRGB | 无 |

### P3 降采样解码（CGImageSourceCreateThumbnailAtIndex，max 480）

| 文件 | 选项 | 尺寸 | 位深 | 颜色空间 | 最大分量 |
|---|---|---|---|---|---|
| chart_prophoto_16.tif | 默认 | 480×320 | 16 | ROMMRGB | 1.00 |
| chart_prophoto_16.tif | ShouldAllowFloat | 480×320 | 16 | ROMMRGB | 1.00 |
| chart_prophoto_16.tif | DecodeToHDR | 480×320 | 16 | ROMMRGB | 1.00 |
| chart_p3.jpg | 默认 | 480×320 | 8 | DisplayP3 | 1.00 |
| chart_p3.jpg | ShouldAllowFloat | 480×320 | 8 | DisplayP3 | 1.00 |
| chart_p3.jpg | DecodeToHDR | 480×320 | 8 | DisplayP3 | 1.00 |
| hdr_float_linear2020.tif | 默认 | 480×320 | 32 float | ICC(580B, Rec. ITU-R BT.2020-1 Linear) | 8.19 |
| hdr_float_linear2020.tif | ShouldAllowFloat | 480×320 | 32 float | ICC(580B, Rec. ITU-R BT.2020-1 Linear) | 8.19 |
| hdr_float_linear2020.tif | DecodeToHDR | 480×320 | 32 float | ICC(580B, Rec. ITU-R BT.2020-1 Linear) | 8.19 |
| hdr_pq2020_203nit.png | 默认 | 480×320 | 16 | ITUR_2100_PQ | 0.82 |
| hdr_pq2020_203nit.png | ShouldAllowFloat | 480×320 | 16 | ITUR_2100_PQ | 0.82 |
| hdr_pq2020_203nit.png | DecodeToHDR | 480×320 | 16 | ITUR_2100_PQ | 0.82 |
| hdr_gainmap.jpg | 默认 | 480×320 | 8 | DisplayP3 | 1.00 |
| hdr_gainmap.jpg | ShouldAllowFloat | 480×320 | 8 | DisplayP3 | 1.00 |
| hdr_gainmap.jpg | DecodeToHDR | 480×320 | 10 | ICC(26680B, BT.2020 Primaries; PQ (Adaptive Gain Curve 0CFB5B0BC141B1F2)) | 0.80 |

### P4 背景色 #FAFAF8 的几种构造方式 → 8-bit sRGB PNG

| 工作空间 | 写法 | CIColor.colorSpace | 输出 PNG 像素 |
|---|---|---|---|
| extLinearSRGB | CIColor(red:green:blue:)（未指定空间） | SRGB | (250,250,248) |
| extLinearSRGB | CIColor(..., colorSpace: sRGB) | SRGB | (250,250,248) |
| extLinearSRGB | CIColor(cgColor: CGColor(srgbRed:...)) | SRGB | (250,250,248) |
| extLinearSRGB | 错误：把 250/255 当 Display P3 | DisplayP3 | (250,250,248) |
| extLinearSRGB | 错误：把 250/255 当线性值 | LinearSRGB | (253,253,252) |
| extLinearP3 | CIColor(red:green:blue:)（未指定空间） | SRGB | (250,250,248) |
| extLinearP3 | CIColor(..., colorSpace: sRGB) | SRGB | (250,250,248) |
| extLinearP3 | CIColor(cgColor: CGColor(srgbRed:...)) | SRGB | (250,250,248) |
| extLinearP3 | 错误：把 250/255 当 Display P3 | DisplayP3 | (250,250,248) |
| extLinearP3 | 错误：把 250/255 当线性值 | LinearSRGB | (253,253,252) |
| extLinear2020 | CIColor(red:green:blue:)（未指定空间） | SRGB | (250,250,248) |
| extLinear2020 | CIColor(..., colorSpace: sRGB) | SRGB | (250,250,248) |
| extLinear2020 | CIColor(cgColor: CGColor(srgbRed:...)) | SRGB | (250,250,248) |
| extLinear2020 | 错误：把 250/255 当 Display P3 | DisplayP3 | (250,250,248) |
| extLinear2020 | 错误：把 250/255 当线性值 | LinearSRGB | (253,253,252) |

### P5 Core Image 是否是唯一做 ICC 转换的组件

| 输入 | CI 色彩管理开（→sRGB）ΔE 中位 | CI 色彩管理关（原值直出）ΔE 中位 |
|---|---|---|
| chart_prophoto_16.tif | 0.05 | 7.97 |
| chart_adobergb_16.tif | 0.05 | 2.72 |
| chart_srgb_16.tif | 0.05 | 0.05 |

### P6 ImageIO 编码器对颜色空间的处理

| 写出方式 | 文件 ICC | 文件位深 | 读回颜色空间 | 负值分量数 | >1 分量数 | 读回→sRGB ΔE 中位 |
|---|---|---|---|---|---|---|
| 色卡 → CGImage RGBA8 Display P3 → JPEG | Display P3 | 8 | DisplayP3 | 0 | 0 | 0.21 |
| 色卡 → CGImage RGBAh extendedLinearSRGB → JPEG | sRGB IEC61966-2.1 Linear | 8 | ICC(572B, sRGB IEC61966-2.1 Linear) | 0 | 0 | 0.40 |
| 色卡 → CGImage RGBAh extendedLinearSRGB → PNG | sRGB IEC61966-2.1 Linear | 8 | LinearSRGB | 0 | 0 | 0.26 |
| 广色域 → CGImage RGBAh extendedLinearSRGB → PNG | Display P3 | 16 | DisplayP3 | 0 | 0 | – |
| 广色域 → CGImage RGBAh extendedLinearSRGB → TIFF | sRGB IEC61966-2.1 Linear | 16 float | ICC(572B, sRGB IEC61966-2.1 Linear) | 486400 | 377600 | – |

### P7 Core Graphics：把 ProPhoto 广色域图画进不同上下文

| CGContext 颜色空间 | 需 extended 像素 | 被截断 | 域内最大误差 |
|---|---|---|---|
| extendedLinearSRGB half | 427424 | 0 | 0.0002 |
| linearSRGB（非 extended）half | 427424 | 410096 | 0.0002 |
| extendedLinearITUR_2020 half | 375440 | 0 | 0.0002 |
| linearITUR_2020（非 extended）half | 375440 | 277248 | 0.0002 |

### P8 ColorSync（CGColor.converted）与参考数学的一致性

| ICC | ΔE 中位 | ΔE max |
|---|---|---|
| srgb | 0.000 | 0.000 |
| adobergb | 0.009 | 0.013 |
| p3 | 0.001 | 0.004 |
| prophoto | 0.001 | 0.004 |

ProPhoto 纯绿 (0,1,0) → extendedSRGB = (-0.869, 1.096, -0.428)，参考 (-0.869, 1.096, -0.428)；→ sRGB = (0.000, 1.000, 0.000)

### P9 输出文件默认带了哪些元数据块

| 写出方式 | 元数据字典 | EXIF 键 | TIFF 字段 | 嵌入 ICC |
|---|---|---|---|---|
| CI writeJPEGRepresentation | {Exif} {TIFF} | ColorSpace,ComponentsConfiguration,ExifVersion,FlashPixVersion,PixelXDimension,PixelYDimension,SceneCaptureType | ResolutionUnit=2,XResolution=72,YResolution=72 | **无** |
| CI writePNGRepresentation | {Exif} {PNG} | ColorSpace,PixelXDimension,PixelYDimension | – | **无** |
| CI JPEG + hdrImage（gain map） | {Exif} {TIFF} | ColorSpace,ComponentsConfiguration,ExifVersion,FlashPixVersion,PixelXDimension,PixelYDimension,SceneCaptureType | Orientation=1,ResolutionUnit=2,XResolution=72,YResolution=72 | 有 |
| ImageIO CGImageDestination JPEG | {Exif} {JFIF} | ColorSpace,PixelXDimension,PixelYDimension | – | **无** |
| CI JPEG，colorSpace = CGColorSpace(iccData: sRGB ICC) | {Exif} {TIFF} |  |  | **无** |
| ImageIO JPEG，CGImage 颜色空间 = CGColorSpace(iccData: sRGB ICC) | {Exif} {JFIF} |  |  | **无** |

### P10 ImageIO 写 ISO gain map JPEG：输入 CGImage 的要求

源：hdr_float_linear2020.tif（峰值 8.0）。读回用 CIImage(expandToHDR) → extendedLinearSRGB，看 8.0 色块与 1.0 色块。

| 输入 CGImage | CGImage headroom | ISO gain map | 底图 ICC | 读回 headroom | 读回 Y(1.0) | 读回 Y(8.0) | SDR 底图中性色块码值 |
|---|---|---|---|---|---|---|---|
| extLinearP3 half，headroom 未知 | 0.00 | ✅ | Display P3 | 4.93 | 1.00 | 1.00 | 63 118 189 225 255 255 255 255 255 255 255 255 |
| extLinearP3 half + CGImageCreateCopyWithContentHeadroom(8) | 8.00 | ✅ | Display P3 | 8.00 | 1.00 | 8.00 | 43 84 130 151 166 187 202 223 237 248 255 255 |
| extLinearP3 half + headroom 8 + BaseColorSpace=sRGB（EncodeRequestOptions 内） | 8.00 | ✅ | Display P3 | 8.00 | 1.00 | 8.00 | 43 84 130 151 166 187 202 223 237 248 255 255 |
| extLinearP3 half + headroom 8 + BaseColorSpace=sRGB（顶层） | 8.00 | ✅ | Display P3 | 8.00 | 1.00 | 8.00 | 43 84 130 151 166 187 202 223 237 248 255 255 |
| ITUR_2100_PQ RGBA16 | 4.93 | ✅ | Display P3 | 4.93 | 1.00 | 4.93 | 50 90 140 167 188 211 224 239 249 255 255 255 |
| DisplayP3_PQ RGBA16 | 4.93 | ✅ | Display P3 | 4.93 | 1.00 | 4.93 | 50 90 140 167 188 211 224 239 249 255 255 255 |

### P11 HDR → SDR 的几种 tone map（extLinearSRGB，8-bit sRGB 输出）

中性色块线性亮度：0.05 0.18 0.50 0.75 1.00 1.50 2.00 3.00 4.00 5.00 6.00 8.00。理想的摄影 SDR 版本：0.18 附近基本不动，1.0 以上逐级压缩但互相可分。

| 输入 | 方法 | 中性色块码值（0.05 … 8.0） | ≥1.0 的 8 级可分辨数 | SDR 色卡 ΔE 中位（相对未压缩） |
|---|---|---|---|---|
| hdr_pq2020_203nit.png | 直接截断 | 63 118 187 214 229 244 250 254 255 255 255 255 | 5/8 | 0.00 |
| hdr_pq2020_203nit.png | CIToneMapHeadroom(source=4.93) | 50 90 141 167 188 211 224 239 249 255 255 255 | 6/8 | 12.30 |
| hdr_pq2020_203nit.png | CISystemToneMap(displayHeadroom=1) | 50 90 141 167 188 211 224 239 249 255 255 255 | 6/8 | 12.30 |
| hdr_pq2020_203nit.png | CIImage 选项 .toneMapHDRtoSDR | 63 118 187 214 229 244 250 254 255 255 255 255 | 5/8 | 0.00 |
| hdr_pq2020_203nit.png | ImageIO DecodeToSDR | 50 90 141 167 188 211 224 239 249 255 255 255 | 6/8 | 12.30 |
| hdr_float_linear2020.tif | 直接截断 | 63 118 188 225 255 255 255 255 255 255 255 255 | 1/8 | 0.00 |
| hdr_float_linear2020.tif | CIToneMapHeadroom(source=8.00) | 42 77 120 142 160 183 197 216 228 237 244 255 | 8/8 | 17.23 |
| hdr_float_linear2020.tif | CISystemToneMap(displayHeadroom=1) | 42 77 120 142 160 183 197 216 228 237 244 255 | 8/8 | 17.23 |
| hdr_float_linear2020.tif | CIImage 选项 .toneMapHDRtoSDR | 63 118 188 225 255 255 255 255 255 255 255 255 | 1/8 | 0.00 |
| hdr_float_linear2020.tif | ImageIO DecodeToSDR | 0 0 0 0 0 0 0 0 0 0 0 0 | 1/8 | 45.13 |
