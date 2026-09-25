#!/usr/bin/env python3
"""Watch the capture as video instead of judging it from a few stills.

Stills hide exactly the two defects that matter on a live screen: pattern noise
that is always in the same place (so every still shows it and no still shows it
moving), and speckle that changes every frame (so any two stills look equally
plausible). Both are temporal, so they need a temporal measurement.

This grabs a few seconds straight off the capture device and reports:

  grey half   the temporal mean and standard deviation. A per-column offset that
              never changes shows up as a comb in the mean, while the standard
              deviation says how much of each column's variation is noise.
  lines       the column profile of the mean is differentiated once, because that
              is what a Sobel does horizontally: a column with a fixed offset
              becomes a pair of spikes in d1 and therefore a lit vertical line in
              the edge map. Columns whose |d1| clears the threshold are counted.
  edge half   per pixel, the fraction of frames in which it is lit. That splits
              the map into solid contour (lit almost always), flicker (lit
              sometimes) and rare, and tells you whether the flickering pixels
              sit on the same columns as the lines.

Outputs a text report plus mean/std/persistence images, a column profile plot and
a looping GIF of the grey and edge halves, so the behaviour can be re-checked
later without re-running the board.

    python tools/analyze_video.py --device 1 --seconds 5 --out work/analysis/video
"""

from __future__ import annotations

import argparse
import os
import time

import cv2
import numpy as np

SEP_COL = 640


def open_device(index: int, width: int, height: int, fps: int) -> cv2.VideoCapture:
    for fourcc in ("YUY2", "MJPG", None):
        cap = cv2.VideoCapture(index, cv2.CAP_DSHOW)
        if not cap.isOpened():
            cap.release()
            continue
        if fourcc:
            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc))
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        cap.set(cv2.CAP_PROP_FPS, fps)
        ok, _ = cap.read()
        if ok:
            print(f"device {index}: {width}x{height} @ {fps}, fourcc {fourcc or 'default'}")
            return cap
        cap.release()
    raise SystemExit(f"could not open device {index} in any format")


def capture(cap: cv2.VideoCapture, seconds: float, keep: int):
    """Accumulate sum, sum of squares and the edge mask, keeping a short tail."""
    total = None
    total_sq = None
    mask_sum = None
    count = 0
    tail: list[np.ndarray] = []
    started = time.time()
    misses = 0
    while time.time() - started < seconds:
        ok, frame = cap.read()
        if not ok or frame is None:
            misses += 1
            if misses > 60:
                break
            time.sleep(0.01)
            continue
        misses = 0
        img = frame.astype(np.float64)
        if total is None:
            total = np.zeros_like(img)
            total_sq = np.zeros_like(img)
            mask_sum = np.zeros(img.shape[:2], dtype=np.float64)
        total += img
        total_sq += img * img
        b, g, r = img[:, :, 0], img[:, :, 1], img[:, :, 2]
        mask = ((r > 140) & (g > 140) & (b > 140)).astype(np.float64)
        mask[:, : SEP_COL + 1] = 0.0
        mask_sum += mask
        count += 1
        tail.append(frame)
        if len(tail) > keep:
            tail.pop(0)
    if count == 0:
        raise SystemExit("no frames arrived")
    return total / count, total_sq / count, mask_sum / count, tail, count


def column_profile(mean_grey: np.ndarray, sep: int) -> dict:
    """Static structure of the grey half, read as the Sobel would read it."""
    prof = mean_grey[:, :sep, :].mean(axis=(0, 2))  # one number per column
    d1 = np.diff(prof)                       # what a horizontal Sobel sees
    # A slow illumination tilt is not a defect; a comb is. Remove the tilt with a
    # wide moving average and keep the spikes.
    width = 65
    pad = width // 2
    smooth = np.convolve(np.pad(prof, pad, mode="edge"), np.ones(width) / width, mode="valid")
    comb = prof - smooth
    return {
        "prof": prof,
        "d1": d1,
        "comb": comb,
        "comb_rms": float(np.sqrt(np.mean(comb ** 2))),
        "comb_max": float(np.max(np.abs(comb))),
        "d1_rms": float(np.sqrt(np.mean(d1 ** 2))),
        "d1_max": float(np.max(np.abs(d1))),
    }


