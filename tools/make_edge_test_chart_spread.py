# -*- coding: utf-8 -*-
"""Spread-out A4 demo chart: same patterns as the dense chart, fewer per page.

The dense version (tools/make_edge_test_chart.py, 2 pages) is for a single
sheet you can hold up; this one gives one or two patterns per page so each
target can fill the camera frame on its own.  All the drawing primitives are
imported from the dense chart, so the two stay consistent - only the page
layout differs.

    python tools\\make_edge_test_chart_spread.py
    python tools\\make_edge_test_chart_spread.py --out outputs/x.pdf --png work/preview
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import make_edge_test_chart as C  # noqa: E402  (needs the path above)
from reportlab.lib.pagesizes import A4  # noqa: E402
from reportlab.pdfgen import canvas  # noqa: E402

MM = C.mm
PAGE_W, PAGE_H, MARGIN = C.PAGE_W, C.PAGE_H, C.MARGIN
TOTAL = 7


def head(c, n, title, sub=None):
    top = PAGE_H / MM - MARGIN
    C.T(c, MARGIN, top - 5.5, title, size=5.0)
    C.T(c, PAGE_W / MM - MARGIN, top - 5.5, "第 %d / %d 页" % (n, TOTAL),
        size=3.4, gray=0.35, align="r")
    if sub:
        C.T(c, MARGIN, top - 11.0, sub, size=3.1, gray=0.35)


def foot(c, note=None):
    C.T(c, MARGIN, MARGIN - 5.0,
        "imx219_team / tools/make_edge_test_chart_spread.py - 尺寸为精确矢量毫米，可随时重新生成。",
        size=2.6, gray=0.45)
    if note:
        C.T(c, PAGE_W / MM - MARGIN, MARGIN - 5.0, note, size=2.6, gray=0.45, align="r")


def cover(c):
    head(c, 1, "边缘检测演示卡（稀疏版）",
         "按 100% 原始比例打印（A4，不要选 适合页面）。演示前先用下面的 100 mm 直尺核对比例。")
    C.ruler(c, MARGIN, 266.0)
    C.T(c, MARGIN + 108, 269.6, "100 mm 校准直尺 - 先用真尺量一下，再信其它尺寸",
         size=2.8, gray=0.4)

    board = 144.0
    x = (PAGE_W / MM - board) / 2.0
    C.panel(c, x, 112.0, board, board, "棋盘格（方格 24 mm，6x6）",
            "三种棋盘格里最大的方格：边缘最干净，任何距离都稳。")
    C.checkerboard(c, x, 112.0, board, 6)

    C.T(c, MARGIN, 100.0, "怎么用", size=3.9)
    for i, s in enumerate([
            "1. 按 100% 打印，先用顶部 100 mm 直尺核对比例；标准 HDMI 输出下图案尽量占满画面宽度。",
            "2. 镜头正对、避免反光；这一版每页只有一两个图案，方便单个图案占满画面拍摄。",
            "3. 最细的 1 mm 特征会最先消失：中值滤波会把 1 像素宽的东西整条删掉（见 docs/contrast_budget.md）。",
            "4. 对照 docs/reference_video_analysis.md：平区要干净、轮廓要连续、不要断成一节一节。"]):
        C.T(c, MARGIN, 90.0 - i * 8.0, s, size=3.2, gray=0.15)
    foot(c, "第 1 页：说明 + 大棋盘格")


def board9(c):
    head(c, 2, "棋盘格（方格 11 mm，15x15）",
         "密度是上一页的两倍多：边缘数量明显变多，也更容易看出滤波链的影响。")
    board = 165.0
    x = (PAGE_W / MM - board) / 2.0
    C.panel(c, x, 95.0, board, board, "", None)
    C.checkerboard(c, x, 95.0, board, 15)
    C.T(c, MARGIN, 80.0, "看什么", size=3.9)
    for i, s in enumerate([
            "1. 方格交界应该全部出边，方格的内部（大块黑/白）不该有噪点。",
            "2. 退远一点：方格变小、边缘变密，画面会先乱后糊，这就是空间频率的作用。"]):
        C.T(c, MARGIN, 70.0 - i * 8.0, s, size=3.2, gray=0.15)
    foot(c, "第 2 页：小棋盘格")


def shapes(c):
    head(c, 3, "几何图形（直线 / 斜线 / 圆 / 拐角）",
         "四种基本形状各一块，每块约 86 mm，尽量占满画面逐个拍摄。")
    cell, gap = 86.0, 10.0
    x0 = (PAGE_W / MM - (2 * cell + gap)) / 2.0
    ys = [140.0, 44.0]
    xs = [x0, x0 + cell + gap]
    titles = ["圆环（线宽 4 mm）", "三角形（实心）", "正方形（实心）", "十字（臂宽 12 mm）"]
    for k, (cx_, cy_) in enumerate([(xs[0], ys[0]), (xs[1], ys[0]),
                                    (xs[0], ys[1]), (xs[1], ys[1])]):
        C.panel(c, cx_, cy_, cell, cell, titles[k])

    c.setStrokeGray(0.0)
    c.setLineWidth(4.0 * MM)
    c.circle((xs[0] + cell / 2) * MM, (ys[0] + cell / 2) * MM, (cell * 0.34) * MM,
             stroke=1, fill=0)
    mx = xs[1] + cell / 2.0
    C.poly(c, [(mx, ys[0] + cell - 10.0), (mx - cell * 0.40, ys[0] + 10.0),
               (mx + cell * 0.40, ys[0] + 10.0)])
    C.poly(c, [(xs[0] + 8.0, ys[1] + 8.0), (xs[0] + cell - 8.0, ys[1] + 8.0),
               (xs[0] + cell - 8.0, ys[1] + cell - 8.0), (xs[0] + 8.0, ys[1] + cell - 8.0)])
    mx = xs[1] + cell / 2.0
    my = ys[1] + cell / 2.0
    C.fill(c, mx - 6.0, ys[1] + 8.0, 12.0, cell - 16.0)
    C.fill(c, xs[1] + 8.0, my - 6.0, cell - 16.0, 12.0)
    foot(c, "第 3 页：基本形状")


def digits(c):
    head(c, 4, "数字 0-9 与四种字号的文字",
         "数字格 38 x 62 mm；下方同一句文字，字号从 20 mm 缩到 5.5 mm。")
    cw, ch = 38.0, 62.0
    y0 = 88.0
    C.T(c, MARGIN, y0 + 2 * ch + 4.0, "数字 0-9（Helvetica Bold）", size=3.7)
    for row in range(2):
        for col in range(5):
            x = MARGIN + col * cw
            yy = y0 + (1 - row) * ch
            C.frame(c, x, yy, cw, ch, gray=0.72, lw=0.2)
            C.T(c, x + cw / 2.0, yy + 12.0, str(row * 5 + col), size=52.0,
                font="Helvetica-Bold", align="c")

    C.T(c, MARGIN, 82.0, "四种字号的文字（字号 20 / 13 / 8.5 / 5.5 mm）", size=3.7)
    for base, size, s in ((64.0, 20.0, "边缘检测 EDGE 0123"),
                          (48.0, 13.0, "边缘检测 EDGE 0123"),
                          (36.0, 8.5, "边缘检测 EDGE 0123"),
                          (26.0, 5.5, "边缘检测 EDGE 0123")):
        C.T(c, MARGIN, base, s, size=size)
    C.T(c, MARGIN, 16.0, "笔画越细越先糊：看哪一行先断开。", size=2.75, gray=0.35)
    foot(c, "第 4 页：数字与文字")


def face_page(c):
    head(c, 5, "人脸轮廓与线宽阶梯",
         "左侧人脸：曲线 + 细笔画；右侧阶梯：水平条与垂直条各五档。")
    C.panel(c, MARGIN, 55.0, 98.0, 195.0, "人脸轮廓", "笔画 1.2-2.0 mm。")
    C.face(c, MARGIN + 2, 57.0, 94.0, 191.0)

    lx = MARGIN + 108.0
    C.panel(c, lx, 55.0, 80.0, 195.0, "线宽阶梯", "厚度 1/2/3/5/8 mm。")
    for i, w_ in enumerate([1.0, 2.0, 3.0, 5.0, 8.0]):
        yy = 236.0 - i * 32.0
        C.fill(c, lx + 6.0, yy, 30.0, w_)
        C.T(c, lx + 40.0, yy - 1.0, "水平 %g mm" % w_, size=2.9, gray=0.3)
    C.T(c, lx + 6.0, 102.0, "垂直条（mm）", size=2.9, gray=0.3)
    for i, w_ in enumerate([1.0, 2.0, 3.0, 5.0, 8.0]):
        xx = lx + 8.0 + i * 8.0
        C.fill(c, xx, 62.0, w_, 34.0)
        C.T(c, xx + 4.0, 57.0, "%g" % w_, size=2.7, gray=0.3, align="c")
    foot(c, "第 5 页：人脸 + 线宽")


def grey_star(c):
    head(c, 6, "灰阶楔与西门子星",
         "上：16 级灰阶（0-255）；下：36 楔径向频率扫掠。")
    C.T(c, MARGIN, 254.0, "灰阶楔（16 级，0-255）", size=3.7)
    C.T(c, MARGIN + 78.0, 254.0, "打印机不是线性的，数字只是理想灰度值。",
        size=2.75, gray=0.35)
    C.shade_wedge(c, MARGIN, 205.0, 190.0, 45.0)
    C.T(c, 105.0, 193.0, "西门子星（36 楔）", size=3.7, align="c")
    C.wedges(c, 105.0, 108.0, 82.0, n=36)
    C.T(c, MARGIN, 18.0, "中心清晰、边缘糊成一片：越靠外，同一角度里的条纹越密。",
        size=2.9, gray=0.35)
    foot(c, "第 6 页：灰阶 + 星")


def gratings_page(c):
    head(c, 7, "条纹光栅（周期 2-12 mm）",
         "六列垂直条纹，周期从左到右变大；最左那列最细。")
    C.T(c, MARGIN, 244.0, "垂直条纹，周期 2 / 3 / 4 / 6 / 8 / 12 mm", size=3.7)
    C.gratings(c, MARGIN, 90.0, 190.0, 150.0, [2, 3, 4, 6, 8, 12])
    C.T(c, MARGIN, 75.0, "怎么读", size=3.9)
    for i, s in enumerate([
            "1. 让这一页占满画面，六列条纹应该都能出边（密集的竖线）。",
            "2. 慢慢后退：p=2 mm 那列最先糊成一片、甚至整列消失，然后轮到 p=3 mm。",
            "3. 这个「最先消失」的顺序就是中值滤波 + 高斯 + 阈值的综合截止频率，比单看棋盘格更直观。"]):
        C.T(c, MARGIN, 65.0 - i * 8.0, s, size=3.2, gray=0.15)
    foot(c, "第 7 页：条纹光栅")


def build(path, clean=False):
    c = canvas.Canvas(path, pagesize=A4)
    c.setTitle("Edge-detection demo chart, spread layout (A4, 100%)")
    c.setAuthor("imx219_team")
    c.setSubject("Printable targets, one or two patterns per page")
    saved = C.T
    if clean:
        # the dense chart draws every glyph through T, and so does every page
        # here; this filter keeps the target glyphs and drops every caption
        C.T = C.T_targets_only(saved)
    try:
        for fn in (cover, board9, shapes, digits, face_page, grey_star, gratings_page):
            fn(c)
            c.showPage()
    finally:
        C.T = saved
    c.save()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    ap.add_argument("--png", default=None)
    ap.add_argument("--dpi", type=int, default=120)
    ap.add_argument("--clean", action="store_true",
                    help="patterns only: no titles, captions, notes or page numbers")
    a = ap.parse_args()
    if a.out is None:
        a.out = os.path.join("outputs", "edge_detect_demo_chart_spread%s_A4.pdf"
                             % ("_clean" if a.clean else ""))
    if a.png is None:
        a.png = os.path.join("work", "preview_spread_clean" if a.clean
                             else "preview_spread")
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    build(a.out, clean=a.clean)
    print("wrote %s (%d bytes, font=%s)" % (a.out, os.path.getsize(a.out), C.FONT))
    print("preview: %s" % ", ".join(C.render(a.out, a.png, a.dpi)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
