#!/usr/bin/env python3
"""Sweep the dark-boost tone curve that feeds the Sobel, with local hysteresis.

Motivation: on the on-board captures ~87% of the frame is darker than 48/255 and
the object contours are broken.  Boosting the dark part of the tone curve before
the Sobel is the cheapest fix (one 256x8 ROM in RTL), but a plain gain also
amplifies the sensor noise of the dark areas, which floods the display.

Metrics used to separate signal from noise:
  noise%  edge density inside "dark AND flat" pixels (source gradient < 8).
          Anything lit here is amplified noise.
  weak%   edge density inside "dark AND weak gradient" pixels (8..24).
          These are the low-contrast contour pixels we want back.
  brt%    edge density in the bright pixels (>=160), to check that the highlight
          compression does not eat the window / instrument edges.
  chain%  share of lit pixels inside connected components >= 40 px.

Usage:
  python tools/proto_curve_sweep.py --frame work/capture/back_t24/frame_00.png \
      --out work/analysis/proto/curve_sweep
"""

import argparse
import os

import cv2
import numpy as np

from proto_edge_enhance import (despeckle, gray_from_capture, sobel_xy, stats)


def gamma_curve(gamma):
    x = np.arange(256, dtype=np.float32) / 255.0
    return np.clip(255.0 * np.power(x, gamma), 0, 255).astype(np.uint8)


def boost_curve(gain, knee):
    """g<knee -> gain*g, then one straight segment to (255,255)."""
    g = np.arange(256, dtype=np.float32)
    y = np.where(g < knee, g * gain,
                 knee * gain + (g - knee) * (255.0 - knee * gain) /
                 max(255.0 - knee, 1.0))
    return np.clip(y, 0, 255).astype(np.uint8)


def boost3_curve(gain, knee, knee2):
    """Two dark segments, then a gentle highlight compression:
    g<knee -> gain*g ; knee..knee2 -> slope 1 ; above knee2 -> slope to 255.
    Mid tones keep full contrast, only the highlights are squeezed."""
    g = np.arange(256, dtype=np.float32)
    y1 = knee * gain
    y2 = y1 + (knee2 - knee)
    slope = (255.0 - y2) / max(255.0 - knee2, 1.0) if y2 < 255.0 else 0.0
    y = np.where(g < knee, g * gain,
                 np.where(g < knee2, y1 + (g - knee), y2 + (g - knee2) * slope))
    return np.clip(y, 0, 255).astype(np.uint8)


CURVES = {
    "ident": np.arange(256, dtype=np.uint8),
    "gam0.70": gamma_curve(0.70),
    "gam0.55": gamma_curve(0.55),
    "bst2k64": boost_curve(2.0, 64),
    "bst2k96": boost_curve(2.0, 96),
    "bst2k128": boost_curve(2.0, 128),
    "b3_2x64to128": boost3_curve(2.0, 64, 128),
    "b3_2x96to160": boost3_curve(2.0, 96, 160),
    "b3_1p5x96to160": boost3_curve(1.5, 96, 160),
    "b3_2p5x64to128": boost3_curve(2.5, 64, 128),
}