def report(args, mean, var, on, prof_info, frames, elapsed, count):
    sep = SEP_COL
    mean_grey = mean[:, :sep, :]
    grey_luma_mean = float(mean_grey.mean())
    grey_luma_sd = float(np.sqrt(var[:, :sep, :].mean()))
    print()
    print(f"{count} frames in {elapsed:.1f} s ({count / max(elapsed, 1e-6):.1f} fps), "
          f"{len(frames)} kept for the gif")
    print(f"grey half   mean {grey_luma_mean:6.2f}   temporal sd {grey_luma_sd:5.2f} LSB")

    print()
    print("--- persistent vertical structure in the grey half ---")
    print(f"column profile: rms |d1| {prof_info['d1_rms']:5.2f}  max |d1| {prof_info['d1_max']:6.2f} LSB")
    print(f"after removing the slow tilt: rms {prof_info['comb_rms']:5.2f}  max {prof_info['comb_max']:6.2f} LSB")
    comb = prof_info["comb"]
    for thresh in (2, 4, 8):
        n = int((np.abs(comb) > thresh).sum())
        print(f"  columns whose fixed offset exceeds {thresh:2d} LSB: {n:4d} of {sep}")
    order = np.argsort(-np.abs(comb))[:12]
    print("  worst columns: " + ", ".join(f"x={int(c)}({comb[c]:+.1f})" for c in sorted(order)))
    # How far apart are the strong columns? A regular comb has a characteristic gap.
    strong = np.where(np.abs(comb) > 4)[0]
    if len(strong) > 4:
        gaps = np.diff(strong)
        print(f"  gap between strong columns: median {int(np.median(gaps))} px, "
              f"10th..90th {int(np.percentile(gaps, 10))}..{int(np.percentile(gaps, 90))} px")

    print()
    print("--- persistence of the edge half ---")
    edge_on = on[:, sep + 1 :]
    lit_any = edge_on > 0.02
    solid = (edge_on > 0.9).sum()
    flick = ((edge_on > 0.1) & (edge_on <= 0.9)).sum()
    rare = ((edge_on > 0.02) & (edge_on <= 0.1)).sum()
    print(f"pixels lit in >2 % of frames: {int(lit_any.sum())}")
    print(f"  solid   (lit >90 % of frames): {int(solid):6d}")
    print(f"  flicker (lit 10..90 %)       : {int(flick):6d}")
    print(f"  rare    (lit 2..10 %)        : {int(rare):6d}")
    if lit_any.sum():
        print(f"  -> {100.0 * flick / lit_any.sum():.1f} % of the lit pixels flicker")

    per_col = edge_on.sum(axis=0)
    top = np.argsort(-per_col)[:10]
    print("  columns carrying the most edge pixels: "
          + ", ".join(f"x={int(sep + 1 + c)}({int(per_col[c])})" for c in sorted(top)))
    # Do the permanently lit pixels form whole columns? That is a line, not an
    # object.
    solid_per_col = (edge_on > 0.9).sum(axis=0)
    line_cols = np.where(solid_per_col > 0.8 * edge_on.shape[0])[0]
    print(f"  columns that are solid for >80 % of their height: {len(line_cols)}"
          + ("" if len(line_cols) == 0 else f"  (first few: {[int(c + sep + 1) for c in line_cols[:10]]})"))

    # Are the flickering pixels the *ends* of the lines, or spread out?
    flick_per_col = ((edge_on > 0.1) & (edge_on <= 0.9)).sum(axis=0)
    if prof_info["comb"].shape[0] == flick_per_col.shape[0]:
        c = np.corrcoef(np.abs(prof_info["comb"]), flick_per_col)[0, 1]
        print(f"  correlation between grey-half column offset and flickering pixels per column: {c:+.2f}")


