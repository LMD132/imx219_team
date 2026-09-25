#!/usr/bin/env python3
"""Measure the 2 px comb on the capture device's own luma channel (Y).

box_probe.py found the red box (drawn by edge_overlay_720p, i.e. after all the
image processing) carries no +22 % column comb, while the grey half does. The
box reading came from a BGR frame, and the card converts to YUY2 (4:2:2), so a
saturated 2 px thick red line can pick up reconstruction artefacts. Redo the
measurement on the card's raw luma bytes, where the conversion cannot reach:

  CONVERT_RGB=0 gives the card's own Y per pixel; BGR frames only regain Y
  through chroma reconstruction, which clips on saturated colours.

If the grey half still shows the comb in raw Y, and the box still does not, the
comb is carried by the image data itself, so it is injected before the overlay
stage - not by the encoder and not by the capture device.

    python tools/y_probe.py --device 1 --seconds 3
"""

from __future__ import annotations

import argparse
import time

import cv2
import numpy as np


def open_cap(device: int, width: int, height: int, convert_rgb: int) -> cv2.VideoCapture:
    cap = cv2.VideoCapture(device, cv2.CAP_DSHOW)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"YUY2"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_CONVERT_RGB, convert_rgb)
    return cap


def grab_mean(cap: cv2.VideoCapture, seconds: float) -> np.ndarray:
    acc = None
    n = 0
    t0 = time.time()
    while time.time() - t0 < seconds:
        ok, frame = cap.read()
        if not ok:
            continue
        a = frame.astype(np.float32)
        acc = a if acc is None else acc + a
        n += 1
    if acc is None:
        raise SystemExit("no frames")
    return acc / n


def phases(rel: np.ndarray, mask: np.ndarray) -> tuple[np.ndarray, int]:
    out = np.zeros(4)
    n = 0
    for iy in range(2):
        for ix in range(2):
            sl = (slice(iy, None, 2), slice(ix, None, 2))
            v = rel[sl][mask[sl]]
            if v.size:
                out[iy * 2 + ix] = float(v.mean())
                n += int(v.size)
    return out, n


def report(name: str, r: np.ndarray, n: int) -> None:
    if n == 0:
        print(f"--- {name}: no samples")
        return
    ax = (r[1] + r[3] - r[0] - r[2]) / 4
    ay = (r[2] + r[3] - r[0] - r[1]) / 4
    axy = (r[0] + r[3] - r[1] - r[2]) / 4
    print(
        f"--- {name}  n={n}\n"
        f"    cells  {r[0]:+.4f} {r[1]:+.4f} / {r[2]:+.4f} {r[3]:+.4f}\n"
        f"    A_x {ax:+.4f}   A_y {ay:+.4f}   A_xy {axy:+.4f}"
    )


def comb(y: np.ndarray, half: str) -> np.ndarray:
    box = cv2.boxFilter(y, -1, (4, 4), normalize=True)
    rel = y / np.maximum(box, 1.0) - 1.0
    left = np.zeros(y.shape, dtype=bool)
    if half == "left":
        left[:, : y.shape[1] // 2] = True
    else:
        left[:, y.shape[1] // 2 :] = True
    return rel


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=1)
    ap.add_argument("--seconds", type=float, default=3.0)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    args = ap.parse_args()

    cap = open_cap(args.device, args.width, args.height, 1)
    if not cap.isOpened():
        raise SystemExit(f"cannot open capture device {args.device}")
    bgr = grab_mean(cap, args.seconds)
    cap.release()

    mx = bgr.max(axis=2)
    mn = bgr.min(axis=2)
    sat = mx - mn
    right = np.zeros(sat.shape)
    right[:, args.width // 2 :] = 1.0
    box_mask = sat * right > 40
    print(f"BGR pass: shape {bgr.shape}, coloured pixels {int(box_mask.sum())}")
    if box_mask.sum() > 100:
        print(f"  box mean BGR {bgr[box_mask].mean(axis=0).round(0)}")

    cap = open_cap(args.device, args.width, args.height, 0)
    raw = grab_mean(cap, args.seconds)
    cap.release()
    print(f"raw pass: shape {raw.shape}")

    if raw.ndim == 3 and raw.shape[2] == 2:
        y = raw[:, :, 0]
        print("  using channel 0 as Y (2-channel YUY2)")
    elif raw.ndim == 3 and raw.shape[2] == 3:
        y = 0.114 * raw[:, :, 0] + 0.587 * raw[:, :, 1] + 0.299 * raw[:, :, 2]
        print("  CONVERT_RGB was ignored, using BGR luma")
    elif raw.ndim == 2 and raw.shape[1] >= args.width * 2:
        y = raw[:, 0::2]
        print("  packed buffer, taking every other byte as Y")
    else:
        raise SystemExit(f"unexpected raw shape {raw.shape}")

    y = y.astype(np.float32)
    print(f"  Y mean, grey half {y[:, : args.width // 2].mean():.1f}")
    print()

    g_left = np.zeros(y.shape, dtype=bool)
    g_left[:, : args.width // 2] = True
    report("grey half, raw Y", *phases(comb(y, "left"), g_left))
    if box_mask.sum() > 100 and box_mask.shape == y.shape:
        report("red box, raw Y", *phases(comb(y, "right"), box_mask))
    grey_right = (~g_left) & (sat < 40) & (y > 8)
    report("right half, grey pixels, raw Y", *phases(comb(y, "right"), grey_right))


if __name__ == "__main__":
    main()
