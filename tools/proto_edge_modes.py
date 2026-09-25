#!/usr/bin/env python3
"""离线对比"我们现在的 Sobel"和"参照工程 Sobeledge_8d 的做法"。

参照工程（B 站 BV1tg6BERZ 源码 zip，work/ref_src）里的核心两行：
    Gmax = max(G0, G45, G90, G135)                      // 4 个方向算子取最大
    edge = (Gmax >= center)                             // 阈值就是中心像素自己的灰度
我们现在的 rtl/edge_display_720p.v 是：
    mag  = |Gx| + |Gy|
    thr  = max(floor, center >> shift)
    edge = (mag >= thr)

本脚本用**我们自己的实拍灰度图**（采集卡抓的帧，左半是灰度）跑三种模式，
把"碎斑/连续性/暗区轮廓"的差别量化出来，改 RTL 之前先看效果。

用法：
  python tools/proto_edge_modes.py --frame work/capture/flick_ab/frame_00.png \
      --out work/analysis/proto
"""

import argparse
import os
import sys

import cv2
import numpy as np


def gray_from_capture(img):
    """采集卡画面：左半是灰度视图，取左半当灰度输入。"""
    h, w = img.shape[:2]
    left = img[:, : w // 2]
    if left.ndim == 3:
        left = cv2.cvtColor(left, cv2.COLOR_BGR2GRAY)
    return left


def sobel_xy(g):
    """我们的做法：Gx/Gy（3x3 标准 Sobel），返回 |Gx|+|Gy|。"""
    f = g.astype(np.int16)
    # 3x3 窗口 p11..p33
    p11 = f[0:-2, 0:-2]; p12 = f[0:-2, 1:-1]; p13 = f[0:-2, 2:]
    p21 = f[1:-1, 0:-2]; p22 = f[1:-1, 1:-1]; p23 = f[1:-1, 2:]
    p31 = f[2:, 0:-2];   p32 = f[2:, 1:-1];   p33 = f[2:, 2:]
    gx = (p13 + 2 * p23 + p33) - (p11 + 2 * p21 + p31)
    gy = (p31 + 2 * p32 + p33) - (p11 + 2 * p12 + p13)
    return np.abs(gx) + np.abs(gy), p22


def sobel_4d(g):
    """参照工程做法：4 个方向算子，取最大，返回 Gmax 和中心像素。"""
    f = g.astype(np.int16)
    p11 = f[0:-2, 0:-2]; p12 = f[0:-2, 1:-1]; p13 = f[0:-2, 2:]
    p21 = f[1:-1, 0:-2]; p22 = f[1:-1, 1:-1]; p23 = f[1:-1, 2:]
    p31 = f[2:, 0:-2];   p32 = f[2:, 1:-1];   p33 = f[2:, 2:]
    g0 = np.abs((p11 + 2 * p12 + p13) - (p31 + 2 * p32 + p33))    # 0°
    g45 = np.abs((p23 + 2 * p33 + p32) - (p12 + 2 * p11 + p21))    # 45°
    g90 = np.abs((p13 + 2 * p23 + p33) - (p11 + 2 * p21 + p31))    # 90°
    g135 = np.abs((p12 + 2 * p13 + p23) - (p21 + 2 * p31 + p32))   # 135°
    gmax = np.maximum(np.maximum(g0, g45), np.maximum(g90, g135))
    return gmax, p22


def despeckle(b, min_nbr):
    """参照 7903df0 的 1bit 去碎斑：中心为 1 且 8 邻域里 >= min_nbr 个 1 才保留。"""
    if min_nbr <= 0:
        return b
    u = b.astype(np.uint8)
    # 8 邻域求和（含中心）
    k = np.ones((3, 3), np.uint8)
    cnt = cv2.filter2D(u, -1, k, borderType=cv2.BORDER_REPLICATE) - u
    return ((u > 0) & (cnt >= min_nbr)).astype(np.uint8)


def stats(b):
    n, _, st, _ = cv2.connectedComponentsWithStats(b.astype(np.uint8), 8)
    areas = [st[i][4] for i in range(1, n)]
    tiny = sum(1 for a in areas if a <= 3)
    lit = int(b.sum())
    return dict(lit_pct=100.0 * b.mean(), nblob=n - 1, tiny=tiny,
                tiny_pct=100.0 * sum(a for a in areas if a <= 3) / max(lit, 1),
                med_area=(np.median(areas) if areas else 0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frame", default="work/capture/flick_ab/frame_00.png")
    ap.add_argument("--out", default="work/analysis/proto")
    ap.add_argument("--floor", type=int, default=16, help="我们现在的固定阈值下限")
    ap.add_argument("--shift", type=int, default=1, help="center >> shift 的自适应项")
    ap.add_argument("--despeckle", type=int, default=3, help=">=N 个邻居才保留（0=关）")
    ap.add_argument("--median", type=int, default=3, help="前置中值滤波核（1=关）")
    ap.add_argument("--crop", default=None, help="可选 x,y,w,h，只看局部")
    ap.add_argument("--sweep", action="store_true",
                    help="在同一帧上扫 shift x floor 全组合，并按源亮度分区看灵敏度")
    args = ap.parse_args()

    img = cv2.imread(args.frame)
    if img is None:
        raise SystemExit("读不到图像: " + args.frame)
    g = gray_from_capture(img)
    if args.crop:
        x, y, w, h = (int(v) for v in args.crop.split(","))
        g = g[y:y + h, x:x + w]
    os.makedirs(args.out, exist_ok=True)
    if args.median > 1:
        gs = cv2.medianBlur(g, args.median)
    else:
        gs = g

    if args.sweep:
        mag, c = sobel_xy(gs)
        dark_m = c < 48
        mid_m = (c >= 48) & (c < 160)
        brt_m = c >= 160
        print(f"输入灰度 mean={gs.mean():.1f}   "
              f"分区像素占比 暗(<48)={100 * dark_m.mean():5.1f}%  "
              f"中={100 * mid_m.mean():5.1f}%  亮(>=160)={100 * brt_m.mean():5.1f}%")
        print(f"despeckle>={args.despeckle}   "
              f"{'S':>2s} {'T':>3s} {'总dens%':>7s} {'暗dens%':>7s} {'中dens%':>7s} "
              f"{'亮dens%':>7s} {'comps':>6s} {'碎斑':>5s} {'最大域':>7s}")
        for shift in (0, 1, 2, 3):
            for floor in (0, 8, 16, 24, 32, 48, 64):
                thr = np.maximum(floor, c >> shift)
                b = despeckle((mag >= thr).astype(np.uint8), args.despeckle)
                st = stats(b)
                dd = 100.0 * b[dark_m].mean()
                dm = 100.0 * b[mid_m].mean()
                db = 100.0 * b[brt_m].mean()
                print(f"{shift:2d} {floor:3d} {st['lit_pct']:7.2f} {dd:7.2f} {dm:7.2f} "
                      f"{db:7.2f} {st['nblob']:6d} {st['tiny']:5d} {st['med_area']:7.0f}")
        return

    modes = {}
    # A. 我们现在的：|Gx|+|Gy| + max(floor, center>>shift)
    mag, c = sobel_xy(gs)
    modes["A_xy_floor+sh"] = (mag >= np.maximum(args.floor, c >> args.shift)).astype(np.uint8)
    # A2. 同样算子，换上参照的阈值规则（center 不右移）
    modes["A2_xy_floor+ctr"] = (mag >= np.maximum(args.floor, c)).astype(np.uint8)
    # B. 参照算子 + 和我们一样的阈值规则（隔离"算子"这一个变量）
    gmax, c4 = sobel_4d(gs)
    modes["B_4dir_floor+sh"] = (gmax >= np.maximum(args.floor, c4 >> args.shift)).astype(np.uint8)
    # C. 参照的阈值规则（阈值 = 中心像素，无下限）
    modes["C_4dir>=ctr_raw"] = (gmax >= c4).astype(np.uint8)
    # D. 参照规则 + 下限，再加去碎斑
    modes["D_C+floor+despk"] = despeckle(modes["B_4dir_floor+sh"], args.despeckle)
    # E. 我们现在的 + 去碎斑
    modes["E_A+despk"] = despeckle(modes["A_xy_floor+sh"], args.despeckle)

    gm, gsd = gs.mean(), gs.std()
    hist = np.histogram(gs, bins=8, range=(0, 256))[0]
    print(f"输入灰度 {g.shape}  mean={gm:.1f} std={gsd:.1f} "
          f"8档直方图={hist.tolist()}")
    print(f"中值={args.median}  floor={args.floor} "
          f"shift={args.shift}  despeckle>={args.despeckle}")
    print(f"{'模式':24s} {'lit%':>6s} {'连通域':>7s} {'碎斑<=3px':>9s} {'碎斑像素%':>9s} {'中位面积':>8s}")
    panels = []
    for name, b in modes.items():
        s = stats(b)
        print(f"{name:24s} {s['lit_pct']:6.2f} {s['nblob']:7d} {s['tiny']:9d} "
              f"{s['tiny_pct']:9.2f} {s['med_area']:8.0f}")
        vis = np.zeros((b.shape[0], b.shape[1], 3), np.uint8)
        vis[b > 0] = (255, 255, 255)
        cv2.putText(vis, name.split("_")[0] + " " + name.split("_", 1)[1][:12],
                    (8, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)
        panels.append(vis)

    # 拼图：上排 A A2 B，下排 C D E，右下角放原灰度（裁到和算子输出同尺寸）
    ph, pw = panels[0].shape[:2]
    g_center = gs[1:1 + ph, 1:1 + pw]
    gray3 = cv2.cvtColor(g_center, cv2.COLOR_GRAY2BGR)
    cv2.putText(gray3, "gray input", (8, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                (0, 0, 255), 2)
    while len(panels) < 6:
        panels.append(np.zeros_like(panels[0]))
    panels = [p[:ph, :pw] for p in panels]
    panels[5] = gray3
    row1 = np.hstack(panels[0:3])
    row2 = np.hstack(panels[3:6])
    sheet = np.vstack([row1, row2])
    out_png = os.path.join(args.out, "proto_compare.png")
    cv2.imwrite(out_png, sheet)
    print("拼图:", out_png)


if __name__ == "__main__":
    main()
