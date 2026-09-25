#!/usr/bin/env python3
"""Draw several candidate bounding boxes on one real captured frame so the
choice can be made by eye instead of from a table of averages.

    python tools/box_contact.py --frames work/capture/hys_h1_1/frame_*.png \
        --out work/analysis/box/contact.png

Colours:  red = current all-pixel min/max, green = row/column projection
(alpha 0.05 of the peak count), blue = largest connected component, which is
what a per-object labeller would give and is a reference only.
"""

from __future__ import annotations

import argparse
import glob
import os

import cv2
import numpy as np

SPLIT = 640


def edge_map(path: str) -> np.ndarray | None:
    img = cv2.imread(path)
    if img is None:
        return None
    b, g, r = (img[:, :, i].astype(np.int16) for i in range(3))
    return (b > 64) & (g > 64) & (r > 64)


def box_all(m):
    ys, xs = np.nonzero(m)
    return (int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max())) if xs.size else None


def box_proj(m, alpha):
    col, row = m.sum(axis=0), m.sum(axis=1)
    cs = np.nonzero(col >= max(1.0, alpha * col.max()))[0]
    rs = np.nonzero(row >= max(1.0, alpha * row.max()))[0]
    if not cs.size or not rs.size:
        return None
    return int(cs.min()), int(cs.max()), int(rs.min()), int(rs.max())


def box_cc(m):
    n, _, st, _ = cv2.connectedComponentsWithStats(m.astype(np.uint8), 8)
    if n <= 1:
        return None
    i = 1 + int(np.argmax(st[1:, 4]))
    x, y, w, h = (int(v) for v in st[i, :4])
    return x, x + w - 1, y, y + h - 1


def draw(img, box, colour, label):
    if box is None:
        return
    x0, x1, y0, y1 = box
    cv2.rectangle(img, (x0, y0), (x1, y1), colour, 1)
    cv2.putText(img, label, (x0 + 3, max(14, y0 + 16)),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, colour, 2)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", nargs="+", required=True)
    ap.add_argument("--out", default="work/analysis/box/contact.png")
    ap.add_argument("--tile", type=int, default=560, help="tile width in the sheet")
    args = ap.parse_args()

    paths = []
    for pat in args.frames:
        paths.extend(sorted(glob.glob(pat)))
    if not paths:
        raise SystemExit("no frames matched")

    tiles = []
    for p in paths:
        m = edge_map(p)
        if m is None:
            continue
        right = m[:, SPLIT + 1:]
        img = cv2.imread(p)
        # shift the box coordinates back into full-frame space
        off = SPLIT + 1
        for box, colour, label in ((box_all(right), (0, 0, 255), "min/max"),
                                   (box_proj(right, 0.05), (0, 255, 0), "proj .05"),
                                   (box_cc(right), (255, 128, 0), "largest cc")):
            # box is (x0, x1, y0, y1): only the two x entries need the half offset
            shifted = tuple(v + off if i < 2 else v for i, v in enumerate(box)) if box else None
            draw(img, shifted, colour, label)
        # annotate with the raw numbers for this frame
        a = box_all(right)
        g = box_proj(right, 0.05)
        txt = "%s  lit=%d" % (os.path.basename(os.path.dirname(p)), int(right.sum()))
        if a and g:
            ah = (a[1] - a[0] + 1) * (a[3] - a[2] + 1)
            gh = (g[1] - g[0] + 1) * (g[3] - g[2] + 1)
            txt += "  area %.0f%% -> %.0f%%" % (100.0 * ah / right.size, 100.0 * gh / right.size)
        cv2.rectangle(img, (0, 0), (1280, 26), (0, 0, 0), -1)
        cv2.putText(img, txt, (6, 19), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 1)
        s = args.tile / img.shape[1]
        tiles.append(cv2.resize(img, (args.tile, int(round(img.shape[0] * s)))))

    cols = 1 if len(tiles) == 1 else 2
    rows = (len(tiles) + cols - 1) // cols
    rh = max(t.shape[0] for t in tiles)
    sheet = np.zeros((rows * rh, cols * args.tile, 3), np.uint8)
    for i, t in enumerate(tiles):
        r, c = divmod(i, cols)
        sheet[r * rh:r * rh + t.shape[0], c * args.tile:(c + 1) * args.tile] = t
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    cv2.imwrite(args.out, sheet)
    print("wrote", args.out, sheet.shape)


if __name__ == "__main__":
    main()
