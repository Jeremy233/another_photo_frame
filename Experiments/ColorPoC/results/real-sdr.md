# ColorPoC 运行结果

生成时间：2026-10-16T18:24:37Z；系统：Version 27.0.1 (Build 26A434)

## 7. 真实照片（12 个文件，目录不入库）

### 7.0 解码一致性（Core Image 缩放结果 vs ImageIO 缩略图）

两者都缩到长边 1032 后在 extended linear Rec.2020 中比较。坏像素 = G 通道差 > 0.2。正常值只有重采样差异（< 0.3%）。

| 文件 | 工作空间 | 送入 CI 的方式 | 平均绝对差 | 坏像素 |
|---|---|---|---|---|
| glacier_np_adobergb.jpg | extLinear2020 | 直接交给 CI | 0.0050 | 0.02% |
| glacier_np_adobergb.jpg | extLinearSRGB | 直接交给 CI | 0.0050 | 0.02% |
| glacier_np_p3.jpg | extLinear2020 | 直接交给 CI | 0.0051 | 0.02% |
| glacier_np_p3.jpg | extLinearSRGB | 直接交给 CI | 0.0051 | 0.02% |
| glacier_np_person_adobergb.jpg | extLinear2020 | 直接交给 CI | 0.0055 | 0.01% |
| glacier_np_person_adobergb.jpg | extLinearSRGB | 直接交给 CI | 0.0055 | 0.01% |
| glacier_np_person_p3.jpg | extLinear2020 | 直接交给 CI | 0.0055 | 0.01% |
| glacier_np_person_p3.jpg | extLinearSRGB | 直接交给 CI | 0.0055 | 0.01% |
| glacier_np_person_prophoto.jpg | extLinear2020 | 直接交给 CI | 0.0056 | 0.01% |
| glacier_np_person_prophoto.jpg | extLinearSRGB | 直接交给 CI | 0.0056 | 0.01% |
| glacier_np_person_prophoto.tif | extLinear2020 | 直接交给 CI | 0.0028 | 0.00% |
| glacier_np_person_prophoto.tif | extLinearSRGB | 直接交给 CI | 0.0028 | 0.00% |
| glacier_np_person_srgb.jpg | extLinear2020 | 直接交给 CI | 0.0055 | 0.01% |
| glacier_np_person_srgb.jpg | extLinearSRGB | 直接交给 CI | 0.0054 | 0.01% |
| glacier_np_person_srgb.tif | extLinear2020 | 直接交给 CI | 0.0028 | 0.00% |
| glacier_np_person_srgb.tif | extLinearSRGB | 直接交给 CI | 0.0028 | 0.00% |
| glacier_np_prophoto.jpg | extLinear2020 | 直接交给 CI | 0.0047 | 0.01% |
| glacier_np_prophoto.jpg | extLinearSRGB | 直接交给 CI | 0.0047 | 0.01% |
| glacier_np_prophoto.tif | extLinear2020 | 直接交给 CI | 0.0036 | 0.01% |
| glacier_np_prophoto.tif | extLinearSRGB | 直接交给 CI | 0.0036 | 0.01% |
| glacier_np_srgb.jpg | extLinear2020 | 直接交给 CI | 0.0050 | 0.02% |
| glacier_np_srgb.jpg | extLinearSRGB | 直接交给 CI | 0.0050 | 0.02% |
| glacier_np_srgb.tif | extLinear2020 | 直接交给 CI | 0.0038 | 0.02% |
| glacier_np_srgb.tif | extLinearSRGB | 直接交给 CI | 0.0038 | 0.02% |

### 7.1 文件识别

