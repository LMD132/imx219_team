# -*- coding: utf-8 -*-
"""Printable A4 demo chart for the real-time edge-detection system.

Everything is vector and laid out in millimetres, so a print at 100%
(never "fit to page") gives exactly the sizes written in the labels.  A 100 mm
ruler is on page 1 so the scale can be checked with a real ruler first.

Page 1: the targets a camera can be pointed at - two checkerboards, four solid
        shapes, the digits 0-9.
Page 2: the quantitative patterns - a line-art face, a line-width ladder, a
        16-step grey wedge, a bar-grating frequency sweep and a Siemens star.

Why those sizes: docs/contrast_budget.md measured that a 3x3 median filter
erases anything one pixel wide and keeps anything two pixels wide, so the
finest bars here are 1 mm.  Point the camera so the sheet fills roughly a third
of the frame (1280 px) and 1 mm is about 3 px - right at the cliff, which is
the interesting part to show.

    python tools\\make_edge_test_chart.py
    python tools\\make_edge_test_chart.py --out outputs/x.pdf --png work/preview
"""

import argparse
import os
import subprocess
import sys
from math import radians, cos, sin

from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas

PAGE_W, PAGE_H = A4
MARGIN = 10.0
HEAD = "边缘检测演示卡  |  FPGA 实时图像边缘检测系统"
SUBTITLE = "请用 100% 原始比例打印（A4，不要选 适合页面）。演示前先用下面的 100 mm 直尺核对比例。"

CJK_FONTS = (
    ("CJK", r"C:\Windows\Fonts\simhei.ttf", None),
    ("CJK", r"C:\Windows\Fonts\msyh.ttc", 0),
    ("CJK", r"C:\Windows\Fonts\simsun.ttc", 0),
)


def register_font():
    for name, path, idx in CJK_FONTS:
        if not os.path.exists(path):
            continue
        try:
            font = TTFont(name, path) if idx is None else TTFont(name, path, subfontIndex=idx)
            pdfmetrics.registerFont(font)
            return name
        except Exception:
            continue
    return "Helvetica"


FONT = register_font()


# --- primitives (all coordinates in mm) ------------------------------------

def T(c, x, y, s, size=3.4, font=None, gray=0.0, align="l"):
    c.setFont(font or FONT, size * mm)
    c.setFillGray(gray)
    if align == "l":
        c.drawString(x * mm, y * mm, s)
    elif align == "c":
        c.drawCentredString(x * mm, y * mm, s)
    else:
        c.drawRightString(x * mm, y * mm, s)


def frame(c, x, y, w, h, gray=0.62, lw=0.25):
    c.setStrokeGray(gray)
    c.setLineWidth(lw * mm)
    c.rect(x * mm, y * mm, w * mm, h * mm, stroke=1, fill=0)


def fill(c, x, y, w, h, gray=0.0):
    c.setFillGray(gray)
    c.rect(x * mm, y * mm, w * mm, h * mm, stroke=0, fill=1)


def line(c, x1, y1, x2, y2, lw=1.0, gray=0.0):
    c.setStrokeGray(gray)
    c.setLineWidth(lw * mm)
    c.line(x1 * mm, y1 * mm, x2 * mm, y2 * mm)


def panel(c, x, y, w, h, title, hint=None):
    """Framed cell with the title above it and an optional hint below."""
    frame(c, x, y, w, h)
    T(c, x, y + h + 1.6, title, size=3.7)
    if hint:
        T(c, x, y - 4.2, hint, size=2.75, gray=0.35)


def checkerboard(c, x, y, total, n):
    fill(c, x, y, total, total, 1.0)
    cell = total / float(n)
    for j in range(n):
        for i in range(n):
            if (i + j) % 2:
                fill(c, x + i * cell, y + (n - 1 - j) * cell, cell, cell, 0.0)


