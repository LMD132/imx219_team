#!/usr/bin/env python3
"""从参考视频里自动抠出显示器面板，量它内部边缘图的观感指标。

与 analyze_reference_video.py 的区别：这里用更宽的暗阈值 + 15x15 闭运算，
把整块面板（含内部大量亮线）连成一个连通域，再向内缩 6% 去掉边框/反光，
然后量：
  lit    亮像素占比（边缘密度）
  run    亮像素行/列游程均值（线条粗细，px）
  tiny   面积 <=3 px 的碎连通域个数（噪点碎段）
  left/right  裁剪图左右半均值（判断是不是左灰度+右边缘的分屏）

用法：
  python tools/probe_reference_screen.py --video work/ref_video/ref.f100026.mp4 \
      --frames 300,450,600,660 --out work/analysis/refvideo
"""

import argparse
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyze_reference_video import analyse_crop  # noqa: E402


def panel_crop(gray, thr=70, ksize=15, inset_frac=0.06):
    dark = (gray < thr).astype(np.uint8)
    k = cv2.getStructuringElement(cv2.MORPH_RECT, (ksize, ksize))
    d = cv2.morphologyEx(dark, cv2.MORPH_CLOSE, k)
    n, _, stats, _ = cv2.connectedComponentsWithStats(d, 8)
    if n < 2:
        return None, None
    i = max(range(1, n), key=lambda j: stats[j][4])
    x, y, bw, bh, _ = stats[i]
    ix = int(inset_frac * bh)
    crop = gray[y + ix:y + bh - ix, x + ix:x + bw - ix]
    if crop.size == 0:
        return None, None
    return crop, (x, y, bw, bh)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", default="work/ref_video/ref.f100026.mp4")
    ap.add_argument("--out", default="work/analysis/refvideo")
    ap.add_argument("--frames", default="300,450,600,660")
    ap.add_argument("--box", action="append", default=[],
                    help="手工裁剪框（自动定位不灵时用），格式 frame:x,y,w,h，可重复")
    args = ap.parse_args()

    manual = {}
    for spec in args.box:
        f, rest = spec.split(":", 1)
        manual[int(f)] = tuple(int(v) for v in rest.split(","))

    frames = [int(t) for t in args.frames.split(",") if t.strip()]
    cap = cv2.VideoCapture(args.video)
    if not cap.isOpened():
        raise SystemExit("打不开视频: " + args.video)
    os.makedirs(args.out, exist_ok=True)

    print("frame  bbox              crop        lit%   run(px)  nblob  tiny tinypx%  bg%")
    for f in frames:
        cap.set(cv2.CAP_PROP_POS_FRAMES, f)
        ok, fr = cap.read()
        if not ok:
            print(f"{f:5d}  <read fail>")
            continue
        gray = cv2.cvtColor(fr, cv2.COLOR_BGR2GRAY)
        if f in manual:
            x, y, bw, bh = manual[f]
            crop = gray[y:y + bh, x:x + bw]
            bb = (x, y, bw, bh)
        else:
            crop, bb = panel_crop(gray)
        if crop is not None and crop.size == 0:
            crop = None
        if crop is None:
            print(f"{f:5d}  <no panel>")
            continue
        cv2.imwrite(os.path.join(args.out, f"probe_f{f:04d}.png"), crop)
        r = analyse_crop(crop)
        tiny_pct = 100.0 * r['tiny_px'] / max(r['lit'] * crop.size, 1)
        print(f"{f:5d}  {str(bb):16s}  {str(crop.shape):11s} "
              f"{r['lit'] * 100:5.1f} {r['run']:7.2f} {r['nblob']:6d} "
              f"{r['tiny']:5d} {tiny_pct:7.2f} {r['bg'] * 100:5.1f}")


if __name__ == "__main__":
    main()
