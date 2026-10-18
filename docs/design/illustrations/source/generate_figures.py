"""Generate the editable SVG illustrations used in the PhotoFrame specification.

This script draws document diagrams; it does not process user photographs.
Run from any directory: python3 docs/design/illustrations/source/generate_figures.py
Then rasterize with render_figures.mjs for the Markdown-compatible PNG assets.
"""

from html import escape
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent
BG = "#FAFAF8"
WHITE = "#FFFFFF"
INK = "#283B36"
MUTED = "#6D7C76"
TEAL = "#356D62"
PALE = "#EAF1ED"
LINE = "#D8E0D9"
SAND = "#EFE6D6"
AMBER = "#9D713B"
RED = "#9E655B"
PHOTO = "source/landscape-sample.png"
FONT = "Arial, 'Heiti SC', 'STHeiti', 'Hiragino Sans GB', sans-serif"


class Figure:
    def __init__(self, number, title, subtitle, height=900, note="概念示意 · 具体参数与实现状态以正文为准"):
        self.height = height
        self.parts = [f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1600" height="{height}" viewBox="0 0 1600 {height}" role="img" aria-labelledby="title desc">',
                      f'<title id="title">{escape(title)}</title><desc id="desc">{escape(subtitle)}</desc>',
                      '<defs><marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 1 1 L 9 5 L 1 9" fill="none" stroke="#356D62" stroke-width="1.5"/></marker></defs>',
                      f'<rect width="1600" height="{height}" fill="{BG}"/>']
        self.text(64, 40, "PHOTOFRAME  /  V1.0", 15, TEAL, 600, spacing=2)
        self.text(1536, 40, f"FIG. {number:02}", 15, MUTED, 600, anchor="end", spacing=2)
        self.text(64, 92, title, 38, INK, 600)
        self.text(64, 126, subtitle, 20, MUTED)
        self.line(64, 150, 1536, 150, color=LINE)
        self.line(64, height - 64, 1536, height - 64, color=LINE)
        self.text(64, height - 31, note, 15, MUTED)
        self.text(1536, height - 31, "LOCAL FIRST · CREATE ONCE", 13, MUTED, anchor="end", spacing=1)

    def add(self, markup):
        self.parts.append(markup)

    def rect(self, x, y, w, h, fill=WHITE, stroke=LINE, radius=14, dash=None, sw=1.5):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')

    def line(self, x1, y1, x2, y2, color=TEAL, width=2, arrow=False, dash=None, both=False):
        marker = ' marker-end="url(#arrow)"' if arrow or both else ""
        if both:
            marker += ' marker-start="url(#arrow)"'
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="{width}"{marker}{d}/>')

    def path(self, d, color=TEAL, width=2, arrow=False, dash=None):
        marker = ' marker-end="url(#arrow)"' if arrow else ""
        ds = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}" stroke-linejoin="round"{marker}{ds}/>')

    def text(self, x, y, value, size=22, color=INK, weight=400, anchor="start", spacing=None):
        ls = f' letter-spacing="{spacing}"' if spacing is not None else ""
        self.add(f'<text x="{x}" y="{y}" font-family="{escape(FONT, quote=True)}" font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}"{ls}>{escape(value)}</text>')

    def lines(self, x, y, values, size=20, gap=32, color=MUTED, weight=400, anchor="start"):
        for i, value in enumerate(values):
            self.text(x, y + i * gap, value, size, color, weight, anchor)

    def pill(self, x, y, value, w=150, color=TEAL, fill=PALE, size=17):
        self.rect(x, y, w, 34, fill, fill, 17, sw=0)
        self.text(x + w / 2, y + 23, value, size, color, 600, "middle")

    def dot(self, x, y, r=4, fill=TEAL):
        self.add(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{fill}"/>')

    def photo(self, x, y, w, h):
        self.add(f'<image x="{x}" y="{y}" width="{w}" height="{h}" xlink:href="{PHOTO}" preserveAspectRatio="xMidYMid meet"/>')

    def cover(self, x, y, w, h, overlays=False):
        self.rect(x, y, w, h, BG, LINE, 0)
        # Geometry follows the ideal 65:24 sample used in §5.3.
        iw = w * (1 - 120 / 1080)
        ih = iw * 24 / 65
        self.photo(x + (w - iw) / 2, y + (h - ih) / 2, iw, ih)
        if overlays:
            self.text(x + w / 2, y + h - 31, "LANDSCAPE STUDY", 10, MUTED, 600, "middle", spacing=1)
            self.text(x + w / 2, y + h - 16, "45 mm · f/8 · ISO 100", 9, MUTED, anchor="middle")

    def strip(self, x, y, w, h, grid=True, padding_tint=False):
        self.rect(x, y, w, h, BG, LINE, 0)
        pad = w * 210 / 4320
        self.photo(x + pad, y, w - 2 * pad, h)
        if padding_tint:
            self.rect(x, y, pad, h, SAND, "none", 0, sw=0)
            self.rect(x + w - pad, y, pad, h, SAND, "none", 0, sw=0)
        if grid:
            for k in range(1, 4):
                self.line(x + k * w / 4, y, x + k * w / 4, y + h, TEAL, 2, dash="7 7")

    def tile(self, x, y, w, h, k):
        # Tile reads the same virtual 4320 × 1440 canvas, without its own border.
        self.add(f'<svg x="{x}" y="{y}" width="{w}" height="{h}" viewBox="{k * 1080} 0 1080 1440" overflow="hidden">')
        self.rect(0, 0, 4320, 1440, BG, "none", 0, sw=0)
        self.photo(210, 0, 3900, 1440)
        self.add('</svg>')
        self.rect(x, y, w, h, "none", LINE, 0, sw=1)

    def card(self, x, y, w, h, title, detail, fill=WHITE, title_size=24):
        self.rect(x, y, w, h, fill)
        self.text(x + 24, y + 40, title, title_size, INK, 600)
        if detail:
            self.lines(x + 24, y + 76, detail, 18, 28)

    def save(self, name):
        path = OUT / f"{name}.svg"
        path.write_text("\n".join(self.parts + ['</svg>']) + "\n", encoding="utf-8")
        print(path.name)


def workflow():
    f = Figure(1, "一次创建，多种发布成品", "完成后期的原图 → 应用预设 → 独立任务 → 本地导出", 860)
    f.pill(64, 190, "01  导入原图", 190)
    f.rect(64, 252, 354, 342)
    f.photo(88, 295, 306, 113)
    f.text(88, 452, "Badlands_panorama.tif", 22, weight=600)
    f.lines(88, 492, ["已完成后期 · 保留输入 ICC", "原图只读 · EXIF 方向校正"], 18)
    f.line(418, 423, 498, 423, arrow=True)
    f.pill(500, 190, "02  应用预设", 190)
    f.card(500, 268, 328, 134, "Instagram Panorama", ["1080 × 1440  /  3:4", "完整封面 + 4 张连续切片"], PALE, 22)
    f.card(500, 448, 328, 134, "XHS Standard", ["1080 × 1080  /  1:1", "完整原图 + 最小 60 px 留白"], WHITE, 22)
    f.path("M 828 335 H 875 V 315 H 916", arrow=True)
    f.path("M 828 515 H 875 V 565 H 916", arrow=True)
    f.pill(918, 190, "03  任务与成品", 190)
    f.rect(918, 252, 618, 232)
    f.text(942, 287, "Job A · Instagram", 20, weight=600)
    f.cover(948, 316, 90, 120)
    f.text(993, 461, "Cover", 16, MUTED, anchor="middle")
    for k in range(4):
        x = 1068 + 108 * k
        f.tile(x, 316, 90, 120, k)
        f.text(x + 45, 461, f"Slide {k + 1}", 16, MUTED, anchor="middle")
    f.rect(918, 506, 618, 164)
    f.cover(948, 528, 120, 120)
    f.text(1094, 557, "Job B · 小红书", 20, weight=600)
    f.lines(1094, 596, ["00_Cover.jpg", "原图相同，任务参数各自保存"], 18)
    f.rect(64, 708, 1472, 60, PALE, PALE, 12)
    f.text(88, 747, "修改某个任务不会自动改写共享预设；GUI、CLI、MCP 都调用同一渲染核心。", 21, TEAL)
    f.save("01-publishing-workflow")


def interface():
    f = Figure(2, "三栏工作台与可调整分隔线", "左侧预设 / 位置 / 素材 · 中间预览与任务列表 · 右侧 Inspector", 1020, "界面概念图 · 参照 Compressor，示意控件位置与信息层级，不代表已实现 UI")
    f.rect(64, 194, 1472, 658, WHITE, LINE, 16)
    for i, color in enumerate(["#D8B4A9", "#DACBA9", "#B9CABB"]):
        f.dot(90 + i * 24, 221, 6, color)
    for x in (164, 1500):
        f.rect(x, 211, 26, 20, "none", MUTED, 4)
        f.line(x + 9 if x < 800 else x + 17, 211, x + 9 if x < 800 else x + 17, 231, MUTED, 1.5)
    f.rect(620, 207, 360, 31, BG, LINE, 8)
    for i, name in enumerate(["当前", "活跃", "已完成"]):
        x = 620 + i * 120
        if i == 0:
            f.rect(x + 3, 210, 114, 25, TEAL, "none", 6, sw=0)
        f.text(x + 60, 228, name, 16, WHITE if i == 0 else INK, 600, "middle")
    f.line(64, 253, 1536, 253, LINE)
    f.rect(66, 254, 310, 554, "#F2F4EF", "none", 0, sw=0)
    f.line(377, 253, 377, 808, LINE, 2)
    f.line(1041, 253, 1041, 808, LINE, 2)

    f.rect(84, 268, 274, 31, WHITE, LINE, 8)
    for i, name in enumerate(["预设", "位置", "素材"]):
        x = 84 + i * 91.3
        if i == 0:
            f.rect(x + 3, 271, 85, 25, PALE, "none", 6, sw=0)
        f.text(x + 45.6, 289, name, 16, TEAL if i == 0 else INK, 600, "middle")
    f.text(88, 336, "内置", 15, MUTED, 600, spacing=1)
    f.rect(78, 350, 284, 40, PALE, "none", 8)
    f.text(96, 377, "Instagram Panorama", 18, TEAL, 600)
    f.lines(96, 420, ["XHS Standard", "Douyin Photo"], 18, 38)
    f.line(88, 474, 351, 474, LINE)
    f.text(88, 506, "用户保存", 15, MUTED, 600, spacing=1)
    f.text(96, 542, "My Landscape", 18)
    f.line(88, 570, 351, 570, LINE)
    f.text(88, 602, "导入", 15, MUTED, 600, spacing=1)
    f.text(96, 638, "Minimal Gallery", 18)
    f.text(88, 780, "拖动预设到源图即可创建任务", 15, MUTED)

    f.text(403, 287, "PREVIEW", 15, MUTED, 600, spacing=1)
    f.pill(707, 267, "Cover", 81, size=15)
    for k in range(4):
        f.text(818 + k * 50, 290, str(k + 1), 16, MUTED, anchor="middle")
    f.cover(615, 308, 180, 240, overlays=True)
    f.text(815, 352, "3:4", 18, MUTED)
    f.text(815, 384, "Fit", 18, TEAL, 600)
    f.line(378, 562, 1040, 562, LINE, 2)
    f.text(403, 594, "BATCH", 15, MUTED, 600, spacing=1)
    f.rect(393, 608, 632, 122, BG, LINE, 10)
    f.photo(410, 622, 98, 36)
    f.text(527, 638, "Badlands_panorama.tif", 19, weight=600)
    f.text(527, 660, "65:24 · TIFF · embedded ICC", 15, MUTED)
    f.rect(412, 672, 595, 26, PALE, "none", 6)
    f.text(429, 691, "IG Panorama", 16, TEAL, 600)
    f.text(989, 691, "Cover + 4  ·  1080 × 1440", 15, TEAL, anchor="end")
    f.text(429, 719, "XHS Panorama", 16)
    f.text(989, 719, "Cover + 3  ·  1080 × 1080", 15, MUTED, anchor="end")
    f.rect(393, 740, 632, 54, BG, LINE, 10)
    f.photo(410, 750, 98, 36)
    f.text(527, 773, "Landscape_02.tif", 19, weight=600)
    f.text(989, 773, "IG Standard  ·  1080 × 1440", 15, MUTED, anchor="end")

    f.rect(1062, 268, 452, 31, BG, LINE, 8)
    for i, name in enumerate(["画布", "全景", "图层", "输出"]):
        x = 1062 + i * 113
        if i == 0:
            f.rect(x + 3, 271, 107, 25, PALE, "none", 6, sw=0)
        f.text(x + 56.5, 289, name, 16, TEAL if i == 0 else INK, 600, "middle")
    rows = [("尺寸", "1080 × 1440"), ("比例", "3:4"), ("适配", "完整嵌入"), ("背景", "#FAFAF8"), ("最小边距", "60 px"), ("对齐", "居中")]
    for i, (key, val) in enumerate(rows):
        y = 346 + 42 * i
        f.text(1066, y, key, 17)
        f.text(1510, y, val, 17, MUTED, anchor="end")
        f.line(1066, y + 16, 1510, y + 16, LINE, 1)
    f.rect(1412, 459, 16, 16, BG, MUTED, 3, sw=1)
    f.text(1066, 640, "选中任务时修改该任务参数，", 15, MUTED)
    f.text(1066, 664, "不会自动写回预设。", 15, MUTED)
    f.rect(1062, 752, 452, 36, BG, LINE, 8)
    f.text(1288, 776, "存储为预设", 16, INK, 600, "middle")

    f.line(64, 808, 1536, 808, LINE)
    f.rect(82, 816, 110, 28, BG, LINE, 7)
    f.text(137, 836, "添加图片", 15, INK, 600, "middle")
    f.text(214, 836, "位置：~/Pictures/Social Exports", 15, MUTED)
    f.rect(1010, 827, 200, 6, LINE, "none", 3, sw=0)
    f.rect(1010, 827, 84, 6, TEAL, "none", 3, sw=0)
    f.text(1224, 836, "42%", 15, TEAL, 600)
    f.rect(1330, 816, 190, 28, TEAL, TEAL, 7)
    f.text(1425, 836, "开始批处理", 15, WHITE, 600, "middle")

    for x, num in [(377, "A"), (1041, "B")]:
        f.line(x, 852, x, 879, TEAL, dash="4 4")
        f.pill(x - 21, 879, num, 42)
    f.pill(978, 545, "C", 42)
    f.text(64, 940, "A / B  横向拖动调整三栏宽度", 19, TEAL, 600)
    f.text(796, 940, "C  上下拖动调整预览与任务列表高度", 19, TEAL, 600)
    f.save("02-three-column-workbench")


def fit():
    f = Figure(3, "Fit：完整照片与最小安全边距", "相同原图等比居中；60 px 是最小值，剩余留白随画布比例变化", 980)
    positions = [(64, 1080, 1440, "Instagram", "3:4"), (387, 1080, 1080, "XHS", "1:1"), (710, 1080, 1920, "Douyin", "9:16")]
    for x, W, H, name, ratio in positions:
        w, h = 248, 248 * H / W
        y = 276 + (441 - h) / 2
        f.text(x + 124, 207, name, 24, INK, 600, "middle")
        f.text(x + 124, 241, f"{W} × {H}  /  {ratio}", 18, MUTED, anchor="middle")
        f.cover(x, y, w, h)
        m = 60 * w / W
        f.rect(x + m, y + m, w - 2 * m, h - 2 * m, "none", TEAL, 0, dash="6 6", sw=1.4)
        f.line(x + w / 2, y + m + 9, x + w / 2, y + (h - (w - 2 * m) * 24 / 65) / 2 - 9, color=TEAL, both=True)
        f.text(x + 124, 756, "左右 ≥ 60 px", 18, TEAL, 600, "middle")
        f.text(x + 124, 788, "上下留白可大于 60 px", 18, MUTED, anchor="middle")
    f.rect(1050, 190, 486, 603, WHITE)
    f.pill(1078, 215, "统一几何规则", 192)
    f.text(1078, 297, "availableWidth  = W − 2m", 24, weight=600)
    f.text(1078, 337, "availableHeight = H − 2m", 24, weight=600)
    f.line(1078, 372, 1508, 372, LINE)
    f.lines(1078, 415, ["scale = min(", "  availableWidth / sourceWidth,", "  availableHeight / sourceHeight", ")"], 21, 37, INK)
    f.lines(1078, 597, ["照片中心 = 画布中心", "保持原图比例与构图", "源图像素的方向先完成校正"], 22, 43, TEAL, 600)
    f.line(1078, 725, 1128, 725, TEAL, dash="6 6")
    f.text(1142, 732, "虚线 = 最小边距内框", 18, MUTED)
    f.rect(64, 839, 1472, 55, PALE, PALE, 10)
    f.text(88, 874, "这里是封面 Fit；全景细节切片使用另一套全局坐标规则，见下一图。", 21, TEAL)
    f.save("03-fit-and-minimum-margins")


def panorama():
    f = Figure(4, "全景长卷：先统一排版，再连续切片", "65:24 → Instagram 1080 × 1440：N = 4；3900 px 照片 + 左右各 210 px 背景", 1400,
               "按正文算例绘制 · AI 风景仅作视觉样例；虚线与尺寸线为说明标记，不写入成品")
    f.pill(64, 185, "01  虚拟总画布", 214)
    x, y, w = 64, 263, 1472
    h = w * 1440 / 4320
    pad = w * 210 / 4320
    f.line(x, 237, x + w, 237, both=True)
    f.text(800, 225, "4320 px = 4 × 1080 px", 22, TEAL, 600, "middle")
    f.strip(x, y, w, h)
    for k in range(4):
        f.pill(x + k * w / 4 + 120, y + 15, f"Tile {k + 1}", 128, size=17)
    f.text(88, y + h / 2 - 10, "210", 17, TEAL, 600)
    f.text(88, y + h / 2 + 17, "px", 17, TEAL)
    f.text(1512, y + h / 2 - 10, "210", 17, TEAL, 600, "end")
    f.text(1512, y + h / 2 + 17, "px", 17, TEAL, anchor="end")
    f.line(x + pad, y + h + 24, x + w - pad, y + h + 24, both=True)
    f.text(800, y + h + 58, "照片整体宽 3900 px · 高 1440 px · 使用同一缩放与采样规则", 21, TEAL, 600, "middle")
    f.pill(64, 845, "00  Cover", 160)
    f.cover(84, 900, 190, 253.333, overlays=True)
    f.text(64, 1193, "完整原图 + 封面留白", 19, INK, 600)
    f.text(64, 1225, "签名 / EXIF 默认仅封面", 17, MUTED)
    for k in range(4):
        xx = 368 + 292 * k
        f.line(x + (k + 0.5) * w / 4, y + h + 78, xx + 112, 880, color=LINE, width=2, arrow=True)
        f.tile(xx, 900, 224, 298.667, k)
        f.text(xx + 112, 1235, f"0{k + 1}  Slide", 20, INK, 600, "middle")
    f.rect(368, 1274, 1096, 48, PALE, PALE, 10)
    f.text(916, 1305, "每张切片 1080 × 1440 · 接缝处没有独立白边 · 只在长卷最外侧补底色", 19, TEAL, 600, "middle")
    f.save("04-seamless-panorama")


def color_pipeline():
    f = Figure(5, "有明确颜色语义的共享渲染管线", "读取源 ICC → 高精度工作空间 → 排版与合成 → 输出转换与编码", 1060,
               "管线为建议方案 · 工作空间、像素格式与 HDR 映射策略仍需 PoC / Golden Images 验证")
    f.card(64, 202, 286, 155, "编码输入", ["JPEG / TIFF / PNG / HEIC", "ICC · 位深 · Alpha · HDR", "EXIF Orientation"], WHITE)
    f.line(350, 279, 402, 279, arrow=True)
    f.card(404, 202, 306, 155, "解码与解释", ["正确识别源色彩空间", "方向只校正一次", "无 ICC：警告 + 可覆盖"], WHITE)
    f.line(710, 279, 761, 279, arrow=True)
    f.card(764, 202, 322, 155, "高精度工作图像", ["受管理的工作空间转换", "线性光 · 高精度缓冲", "宽色域不提前夹断"], PALE)
    f.line(1086, 279, 1137, 279, arrow=True)
    f.card(1140, 202, 396, 155, "Layout + Composite", ["Fit / 全局全景变换 / 重采样", "背景 + 素材 + 字形 / 元数据", "在线性光域处理透明合成"], PALE)
    f.rect(64, 423, 647, 206, WHITE)
    f.pill(88, 447, "图层颜色也进入同一工作空间", 327)
    f.rect(92, 509, 57, 57, BG, LINE, 0)
    f.lines(170, 530, ["背景 #FAFAF8 = sRGB 编码 (250, 250, 248)", "文字 / PNG 素材保留明确的颜色与 Alpha 语义"], 19, 33)
    f.path("M 711 528 H 728 V 389 H 1200 V 359", arrow=True)
    f.path("M 1338 357 V 426", arrow=True)
    f.card(1140, 428, 396, 166, "输出颜色转换", ["工作空间 → 请求的输出空间", "sRGB 默认；主动色域映射", "按输出格式执行量化"], PALE)
    f.path("M 1140 511 H 1089", arrow=True)
    # Preview and export share the layout, compositing and color policy.
    f.card(764, 428, 322, 166, "输出预览", ["相同排版与颜色策略", "按预览分辨率采样", "经显示器 ICC 显示"], WHITE)
    f.line(1338, 594, 1338, 659, arrow=True)
    f.card(1140, 662, 396, 149, "编码与发布成品", ["JPEG / PNG / HEIC / SDR 视频", "正确输出 ICC 或视频颜色标签", "清理敏感元数据 + 渲染报告"], WHITE)
    f.rect(64, 677, 1022, 134, SAND, SAND, 14)
    f.text(88, 714, "HDR 源的受控分支", 23, AMBER, 600)
    f.lines(88, 754, ["仅在启用并通过测试时进行 HDR → SDR tone mapping。", "未实现映射时明确拒绝；不静默剪裁高光。"], 20, 32, INK)
    f.rect(64, 869, 1472, 91, PALE, PALE, 14)
    f.text(88, 904, "每个任务记录 Source / Working / Output Profile 与转换、量化及警告信息。", 22, TEAL, 600)
    f.text(88, 939, "预览与导出共用计算链路；预览尺度、显示路径和最终编码可以不同。", 20, TEAL)
    f.save("05-managed-color-pipeline")


def slots():
    f = Figure(6, "分享布局，素材留在用户本地", "Preset 定义 Slot；Asset Binding 解析本地 Asset ID；Renderer 使用已解析的素材", 980)
    f.pill(64, 190, "可分享的预设包", 215)
    f.rect(64, 254, 418, 454, WHITE)
    f.text(91, 296, "Minimal.photoframe", 25, INK, 600)
    f.text(91, 333, "manifest.json  /  schemaVersion", 19, MUTED)
    f.line(91, 361, 455, 361, LINE)
    f.lines(91, 402, ["画布 · 全景规则 · 图层位置", "Slot: camera.badge", "Slot: photographer.signature"], 20, 41, INK)
    f.rect(88, 536, 369, 136, SAND, SAND, 12)
    f.text(110, 574, "默认只含占位符", 22, AMBER, 600)
    f.lines(110, 611, ["不含私人签名、品牌贴图", "不含用户本地绝对路径"], 19, 30, INK)
    f.line(482, 461, 569, 461, arrow=True)
    f.rect(572, 254, 964, 454, "#F2F5F0", LINE, 14, dash="8 7")
    f.pill(596, 276, "用户 B 的本地环境", 240)
    f.card(598, 339, 402, 182, "Asset Binding", ["camera.badge → localAssetId", "单任务 / 本地预设 / 用户默认", "按已配置的优先级解析"], WHITE)
    f.line(1000, 430, 1083, 430, arrow=True)
    f.card(1086, 339, 424, 182, "Local Asset Library", ["assetId → 实际本地文件", "自选 PNG / 签名 / 相机线稿", "真实路径由 Library 管理"], WHITE)
    f.path("M 1298 521 V 568 H 1154", arrow=True)
    f.card(808, 555, 346, 125, "Renderer", ["读取已解析的素材与几何参数", "按 visibleOn 决定显示页面"], PALE, 23)
    f.path("M 799 521 V 607 H 806", arrow=True)
    f.rect(64, 761, 717, 114, PALE, PALE, 14)
    f.text(88, 801, "可选 Slot 缺失  /  required = false", 23, TEAL, 600)
    f.text(88, 842, "显示警告，跳过该图层，允许继续输出。", 21)
    f.rect(819, 761, 717, 114, SAND, SAND, 14)
    f.text(843, 801, "必需 Slot 缺失  /  required = true", 23, AMBER, 600)
    f.text(843, 842, "阻止输出，提示绑定本地素材后重试。", 21)
    f.save("06-preset-and-local-assets")


def queue():
    f = Figure(7, "任务生命周期与安全落盘", "一个任务绑定源图与预设快照；真实进度、可取消、可重试、输出可追踪", 910)
    states = [("queued", "排队"), ("validating", "校验"), ("decoding", "解码"), ("rendering", "渲染"), ("encoding", "编码"), ("writing", "写文件"), ("completed", "完成")]
    for k, (state, cn) in enumerate(states):
        x = 64 + 214 * k
        f.rect(x, 226, 188, 121, PALE if k in [3, 6] else WHITE)
        f.text(x + 94, 270, state, 21, TEAL if k in [3, 6] else INK, 600, "middle")
        f.text(x + 94, 310, cn, 20, MUTED, anchor="middle")
        if k < 6:
            f.line(x + 188, 287, x + 209, 287, arrow=True)
    f.text(64, 191, "正常路径", 20, TEAL, 600)
    # Middle processing states can all transition to failed or canceled.
    for k in range(1, 6):
        cx = 64 + 214 * k + 94
        f.line(cx, 347, cx, 395, LINE)
    f.line(372, 395, 1228, 395, LINE)
    f.line(800, 395, 800, 425, LINE)
    f.path("M 800 425 H 520 V 464", arrow=True)
    f.path("M 800 425 H 1080 V 464", arrow=True)
    f.rect(342, 468, 356, 101, SAND, SAND, 14)
    f.text(520, 507, "failed  /  失败", 25, AMBER, 600, "middle")
    f.text(520, 545, "保存错误与可修复提示", 20, INK, anchor="middle")
    f.rect(902, 468, 356, 101, "#F1E9E4", "#F1E9E4", 14)
    f.text(1080, 507, "canceled  /  已取消", 25, RED, 600, "middle")
    f.text(1080, 545, "停止后续处理，清理自己的临时文件", 18, INK, anchor="middle")
    f.path("M 342 520 H 89 V 381 H 158 V 350", arrow=True, dash="6 6")
    f.text(107, 417, "重试：新 Attempt ID", 18, TEAL)
    f.text(107, 447, "保留原 Job 历史", 18, MUTED)
    f.pill(64, 624, "writing 阶段", 189)
    steps = [("临时目录", "仅写入本次任务文件"), ("校验结果", "检查尺寸、编码与文件完整性"), ("原子发布", "移入已授权的目标目录"), ("结果清单", "路径 / 尺寸 / ICC / 警告")]
    for k, (title, detail) in enumerate(steps):
        x = 64 + k * 382
        f.rect(x, 682, 326, 112, WHITE)
        f.text(x + 24, 722, title, 24, INK, 600)
        f.text(x + 24, 762, detail, 17, MUTED)
        if k < 3:
            f.line(x + 327, 739, x + 376, 739, arrow=True)
    f.save("07-job-lifecycle-and-atomic-export")


def architecture():
    f = Figure(8, "三种入口，共享同一后端", "GUI、CLI、MCP 调用稳定业务接口；排版、色彩处理与任务逻辑集中在共享模块", 1040,
               "模块依赖示意 · V1 默认各入口拥有独立宿主与队列；共享模块不等于跨进程共享实时队列")
    clients = [(64, "macOS App", ["SwiftUI + AppKit", "交互 / 预览 / Inspector"]), (572, "CLI  ·  photoframe", ["脚本批量 / JSON 输出", "export / dry-run / inspect"]), (1080, "MCP  ·  local stdio", ["AI 客户端调用本地工具", "校验 / 预览 / 授权导出"])]
    for x, title, details in clients:
        f.card(x, 199, 456, 138, title, details, WHITE, 26)
        f.line(x + 228, 337, x + 228, 368, LINE)
    f.line(292, 368, 1308, 368, LINE)
    f.line(800, 368, 800, 409, arrow=True)
    f.rect(533, 382, 534, 35, BG, "none", 0)
    f.text(800, 407, "Stable API / protocols / shared DTOs", 20, TEAL, 600, "middle")
    f.line(800, 418, 800, 438, arrow=True)
    f.rect(306, 441, 988, 140, PALE, LINE, 14)
    f.text(800, 483, "PhotoFrameApplication", 29, TEAL, 600, "middle")
    f.text(800, 523, "ExportService · Preset Snapshots · Asset Slots · Jobs", 22, INK, anchor="middle")
    f.text(800, 555, "权限 / 进度 / 取消 / 输出清单", 19, MUTED, anchor="middle")
    f.line(800, 581, 800, 611, LINE)
    f.line(292, 611, 1308, 611, LINE)
    for x, title, lines in [(64, "PhotoFrameCore", ["纯 Swift 模型 / 几何 / Layout", "Preset Schema / 无 UI 依赖"]), (572, "PhotoFrameRendering", ["Color / Image / Video / Preview", "封装 ColorSync、ImageIO 等"]), (1080, "Adapters", ["文件权限 / 元数据 / 编码适配", "隔离平台与 I/O 实现细节"])]:
        f.line(x + 228, 611, x + 228, 641, arrow=True)
        f.card(x, 645, 456, 145, title, lines, WHITE, 25)
        f.line(x + 228, 790, x + 228, 827, LINE)
    f.line(292, 827, 1308, 827, LINE)
    f.line(800, 827, 800, 860, arrow=True)
    f.rect(306, 864, 988, 78, WHITE, LINE, 14)
    f.text(800, 897, "Local Storage", 24, INK, 600, "middle")
    f.text(800, 925, "原图只读 · 本地预设 · 私有素材 · 本地导出与诊断", 19, MUTED, anchor="middle")
    f.save("08-shared-backend-architecture")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for generate in [workflow, interface, fit, panorama, color_pipeline, slots, queue, architecture]:
        generate()
