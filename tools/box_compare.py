#!/usr/bin/env python3
"""Compare candidate bounding-box rules on real captured frames.

edge_overlay_720p.v currently takes the min/max of every despeckled edge pixel
of a frame. That rule is destroyed by a single outlier: one edge pixel in the
far corner of the frame stretches the box to the full panel. This script asks
the only question that matters before touching the RTL - given the frames we
have already captured, how much tighter can a different rule be without
throwing away the object?

Frames are scored one at a time, not averaged, because the board computes one
box per frame. (Averaging twelve frames first and then requiring "all twelve"
was the bug behind an earlier, wrong conclusion: edge pixels that flicker drop
out, the mask shreds into confetti, and "largest connected component" stops
being a usable reference.)

The right half of a captured frame is the binary edge map; the overlay box is
red, so requiring all three channels to be high keeps it out of the mask.

    python tools/box_compare.py --dirs work/capture/hys_h1_1 work/capture/ab3_b1

Reported per rule, averaged over the frames of a directory:
  area%  box area as a share of the right-half area   (smaller = tighter)
  cover% share of edge pixels that fall inside the box (larger = keeps object)
A rule is only interesting when it moves cover% down much less than area%.
"""

from __future__ import annotations

import argparse
import glob
import os

import cv2
import numpy as np

SPLIT = 640  # separator column; the edge map is x = 641..1279


def edge_map(path: str) -> np.ndarray | None:
    img = cv2.imread(path)
    if img is None:
        return None
    b, g, r = (img[:, :, i].astype(np.int16) for i in range(3))
    return (b > 64) & (g > 64) & (r > 64)


def box_metrics(mask: np.ndarray, box) -> tuple[float, float]:
    x0, x1, y0, y1 = box
    h, w = mask.shape
    area = ((x1 - x0 + 1) * (y1 - y0 + 1)) / float(w * h)
    inside = mask[y0:y1 + 1, x0:x1 + 1]
    lit = int(mask.sum())
    cover = (inside.sum() / lit) if lit else 0.0
    return 100.0 * area, 100.0 * float(cover)


def box_all(mask: np.ndarray):
    ys, xs = np.nonzero(mask)
    if xs.size == 0:
        return None
    return int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())


def box_proj(mask: np.ndarray, alpha: float):
    """Keep columns/rows whose edge count is at least alpha of the peak."""
    col = mask.sum(axis=0)
    row = mask.sum(axis=1)
    csel = np.nonzero(col >= max(1.0, alpha * col.max()))[0]
    rsel = np.nonzero(row >= max(1.0, alpha * row.max()))[0]
    if csel.size == 0 or rsel.size == 0:
        return None
    return int(csel.min()), int(csel.max()), int(rsel.min()), int(rsel.max())


def box_block(mask: np.ndarray, bw: int, bh: int, alpha: float):
    """Coarse grid: keep blocks whose count is at least alpha of the peak."""
    h, w = mask.shape
    ny, nx = h // bh, w // bw
    cut = mask[:ny * bh, :nx * bw]
    bs = cut.reshape(ny, bh, nx, bw).sum(axis=(1, 3))
    sel = np.nonzero(bs >= max(1.0, alpha * bs.max()))
    if sel[0].size == 0:
        return None
    y0, y1 = int(sel[0].min()) * bh, int(sel[0].max()) * bh + bh - 1
    x0, x1 = int(sel[1].min()) * bw, int(sel[1].max()) * bw + bw - 1
    return x0, x1, y0, y1


def box_largest_cc(mask: np.ndarray):
    """Reference only: the box a per-object labeller would produce."""
    n, lab, st, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), 8)
    if n <= 1:
        return None
    i = 1 + int(np.argmax(st[1:, 4]))
    x, y, w, h = (int(v) for v in st[i, :4])
    return x, x + w - 1, y, y + h - 1


def rules():
    out = [("all-minmax", box_all)]
    for a in (0.05, 0.10, 0.20, 0.35):
        out.append((f"proj a={a:.2f}", (lambda m, a=a: box_proj(m, a))))
    for bw, bh in ((32, 20), (64, 36)):
        for a in (0.15, 0.30):
            out.append((f"blk {bw}x{bh} a={a:.2f}",
                        (lambda m, bw=bw, bh=bh, a=a: box_block(m, bw, bh, a))))
    out.append(("largest-cc", box_largest_cc))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dirs", nargs="+", required=True)
    args = ap.parse_args()

    print("right half only (x=641..1279); one box per frame, then averaged")
    print(f"{'directory':<20}{'frames':>7}{'lit px':>10}", end="")
    for name, _ in rules():
        print(f"  {name:>14}", end="")
    print()
    print(f"{'':<20}{'':>7}{'':>10}", end="")
    for _ in rules():
        print(f"  {'area/cover':>14}", end="")
    print()

    for d in args.dirs:
        frames = sorted(glob.glob(os.path.join(d, "frame_*.png")))
        acc = {name: [] for name, _ in rules()}
        lit = []
        for f in frames:
            m = edge_map(f)
            if m is None:
                continue
            m = m[:, SPLIT + 1:]
            if not m.any():
                continue
            lit.append(int(m.sum()))
            for name, fn in rules():
                box = fn(m)
                acc[name].append(box_metrics(m, box) if box else (np.nan, np.nan))
        if not lit:
            print(f"{os.path.basename(d):<20} no usable frames")
            continue
        print(f"{os.path.basename(d):<20}{len(lit):>7}{int(np.mean(lit)):>10}", end="")
        for name, _ in rules():
            a = np.array(acc[name], dtype=float)
            print(f"  {np.nanmean(a[:, 0]):>6.1f}/{np.nanmean(a[:, 1]):>5.0f}", end="")
        print()


if __name__ == "__main__":
    main()