| 文件 | 尺寸 | 位深 | ImageIO ProfileName | 文件内颜色描述 | CIImage.colorSpace | gain map | contentHeadroom | EXIF 方向 | 判定 |
|---|---|---|---|---|---|---|---|---|---|
| glacier_np_adobergb.jpg | 3209×4813 | 8 | Adobe RGB (1998) | ICC | ICC(560B, Adobe RGB (1998)) | – | 1.00 | 1 | SDR |
| glacier_np_p3.jpg | 3209×4813 | 8 | Display P3 | ICC | DisplayP3 | – | 1.00 | 1 | SDR |
| glacier_np_person_adobergb.jpg | 8245×5497 | 8 | Adobe RGB (1998) | ICC | ICC(560B, Adobe RGB (1998)) | – | 1.00 | 1 | SDR |
| glacier_np_person_p3.jpg | 8245×5497 | 8 | Display P3 | ICC | DisplayP3 | – | 1.00 | 1 | SDR |
| glacier_np_person_prophoto.jpg | 8245×5497 | 8 | ProPhoto RGB | ICC | ICC(940B, ProPhoto RGB) | – | 1.00 | 1 | SDR |
| glacier_np_person_prophoto.tif | 8245×5497 | 16 | ProPhoto RGB | ICC（ProPhoto RGB） | ICC(940B, ProPhoto RGB) | – | 1.00 | 1 | SDR |
| glacier_np_person_srgb.jpg | 8245×5497 | 8 | sRGB IEC61966-2.1 | ICC | SRGB | – | 1.00 | 1 | SDR |
| glacier_np_person_srgb.tif | 8245×5497 | 16 | sRGB IEC61966-2.1 | ICC（sRGB IEC61966-2.1） | SRGB | – | 1.00 | 1 | SDR |
| glacier_np_prophoto.jpg | 3209×4813 | 8 | ProPhoto RGB | ICC | ICC(940B, ProPhoto RGB) | – | 1.00 | 1 | SDR |
| glacier_np_prophoto.tif | 3209×4813 | 16 | ProPhoto RGB | ICC（ProPhoto RGB） | ICC(940B, ProPhoto RGB) | – | 1.00 | 1 | SDR |
| glacier_np_srgb.jpg | 3209×4813 | 8 | sRGB IEC61966-2.1 | ICC | SRGB | – | 1.00 | 1 | SDR |
| glacier_np_srgb.tif | 3209×4813 | 16 | sRGB IEC61966-2.1 | ICC（sRGB IEC61966-2.1） | SRGB | – | 1.00 | 1 | SDR |

### 7.2 各工作空间：需要 extended 的像素比例与一致性

“与 2020 的 XYZ 最大差”：同一合成图在该空间渲染为 RGBAf 后换算到 XYZ，与 extLinear2020 结果的最大差（若某空间截断，这里会明显变大）。