def sweep_thresholds(g, curve, args):
    """After the tone curve the dark part is amplified, so the old floor no
    longer means the same thing.  Sweep (shift, floor) again on the boosted
    gray, exactly like proto_edge_modes.py --sweep does on the raw gray."""
    mag0, c0 = sobel_xy(g)
    dark = c0 < 48
    brt = c0 >= 160
    m_noise = dark & (mag0 < 8)
    m_weak = dark & (mag0 >= 8) & (mag0 < 24)
    src = CURVES[curve][g]
    mag, c = sobel_xy(src)
    hdr = ("%-10s %4s %4s %6s %6s %6s %6s %6s %6s %6s %6s %7s %8s"
           % ("curve", "S", "T", "lit%", "dark%", "noise%", "weak%", "brt%",
              "blob", "tiny", "chain", "chnpx%", "med"))
    print("curve=" + curve + "  gray mean=%.1f  dark=%.1f%%  dark&flat=%.1f%%"
          % (src.mean(), 100 * dark.mean(), 100 * m_noise.mean()))
    print(hdr)
    panels = []
    for shift in (8, 3, 2, 1):
        for floor in (16, 24, 32, 40, 48, 64):
            b = despeckle((mag >= np.maximum(floor, c >> shift)).astype(np.uint8),
                          args.despeckle)
            s = stats(b)
            print("%-10s %4d %4d %6.2f %6.2f %6.2f %6.2f %6.2f %6d %6d %6d %7.1f %8.0f"
                  % (curve, shift, floor, s["lit"], 100 * b[dark].mean(),
                     100 * b[m_noise].mean(), 100 * b[m_weak].mean(),
                     100 * b[brt].mean(), s["blob"], s["tiny"], s["chain"],
                     s["chain_pix"], s["med"]))
            vis = np.zeros((b.shape[0], b.shape[1], 3), np.uint8)
            vis[b > 0] = (255, 255, 255)
            cv2.putText(vis, "%s S%dT%d" % (curve, shift, floor), (6, 24),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)
            panels.append(vis)
    ph, pw = panels[0].shape[:2]
    rows = []
    for i in range(0, len(panels), 3):
        row = panels[i:i + 3]
        while len(row) < 3:
            row.append(np.zeros_like(panels[0]))
        rows.append(np.hstack(row))
    out_png = os.path.join(args.out, "sweep_%s.png" % curve)
    cv2.imwrite(out_png, np.vstack(rows))
    print("sheet:", out_png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frame", default="work/capture/back_t24/frame_00.png")
    ap.add_argument("--out", default="work/analysis/proto/curve_sweep")
    ap.add_argument("--lo-floor", type=int, default=8)
    ap.add_argument("--hi-floor", type=int, default=40)
    ap.add_argument("--shift", type=int, default=2)
    ap.add_argument("--despeckle", type=int, default=3)
    ap.add_argument("--hys", type=int, default=1, help="0 = plain threshold")
    ap.add_argument("--sweep-thr", action="store_true",
                    help="sweep shift x floor on top of one tone curve")
    ap.add_argument("--curve", default="bst2k64")
    args = ap.parse_args()

    img = cv2.imread(args.frame)
    if img is None:
        raise SystemExit("cannot read " + args.frame)
    g = gray_from_capture(img)
    os.makedirs(args.out, exist_ok=True)

    if args.sweep_thr:
        sweep_thresholds(g, args.curve, args)
        return
    mag0, c0 = sobel_xy(g)
    dark = c0 < 48
    brt = c0 >= 160
    m_noise = dark & (mag0 < 8)
    m_weak = dark & (mag0 >= 8) & (mag0 < 24)
    print("gray mean=%.1f  dark=%.1f%%  dark&flat=%.1f%%  dark&weak=%.1f%%"
          % (g.mean(), 100 * dark.mean(), 100 * m_noise.mean(),
             100 * m_weak.mean()))
    print("%-14s %6s %6s %6s %6s %6s %6s %6s %6s %7s %8s"
          % ("curve", "lit%", "dark%", "noise%", "weak%", "brt%", "blob",
             "tiny", "chain", "chnpx%", "med"))
    panels = []
    for name, lut in CURVES.items():
        src = lut[g]
        mag, c = sobel_xy(src)
        w = mag >= np.maximum(args.lo_floor, c >> args.shift)
        if args.hys:
            strong = (mag >= np.maximum(args.hi_floor, c >> args.shift))
            nbr = cv2.dilate(strong.astype(np.uint8), np.ones((3, 3), np.uint8))
            b = (w & (nbr > 0)).astype(np.uint8)
        else:
            b = w.astype(np.uint8)
        b = despeckle(b, args.despeckle)
        s = stats(b)
        print("%-14s %6.2f %6.2f %6.2f %6.2f %6.2f %6d %6d %6d %7.1f %8.0f"
              % (name, s["lit"], 100 * b[dark].mean(), 100 * b[m_noise].mean(),
                 100 * b[m_weak].mean(), 100 * b[brt].mean(), s["blob"],
                 s["tiny"], s["chain"], s["chain_pix"], s["med"]))
        vis = np.zeros((b.shape[0], b.shape[1], 3), np.uint8)
        vis[b > 0] = (255, 255, 255)
        cv2.putText(vis, name, (6, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                    (0, 0, 255), 2)
        panels.append(vis)
        cv2.imwrite(os.path.join(args.out, name + ".png"), vis)

    ph, pw = panels[0].shape[:2]
    gray3 = cv2.cvtColor(g[1:1 + ph, 1:1 + pw], cv2.COLOR_GRAY2BGR)
    cv2.putText(gray3, "gray input", (6, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                (0, 0, 255), 2)
    panels.append(gray3)
    blank = np.zeros_like(panels[0])
    rows = []
    for i in range(0, len(panels), 3):
        row = panels[i:i + 3]
        while len(row) < 3:
            row.append(blank)
        rows.append(np.hstack(row))
    out_png = os.path.join(args.out, "curve_sweep.png")
    cv2.imwrite(out_png, np.vstack(rows))
    print("sheet:", out_png)


if __name__ == "__main__":
    main()