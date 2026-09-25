#!/usr/bin/env python3
"""Offline A/B of the fixes for "dark areas lose their contours".

Problem measured on the on-board capture work/capture/back_t24: the scene is
mostly very dark (about 60% of the pixels are below 48/255) and the contour of
the instruments/person is *broken* -- the gradient is under the threshold along
whole segments, so the line disappears.

Candidates tested here, all of them derivable from public FPGA sources:

  HYS  local hysteresis, after DOUDIU/Hardware-Implementation-of-the-Canny-
       Edge-Detection-Algorithm (work/ref_gh/doudiu, canny_doubleThreshold.v):
       strong = mag >= TH_high, weak = mag >= TH_low (TH_low < TH_high)
       out    = weak && (some pixel of the 3x3 window is strong)
       Everything is a pure 3x3 combination, no cross-line propagation.

  GAM  dark-region contrast boost (gamma < 1) applied to the 8-bit gray before
       the Sobel. A gamma curve is a 256x8 ROM in RTL.  See the histogram
       equalisation module of the reference project (work/ref_src) for the same
       idea taken further.

  T/D  plain "lower the noise floor" / "relax the despeckle" references.

Usage:
  python tools/proto_edge_enhance.py --frame work/capture/back_t24/frame_00.png \
      --out work/analysis/proto/back_t24_enh
"""

import argparse
import os

import cv2
import numpy as np


