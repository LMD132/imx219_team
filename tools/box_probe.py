#!/usr/bin/env python3
"""Is the 2 px comb inside the image data, or added after the overlay stage?

comb_phase.py showed the grey half carries a separable multiplicative 2D comb:
odd columns +22.5 %, odd rows -12.2 %, checkerboard term ~0. That structure
means it is applied to the finished picture, not to the raw Bayer stream (a
Bayer-phase problem would put nearly all of its power in the checkerboard term,
and a per-channel gain difference cannot reach luma at all).

The image carries its own tracer: edge_overlay_720p draws the target box itself,
downstream of everything that touches the grey image. If the comb is injected
with the image data, the box is clean; if it is injected after the overlay (in
the DVI encoder's input mux, or in the capture device), the box carries it too.

So: find the strongly coloured pixels (the box), measure the same four-phase
comb decomposition on them, and compare with the grey half as a control.

    python tools/box_probe.py --device 1 --seconds 3
"""

from __future__ import annotations

import argparse
import time

import cv2
import numpy as np


def phases(rel: np.ndarray, mask: np.ndarray | None = None) -> tuple[np.ndarray, int]:
    out = np.zeros(4)
    n = 0
    for iy in range(2):
        for ix in range(2):
            sl = (slice(iy, None, 2), slice(ix, None, 2))
            v = rel[sl]
            if mask is not None:
                v = v[mask[sl]]
            if v.size:
                out[iy * 2 + ix] = float(v.mean())
                n += int(v.size)
    return out, n


def report(name: str, r: np.ndarray, n: int) -> None:
    print(f"--- {name}  ({n} samples)")
    print(f"  (y even, x even) {r[0]:+.4f}   (y even, x odd) {r[1]:+.4f}")
    print(f"  (y odd , x even) {r[2]:+.4f}   (y odd , x odd) {r[3]:+.4f}")
    ax = (r[1] + r[3] - r[0] - r[2]) / 4
    ay = (r[2] + r[3] - r[0] - r[1]) / 4
    axy = (r[0] + r[3] - r[1] - r[2]) / 4
    print(f"  A_x {ax:+.4f}   A_y {ay:+.4f}   A_xy {axy:+.4f}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=1)
    ap.add_argument("--seconds", type=float, default=3.0)
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

    acc = None
    frames = 0
    t0 = time.time()
    while time.time() - t0 < args.seconds:
        ok, frame = cap.read()
        if not ok:
            continue
        a = frame.astype(np.float32)
        acc = a if acc is None else acc + a
        frames += 1
    cap.release()
    if acc is None:
        raise SystemExit("no frames")
    mean = acc / frames
    print(f"frames {frames}")

    yy = 0.114 * mean[:, :, 0] + 0.587 * mean[:, :, 1] + 0.299 * mean[:, :, 2]
    box = cv2.boxFilter(yy, -1, (4, 4), normalize=True)
    rel = yy / np.maximum(box, 1.0) - 1.0

    left = np.zeros_like(yy, dtype=bool)
    left[:, : args.width // 2] = True
    report("grey half (control)", *phases(rel, left))

    mx = mean.max(axis=2)
    mn = mean.min(axis=2)
    sat = mx - mn
    right = np.zeros_like(sat)
    right[:, args.width // 2 :] = 1.0
    coloured = sat * right > 40
    print()
    print(f"strongly coloured pixels in the right half: {int(coloured.sum())}")
    if coloured.sum() > 100:
        rgb = mean[coloured].mean(axis=0)
        print(f"their mean BGR = {rgb[0]:.0f} {rgb[1]:.0f} {rgb[2]:.0f}")
        report("coloured pixels (the box)", *phases(rel, coloured))
    else:
        print("no box visible in this frame")

    rest = (sat * right <= 40) & (right > 0)
    if rest.sum() > 100:
        print()
        report("right half, grey pixels", *phases(rel, rest))


if __name__ == "__main__":
    main()
