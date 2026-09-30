#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成赛题4 形状识别用的 16x16 点阵字库  shp_font.mem

字库内容 = 屏幕上要显示的中文标签用字(每个标签固定 2 字):
    0 圆   1 形   2 矩   3 三   4 角   5 十   6 字   7 未   8 知
    标签组合: 圆形[0,1]  矩形[2,1]  三角[3,4]  十字[5,6]  未知[7,8]
字库格式 (给 rtl/algo/shp_font.v 的 $readmemh 用):
    每个字 16 行, 每行 1 个 16bit 字 (MSB = 最左像素), 行序从上到下;
    字模地址 = 字序号*16 + 行号;  文件共 256 行(多余的填 0000)。

字形来源: Windows 自带 simhei.ttf (黑体), PIL 渲染 -> 阈值二值化。
黑体笔画粗细均匀, 16px 下比宋体清晰; 生成后会自动打印 ASCII 预览,
可以直接在终端里肉眼检查每一个字是否可辨认。

用法:  python tools/gen_font.py            # 写到工程根目录 shp_font.mem
       python tools/gen_font.py --out X.mem
"""

import argparse
import os

from PIL import Image, ImageDraw, ImageFont

GLYPHS = ["圆", "形", "矩", "三", "角", "十", "字", "未", "知"]
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\simhei.ttf",
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\simsun.ttc",
]
SIZE = 16
THRESH = 96          # 灰度阈值: > THRESH 记为笔画


def render_glyph(ch, font_path):
    """把一个汉字渲染成 16x16 的 0/1 矩阵(1 = 笔画)。"""
    font = ImageFont.truetype(font_path, SIZE)
    img = Image.new("L", (SIZE, SIZE), 0)
    draw = ImageDraw.Draw(img)
    l, t, r, b = draw.textbbox((0, 0), ch, font=font)
    # 居中(用 4x 超采样抗锯齿后再缩放, 小字号下笔画更均匀)
    x = (SIZE - (r - l)) // 2 - l
    y = (SIZE - (b - t)) // 2 - t
    draw.text((x, y), ch, fill=255, font=font)
    return [[1 if img.getpixel((i, j)) > THRESH else 0 for i in range(SIZE)]
            for j in range(SIZE)]


def glyph_to_hex_rows(bits):
    rows = []
    for j in range(SIZE):
        w = 0
        for i in range(SIZE):
            if bits[j][i]:
                w |= 1 << (SIZE - 1 - i)      # MSB = 最左
        rows.append(w)
    return rows


def ascii_preview(ch, bits):
    print("  --- %s ---" % ch)
    for j in range(SIZE):
        print("   " + "".join("##" if bits[j][i] else ".." for i in range(SIZE)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "shp_font.mem"))
    ap.add_argument("--quiet", action="store_true", help="不打印 ASCII 预览")
    args = ap.parse_args()

    font_path = None
    for c in FONT_CANDIDATES:
        if os.path.exists(c):
            font_path = c
            break
    if font_path is None:
        raise SystemExit("找不到可用的中文字体: %s" % FONT_CANDIDATES)
    print("字体: %s" % font_path)

    words = []
    for ch in GLYPHS:
        bits = render_glyph(ch, font_path)
        rows = glyph_to_hex_rows(bits)
        words.extend(rows)
        if not args.quiet:
            ascii_preview(ch, bits)

    # 补齐到 16 个字 (256 words, 8bit 地址的一块 RAM 刚好)
    words.extend([0] * (16 * SIZE - len(words)))

    with open(args.out, "w", encoding="ascii") as f:
        for w in words:
            f.write("%04X\n" % w)
    print("已写出 %s (%d 行)" % (args.out, len(words)))


if __name__ == "__main__":
    main()