def gray_from_capture(img):
    h, w = img.shape[:2]
    left = img[:, : w // 2]
    if left.ndim == 3:
        left = cv2.cvtColor(left, cv2.COLOR_BGR2GRAY)
    return left


def sobel_xy(g):
    f = g.astype(np.int16)
    p11 = f[0:-2, 0:-2]; p12 = f[0:-2, 1:-1]; p13 = f[0:-2, 2:]
    p21 = f[1:-1, 0:-2]; p22 = f[1:-1, 1:-1]; p23 = f[1:-1, 2:]
    p31 = f[2:, 0:-2]; p32 = f[2:, 1:-1]; p33 = f[2:, 2:]
    gx = (p13 + 2 * p23 + p33) - (p11 + 2 * p21 + p31)
    gy = (p31 + 2 * p32 + p33) - (p11 + 2 * p12 + p13)
    return (np.abs(gx) + np.abs(gy)).astype(np.int32), p22.astype(np.int32)


def gamma_table(gamma):
    x = np.arange(256, dtype=np.float32) / 255.0
    return np.clip(255.0 * np.power(x, gamma), 0, 255).astype(np.uint8)


def despeckle(b, min_nbr):
    if min_nbr <= 0:
        return b
    u = b.astype(np.uint8)
    cnt = cv2.filter2D(u, -1, np.ones((3, 3), np.uint8),
                      borderType=cv2.BORDER_REPLICATE) - u
    return ((u > 0) & (cnt >= min_nbr)).astype(np.uint8)


def stats(b):
    n, _, st, _ = cv2.connectedComponentsWithStats(b.astype(np.uint8), 8)
    areas = [int(st[i][4]) for i in range(1, n)]
    tiny = sum(1 for a in areas if a <= 3)
    chains = [a for a in areas if a >= 40]
    lit = int(b.sum())
    return dict(lit=100.0 * b.mean(), blob=n - 1, tiny=tiny,
                chain=len(chains), chain_pix=100.0 * sum(chains) / max(lit, 1),
                med=(np.median(areas) if areas else 0))


def edge_rule(g, floor, shift, ds, gamma=1.0, hi_floor=None, hi_shift=None):
    src = gamma_table(gamma)[g] if gamma != 1.0 else g
    mag, c = sobel_xy(src)
    lo = np.maximum(floor, c >> shift)
    weak = mag >= lo
    if hi_floor is None:
        b = weak.astype(np.uint8)
    else:
        hi = np.maximum(hi_floor, c >> hi_shift)
        strong = (mag >= hi).astype(np.uint8)
        nbr = cv2.dilate(strong, np.ones((3, 3), np.uint8))
        b = (weak & (nbr > 0)).astype(np.uint8)
    return despeckle(b, ds)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frame", default="work/capture/back_t24/frame_00.png")
    ap.add_argument("--out", default="work/analysis/proto/enh")
    ap.add_argument("--floor", type=int, default=24)
    ap.add_argument("--shift", type=int, default=2)
    ap.add_argument("--hi-floor", type=int, default=40)
    ap.add_argument("--hi-shift", type=int, default=2)
    ap.add_argument("--despeckle", type=int, default=3)
    args = ap.parse_args()

    img = cv2.imread(args.frame)
    if img is None:
        raise SystemExit("cannot read " + args.frame)
    g = gray_from_capture(img)
    os.makedirs(args.out, exist_ok=True)

    _, c0 = sobel_xy(g)
    dark = c0 < 48
    mid = (c0 >= 48) & (c0 < 160)
    brt = c0 >= 160
    print("gray mean=%.1f std=%.1f  dark(<48)=%.1f%% mid=%.1f%% bright=%.1f%%"
          % (g.mean(), g.std(), 100 * dark.mean(), 100 * mid.mean(),
             100 * brt.mean()))
    print("floor=%d shift=%d despeckle>=%d hyst hi=floor%d shift%d"
          % (args.floor, args.shift, args.despeckle, args.hi_floor,
             args.hi_shift))

    F, S, D = args.floor, args.shift, args.despeckle
    HF, HS = args.hi_floor, args.hi_shift
    modes = [
        ("0_base_T%dS%dD%d" % (F, S, D), edge_rule(g, F, S, D)),
        ("1_floor12", edge_rule(g, 12, S, D)),
        ("2_floor8", edge_rule(g, 8, S, D)),
        ("3_nodspk", edge_rule(g, F, S, 0)),
        ("4_gam0.5_T%d" % F, edge_rule(g, F, S, D, gamma=0.5)),
        ("5_gam0.5_floor8", edge_rule(g, 8, S, D, gamma=0.5)),
        ("6_hys_lo%d_hi%d" % (F, HF),
         edge_rule(g, F, S, D, hi_floor=HF, hi_shift=HS)),
        ("7_hys_lo8_hi%d" % HF, edge_rule(g, 8, S, D, hi_floor=HF, hi_shift=HS)),
        ("8_gam0.5_hys_lo8", edge_rule(g, 8, S, D, gamma=0.5,
                                       hi_floor=HF, hi_shift=HS)),
    ]

    print("%-22s %6s %6s %7s %7s %7s %7s %6s %7s %8s"
          % ("mode", "lit%", "dark%", "mid%", "brt%", "blob", "tiny",
             "chain", "chnpx%", "medarea"))
    panels = []
    for name, b in modes:
        s = stats(b)
        print("%-22s %6.2f %6.2f %6.2f %6.2f %7d %6d %7d %7.1f %8.0f"
              % (name, s["lit"], 100.0 * b[dark].mean(), 100.0 * b[mid].mean(),
                 100.0 * b[brt].mean(), s["blob"], s["tiny"], s["chain"],
                 s["chain_pix"], s["med"]))
        vis = np.zeros((b.shape[0], b.shape[1], 3), np.uint8)
        vis[b > 0] = (255, 255, 255)
        cv2.putText(vis, name, (6, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                    (0, 0, 255), 2)
        panels.append(vis)
        cv2.imwrite(os.path.join(args.out, name + ".png"), vis)

    ph, pw = panels[0].shape[:2]
    gray3 = cv2.cvtColor(g[1:1 + ph, 1:1 + pw], cv2.COLOR_GRAY2BGR)
    cv2.putText(gray3, "gray input", (6, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                (0, 0, 255), 2)
    out_png = os.path.join(args.out, "enh_compare.png")
    while len(panels) % 3:
        panels.append(np.zeros_like(panels[0]))
    rows = [np.hstack(panels[i:i + 3]) for i in range(0, len(panels), 3)]
    rows[-1] = np.hstack([gray3, rows[-1][:, pw:]])
    cv2.imwrite(out_png, np.vstack(rows))
    print("sheet:", out_png)


if __name__ == "__main__":
    main()