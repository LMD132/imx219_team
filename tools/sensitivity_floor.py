#!/usr/bin/env python3
"""How small a source contrast can the board still turn into an edge?

This answers the holder's standard: "if you reach the reference video's level,
any object you point at should come out, no chessboard needed."  That standard
is measurable without choosing a scene, because it is a property of the
algorithm, not of the object:

    detection floor  = the smallest source contrast (in 8-bit LSB) that still
                       gets drawn, at 50% / 90% probability
    noise floor      = the source contrast that appears in FLAT areas anyway,
                       i.e. what the sensor+sensor-readout hands us for free

If floor ~= noise floor we are at the sensor limit and no algorithm can do
better on that scene.  If floor >> noise floor, the remaining gap is pure
algorithm headroom - that is the part we can still win.

Contrast axis is measured on the RAW gray (curve bypassed, UART `C0`), so the
number is comparable between settings and between scenes.  Detection itself is
simulated with the board's exact rule (same curve LUT, same Sobel |Gx|+|Gy|,
same lo/hi hysteresis, same 3x3 despeckle) applied to the board's own gray.

Caveat: the gray half only carries columns 0..639 of the camera image, and the
edge half carries columns 640..1279, so this cannot be cross-checked against
the board's own right half in the same frame.  Same per-pixel maths, different
crop.  The curve LUT is bit-exact (see work/_lutcheck.py for the 1-LSB check).

Usage:
    python tools/sensitivity_floor.py --frame work/capture/raw_gray/frame_00.png \
        --out work/analysis/sens
"""

import argparse
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from proto_edge_enhance import despeckle, gray_from_capture, sobel_xy
from proto_curve_sweep import CURVES

BANDS = [("dark  <48", lambda c: c < 48),
         ("mid 48..159", lambda c: (c >= 48) & (c < 160)),
         ("bright >=160", lambda c: c >= 160)]


def board_edges(g, curve, lo, hi, ds):
    src = CURVES[curve][g]
    mag, c = sobel_xy(src)
    weak = (mag >= lo).astype(np.uint8)
    strong = (mag >= hi).astype(np.uint8)
    nbr = cv2.dilate(strong, np.ones((3, 3), np.uint8))
    return despeckle((weak & (nbr > 0)).astype(np.uint8), ds)


def floor_at(rate_curve, target):
    hit = np.nonzero(np.asarray(rate_curve) >= target)[0]
    return int(hit[0]) if len(hit) else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frame", required=True)
    ap.add_argument("--out", default="work/analysis/sens")
    ap.add_argument("--curve", default="bst2k64")
    ap.add_argument("--floor", type=int, default=24)
    ap.add_argument("--hi", type=int, default=48)
    ap.add_argument("--despeckle", type=int, default=3)
    ap.add_argument("--max-contrast", type=int, default=48)
    args = ap.parse_args()

    img = cv2.imread(args.frame)
    if img is None:
        raise SystemExit("cannot read " + args.frame)
    g = gray_from_capture(img)
    s_raw, c_raw = sobel_xy(g)
    b = board_edges(g, args.curve, args.floor, args.hi, args.despeckle)

    k = np.ones((3, 3), np.uint8)
    local_range = cv2.dilate(g, k).astype(np.int16) - cv2.erode(g, k).astype(np.int16)
    flat = local_range <= 2

    print("frame %s  curve=%s lo=%d hi=%d ds=%d" % (args.frame, args.curve,
                                                    args.floor, args.hi, args.despeckle))
    print("gray mean=%.1f  lit%%=%.2f  flat%%=%.1f"
          % (g.mean(), 100 * b.mean(), 100 * flat.mean()))
    print()
    print("%-13s %8s %8s %8s %8s %8s" %
          ("luma band", "px%", "floor50", "floor90", "noise95", "gap"))
    dark_s = None
    for name, sel in BANDS:
        m = sel(c_raw)
        if m.sum() < 500:
            print("%-13s  (band too small: %d px)" % (name, m.sum()))
            continue
        s = s_raw[m]
        bb = b[m]
        curve = np.array([bb[s >= t].mean() if (s >= t).sum() else 0.0
                          for t in range(args.max_contrast + 1)])
        f50, f90 = floor_at(curve, 0.50), floor_at(curve, 0.90)
        fm = m & flat
        noise = float(np.percentile(s_raw[fm], 95)) if fm.sum() > 200 else float("nan")
        gap = (f50 - noise) if (f50 is not None and noise == noise) else float("nan")
        print("%-13s %7.1f%% %8s %8s %8.1f %8.1f"
              % (name, 100 * m.mean(), f50, f90, noise, gap))
        if name.startswith("dark"):
            dark_s = s

    # how much of the picture sits between the noise floor and the current floor
    fm = BANDS[0][1](c_raw) & flat
    noise = np.percentile(s_raw[fm], 95)
    if dark_s is None:
        print("暗区太小，跳过可抢细节统计")
    else:
        interval = ((dark_s >= noise) & (dark_s < args.floor)).mean()
        print()
        print("暗区里'高于噪声底(%.1f)但低于当前下限(%d)'的像素占比 = %.1f%%  <- 还能抢的细节量"
              % (noise, args.floor, 100 * interval))

    os.makedirs(args.out, exist_ok=True)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(8, 5))
    for name, sel in BANDS:
        m = sel(c_raw)
        if m.sum() < 500:
            continue
        s, bb = s_raw[m], b[m]
        ys = [bb[s >= t].mean() if (s >= t).sum() else 0.0
              for t in range(args.max_contrast + 1)]
        ax.plot(range(args.max_contrast + 1), ys, label=name)
    ax.set_xlabel("raw source Sobel contrast |Gx|+|Gy|  (8-bit LSB)")
    ax.set_ylabel("P(drawn as edge)")
    ax.set_title("detection floor vs source contrast  (%s, lo=%d hi=%d)" %
                 (args.curve, args.floor, args.hi))
    ax.grid(alpha=.3)
    ax.legend()
    p = os.path.join(args.out, "detection_floor.png")
    fig.tight_layout()
    fig.savefig(p, dpi=110)
    print("plot:", p)


if __name__ == "__main__":
    main()
