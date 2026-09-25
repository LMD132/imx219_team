#!/usr/bin/env python3
"""Decompose the 2 px comb into its four (x parity, y parity) phases.

comb_probe.py showed the pair difference scales with brightness (d/mean ~ 0.5,
ratio ~ 1.7) rather than being a fixed offset, and that the horizontal comb is
about twice the vertical one. That rules out a plain offset but does not yet
say which of these three patterns it is:

  column gain      even columns down, odd columns up, rows unaffected
  row gain         even rows down, odd rows up, columns unaffected
  checkerboard     all four phases differ (a 2x2 cell pattern)

Only a checkerboard is what a Bayer mosaic looks like; a pure column or row gain
points at the packed word / slot processing instead. Measure it with the local
relative gain per phase: divide the frame by a 4 px box average (which kills
anything at the 2 px scale but keeps the scene), then average the ratio inside
each of the four phases.

    python tools/comb_phase.py --device 1 --seconds 6
"""

from __future__ import annotations

import argparse
import time

import cv2
import numpy as np


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=1)
    ap.add_argument("--seconds", type=float, default=6.0)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    args = ap.parse_args()

    cap = cv2.VideoCapture(args.device, cv2.CAP_DSHOW)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"YUY2"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)
    cap.set(cv2.CAP_PROP_CONVERT_RGB, 1)
    if not cap.isOpened():
        raise SystemExit(f"cannot open capture device {args.device}")

    acc = np.zeros(4)          # sum of (g / box - 1) per phase
    n = 0
    gsum = 0.0
    frames = 0
    t0 = time.time()
    while time.time() - t0 < args.seconds:
        ok, frame = cap.read()
        if not ok:
            continue
        frames += 1
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).astype(np.float32)
        gray = gray[:, : args.width // 2]          # grey half only
        gsum += float(gray.mean())
        box = cv2.boxFilter(gray, -1, (4, 4), normalize=True)
        rel = gray / np.maximum(box, 1.0) - 1.0
        for iy in range(2):
            for ix in range(2):
                acc[iy * 2 + ix] += float(rel[iy::2, ix::2].mean())
        n += 1

    cap.release()
    r = acc / max(n, 1)
    print(f"frames {frames} in {args.seconds:g} s, grey half {args.width // 2} x {args.height}")
    print(f"grey half mean {gsum / max(n, 1):.2f}")
    print()
    print("relative gain per phase  (0 = matches the 4 px local average)")
    print("              x even      x odd")
    print(f"  y even   {r[0]:+8.4f}  {r[1]:+8.4f}")
    print(f"  y odd    {r[2]:+8.4f}  {r[3]:+8.4f}")
    print()
    ax = (r[1] + r[3] - r[0] - r[2]) / 4
    ay = (r[2] + r[3] - r[0] - r[1]) / 4
    axy = (r[0] + r[3] - r[1] - r[2]) / 4
    print(f"column term  A_x  = {ax:+.4f}")
    print(f"row term     A_y  = {ay:+.4f}")
    print(f"checker term A_xy = {axy:+.4f}")
    print()
    dom = max((abs(ax), "column gain"), (abs(ay), "row gain"), (abs(axy), "checkerboard"))
    print(f"largest term: {dom[1]} ({dom[0]:.4f})")


if __name__ == "__main__":
    main()
