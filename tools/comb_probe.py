#!/usr/bin/env python3
"""Is the 2 px comb a value pattern or a colour pattern?

The grey half of the HDMI output carries a comb whose period is exactly 2 px
along x and along y (see docs/capture_and_quantify.md). Two families of cause
survive the RTL reading:

  (A) a per-slot value imbalance in the raw stream, i.e. the two Bayer pixels
      packed into one 16-bit word come out with different amplitude. A linear
      demosaic followed by a BT.601 luma cannot remove that, so it shows up as
      a comb no matter what the scene colour is.
  (B) the display path is showing mosaic-like data, so the comb amplitude
      tracks how colourful the scene is: under a grey target the channels are
      equal and there is nothing to see; under a saturated target the two
      Bayer phases differ a lot and the comb blows up.

Both predict a comb, so amplitude alone cannot separate them. Colour can:
bin every column pair by its own brightness and by its own colourfulness
(max-min of the captured BGR, which the card subsamples 4:2:2 but that is
per-pair anyway) and report the comb amplitude per bin. If the comb is flat in
colourfulness it is (A); if it scales with colour it is (B).

    python tools/comb_probe.py --device 1 --seconds 6
"""

from __future__ import annotations

import argparse
import time

import cv2
import numpy as np

LEFT = 640


def open_cap(device: int, width: int, height: int) -> cv2.VideoCapture:
    cap = cv2.VideoCapture(device, cv2.CAP_DSHOW)
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"YUY2"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_CONVERT_RGB, 1)
    return cap


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=1)
    ap.add_argument("--seconds", type=float, default=6.0)
    args = ap.parse_args()

    cap = open_cap(args.device, 1280, 720)
    if not cap.isOpened():
        raise SystemExit(f"cannot open capture device {args.device}")

    lum_edges = np.array([0, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256])
    col_edges = np.array([0, 2, 4, 8, 16, 32, 64, 128, 256])
    n_l = len(lum_edges) - 1
    n_c = len(col_edges) - 1

    # per luma bin x chroma bin: count, sum|d|, sum d   (horizontal pairs)
    h_cnt = np.zeros((n_l, n_c))
    h_abs = np.zeros((n_l, n_c))
    h_sum = np.zeros((n_l, n_c))
    # same for vertical pairs (rows), binned by luma only
    v_cnt = np.zeros(n_l)
    v_abs = np.zeros(n_l)
    v_sum = np.zeros(n_l)

    frames = 0
    t0 = time.time()
    while time.time() - t0 < args.seconds:
        ok, frame = cap.read()
        if not ok:
            continue
        frames += 1
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).astype(np.int16)
        mx = frame.max(axis=2).astype(np.int16)
        mn = frame.min(axis=2).astype(np.int16)
        chroma = mx - mn

        left = gray[:, :LEFT]
        a = left[:, 0::2]
        b = left[:, 1::2]
        d = (b - a).astype(np.float32)
        m = ((a + b) / 2.0).astype(np.float32)
        c = np.maximum(chroma[:, :LEFT][:, 0::2], chroma[:, :LEFT][:, 1::2]).astype(np.float32)

        li = np.clip(np.digitize(m, lum_edges) - 1, 0, n_l - 1).astype(np.int32)
        ci = np.clip(np.digitize(c, col_edges) - 1, 0, n_c - 1).astype(np.int32)
        flat = li.ravel() * n_c + ci.ravel()
        h_cnt += np.bincount(flat, minlength=n_l * n_c).reshape(n_l, n_c)
        h_abs += np.bincount(flat, weights=np.abs(d).ravel(), minlength=n_l * n_c).reshape(n_l, n_c)
        h_sum += np.bincount(flat, weights=d.ravel(), minlength=n_l * n_c).reshape(n_l, n_c)

        av = left[0::2, :]
        bv = left[1::2, :]
        dv = (bv - av).astype(np.float32)
        mv = ((av + bv) / 2.0).astype(np.float32)
        lv = np.clip(np.digitize(mv, lum_edges) - 1, 0, n_l - 1).astype(np.int32)
        v_cnt += np.bincount(lv.ravel(), minlength=n_l)
        v_abs += np.bincount(lv.ravel(), weights=np.abs(dv).ravel(), minlength=n_l)
        v_sum += np.bincount(lv.ravel(), weights=dv.ravel(), minlength=n_l)

    cap.release()
    print(f"frames {frames} in {args.seconds:g} s")
    print()
    print("horizontal pairs  |d| = mean |right - left| inside a 2 px pair")
    hdr = "luma bin      n        |d|      d    " + "".join(
        f"  |d|c{c:<3d}" for c in col_edges[:-1]
    )
    print(hdr)
    for i in range(n_l):
        tot = h_cnt[i].sum()
        if tot < 200:
            continue
        row = h_abs[i].sum() / tot
        rsum = h_sum[i].sum() / tot
        cells = ""
        for j in range(n_c):
            if h_cnt[i, j] > 100:
                cells += f"  {h_abs[i, j] / h_cnt[i, j]:7.2f}"
            else:
                cells += "        -"
        print(
            f"{lum_edges[i]:3d}..{lum_edges[i + 1]:<3d} {int(tot):8d} {row:8.2f} {rsum:7.2f} "
            + cells
        )
    print()
    print("vertical pairs    |d| = mean |lower - upper| inside a 2 px pair")
    print("luma bin      n        |d|      d")
    for i in range(n_l):
        if v_cnt[i] < 200:
            continue
        print(
            f"{lum_edges[i]:3d}..{lum_edges[i + 1]:<3d} {int(v_cnt[i]):8d} "
            f"{v_abs[i] / v_cnt[i]:8.2f} {v_sum[i] / v_cnt[i]:7.2f}"
        )


if __name__ == "__main__":
    main()
