# 应用图标

| 文件 | 内容 |
|---|---|
| `photo-stack.png` | 前景：叠在一起的相纸，前面一张装着日落海岸插画，透明背景（1254 × 1254）。 |
| `sunset-artwork.png` | 同一幅日落海岸插画的完整版，没有相框（1587 × 991），备用。 |
| `make_app_icon.py` | 把前景放到中性深灰的圆角方形底板上，生成各尺寸图标。 |

生成结果在 `../../App/Assets.xcassets/AppIcon.appiconset/`，不要手改，改完素材或脚本后重新运行：

```bash
python3 Apps/PhotoFrameMac/Design/AppIcon/make_app_icon.py
```

需要 Python 3 和 Pillow。

- 插画是用图像生成工具从开发者自己拍的照片简化成的平面插画，不是照片原片。
- 底板用界面同一套中性灰（D-105），不带色相；图标网格按 macOS 规范：1024 画布中央 824 的圆角方形，下方带柔和投影。
