#!/usr/bin/env python3
"""生成 App 图标（Resources/AppIcon.icns）。

设计：蓝→紫渐变圆角块（取自 Theme.photo / Theme.video），
文字 CleanMyiPhone + 换行 ygelon，底部一条容量条 —— 左边暗的是已占用，
右边白的是清理出来的空间。

改完直接跑：python3 scripts/make-icon.py
依赖：Pillow（DSH 自带那份就行）
"""
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
# iconutil 在 /var/folders 下的临时目录会失败，固定用 /tmp
WORK = Path(tempfile.mkdtemp(prefix="cmicon-", dir="/tmp"))


S = 1024
BODY = 824
MARGIN = (S - BODY) // 2
RADIUS = 185

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# 主题色：Theme.photo (82,148,252) -> Theme.video (158,112,242)
C1 = (74, 132, 252)
C2 = (150, 106, 244)

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# --- 投影 ---
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle(
    [MARGIN, MARGIN + 14, MARGIN + BODY, MARGIN + BODY + 14],
    radius=RADIUS, fill=(30, 24, 70, 110))
shadow = shadow.filter(ImageFilter.GaussianBlur(22))
img.alpha_composite(shadow)

# --- 主体渐变（对角线） ---
body = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 0))
bd = ImageDraw.Draw(body)
for y in range(BODY):
    for x in range(0, BODY, 4):
        t = (x / BODY * 0.55 + y / BODY * 0.45)
        bd.rectangle([x, y, x + 4, y + 1], fill=lerp(C1, C2, t))

# 顶部高光（上亮下暗，玻璃感）
gloss = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 0))
gd = ImageDraw.Draw(gloss)
for y in range(BODY):
    a = int(58 * (1 - y / BODY) ** 1.6)
    gd.rectangle([0, y, BODY, y + 1], fill=(255, 255, 255, a))
body.alpha_composite(gloss)

# 圆角裁切
mask = Image.new("L", (BODY, BODY), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, BODY - 1, BODY - 1], radius=RADIUS, fill=255)
body.putalpha(mask)

img.alpha_composite(body, (MARGIN, MARGIN))

# --- 文字 ---
d = ImageDraw.Draw(img)
FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

name = "CleanMyiPhone"
sub = "ygelon"

size = 104
font = ImageFont.truetype(FONT, size)
while d.textlength(name, font=font) > BODY - 130 and size > 40:
    size -= 2
    font = ImageFont.truetype(FONT, size)

w = d.textlength(name, font=font)
# 视觉居中：文字块整体略偏上，下面留给容量条
name_y = MARGIN + 272
d.text(((S - w) / 2, name_y), name, font=font, fill=(255, 255, 255, 255))

sub_size = 64
sfont = ImageFont.truetype(FONT, sub_size)
sw = d.textlength(sub, font=sfont)
d.text(((S - sw) / 2, name_y + size + 34), sub, font=sfont, fill=(255, 255, 255, 190))

# --- 容量条：左段已用（半透明白），右段可用（亮白） ---
bar_w, bar_h = 560, 30
bar_x = (S - bar_w) // 2
bar_y = MARGIN + BODY - 186
used = 0.66
gap = 16
used_w = int(bar_w * used)
# 左段：已占用 —— 用半透明深色"压下去"（PIL 的 draw 不混合，写入的就是半透明像素，
# 存成 PNG 之后才和底色混，所以这里必须给深色，给半透明白只会更亮）
d.rounded_rectangle([bar_x, bar_y, bar_x + used_w, bar_y + bar_h],
                    radius=bar_h // 2, fill=(14, 10, 46, 128))
# 右段：可用 / 清理出来的空间 —— 纯白顶在最后
d.rounded_rectangle([bar_x + used_w + gap, bar_y,
                     bar_x + bar_w, bar_y + bar_h],
                    radius=bar_h // 2, fill=(255, 255, 255, 255))

img.save(str(WORK / "icon_1024.png"))
print("生成完成", img.size)

# ---- 打包成 .icns ----
iconset = WORK / "AppIcon.iconset"
iconset.mkdir(exist_ok=True)
for px, name in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                 (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                 (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]:
    out = iconset / f"icon_{name}.png"
    subprocess.run(["sips", "-z", str(px), str(px), str(WORK / "icon_1024.png"),
                    "--out", str(out)], check=True, capture_output=True)

# iconutil 直接往外置卷/沙箱内写会失败（Failed to generate ICNS），
# 所以先生成到 /tmp 再搬过来
staged = WORK / "AppIcon.icns"
subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(staged)], check=True)

target = ROOT / "Resources" / "AppIcon.icns"
target.write_bytes(staged.read_bytes())
print("已生成", target, target.stat().st_size, "字节")