| 文件 | 工作空间 | 分量 <0 的像素 | 分量 >1 的像素 | 与 2020 的 XYZ 最大差 | SDR 输出方法 | SDR 背景≠#FAFAF8 |
|---|---|---|---|---|---|---|
| glacier_np_adobergb.jpg | extLinear2020 | 0.90% | 0.09% | （基准） | 直接 | 0 |
| glacier_np_adobergb.jpg | extLinearP3 | 0.96% | 0.10% | 0.00159 | 直接 | 0 |
| glacier_np_adobergb.jpg | extLinearSRGB | 2.25% | 0.12% | 0.00157 | 直接 | 0 |
| glacier_np_p3.jpg | extLinear2020 | 0.87% | 0.09% | （基准） | 直接 | 0 |
| glacier_np_p3.jpg | extLinearP3 | 0.93% | 0.10% | 0.00172 | 直接 | 0 |
| glacier_np_p3.jpg | extLinearSRGB | 2.09% | 0.11% | 0.00148 | 直接 | 0 |
| glacier_np_person_adobergb.jpg | extLinear2020 | 0.10% | 0.00% | （基准） | 直接 | 0 |
| glacier_np_person_adobergb.jpg | extLinearP3 | 0.11% | 0.03% | 0.00130 | 直接 | 0 |
| glacier_np_person_adobergb.jpg | extLinearSRGB | 4.03% | 0.18% | 0.00166 | 直接 | 0 |
| glacier_np_person_p3.jpg | extLinear2020 | 0.10% | 0.00% | （基准） | 直接 | 0 |
| glacier_np_person_p3.jpg | extLinearP3 | 0.11% | 0.02% | 0.00161 | 直接 | 0 |
| glacier_np_person_p3.jpg | extLinearSRGB | 3.63% | 0.18% | 0.00170 | 直接 | 0 |
| glacier_np_person_prophoto.jpg | extLinear2020 | 0.10% | 0.00% | （基准） | 直接 | 0 |
| glacier_np_person_prophoto.jpg | extLinearP3 | 0.11% | 0.03% | 0.00137 | 直接 | 0 |
| glacier_np_person_prophoto.jpg | extLinearSRGB | 3.75% | 0.18% | 0.00163 | 直接 | 0 |
| glacier_np_person_prophoto.tif | extLinear2020 | 0.10% | 0.00% | （基准） | 直接 | 0 |
| glacier_np_person_prophoto.tif | extLinearP3 | 0.11% | 0.03% | 0.00156 | 直接 | 0 |
| glacier_np_person_prophoto.tif | extLinearSRGB | 3.75% | 0.18% | 0.00165 | 直接 | 0 |
| glacier_np_person_srgb.jpg | extLinear2020 | 0.10% | 0.00% | （基准） | 直接 | 0 |
| glacier_np_person_srgb.jpg | extLinearP3 | 0.11% | 0.00% | 0.00142 | 直接 | 0 |
| glacier_np_person_srgb.jpg | extLinearSRGB | 0.32% | 0.06% | 0.00159 | 直接 | 0 |
| glacier_np_person_srgb.tif | extLinear2020 | 0.10% | 0.00% | （基准） | 直接 | 0 |
| glacier_np_person_srgb.tif | extLinearP3 | 0.11% | 0.00% | 0.00157 | 直接 | 0 |
| glacier_np_person_srgb.tif | extLinearSRGB | 0.36% | 0.08% | 0.00165 | 直接 | 0 |
| glacier_np_prophoto.jpg | extLinear2020 | 0.88% | 0.09% | （基准） | 直接 | 0 |
| glacier_np_prophoto.jpg | extLinearP3 | 0.93% | 0.10% | 0.00145 | 直接 | 0 |
| glacier_np_prophoto.jpg | extLinearSRGB | 2.07% | 0.11% | 0.00166 | 直接 | 0 |
| glacier_np_prophoto.tif | extLinear2020 | 0.87% | 0.09% | （基准） | 直接 | 0 |
| glacier_np_prophoto.tif | extLinearP3 | 0.93% | 0.10% | 0.00142 | 直接 | 0 |
| glacier_np_prophoto.tif | extLinearSRGB | 2.10% | 0.11% | 0.00165 | 直接 | 0 |
| glacier_np_srgb.jpg | extLinear2020 | 0.87% | 0.09% | （基准） | 直接 | 0 |
| glacier_np_srgb.jpg | extLinearP3 | 0.93% | 0.09% | 0.00150 | 直接 | 0 |
| glacier_np_srgb.jpg | extLinearSRGB | 1.57% | 0.11% | 0.00191 | 直接 | 0 |
| glacier_np_srgb.tif | extLinear2020 | 0.87% | 0.09% | （基准） | 直接 | 0 |
| glacier_np_srgb.tif | extLinearP3 | 0.93% | 0.10% | 0.00167 | 直接 | 0 |
| glacier_np_srgb.tif | extLinearSRGB | 1.65% | 0.11% | 0.00169 | 直接 | 0 |

### 7.3 SDR 输出随工作空间的差异（ΔE2000）