def poly(c, pts, gray=0.0):
    p = c.beginPath()
    p.moveTo(pts[0][0] * mm, pts[0][1] * mm)
    for px, py in pts[1:]:
        p.lineTo(px * mm, py * mm)
    p.close()
    c.setFillGray(gray)
    c.drawPath(p, fill=1, stroke=0)


def wedges(c, cx, cy, r, n=36):
    """Siemens star: black/white pie wedges, a radial frequency sweep."""
    step = 360.0 / n
    for i in range(n):
        if i % 2 == 0:
            continue
        c.setFillGray(0.0)
        c.wedge((cx - r) * mm, (cy - r) * mm, (cx + r) * mm, (cy + r) * mm,
                i * step, step, fill=1, stroke=0)


def gratings(c, x, y, w, h, periods, gap=2.0):
    """Vertical black/white bar gratings of the given periods (mm)."""
    cw = (w - gap * (len(periods) - 1)) / float(len(periods))
    for k, p in enumerate(periods):
        gx = x + k * (cw + gap)
        fill(c, gx, y, cw, h, 1.0)
        half = p / 2.0
        i = 0
        while i * p < cw:
            fill(c, gx + i * p, y, min(half, cw - i * p), h, 0.0)
            i += 1
        frame(c, gx, y, cw, h, gray=0.75)
        T(c, gx + cw / 2.0, y - 4.0, "p=%gmm" % p, size=2.9, gray=0.3, align="c")


def shade_wedge(c, x, y, w, h, steps=16):
    """16-step grey wedge; the printed values are the ideal 8-bit levels."""
    cw = w / float(steps)
    for i in range(steps):
        g = i / float(steps - 1)
        fill(c, x + i * cw, y, cw, h, g)
        frame(c, x + i * cw, y, cw, h, gray=0.75, lw=0.15)
        T(c, x + (i + 0.5) * cw, y - 4.0, str(int(round(g * 255))),
          size=2.7, gray=0.3, align="c")


def face(c, x, y, w, h):
    """Line-art face outline, thick strokes so it survives the filter chain."""
    cx = x + w / 2.0
    cy = y + h * 0.64
    rx, ry = w * 0.29, h * 0.29
    box = ((cx - rx) * mm, (cy - ry) * mm, (cx + rx) * mm, (cy + ry) * mm)
    lw = 1.8

    # hair: the arc segment above the hairline, filled solid
    p = c.beginPath()
    p.moveTo((cx + rx * cos(radians(35))) * mm, (cy + ry * sin(radians(35))) * mm)
    p.arcTo(*box, 35, 110)
    p.close()
    c.setFillGray(0.0)
    c.drawPath(p, fill=1, stroke=0)

    c.setStrokeGray(0.0)
    c.setLineWidth(lw * mm)
    c.ellipse(box[0], box[1], box[2], box[3], stroke=1, fill=0)
    # ears
    for sgn in (-1, 1):
        c.ellipse((cx + sgn * rx - 3.2) * mm, (cy - 7.0) * mm,
                  (cx + sgn * rx + 3.2) * mm, (cy + 7.0) * mm, stroke=1, fill=0)
    # eyes: stroked almond plus a solid pupil
    c.setLineWidth(1.2 * mm)
    for sgn in (-1, 1):
        ex = cx + sgn * rx * 0.45
        ey = cy + ry * 0.12
        c.ellipse((ex - rx * 0.22) * mm, (ey - ry * 0.13) * mm,
                  (ex + rx * 0.22) * mm, (ey + ry * 0.13) * mm, stroke=1, fill=0)
        c.setFillGray(0.0)
        c.circle(ex * mm, ey * mm, 2.6 * mm, stroke=0, fill=1)
    # brows
    c.setStrokeGray(0.0)
    c.setLineWidth(2.0 * mm)
    for sgn in (-1, 1):
        ex = cx + sgn * rx * 0.45
        by = cy + ry * 0.34
        c.bezier((ex - rx * 0.26) * mm, by * mm,
                 (ex - rx * 0.08) * mm, (by + ry * 0.10) * mm,
                 (ex + rx * 0.08) * mm, (by + ry * 0.10) * mm,
                 (ex + rx * 0.26) * mm, by * mm)
    # nose
    c.setLineWidth(1.5 * mm)
    p = c.beginPath()
    p.moveTo(cx * mm, (cy - ry * 0.02) * mm)
    p.lineTo((cx - rx * 0.12) * mm, (cy - ry * 0.20) * mm)
    p.lineTo((cx + rx * 0.09) * mm, (cy - ry * 0.23) * mm)
    c.drawPath(p, fill=0, stroke=1)
    # mouth
    c.setLineWidth(1.8 * mm)
    my = cy - ry * 0.48
    c.bezier((cx - rx * 0.42) * mm, my * mm,
             (cx - rx * 0.16) * mm, (my - ry * 0.20) * mm,
             (cx + rx * 0.16) * mm, (my - ry * 0.20) * mm,
             (cx + rx * 0.42) * mm, my * mm)
    # neck and shoulders
    c.setLineWidth(lw * mm)
    ny = y + h * 0.10
    for sgn in (-1, 1):
        line(c, cx + sgn * rx * 0.34, cy - ry * 0.98, cx + sgn * rx * 0.34, ny, lw=lw)
        line(c, cx + sgn * rx * 0.34, ny, cx + sgn * (rx + 12.0), y + h * 0.02, lw=lw)


