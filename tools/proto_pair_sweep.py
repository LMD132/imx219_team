#!/usr/bin/env python3
"""Sweep the weak/strong threshold pair on real captured frames.

Why this and not the adaptive term: in edge_display_720p.v

    active_threshold = max(local_mean >> shift, floor)      (only ever raises)
    strong_threshold = 2 * active_threshold                 (fixed ratio)

so a dark region can never get a threshold below the floor, and its strong
seeds sit at twice that. Hysteresis keeps a weak pixel only when a strong one
is adjacent, so if a dim scene produces hardly any pixel above 2*floor the
whole contour is dropped - which is what "the picture is black, the outline is
missing" looks like. The lever is the floor / strong pair, not the adaptive
base.

The grey half of an on-board capture is the picture the board feeds to Sobel
(tone curve already applied), so this reproduces the board faithfully on that
half of the view. Verified: on ab3_b1 the offline rule reports 15.9 % lit and
the board's own capture measures 16.2 %.

    python tools/proto_pair_sweep.py --dirs work/capture/diag_daylight \
        work/capture/ab3_b1
"""

from __future__ import annotations

import argparse
import glob
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from proto_edge_enhance import despeckle, gray_from_capture, stats  # noqa: E402


def fields(gray: np.ndarray):
    f = gray.astype(np.int32)
    gx = (f[0:-2, 2:] + 2 * f[1:-1, 2:] + f[2:, 2:]) \
        - (f[0:-2, 0:-2] + 2 * f[1:-1, 0:-2] + f[2:, 0:-2])
    gy = (f[2:, 0:-2] + 2 * f[2:, 1:-1] + f[2:, 2:]) \
        - (f[0:-2, 0:-2] + 2 * f[0:-2, 1:-1] + f[0:-2, 2:])
    mag = np.abs(gx) + np.abs(gy)
    mean = cv2.blur(gray.astype(np.float32), (3, 3),
                    borderType=cv2.BORDER_REPLICATE)[0:-2, 0:-2]
    return mag.astype(np.int32), mean.astype(np.int32), gray[2:, 2:]


def apply(mag, mean, src, floor, shift, ratio, ds):
    active = np.maximum(mean >> shift, floor)
    weak = (mag >= active).astype(np.uint8)
    strong = (mag >= active * ratio).astype(np.uint8)
    b = (weak & (cv2.dilate(strong, np.ones((3, 3), np.uint8)) > 0)).astype(np.uint8)
    return despeckle(b, ds)


def score(b, mag, src):
    st = stats(b)
    dark = src < 48
    # A lit pixel can never sit in a "flat" window: the threshold floor alone is
    # >= 8, so |grad| < 8 can never fire. The usable garbage proxy is the share
    # of lit pixels that live in tiny (<= 3 px) components.
    n, _, cs, _ = cv2.connectedComponentsWithStats(b.astype(np.uint8), 8)
    areas = [int(cs[i][4]) for i in range(1, n)]
    lit = max(int(b.sum()), 1)
    tiny_pix = 100.0 * sum(a for a in areas if a <= 3) / lit
    return dict(lit=st["lit"], chain=st["chain_pix"],
                dark=(100.0 * b[dark].mean() if dark.any() else 0.0),
                tiny=tiny_pix, blob=st["blob"])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dirs", nargs="+", required=True)
    ap.add_argument("--ds", type=int, default=3)
    ap.add_argument("--visual", action="store_true",
                    help="also write a side-by-side sheet of the preset pairs")
    ap.add_argument("--frame", default=None, help="frame for --visual")
    ap.add_argument("--out", default="work/analysis/pair")
    args = ap.parse_args()

    combos = []
    for floor in (12, 16, 20):
        for shift in (0, 1, 2, 3, 8):
            combos.append((floor, shift, 2.0))

    cache = {}
    for d in args.dirs:
        for p in sorted(glob.glob(os.path.join(d, "frame_*.png")))[:6]:
            img = cv2.imread(p)
            if img is not None:
                cache[os.path.normpath(p)] = fields(gray_from_capture(img))

    if args.visual:
        p = os.path.normpath(args.frame) if args.frame else sorted(cache)[0]
        img = cv2.imread(p)
        gray = gray_from_capture(img)
        mag, mean, src = cache[p]
        panels = []
        base = None
        for floor, shift, ratio in ((24, 8, 2.0), (16, 8, 2.0), (16, 2, 2.0),
                                    (12, 2, 2.0)):
            b = apply(mag, mean, src, floor, shift, ratio, args.ds)
            if base is None:
                base = b
            v = cv2.cvtColor(src.astype(np.uint8), cv2.COLOR_GRAY2BGR)
            v[b > 0] = (0, 255, 0)
            new = (b > 0) & (base == 0)
            v[new] = (0, 128, 255)  # pixels this setting adds, in orange
            cv2.rectangle(v, (0, 0), (v.shape[1], 22), (0, 0, 0), -1)
            cv2.putText(v, "T%d S%d x%.1f  lit %.1f%%  dark %.1f%%  +%d px vs T24"
                        % (floor, shift, ratio, 100.0 * b.mean(),
                           100.0 * b[src < 48].mean(), int(new.sum())),
                        (5, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (255, 255, 255), 1)
            panels.append(v)
        sheet = np.hstack(panels)
        os.makedirs(args.out, exist_ok=True)
        out = os.path.join(args.out, "pair_" + os.path.basename(os.path.dirname(p)) + ".png")
        cv2.imwrite(out, sheet)
        print("visual:", out)

    dark_share = float(np.mean([100.0 * (src < 48).mean() for _, _, src in cache.values()]))
    print("ds=%d, %d frames; dark = source < 48 (%.0f%% of the grey half); "
          "tiny%% = lit pixels in components <= 3 px"
          % (args.ds, len(cache), dark_share))
    print("%-18s %6s %6s %6s %6s %6s" % ("floor/shift/ratio", "lit%", "dark%",
                                         "tiny%", "chain%", "blobs"))
    rows = []
    for floor, shift, ratio in combos:
        acc = []
        for mag, mean, src in cache.values():
            acc.append(score(apply(mag, mean, src, floor, shift, ratio, args.ds),
                             mag, src))
        m = {k: float(np.mean([a[k] for a in acc])) for k in acc[0]}
        rows.append((floor, shift, ratio, m))

    # sort by dark contours recovered per unit of tiny-component litter
    rows.sort(key=lambda r: -(r[3]["dark"] / max(r[3]["tiny"], 0.05)))
    for floor, shift, ratio, m in rows:
        print("%-18s %6.2f %6.2f %6.2f %6.0f %6.0f"
              % ("T%d S%d x%.1f" % (floor, shift, ratio), m["lit"], m["dark"],
                 m["tiny"], m["chain"], m["blob"]))


if __name__ == "__main__":
    main()
