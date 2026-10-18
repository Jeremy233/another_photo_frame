#!/usr/bin/env python3
"""生成 macOS 应用图标：中性深灰底板 + photo-stack.png（透明背景的相纸堆）。

从仓库根目录运行（需要 Pillow）：

    python3 Apps/PhotoFrameMac/Design/AppIcon/make_app_icon.py

输出到 Apps/PhotoFrameMac/App/Assets.xcassets/AppIcon.appiconset/，并写好 Contents.json。
底板颜色取自界面的中性灰（D-105），不带色相，不随壁纸染色。
"""
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
OUT = HERE.parents[1] / "App" / "Assets.xcassets" / "AppIcon.appiconset"

CANVAS = 1024
BODY = 824                 # macOS 图标网格：824 pt 的圆角方形放在 1024 画布中央
SS = 4                     # 超采样倍数，用于抗锯齿
TOP, BOTTOM = (58, 58, 58), (36, 36, 36)   # 底板竖向渐变，中性灰（与界面面板 #2d2d2d 同一色系）
STACK_WIDTH = 700          # 相纸堆在 1024 画布上的宽度
STACK_CENTER = (512, 506)


def squircle_mask(size: int, exponent: float = 6.5) -> Image.Image:
    """超椭圆（接近 macOS 的连续圆角）蒙版，size×size。"""
    big = size * SS
    mask = Image.new("L", (big, big), 0)
    r = big / 2
    points = []
    steps = 2000
    import math
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = r + r * math.copysign(abs(c) ** (2 / exponent), c)
        y = r + r * math.copysign(abs(s) ** (2 / exponent), s)
        points.append((x, y))
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def tile() -> Image.Image:
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    mask = squircle_mask(BODY)
    off = (CANVAS - BODY) // 2

    # 底板下方的投影（系统图标同样带一个柔和的落影）
    shadow = Image.new("L", (CANVAS, CANVAS), 0)
    shadow.paste(mask, (off, off + 12))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18)).point(lambda v: int(v * 0.45))
    canvas.paste(Image.new("RGBA", canvas.size, (0, 0, 0, 255)), (0, 0), shadow)

    # 竖向渐变底板
    grad = Image.new("RGBA", (BODY, BODY))
    draw = ImageDraw.Draw(grad)
    for y in range(BODY):
        t = y / (BODY - 1)
        color = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
        draw.line([(0, y), (BODY, y)], fill=color + (255,))
    canvas.paste(grad, (off, off), mask)

    # 顶边一道很淡的高光，让底板在深色 Dock 上也有轮廓
    inner = squircle_mask(BODY - 4)
    rim = Image.new("L", (BODY, BODY), 0)
    rim.paste(mask)
    hole = Image.new("L", (BODY, BODY), 0)
    hole.paste(inner, (2, 3))
    rim = ImageChops.subtract(rim, hole)
    fade = Image.linear_gradient("L").resize((BODY, BODY)).point(lambda v: int((255 - v) * 0.10))
    rim = ImageChops.multiply(rim, fade)
    canvas.paste(Image.new("RGBA", (BODY, BODY), (255, 255, 255, 255)), (off, off), rim)
    return canvas


def photo_stack() -> Image.Image:
    stack = Image.open(HERE / "photo-stack.png").convert("RGBA")
    r, g, b, a = stack.split()
    # 生成时留下的半透明：几乎不透明的地方补成不透明，零星噪点去掉
    a = a.point(lambda v: 0 if v < 24 else (255 if v > 232 else v))
    stack = Image.merge("RGBA", (r, g, b, a))
    stack = stack.crop(a.getbbox())
    scale = STACK_WIDTH / stack.width
    return stack.resize((STACK_WIDTH, round(stack.height * scale)), Image.LANCZOS)


def compose() -> Image.Image:
    icon = tile()
    stack = photo_stack()
    x = STACK_CENTER[0] - stack.width // 2
    y = STACK_CENTER[1] - stack.height // 2

    # 相纸堆的落影
    shadow = Image.new("L", icon.size, 0)
    shadow.paste(stack.split()[3], (x, y + 10))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.55))
    icon.paste(Image.new("RGBA", icon.size, (0, 0, 0, 255)), (0, 0), shadow)

    icon.alpha_composite(stack, (x, y))
    return icon


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    master = compose()
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(OUT / name, optimize=True)
            images.append({"idiom": "mac", "size": f"{points}x{points}", "scale": f"{scale}x", "filename": name})
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (OUT / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    catalog = OUT.parent / "Contents.json"
    if not catalog.exists():
        catalog.write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(f"wrote {len(images)} sizes to {OUT}")


if __name__ == "__main__":
    main()
