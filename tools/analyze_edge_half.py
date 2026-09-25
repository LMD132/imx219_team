#!/usr/bin/env python3
"""Measure the binary edge map that is actually on the board's right half.

The offline tools in this directory simulate a pipeline on a captured gray frame.
This one instead reads the edge map straight off the HDMI capture, so it measures
what the board really draws - tone curve and hysteresis included.

Layout of a captured 1280x720 frame (rtl/edge_display_720p.v):
    x = 0..639    gray view (whatever feeds in_r/in_g/in_b)
    x = 640       white separator column
    x = 641..1279 binary edge map  <- what this script measures
The target box drawn by edge_overlay_720p.v is red, so requiring all three
channels to be high keeps it out of the binary map.

Usage:
    python tools/analyze_edge_half.py --a work/capture/old --b work/capture/new \
        --out work/analysis/ab
"""

import argparse
import glob
import os

import cv2
import numpy as np

SPLIT = 640            # separator column
BANDS = ((0, 200), (200, 420), (420, 720))


def edge_map(img):
    b, g, r = img[:, :, 0].astype(np.int16), img[:, :, 1].astype(np.int16), img[:, :, 2].astype(np.int16)
    white = (b > 64) & (g > 64) & (r > 64)
    return white[:, SPLIT + 1:]


def stats(b):
    u = b.astype(np.uint8)
    n, _, st, _ = cv2.connectedComponentsWithStats(u, 8)
    areas = [int(st[i][4]) for i in range(1, n)]
    tiny = sum(1 for a in areas if a <= 3)
    lit = int(b.sum())
    chains = sum(a for a in areas if a >= 40)
    return dict(lit=100.0 * b.mean(), blob=n - 1, tiny=tiny,
                tiny_pix=100.0 * sum(a for a in areas if a <= 3) / max(lit, 1),
                chain=sum(1 for a in areas if a >= 40),
                chain_pix=100.0 * chains / max(lit, 1),
                med=(float(np.median(areas)) if areas else 0.0))


def report(label, frames, out_prefix=None):
    acc = []
    for f in frames:
        img = cv2.imread(f)
        if img is None:
            continue
        acc.append(edge_map(img))
    if not acc:
        print(label, ": no frames")
        return None
    b = np.mean(np.stack(acc), axis=0) > 0.99
    s = stats(b)
    band = [100.0 * b[y0:y1].mean() for y0, y1 in BANDS]
    print("%-14s lit%% %5.2f  暗带%% %5.2f  中带%% %5.2f  上带%% %5.2f  "
          "blob %5d  碎片<=3 %5d (%.1f%% of lit)  长链 %4d (%.0f%% of lit)  中位 %4.1f"
          % (label, s["lit"], band[2], band[1], band[0], s["blob"], s["tiny"],
             s["tiny_pix"], s["chain"], s["chain_pix"], s["med"]))
    if out_prefix:
        vis = np.zeros((b.shape[0], b.shape[1], 3), np.uint8)
        vis[b] = (255, 255, 255)
        cv2.imwrite(out_prefix + "_edge.png", vis)
        cv2.imwrite(out_prefix + "_frame.png", cv2.imread(frames[len(frames) // 2]))
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True, help="capture directory, old configuration")
    ap.add_argument("--b", required=True, help="capture directory, new configuration")
    ap.add_argument("--b2", default=None, help="optional repeat of --b (drift check)")
    ap.add_argument("--out", default="work/analysis/ab")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    print("all figures are for the right half only (x=641..1279, the board's edge map)")
    print("bands: 上 0..200 / 中 200..420 / 下 420..720 of the 720 rows")
    fa = sorted(glob.glob(os.path.join(args.a, "frame_*.png")))
    fb = sorted(glob.glob(os.path.join(args.b, "frame_*.png")))
    print("frames: a=%d b=%d" % (len(fa), len(fb)))
    report("A " + os.path.basename(args.a), fa, os.path.join(args.out, "a"))
    if args.b2:
        f2 = sorted(glob.glob(os.path.join(args.b2, "frame_*.png")))
        report("B'" + os.path.basename(args.b2), f2)
    report("B " + os.path.basename(args.b), fb, os.path.join(args.out, "b"))

    # side by side, mid frame of each
    imgs = []
    for d in (args.a, args.b):
        fl = sorted(glob.glob(os.path.join(d, "frame_*.png")))
        imgs.append(cv2.imread(fl[len(fl) // 2]))
    if all(i is not None for i in imgs):
        sheet = np.vstack([np.hstack(imgs)])
        cv2.putText(sheet, "A " + os.path.basename(args.a), (6, 26),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
        cv2.putText(sheet, "B " + os.path.basename(args.b), (1290, 26),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
        p = os.path.join(args.out, "ab_frames.png")
        cv2.imwrite(p, sheet)
        print("sheet:", p)


if __name__ == "__main__":
    main()