def ruler(c, x, y, length=100.0):
    line(c, x, y, x + length, y, lw=0.4)
    for i in range(int(length) + 1):
        if i % 10 == 0:
            tall = 3.0
        elif i % 5 == 0:
            tall = 2.0
        else:
            tall = 1.2
        line(c, x + i, y, x + i, y + tall, lw=0.3)
    for i in range(0, int(length) + 1, 10):
        T(c, x + i, y + 3.6, "%d" % i, size=2.6, gray=0.35, align="c")


# --- pages -----------------------------------------------------------------

def page1(c):
    top = PAGE_H / mm - MARGIN
    T(c, MARGIN, top - 5.0, HEAD, size=5.2)
    T(c, MARGIN, top - 10.0, SUBTITLE, size=3.1, gray=0.35)
    T(c, PAGE_W / mm - MARGIN, top - 5.0, "第 1 / 2 页", size=3.4, gray=0.35, align="r")
    ruler(c, MARGIN, top - 20.0)
    T(c, MARGIN + 108, top - 16.4, "100 mm 校准直尺 - 先用真尺量一下，再信其它尺寸",
      size=2.8, gray=0.4)

    # two checkerboards
    board = 90.0
    y = top - 27.0 - board
    panel(c, MARGIN, y, board, board, "棋盘格（方格 22.5 mm）",
          "4x4，90 mm。特征大，边缘最干净的一组。")
    panel(c, MARGIN + 100, y, board, board, "棋盘格（方格 9 mm）",
          "10x10，90 mm。更密，滤波链开始起作用。")
    checkerboard(c, MARGIN, y, board, 4)
    checkerboard(c, MARGIN + 100, y, board, 10)

    # solid shapes
    sy = y - 17.0 - 44.0
    cell = 44.0
    xs = [MARGIN + i * 48.0 for i in range(4)]
    names = ["圆环（线宽 3 mm）", "三角形", "正方形", "十字（臂宽 8 mm）"]
    for x, nm in zip(xs, names):
        panel(c, x, sy, cell, cell, nm)
    # ring
    c.setStrokeGray(0.0)
    c.setLineWidth(3.0 * mm)
    c.circle((xs[0] + cell / 2) * mm, (sy + cell / 2) * mm, (cell * 0.34) * mm,
             stroke=1, fill=0)
    cx = xs[1] + cell / 2.0
    poly(c, [(cx, sy + cell - 6.0), (cx - cell * 0.40, sy + 6.0), (cx + cell * 0.40, sy + 6.0)])
    poly(c, [(xs[2] + 8.0, sy + 8.0), (xs[2] + cell - 8.0, sy + 8.0),
             (xs[2] + cell - 8.0, sy + cell - 8.0), (xs[2] + 8.0, sy + cell - 8.0)])
    cx = xs[3] + cell / 2.0
    cy = sy + cell / 2.0
    fill(c, cx - 4.0, sy + 6.0, 8.0, cell - 12.0)
    fill(c, xs[3] + 6.0, cy - 4.0, cell - 12.0, 8.0)

    # digits: 38 mm wide by 40 mm tall cells, digits sized to sit inside them
    cellw, cellh = 38.0, 40.0
    dy = sy - 16.0 - 2.0 * cellh
    T(c, MARGIN, dy + 2.0 * cellh + 4.0, "数字 0-9（Helvetica Bold）", size=3.7)
    for row in range(2):
        for col in range(5):
            x = MARGIN + col * cellw
            yy = dy + (1 - row) * cellh
            frame(c, x, yy, cellw, cellh, gray=0.72, lw=0.2)
            d = str(row * 5 + col)
            T(c, x + cellw / 2.0, yy + 6.4, d, size=38.0,
              font="Helvetica-Bold", align="c")


