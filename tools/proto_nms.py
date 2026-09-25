#!/usr/bin/env python3
"""Non-maximum suppression (the one Canny stage this project is missing) on a
real captured frame, so the RTL change can be judged before it is written.

The left half of a captured frame is the grey picture the board feeds into the
Sobel stage (tone curve already applied), so running the same arithmetic here
reproduces what the board would do on that half of the view.

NMS keeps a pixel only when its gradient magnitude is a local maximum along the
gradient direction. The direction comes from the signs of gx and gy, quantised
into four sectors - no atan, no divider, which is exactly what the RTL will do.

    python tools/proto_nms.py --frame work/capture/ab3_b1/frame_06.png \
        --out work/analysis/nms
"""

from __future__ import annotations

import argparse
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from proto_edge_enhance import despeckle, gray_from_capture, stats  # noqa: E402

# tan(67.5 deg): a gradient within 22.5 deg of an axis is treated as axis aligned
TAN_67_5 = 2.41421356


def sobel_signed(g: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    f = g.astype(np.int32)
    gx = (f[0:-2, 2:] + 2 * f[1:-1, 2:] + f[2:, 2:]) \
        - (f[0:-2, 0:-2] + 2 * f[1:-1, 0:-2] + f[2:, 0:-2])
    gy = (f[2:, 0:-2] + 2 * f[2:, 1:-1] + f[2:, 2:]) \
        - (f[0:-2, 0:-2] + 2 * f[0:-2, 1:-1] + f[0:-2, 2:])
    return gx, gy


def nms(mag: np.ndarray, gx: np.ndarray, gy: np.ndarray, strict: bool) -> np.ndarray:
    """Zero every pixel that is not a local maximum along its gradient."""
    ax, ay = np.abs(gx), np.abs(gy)
    m = np.pad(mag, 1, mode="edge")
    up, dn = m[0:-2, 1:-1], m[2:, 1:-1]
    lf, rt = m[1:-1, 0:-2], m[1:-1, 2:]
    ul, ur = m[0:-2, 0:-2], m[0:-2, 2:]
    dl, dr = m[2:, 0:-2], m[2:, 2:]
    horiz = ax > ay * TAN_67_5
    vert = ay > ax * TAN_67_5
    same = (gx.astype(np.int64) * gy.astype(np.int64)) > 0
    n1 = np.where(horiz, lf, np.where(vert, up, np.where(same, ul, ur)))
    n2 = np.where(horiz, rt, np.where(vert, dn, np.where(same, dr, dl)))
    keep = (mag > n1) & (mag > n2) if strict else (mag >= n1) & (mag >= n2)
    return np.where(keep, mag, 0).astype(np.int32)


def rule(mag: np.ndarray, floor: int, shift: int, center: np.ndarray,
         ds: int, hi_floor: int | None) -> np.ndarray:
    lo = np.maximum(floor, center >> shift)
    weak = mag >= lo
    if hi_floor is None:
        b = weak.astype(np.uint8)
    else:
        strong = (mag >= np.maximum(hi_floor, center >> shift)).astype(np.uint8)
        b = (weak & (cv2.dilate(strong, np.ones((3, 3), np.uint8)) > 0)).astype(np.uint8)
    return despeckle(b, ds)


def panel(gray: np.ndarray, b: np.ndarray, label: str) -> np.ndarray:
    # sobel_signed drops the last two rows/columns, so the result pixel (i, j)
    # is the window's bottom-right corner at gray[i + 2, j + 2].
    vis = cv2.cvtColor(gray[2:, 2:], cv2.COLOR_GRAY2BGR)
    vis[b > 0] = (0, 255, 0)
    cv2.rectangle(vis, (0, 0), (vis.shape[1], 22), (0, 0, 0), -1)
    cv2.putText(vis, label, (5, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
    return vis


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--frame", default="work/capture/ab3_b1/frame_06.png")
    ap.add_argument("--out", default="work/analysis/nms")
    ap.add_argument("--floor", type=int, default=24)
    ap.add_argument("--shift", type=int, default=8)
    ap.add_argument("--hi-floor", type=int, default=48)
    ap.add_argument("--despeckle", type=int, default=3)
    args = ap.parse_args()

    img = cv2.imread(args.frame)
    if img is None:
        raise SystemExit("cannot read " + args.frame)
    gray = gray_from_capture(img)
    gx, gy = sobel_signed(gray)
    mag = (np.abs(gx) + np.abs(gy)).astype(np.int32)
    # the board gates on the mean of the same causal 3x3 window, so the base for
    # output pixel (i, j) is the mean of gray[i:i+3, j:j+3]
    center = cv2.blur(gray.astype(np.float32), (3, 3),
                      borderType=cv2.BORDER_REPLICATE)[0:-2, 0:-2].astype(np.int32)
    hi = args.hi_floor if args.hi_floor else None

    base = rule(mag, args.floor, args.shift, center, args.despeckle, hi)
    sup = nms(mag, gx, gy, strict=False)
    cost = float((sup > 0).sum()) / max(1, int((mag > 0).sum()))

    rows = [("no NMS   D%d" % args.despeckle, base)]
    for ds in (0, 1, 3):
        rows.append(("NMS -D%d" % ds, rule(sup, args.floor, args.shift, center, ds, hi)))

    os.makedirs(args.out, exist_ok=True)
    for label, b in rows:
        st = stats(b)
        print("%-14s lit%% %5.2f  blob %5d  碎片 %5d  长链 %4d (%.0f%% of lit)  中位 %5.1f"
              % (label, st["lit"], st["blob"], st["tiny"], st["chain"],
                 st["chain_pix"], st["med"]))
    print("magnitude pixels surviving NMS: %.1f%%" % (100.0 * cost))

    panels = [panel(gray, b, lab) for lab, b in rows]
    top = np.hstack(panels[:2])
    bot = np.hstack(panels[2:])
    sheet = np.vstack([top, bot])
    p = os.path.join(args.out, "nms_" + os.path.basename(os.path.dirname(args.frame)) + ".png")
    cv2.imwrite(p, sheet)
    print("sheet:", p)


if __name__ == "__main__":
    main()
