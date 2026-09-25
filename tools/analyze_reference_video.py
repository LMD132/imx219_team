#!/usr/bin/env python3
"""分析参考视频里"目标效果"的量化特征。

背景：竞赛参照视频（B 站 BV1HYtg6BERZ，易灵思 FPGA 实时图像边缘检测）是
手持相机拍摄的显示器画面。要回答"目标效果到底长什么样"，需要把"显示器的
那块屏幕"从整个画面里抠出来，再量它内部的内容：

  * 是整屏边缘图，还是左半灰度 + 右半边缘的分屏？
  * 边缘密度、线条粗细（行/列亮游程均值）、碎斑（小连通域）数量
  * 有没有红色目标框
  * 屏幕区域内的帧间差（判断边缘是否闪烁；相机不动时才可信）

输出：work/analysis/refvideo/screen_stats.csv + 控制台汇总 + 若干裁剪图。

用法：
  python tools/analyze_reference_video.py --video work/ref_video/ref.f100026.mp4
"""

import argparse
import csv
import os

import cv2
import numpy as np


def runs_mean(binary):
    """亮像素行/列游程的平均长度（像素）。细线 -> 1~3。"""
    total = 0
    nrun = 0
    for axis in (0, 1):
        b = binary if axis == 0 else binary.T
        d = np.diff(b.astype(np.int8), axis=1)
        starts = (b[:, 0] != 0).sum() + (d == 1).sum()
        total += int(b.sum())
        nrun += int(starts)
    if nrun == 0:
        return 0.0
    return total / nrun


def find_display(gray, thr=45, min_area_frac=0.05, ar_lo=1.05, ar_hi=2.8):
    """找出画面中最大的一块近黑矩形（显示器面板）。返回 bbox 或 None。"""
    h, w = gray.shape
    dark = (gray < thr).astype(np.uint8)
    k = cv2.getStructuringElement(cv2.MORPH_RECT, (9, 9))
    dark = cv2.morphologyEx(dark, cv2.MORPH_CLOSE, k)
    dark = cv2.morphologyEx(dark, cv2.MORPH_OPEN, k)
    n, _, stats, _ = cv2.connectedComponentsWithStats(dark, 8)
    best = None
    for i in range(1, n):
        x, y, bw, bh, area = stats[i]
        if area < min_area_frac * w * h:
            continue
        ar = bw / max(bh, 1)
        if not (ar_lo <= ar <= ar_hi):
            continue
        if best is None or area > best[4]:
            best = (x, y, bw, bh, area)
    return best