def page2(c):
    top = PAGE_H / mm - MARGIN
    T(c, MARGIN, top - 5.0, "第 2 页 - 定量测试图形", size=4.6)
    T(c, MARGIN, top - 10.0,
      "打印规则同上：100%、A4。最细的条纹是 1 mm，这是故意的。",
      size=3.1, gray=0.35)
    T(c, PAGE_W / mm - MARGIN, top - 5.0, "第 2 / 2 页", size=3.4, gray=0.35, align="r")

    # R1: face outline + line-width ladder
    fy, fh = 180.0, 82.0
    panel(c, MARGIN, fy, 80.0, fh, "人脸轮廓",
          "曲线，笔画 1.2-2.0 mm。")
    face(c, MARGIN + 2, fy + 2, 76.0, fh - 4.0)

    lx = MARGIN + 90.0
    panel(c, lx, fy, 100.0, fh, "线宽阶梯",
          "左：水平条；右：垂直条。厚度 1/2/3/5/8 mm。")
    widths = [1.0, 2.0, 3.0, 5.0, 8.0]
    for i, w_ in enumerate(widths):
        yy = fy + fh - 14.0 - i * 14.0
        fill(c, lx + 10.0, yy, 32.0, w_)
        T(c, lx + 46.0, yy - 1.0, "水平 %g mm" % w_, size=2.9, gray=0.3)
    for i, w_ in enumerate(widths):
        xx = lx + 64.0 + i * 6.0
        fill(c, xx, fy + 12.0, w_, 40.0)
        T(c, xx + 3.0, fy + 6.4, "%g" % w_, size=2.7, gray=0.3, align="c")
    T(c, lx + 64.0, fy + 56.0, "垂直条，单位 mm", size=2.9, gray=0.3)

    # R2: grey wedge
    wy, wh = 133.0, 30.0
    T(c, MARGIN, wy + wh + 4.0, "灰阶楔（16 级，0-255）", size=3.7)
    T(c, MARGIN + 78.0, wy + wh + 4.0,
      "打印机不是线性的，数字只是理想灰度值。",
      size=2.75, gray=0.35)
    shade_wedge(c, MARGIN, wy, 190.0, wh)

    # R3: bar gratings + Siemens star
    gy, gh = 70.0, 50.0
    T(c, MARGIN, gy + gh + 4.0, "条纹光栅（周期 2-12 mm）", size=3.7)
    gratings(c, MARGIN, gy, 128.0, gh, [2, 3, 4, 6, 8, 12])
    T(c, MARGIN, gy - 9.5,
      "凑近到 p=2 mm 那一列还有边缘；再远，它最先消失。",
      size=2.75, gray=0.35)

    sx = MARGIN + 140.0
    T(c, sx, gy + gh + 4.0, "西门子星", size=3.7)
    wedges(c, sx + 25.0, gy + 25.0, 24.0, n=36)
    T(c, sx, gy - 9.5, "中心清晰，边缘糊成一片。", size=2.75, gray=0.35)

    # R4: text at four sizes
    ty, th = 18.0, 30.0
    T(c, MARGIN, ty + th + 4.0, "四种字号的文字（字高 6.5-2.3 mm）",
      size=3.7)
    for base, size, s in ((41.0, 9.0, "EDGE 0123 边缘检测"),
                          (33.5, 6.5, "EDGE 0123 边缘检测"),
                          (27.0, 4.5, "EDGE 0123 边缘检测"),
                          (21.5, 3.2, "EDGE 0123 边缘检测")):
        T(c, MARGIN, base, s, size=size)
    T(c, MARGIN, ty - 4.5,
      "笔画越细越先糊：看哪一行先断开。",
      size=2.75, gray=0.35)

    T(c, MARGIN, MARGIN - 5.0,
      "imx219_team / tools/make_edge_test_chart.py - 尺寸为精确矢量毫米，可随时重新生成。",
      size=2.6, gray=0.45)