| 文件 | 比较 | 中位 | P95 | max |
|---|---|---|---|---|
| glacier_np_adobergb.jpg | extLinearSRGB vs extLinear2020 | 0.00 | 0.48 | 1.81 |
| glacier_np_adobergb.jpg | extLinearP3 vs extLinear2020 | 0.00 | 0.47 | 1.68 |
| glacier_np_p3.jpg | extLinearSRGB vs extLinear2020 | 0.00 | 0.48 | 1.85 |
| glacier_np_p3.jpg | extLinearP3 vs extLinear2020 | 0.00 | 0.51 | 1.86 |
| glacier_np_person_adobergb.jpg | extLinearSRGB vs extLinear2020 | 0.00 | 0.45 | 1.70 |
| glacier_np_person_adobergb.jpg | extLinearP3 vs extLinear2020 | 0.00 | 0.44 | 1.66 |
| glacier_np_person_p3.jpg | extLinearSRGB vs extLinear2020 | 0.00 | 0.46 | 1.69 |
| glacier_np_person_p3.jpg | extLinearP3 vs extLinear2020 | 0.00 | 0.48 | 1.80 |
| glacier_np_person_prophoto.jpg | extLinearSRGB vs extLinear2020 | 0.00 | 0.45 | 1.52 |
| glacier_np_person_prophoto.jpg | extLinearP3 vs extLinear2020 | 0.00 | 0.44 | 1.62 |
| glacier_np_person_prophoto.tif | extLinearSRGB vs extLinear2020 | 0.00 | 0.45 | 1.54 |
| glacier_np_person_prophoto.tif | extLinearP3 vs extLinear2020 | 0.00 | 0.44 | 1.67 |
| glacier_np_person_srgb.jpg | extLinearSRGB vs extLinear2020 | 0.00 | 0.49 | 1.65 |
| glacier_np_person_srgb.jpg | extLinearP3 vs extLinear2020 | 0.00 | 0.44 | 1.71 |
| glacier_np_person_srgb.tif | extLinearSRGB vs extLinear2020 | 0.00 | 0.45 | 1.50 |
| glacier_np_person_srgb.tif | extLinearP3 vs extLinear2020 | 0.00 | 0.45 | 1.74 |
| glacier_np_prophoto.jpg | extLinearSRGB vs extLinear2020 | 0.00 | 0.48 | 1.92 |
| glacier_np_prophoto.jpg | extLinearP3 vs extLinear2020 | 0.00 | 0.47 | 1.68 |
| glacier_np_prophoto.tif | extLinearSRGB vs extLinear2020 | 0.00 | 0.48 | 1.66 |
| glacier_np_prophoto.tif | extLinearP3 vs extLinear2020 | 0.00 | 0.47 | 1.68 |
| glacier_np_srgb.jpg | extLinearSRGB vs extLinear2020 | 0.00 | 0.50 | 1.69 |
| glacier_np_srgb.jpg | extLinearP3 vs extLinear2020 | 0.00 | 0.47 | 1.78 |
| glacier_np_srgb.tif | extLinearSRGB vs extLinear2020 | 0.00 | 0.48 | 1.67 |
| glacier_np_srgb.tif | extLinearP3 vs extLinear2020 | 0.00 | 0.47 | 1.66 |

### 7.5 同一照片不同 ICC 版本 → sRGB 输出的 ΔE2000（D-19）

基准为 sRGB 版本的输出。“sRGB 域内”剔除了源图超出 sRGB 的像素；“域外像素”一栏单独统计这些像素，反映 Lightroom 导出 sRGB 时的色域映射与本管线逐通道截断的差别。