def analyse_crop(crop):
    """量一块屏幕裁剪图内部的内容。"""
    h, w = crop.shape
    if h < 20 or w < 20:
        return None
    bg = float((crop < 45).mean())
    # Otsu 自适应分开"黑底"和"亮线"
    t, bright = cv2.threshold(crop, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    b = (bright > 0).astype(np.uint8)
    lit = float(b.mean())
    # 碎斑统计
    nb, _, bstats, _ = cv2.connectedComponentsWithStats(b, 8)
    areas = [bstats[i][4] for i in range(1, nb)]
    tiny = sum(1 for a in areas if a <= 3)
    tiny_px = sum(a for a in areas if a <= 3)
    run = runs_mean(b)
    bgr = cv2.cvtColor(crop, cv2.COLOR_GRAY2BGR)
    # 红框检测（在彩色裁剪图上做，调用方传入）
    return dict(bg=bg, lit=lit, otsu=t, nblob=nb - 1, tiny=tiny,
                tiny_px=tiny_px,
                run=run, left=float(crop[:, : w // 2].mean()),
                right=float(crop[:, w // 2:].mean()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video", default="work/ref_video/ref.f100026.mp4")
    ap.add_argument("--out", default="work/analysis/refvideo")
    ap.add_argument("--stride", type=int, default=1)
    ap.add_argument("--scale", type=float, default=0.5)
    ap.add_argument("--save-every", type=int, default=100)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    cap = cv2.VideoCapture(args.video)
    if not cap.isOpened():
        raise SystemExit(f"打不开视频: {args.video}")

    fps = cap.get(cv2.CAP_PROP_FPS)
    nframes = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    print(f"video: {args.video}")
    print(f"fps={fps:.2f} frames={nframes} stride={args.stride}")

    rows = []
    prev_crop = None
    prev_rec = None
    prev_idx = None
    saved = 0
    idx = -1
    nproc = 0
    while True:
        ok, frame = cap.read()
        idx += 1
        if not ok:
            break
        if idx % args.stride:
            continue
        nproc += 1
        small = cv2.resize(frame, None, fx=args.scale, fy=args.scale,
                           interpolation=cv2.INTER_AREA)
        gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
        h, w = gray.shape
        bb = find_display(gray)
        rec = dict(frame=idx, fps=fps, found=0)
        crop = None
        if bb is not None:
            x, y, bw, bh, area = bb
            rec.update(found=1, x=x, y=y, w=bw, h=bh,
                       frac=area / (w * h), ar=bw / max(bh, 1))
            crop = gray[y:y + bh, x:x + bw]
            a = analyse_crop(crop)
            if a:
                rec.update(a)
                sub = small[y:y + bh, x:x + bw]
                r = sub[:, :, 2].astype(np.int16)
                g = sub[:, :, 1].astype(np.int16)
                bl = sub[:, :, 0].astype(np.int16)
                red = (r > 140) & (r - g > 60) & (r - bl > 60)
                rec["red_frac"] = float(red.mean())
                rec["closeup"] = 1 if bw >= 0.35 * w else 0
        # 屏幕区域帧间差（相机不动时才可信：要求 bbox 几乎重合）
        if crop is not None and prev_crop is not None and rec.get("found") and \
                prev_rec.get("found") and crop.shape == prev_crop.shape:
            iou = 0.0
            ix = max(rec["x"], prev_rec["x"])
            iy = max(rec["y"], prev_rec["y"])
            ax = min(rec["x"] + rec["w"], prev_rec["x"] + prev_rec["w"])
            ay = min(rec["y"] + rec["h"], prev_rec["y"] + prev_rec["h"])
            if ax > ix and ay > iy:
                inter = (ax - ix) * (ay - iy)
                iou = inter / (rec["w"] * rec["h"] + prev_rec["w"] * prev_rec["h"] - inter)
            rec["iou"] = round(iou, 3)
            if iou > 0.9:
                rec["dt_screen"] = float(
                    np.abs(crop.astype(np.int16) - prev_crop.astype(np.int16)).mean())
        rows.append(rec)
        if crop is not None:
            prev_crop = crop
            prev_rec = rec
        else:
            prev_crop = None
            prev_rec = None

        if rec.get("closeup") and args.save_every and (nproc - 1) % args.save_every == 0:
            cv2.imwrite(os.path.join(args.out, f"screen_{saved:02d}_f{idx:04d}.png"), crop)
            saved += 1
        if nproc % 50 == 0:
            print(f"  ..{idx}", flush=True)

    keys = sorted({k for r in rows for k in r})
    csv_path = os.path.join(args.out, "screen_stats.csv")
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        wtr = csv.DictWriter(f, fieldnames=keys)
        wtr.writeheader()
        wtr.writerows(rows)
    print(f"\nwrote {csv_path}  ({len(rows)} sampled frames)")

    def med(k, sel=None):
        v = [r[k] for r in rows if k in r and (sel is None or sel(r))]
        return (len(v), float(np.median(v)), float(min(v)), float(max(v))) if v else (0, 0, 0, 0)

    found = [r for r in rows if r.get("found")]
    close = [r for r in found if r.get("closeup")]
    print(f"\n屏幕定位成功: {len(found)}/{len(rows)} 帧；其中近景(>=35% 屏宽): {len(close)} 帧")
    for k in ("frac", "ar", "lit", "run", "nblob", "tiny", "bg", "red_frac"):
        n, m, lo, hi = med(k, lambda r: r.get("closeup"))
        print(f"  closeup {k:9s} n={n:4d} med={m:8.3f} min={lo:8.3f} max={hi:8.3f}")
    n, m, lo, hi = med("dt_screen", lambda r: r.get("closeup"))
    n2, m2, lo2, hi2 = med("dt_screen")
    print(f"  dt_screen(近景)  n={n} med={m:.3f} min={lo:.3f} max={hi:.3f}")
    print(f"  dt_screen(全部)  n={n2} med={m2:.3f} min={lo2:.3f} max={hi2:.3f}")
    # 分屏检测
    split = [r for r in close if r["left"] > 2.2 * r["right"] and r["left"] > 40]
    print(f"  疑似分屏(左亮右黑)帧数: {len(split)}/{len(close)}")


if __name__ == "__main__":
    main()