def T_targets_only(base):
    """--clean filter: keep the target glyphs, drop every caption.

    The only text that is part of a target (rather than a note about it) is the
    0-9 glyph set, drawn in Helvetica-Bold, and the four strokes of the
    'EDGE 0123' size ladder.  Everything else - page titles, panel captions,
    hints, ruler numbers, wedge levels, grating periods, page numbers - is an
    annotation and is dropped so the sheet holds nothing but patterns.
    """
    def t(c, x, y, s, size=3.4, font=None, gray=0.0, align="l"):
        if font == "Helvetica-Bold" or "EDGE 0123" in s:
            base(c, x, y, s, size=size, font=font, gray=gray, align=align)
    return t


def build(path, clean=False):
    c = canvas.Canvas(path, pagesize=A4)
    c.setTitle("Edge-detection demo chart (A4, 100%)")
    c.setAuthor("imx219_team")
    c.setSubject("Printable targets for the FPGA real-time edge-detection demo")
    saved = globals()["T"]
    if clean:
        globals()["T"] = T_targets_only(saved)
    try:
        page1(c)
        c.showPage()
        page2(c)
        c.showPage()
    finally:
        globals()["T"] = saved
    c.save()


def render(pdf, outdir, dpi=150):
    exe = None
    for cand in (r"C:\Users\HUAWEI\.cache\codex-runtimes\codex-primary-runtime\dependencies"
                 r"\native\poppler\Library\bin\pdftoppm.exe", "pdftoppm"):
        try:
            subprocess.run([cand, "-v"], capture_output=True)
            exe = cand
            break
        except Exception:
            continue
    if exe is None:
        print("pdftoppm not found - skip PNG preview")
        return []
    os.makedirs(outdir, exist_ok=True)
    subprocess.run([exe, "-png", "-r", str(dpi), pdf, os.path.join(outdir, "chart")], check=True)
    return sorted(f for f in os.listdir(outdir) if f.startswith("chart"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    ap.add_argument("--png", default=None)
    ap.add_argument("--dpi", type=int, default=150)
    ap.add_argument("--clean", action="store_true",
                    help="patterns only: no titles, captions, notes or page numbers")
    a = ap.parse_args()
    if a.out is None:
        a.out = os.path.join("outputs", "edge_detect_demo_chart%s_A4.pdf"
                             % ("_clean" if a.clean else ""))
    if a.png is None:
        a.png = os.path.join("work", "preview_clean" if a.clean else "preview")
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    build(a.out, clean=a.clean)
    print("wrote %s (%d bytes, font=%s)" % (a.out, os.path.getsize(a.out), FONT))
    print("preview: %s" % ", ".join(render(a.out, a.png, a.dpi)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