| 照片 | 工作空间 | 比较 | 全部像素 中位/P95 | sRGB 域内 中位/P95 | 域外像素占比 | 域外像素 中位/P95/max | D-19（中位≤1, P95≤2） |
|---|---|---|---|---|---|---|---|
| glacier_np.jpg | extLinearSRGB | adobergb vs glacier_np_srgb.jpg | 0.45 / 1.25 | 0.45 / 1.26 | 1.3% | 0.00 / 0.79 / 3.67 | ✅ |
| glacier_np.jpg | extLinearSRGB | p3 vs glacier_np_srgb.jpg | 0.43 / 1.23 | 0.43 / 1.24 | 1.3% | 0.00 / 0.76 / 2.44 | ✅ |
| glacier_np.jpg | extLinearSRGB | prophoto vs glacier_np_srgb.jpg | 0.51 / 1.65 | 0.51 / 1.65 | 1.3% | 0.00 / 1.05 / 6.11 | ✅ |
| glacier_np.jpg | extLinearP3 | adobergb vs glacier_np_srgb.jpg | 0.45 / 1.26 | 0.45 / 1.26 | 1.3% | 0.00 / 0.79 / 3.67 | ✅ |
| glacier_np.jpg | extLinearP3 | p3 vs glacier_np_srgb.jpg | 0.43 / 1.24 | 0.43 / 1.24 | 1.3% | 0.00 / 0.76 / 2.44 | ✅ |
| glacier_np.jpg | extLinearP3 | prophoto vs glacier_np_srgb.jpg | 0.51 / 1.65 | 0.51 / 1.65 | 1.3% | 0.00 / 1.07 / 6.11 | ✅ |
| glacier_np.jpg | extLinear2020 | adobergb vs glacier_np_srgb.jpg | 0.45 / 1.26 | 0.45 / 1.26 | 1.3% | 0.00 / 0.79 / 3.67 | ✅ |
| glacier_np.jpg | extLinear2020 | p3 vs glacier_np_srgb.jpg | 0.43 / 1.24 | 0.43 / 1.24 | 1.3% | 0.00 / 0.77 / 2.44 | ✅ |
| glacier_np.jpg | extLinear2020 | prophoto vs glacier_np_srgb.jpg | 0.51 / 1.65 | 0.51 / 1.65 | 1.3% | 0.00 / 1.08 / 6.11 | ✅ |
| glacier_np.tif | extLinearSRGB | prophoto vs glacier_np_srgb.tif | 0.00 / 0.00 | 0.00 / 0.00 | 1.3% | 0.00 / 0.41 / 7.02 | ✅ |
| glacier_np.tif | extLinearP3 | prophoto vs glacier_np_srgb.tif | 0.00 / 0.00 | 0.00 / 0.00 | 1.3% | 0.00 / 0.44 / 7.02 | ✅ |
| glacier_np.tif | extLinear2020 | prophoto vs glacier_np_srgb.tif | 0.00 / 0.00 | 0.00 / 0.00 | 1.3% | 0.00 / 0.45 / 7.02 | ✅ |
| glacier_np_person.jpg | extLinearSRGB | adobergb vs glacier_np_person_srgb.jpg | 0.40 / 1.28 | 0.41 / 1.29 | 2.4% | 0.08 / 0.49 / 5.07 | ✅ |
| glacier_np_person.jpg | extLinearSRGB | p3 vs glacier_np_person_srgb.jpg | 0.34 / 1.15 | 0.35 / 1.16 | 2.4% | 0.09 / 0.52 / 4.60 | ✅ |
| glacier_np_person.jpg | extLinearSRGB | prophoto vs glacier_np_person_srgb.jpg | 0.51 / 1.74 | 0.52 / 1.75 | 2.4% | 0.13 / 0.57 / 2.87 | ✅ |
| glacier_np_person.jpg | extLinearP3 | adobergb vs glacier_np_person_srgb.jpg | 0.40 / 1.29 | 0.41 / 1.30 | 2.4% | 0.09 / 0.49 / 4.94 | ✅ |
| glacier_np_person.jpg | extLinearP3 | p3 vs glacier_np_person_srgb.jpg | 0.34 / 1.15 | 0.35 / 1.17 | 2.4% | 0.08 / 0.54 / 4.47 | ✅ |
| glacier_np_person.jpg | extLinearP3 | prophoto vs glacier_np_person_srgb.jpg | 0.51 / 1.74 | 0.52 / 1.76 | 2.4% | 0.12 / 0.57 / 2.52 | ✅ |
| glacier_np_person.jpg | extLinear2020 | adobergb vs glacier_np_person_srgb.jpg | 0.40 / 1.29 | 0.41 / 1.30 | 2.4% | 0.09 / 0.50 / 5.30 | ✅ |
| glacier_np_person.jpg | extLinear2020 | p3 vs glacier_np_person_srgb.jpg | 0.34 / 1.16 | 0.35 / 1.17 | 2.4% | 0.09 / 0.55 / 4.60 | ✅ |
| glacier_np_person.jpg | extLinear2020 | prophoto vs glacier_np_person_srgb.jpg | 0.51 / 1.74 | 0.52 / 1.76 | 2.4% | 0.15 / 0.58 / 3.14 | ✅ |
| glacier_np_person.tif | extLinearSRGB | prophoto vs glacier_np_person_srgb.tif | 0.00 / 0.00 | 0.00 / 0.00 | 2.5% | 0.00 / 0.38 / 2.62 | ✅ |
| glacier_np_person.tif | extLinearP3 | prophoto vs glacier_np_person_srgb.tif | 0.00 / 0.00 | 0.00 / 0.00 | 2.5% | 0.00 / 0.39 / 2.85 | ✅ |
| glacier_np_person.tif | extLinear2020 | prophoto vs glacier_np_person_srgb.tif | 0.00 / 0.00 | 0.00 / 0.00 | 2.5% | 0.00 / 0.40 / 3.20 | ✅ |
