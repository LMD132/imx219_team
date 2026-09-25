#!/usr/bin/env python3
"""判断参考视频里的边缘图有没有闪烁（相机手持 -> 先做整帧对齐再比）。

思路：找两个"拍摄场景基本静止"的帧，用相位相关把后一帧对齐到前一帧，
再算帧间差。然后比较**屏幕区域**和**屏幕外的静止背景区域**的残差：
  - 若 屏幕残差 ≈ 背景残差  -> 屏幕内容没有引入额外时域噪声（不闪）
  - 若 屏幕残差 >> 背景残差  -> 边缘图在闪
这样做的差分残差里"相机噪声"这一项被背景区抵消掉了，可以跨设备比较。

用法：
  python tools/ref_flicker_check.py --a 300 --b 420 --screen 430,375,1040,620 \
      --bg 60,940,320,120
"""

import argparse

import cv2
import numpy as np


def load(path, idx):
    cap = cv2.VideoCapture(path)
    cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
    ok, fr = cap.read()
    cap.release()
    if not ok:
        raise SystemExit(f"读不到第 {idx} 帧")
    return fr


def box_rect(spec):
    x, y, w, h = (int(v) for v in spec.split(","))
    return x, y, w, h


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", default="work/ref_video/ref.f100026.mp4")
    ap.add_argument("--a", type=int, default=300)
    ap.add_argument("--b", type=int, default=420)
    ap.add_argument("--screen", default="430,375,1040,620")
    ap.add_argument("--bg", default="60,940,320,120")
    ap.add_argument("--seq", default=None,
                    help="连续帧扫描模式，格式 起,止（含），逐帧算屏幕区大跳变比例")
    ap.add_argument("--jump", type=int, default=64, help="大跳变阈值 LSB")
    args = ap.parse_args()

    if args.seq:
        a, b = (int(v) for v in args.seq.split(","))
        x, y, w, h = box_rect(args.screen)
        cap = cv2.VideoCapture(args.video)
        prev = None
        vals = []
        for i in range(a, b + 1):
            cap.set(cv2.CAP_PROP_POS_FRAMES, i)
            ok, fr = cap.read()
            if not ok:
                break
            g = cv2.cvtColor(fr, cv2.COLOR_BGR2GRAY)[y:y + h, x:x + w].astype(np.int16)
            if prev is not None:
                d = np.abs(g - prev)
                pct = 100.0 * (d > args.jump).mean()
                vals.append(pct)
                if len(vals) % 10 == 0 or len(vals) == 1:
                    print(f"  帧{i - 1}->{i} 大跳变(>{args.jump}LSB) 占比 {pct:5.2f}%")
            prev = g
        cap.release()
        if vals:
            v = np.array(vals)
            print(f"连续帧扫描 {a}..{b} 共 {len(v)} 对：mean={v.mean():.2f}% "
                  f"med={np.median(v):.2f}% min={v.min():.2f}% max={v.max():.2f}%")
        raise SystemExit(0)

    fa = load(args.video, args.a)
    fb = load(args.video, args.b)
    ga = cv2.cvtColor(fa, cv2.COLOR_BGR2GRAY).astype(np.float32)
    gb = cv2.cvtColor(fb, cv2.COLOR_BGR2GRAY).astype(np.float32)

    (dx, dy), resp = cv2.phaseCorrelate(ga, gb)
    M = np.float32([[1, 0, dx], [0, 1, dy]])
    gb_al = cv2.warpAffine(gb, M, (ga.shape[1], ga.shape[0]),
                           flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    diff = np.abs(ga - gb_al)
    print(f"帧 {args.a} vs {args.b}: 对齐位移 dx={dx:+.3f} dy={dy:+.3f} "
          f"响应={resp:.4f}")
    print(f"整帧残差 mean={diff.mean():.3f} LSB  >8LSB 占比={100 * (diff > 8).mean():.2f}%")

    for name, spec in (("屏幕区", args.screen), ("背景区", args.bg)):
        x, y, w, h = box_rect(spec)
        d = diff[y:y + h, x:x + w]
        if d.size == 0:
            print(f"  {name} 框超出画面")
            continue
        print(f"  {name} ({x},{y},{w},{h}) 残差 mean={d.mean():6.3f} "
              f"med={np.median(d):6.3f} p95={np.percentile(d, 95):6.2f} "
              f">8LSB={100 * (d > 8).mean():5.2f}%  >32LSB={100 * (d > 32).mean():5.2f}%")


if __name__ == "__main__":
    main()
