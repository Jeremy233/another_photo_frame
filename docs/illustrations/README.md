# PhotoFrame 规范配图

主文档 `PhotoFrame_V1_Specification.md` 直接引用此目录中的八张 PNG；同名 SVG 保留可编辑的矢量源文件。

## 配图与插入位置

| 图 | 文件 | 正文章节 | 说明 |
|---|---|---|---|
| 1 | `01-publishing-workflow` | §3.2 后 | 同一原图、多预设、独立任务与本地成品 |
| 2 | `02-three-column-workbench` | §4.1 | 参照 Compressor 的三栏界面、预览位置与可拖动分隔线 |
| 3 | `03-fit-and-minimum-margins` | §5.2 后 | 完整图 Fit、画布比例与最小安全边距 |
| 4 | `04-seamless-panorama` | §5.3 数值表后 | 65:24 算例、全局切片、两端补边与独立封面 |
| 5 | `05-managed-color-pipeline` | §6.3 | 输入 ICC、高精度合成、输出预览与颜色转换 |
| 6 | `06-preset-and-local-assets` | §8.2 后 | 可分享的 Slots 与用户本地素材解析 |
| 7 | `07-job-lifecycle-and-atomic-export` | §9.2 后 | 阶段进度、失败、取消、重试与原子发布 |
| 8 | `08-shared-backend-architecture` | §10.1 后 | GUI / CLI / MCP 共享服务与核心模块 |

## 统一视觉规范

- 暖白背景 `#FAFAF8`，白色信息卡片，深灰文字 `#283B36`。
- 青绿色强调 `#356D62`、浅绿填色 `#EAF1ED`、灰绿连线 `#D8E0D9`。
- 需要解释风险、缺失或异常时使用低饱和沙色与棕色，不依靠颜色单独传达含义。
- 1600 px 宽逻辑画布，统一标题、编号、页脚、圆角、箭头与中文无衬线字体。
- PNG 按 2 倍逻辑尺寸导出；SVG 使用同一个本地风景源文件。
- 风景仅用于示意，不是用户原始照片；UI 是概念图，建议方案仍保留原文中的待验证状态。
- 图 4 的画布与切片按正文的理想 65:24 数值绘制；AI 风景接近该比例，以 `meet` 等比显示，不裁切或拉伸源图。

## 生成方式与最终提示词

风景使用内置 **image_gen** 工具生成；八张技术示意用矢量代码绘制，再输出 PNG，以保证中文文字、尺寸标注和模块关系准确。未使用 CLI / API 图像生成路径。

共用风景保存在 `source/landscape-sample.png`。最终传入 image_gen 的提示词如下：

```text
Use case: photorealistic-natural
Asset type: shared illustrative landscape sample for a Chinese PhotoFrame product and technical specification. This will be embedded in precisely drawn vector diagrams; it is a fictional sample, not a user's original photo.
Primary request: Generate a very wide fine-art landscape panorama with aspect ratio exactly 65:24 (approximately 2.7083:1), around 2600 by 960 pixels if possible. A continuous tranquil range of layered badlands mesas, pale sandstone ridges, distant blue-grey mountains and a restrained pale sky. Clear landmarks spaced across the entire panorama make neighboring carousel slices easy to recognize. All ridges form one continuous natural photograph.
Style/medium: refined fine-art landscape photography, realistic texture, subtle filmic detail, soft diffuse morning light, neutral low saturation.
Color palette: warm sandstone, soft taupe, slate blue, muted sage; consistent with warm-white #FAFAF8 documentation and restrained dark-teal accents.
Composition: horizon near upper third, continuous terrain across the whole width, no foreground subject, no isolated hero peak, edge-to-edge photograph with NO margins or frame.
Constraints: no text, no logos, no watermark, no UI, no arrows, no collage, no panels, no borders, no signature. One continuous wide photograph. Avoid oversaturated orange, fantasy scenery, dramatic color grading.
```

各张技术图的内容、尺寸、文案和视觉规范直接保存在 `source/generate_figures.py` 中。

## 重新生成

从仓库根目录运行，需要 Python 3、Node.js 与 Node `sharp` 库；中文字体需可用。

```bash
python3 docs/illustrations/source/generate_figures.py
node docs/illustrations/source/render_figures.mjs
```

若 `sharp` 不在常规 Node 模块查找路径中，可通过环境变量 `PHOTOFRAME_SHARP_MODULE` 指定已安装模块的位置。无需调用图像生成工具即可重绘和渲染现有技术示意。