def save_images(args, mean, var, on, prof_info, frames):
    os.makedirs(args.out, exist_ok=True)
    cv2.imwrite(os.path.join(args.out, "mean.png"), mean.astype(np.uint8))
    cv2.imwrite(os.path.join(args.out, "std_x8.png"),
                np.clip(np.sqrt(var) * 8, 0, 255).astype(np.uint8))
    # Persistence, colour coded: grey = lit rarely, green = solid, red = flickering.
    edge_on = on[:, SEP_COL + 1 :]
    vis = np.zeros((on.shape[0], edge_on.shape[1], 3), np.uint8)
    vis[..., 1] = np.clip(edge_on * 255 * (edge_on > 0.9), 0, 255).astype(np.uint8)
    flick = (edge_on > 0.1) & (edge_on <= 0.9)
    vis[flick] = (0, 0, 255)
    vis[..., 0] = np.where(edge_on <= 0.1, np.clip(edge_on * 255, 0, 255), 0).astype(np.uint8)
    cv2.imwrite(os.path.join(args.out, "persistence.png"), vis)

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    prof = prof_info["prof"]
    fig, axes = plt.subplots(3, 1, figsize=(11, 7), sharex=True)
    axes[0].plot(np.arange(SEP_COL), prof, lw=0.7)
    axes[0].set_ylabel("column mean (LSB)")
    axes[0].set_title("grey half, column profile of the temporal mean")
    axes[1].plot(np.arange(SEP_COL - 1), prof_info["d1"], lw=0.7, color="tab:red")
    axes[1].axhline(16, ls="--", c="k", lw=0.8)
    axes[1].axhline(-16, ls="--", c="k", lw=0.8)
    axes[1].set_ylabel("d1 (LSB)")
    axes[1].set_title("first difference - dashed lines are at the default floor of 16")
    axes[2].plot(np.arange(SEP_COL), prof_info["comb"], lw=0.7, color="tab:green")
    axes[2].set_ylabel("offset (LSB)")
    axes[2].set_xlabel("column x in the grey half")
    axes[2].set_title("column offset after removing the slow tilt (the fixed pattern)")
    fig.tight_layout()
    fig.savefig(os.path.join(args.out, "column_profile.png"), dpi=110)
    plt.close(fig)

    from PIL import Image

    step = max(1, len(frames) // args.gif_frames)
    picks = frames[::step][: args.gif_frames]
    small = [cv2.resize(f, None, fx=0.5, fy=0.5, interpolation=cv2.INTER_AREA) for f in picks]
    rgb = [cv2.cvtColor(f, cv2.COLOR_BGR2RGB) for f in small]
    gif_path = os.path.join(args.out, "loop.gif")
    imgs = [Image.fromarray(f) for f in rgb]
    imgs[0].save(gif_path, save_all=True, append_images=imgs[1:],
                 duration=int(1000 / args.gif_fps), loop=0, optimize=True)
    print(f"\nwrote {args.out}/mean.png, std_x8.png, persistence.png, column_profile.png, loop.gif "
          f"(gif {os.path.getsize(gif_path) / 1e6:.1f} MB, {len(imgs)} frames at {args.gif_fps} fps)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--device", type=int, default=1)
    parser.add_argument("--seconds", type=float, default=5.0)
    parser.add_argument("--out", default="work/analysis/video")
    parser.add_argument("--gif-frames", type=int, default=24)
    parser.add_argument("--gif-fps", type=int, default=8)
    parser.add_argument("--no-gif", action="store_true")
    args = parser.parse_args()
    args.frames = 0  # filled in by capture, kept for the report

    import subprocess

    subprocess.run(["powershell", "-NoProfile", "-Command",
                    "Get-Process WindowsCamera -ErrorAction SilentlyContinue | Stop-Process -Force"],
                   capture_output=True)
    time.sleep(0.4)

    cap = open_device(args.device, 1280, 720, 60)
    keep = 0 if args.no_gif else max(args.gif_frames, 1)
    started = time.time()
    mean, sq, on, tail, count = capture(cap, args.seconds, keep)
    elapsed = time.time() - started
    cap.release()
    var = np.maximum(sq - mean * mean, 0.0)

    args.frames = count
    prof_info = column_profile(mean, SEP_COL)
    report(args, mean, var, on, prof_info, tail, elapsed, count)
    if not args.no_gif:
        save_images(args, mean, var, on, prof_info, tail)
    else:
        save_images_no_gif(args, mean, var, on, prof_info)
    return 0


def save_images_no_gif(args, mean, var, on, prof_info):
    os.makedirs(args.out, exist_ok=True)
    cv2.imwrite(os.path.join(args.out, "mean.png"), mean.astype(np.uint8))
    cv2.imwrite(os.path.join(args.out, "std_x8.png"),
                np.clip(np.sqrt(var) * 8, 0, 255).astype(np.uint8))
    print(f"\nwrote {args.out}/mean.png, std_x8.png")


if __name__ == "__main__":
    raise SystemExit(main())
