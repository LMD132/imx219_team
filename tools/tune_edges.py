#!/usr/bin/env python3
"""Offline tuner for the on-board Sobel stage.

Replays the chain of rtl/edge_display_720p.v on a *sequence of captured HDMI
frames* so the denoiser, the threshold floor, the adaptive weight and a
candidate contrast front-end can be compared with numbers instead of by eye:

    BT.601 gray -> median 3x3 -> [denoise] -> [front-end] -> Sobel -> magnitude
    >= max(center >> shift, floor) -> despeckle

Why the left half of a split-screen capture is a valid input: the left half is
the raw grayscale of camera columns 0..639 (the board puts raw_gray there), the
right half is the Sobel of columns 640..1279. So the left half is a real,
unprocessed sample of what the camera sees, including the dark scenes that are
the problem.

Metrics. The first four are reference free and can be trusted:

  dens%     fraction of the frame marked as edge
  specks    one-pixel components (pure noise)
  frags     2..39 pixel components (dashes -> a broken contour)
  comps     all components (fewer means longer, smoother contours)

The next two need a sequence of a *static* scene, which is why this tool wants a
folder (or an AVI), not a single still. With the camera fixed, anything that
blinks is noise and anything that stays is structure:

  stable%   pixels marked in >=90% of frames, as a share of the union
  flick%    mean frame-to-frame edge churn, |XOR| / |OR|

The last column compares against a Canny edge map of the raw gray, to say
whether the extra pixels that a lower floor finds are real edges or noise.
"""

from __future__ import annotations

import argparse
import glob
import os
import sys

import cv2
import numpy as np


# ---------------------------------------------------------------- image input
def load_frames(path: str, limit: int, crop: str) -> list[np.ndarray]:
    files: list[str] = []
    if os.path.isdir(path):
        files = sorted(glob.glob(os.path.join(path, "*.png")))
        if not files:
            files = sorted(glob.glob(os.path.join(path, "*.avi")))
    else:
        files = [path]

    frames: list[np.ndarray] = []
    for f in files:
        if f.lower().endswith(".avi"):
            cap = cv2.VideoCapture(f)
            while len(frames) < limit:
                ok, img = cap.read()
                if not ok:
                    break
                frames.append(img)
            cap.release()
        else:
            img = cv2.imread(f, cv2.IMREAD_GRAYSCALE)
            if img is not None:
                frames.append(img)
        if len(frames) >= limit:
            break

    if not frames:
        raise SystemExit(f"no frames found under {path}")
    return [crop_split(gray_bt601(f) if f.ndim == 3 else f, crop) for f in frames]


def crop_split(img: np.ndarray, crop: str) -> np.ndarray:
    if crop == "none":
        return img
    h, w = img.shape[:2]
    if crop == "auto":
        crop = "left"
    if crop == "left":
        return img[:, : w // 2]
    if crop == "right":
        return img[:, w // 2 :]
    raise SystemExit(f"unknown crop {crop}")


# ------------------------------------------------------------- the RTL stages
def gray_bt601(bgr: np.ndarray) -> np.ndarray:
    """(77R + 150G + 29B) / 256, the integer constant of edge_display_720p.v."""
    b, g, r = (bgr[:, :, i].astype(np.uint32) for i in range(3))
    return ((r * 77 + g * 150 + b * 29) >> 8).astype(np.uint8)


def median3x3(img: np.ndarray) -> np.ndarray:
    """3x3 median, same window as median_filter_3x3_720p.v."""
    p = np.pad(img, 1, mode="edge")
    w = np.lib.stride_tricks.sliding_window_view(p, (3, 3))
    return np.median(w, axis=(2, 3)).astype(np.uint8)


def mean3x3(img: np.ndarray) -> np.ndarray:
    return cv2.blur(img, (3, 3))


def gauss3x3(img: np.ndarray) -> np.ndarray:
    """[1 2 1; 2 4 2; 1 2 1] / 16 - a power-of-two divide, so it is cheap in RTL."""
    return cv2.GaussianBlur(img, (3, 3), 0)


DENOISERS = {
    "none": lambda im: im,
    "mean3": mean3x3,
    "gauss3": gauss3x3,
    "mean3x2": lambda im: mean3x3(mean3x3(im)),
    "gauss3x2": lambda im: gauss3x3(gauss3x3(im)),
    "median5": lambda im: cv2.medianBlur(im, 5),
    "median3x2": median3x3,
}


def sobel_magnitude(img: np.ndarray) -> np.ndarray:
    """Standard 3x3 Sobel, |Gx| + |Gy|, un-normalised exactly like the RTL."""
    p = np.pad(img.astype(np.int32), 1, mode="edge")
    tl, tc, tr = p[0:-2, 0:-2], p[0:-2, 1:-1], p[0:-2, 2:]
    ml, mr = p[1:-1, 0:-2], p[1:-1, 2:]
    bl, bc, br = p[2:, 0:-2], p[2:, 1:-1], p[2:, 2:]
    gx = (tr + 2 * mr + br) - (tl + 2 * ml + bl)
    gy = (bl + 2 * bc + br) - (tl + 2 * tc + tr)
    return np.abs(gx) + np.abs(gy)


def rtl_edges(img: np.ndarray, floor: int, shift: int, ds: int) -> np.ndarray:
    """Binary edge map of one frame: edge_display_720p.v + edge_overlay_720p.v."""
    mag = sobel_magnitude(img)
    p = np.pad(img.astype(np.int32), 1, mode="edge")
    center = p[1:-1, 1:-1]
    binary = (mag >= np.maximum(center >> shift, floor)).astype(np.uint8)
    binary[0, :] = 0
    binary[:, 0] = 0
    if ds:
        k = np.ones((3, 3), np.uint8)
        nbr = cv2.filter2D(binary, -1, k, borderType=cv2.BORDER_CONSTANT) - binary
        binary = ((binary == 1) & (nbr >= ds)).astype(np.uint8)
    return binary


# ------------------------------------------------------------ contrast stages
def apply_gamma(img: np.ndarray, gamma: float) -> np.ndarray:
    lut = np.clip(np.round(255.0 * (np.arange(256) / 255.0) ** gamma), 0, 255)
    return lut[img].astype(np.uint8)


def apply_gain(img: np.ndarray, gain: float) -> np.ndarray:
    return np.clip(img.astype(np.float32) * gain, 0, 255).astype(np.uint8)


def apply_agc(img: np.ndarray, target: float, k_max: float = 6.0) -> np.ndarray:
    """Linear gain driving the frame mean towards `target`, capped at k_max."""
    mean = float(img.mean())
    k = 1.0 if mean < 1.0 else min(k_max, max(1.0, target / mean))
    return apply_gain(img, k)


def apply_histeq(img: np.ndarray) -> np.ndarray:
    hist = np.bincount(img.ravel(), minlength=256).astype(np.float64)
    cdf = np.cumsum(hist) / img.size
    lut = np.clip(np.round(cdf * 255.0), 0, 255).astype(np.uint8)
    return lut[img]


def apply_clahe(img: np.ndarray, clip: float = 2.0, tiles: int = 8) -> np.ndarray:
    return cv2.createCLAHE(clipLimit=clip, tileGridSize=(tiles, tiles)).apply(img)


FRONTENDS = {
    "none": lambda arg: (lambda im: im, "none"),
    "gain": lambda arg: (lambda im: apply_gain(im, float(arg or 2)), f"gainx{arg or 2}"),
    "agc": lambda arg: (lambda im: apply_agc(im, float(arg or 96)), f"agc{arg or 96}"),
    "gamma": lambda arg: (lambda im: apply_gamma(im, float(arg or 0.6)), f"gam{arg or 0.6}"),
    "histeq": lambda arg: (apply_histeq, "histeq"),
    "clahe": lambda arg: (apply_clahe, "clahe"),
}


def parse_frontend(spec: str):
    name, _, arg = spec.partition(":")
    if name not in FRONTENDS:
        raise SystemExit(f"unknown front-end {spec}")
    return FRONTENDS[name](arg)


# -------------------------------------------------------------------- metrics
def components(binary: np.ndarray):
    n, _, stats, _ = cv2.connectedComponentsWithStats(binary, connectivity=8)
    sizes = stats[1:, cv2.CC_STAT_AREA]
    return n - 1, int((sizes == 1).sum()), int(((sizes >= 2) & (sizes < 40)).sum())


def sequence_metrics(maps: list[np.ndarray], ref: np.ndarray | None) -> dict:
    stack = np.stack([m.astype(np.float32) for m in maps])
    n, total = len(maps), maps[0].size
    cnt = stack.sum(0)
    union = cnt > 0
    stable = cnt >= 0.9 * n
    flick = 0.0
    for i in range(n - 1):
        x = maps[i].astype(bool)
        y = maps[i + 1].astype(bool)
        flick += np.count_nonzero(x ^ y) / max(1, np.count_nonzero(x | y))
    comps, specks, frags = components(maps[0].astype(np.uint8))
    out = {
        "density": 100.0 * stack.mean(),
        "udens": 100.0 * union.sum() / total,
        "specks": specks,
        "frags": frags,
        "comps": comps,
        "stable": 100.0 * stable.sum() / max(1, union.sum()),
        "flick": 100.0 * flick / max(1, n - 1),
        "onreal": float("nan"),
    }
    if ref is not None:
        d = cv2.dilate(union.astype(np.uint8), np.ones((3, 3), np.uint8))
        out["onreal"] = 100.0 * np.count_nonzero(d & ref) / max(1, int(d.sum()))
    return out


def fmt_header() -> str:
    return ("     front       deno floor sh ds  dens% udens% specks  frags   comps "
            "stable% flick% onreal%")


def fmt_row(r: dict) -> str:
    return (f"{r['front']:>9} {r['deno']:>10} {r['floor']:>5} {r['shift']:>2} "
            f"{r['ds']:>2} {r['density']:>6.2f} {r['udens']:>6.2f} "
            f"{r['specks']:>6} {r['frags']:>6} "
            f"{r['comps']:>7} {r['stable']:>6.1f}% {r['flick']:>5.1f}% "
            f"{r['onreal']:>6.1f}%")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--input", required=True, help="folder of PNGs, a PNG, or an AVI")
    ap.add_argument("--crop", default="auto", choices=["auto", "left", "right", "none"])
    ap.add_argument("--frames", type=int, default=12, help="how many frames to use")
    ap.add_argument("--no-median", dest="median", action="store_false", default=True,
                    help="skip the RTL's own 3x3 median (it is on by default)")
    ap.add_argument("--denoise", default="none",
                    help="comma list of none,mean3,mean3x2,median5,median3x2")
    ap.add_argument("--frontend", default="none",
                    help="comma list of none,gain:K,agc:T,gamma:G,histeq,clahe")
    ap.add_argument("--floor", default="8,12,16,24", help="comma list of floors")
    ap.add_argument("--shift", default="1", help="comma list of adaptive weights")
    ap.add_argument("--ds", default="3", help="comma list of despeckle neighbours")
    ap.add_argument("--dump", default=None, help="write the best edge maps here")
    ap.add_argument("--dump-best", type=int, default=8, help="how many maps to save")
    args = ap.parse_args()

    frames = load_frames(args.input, args.frames, args.crop)
    grays = [median3x3(f) for f in frames] if args.median else frames

    h, w = grays[0].shape
    print(f"frames {len(grays)}  crop={args.crop}  {w}x{h}  "
          f"median3={'on' if args.median else 'off'}")
    print(f"gray mean {np.mean([g.mean() for g in grays]):.1f}/255  "
          f"p1 {np.percentile(grays[0],1):.0f}  p50 {np.median(grays[0]):.0f}  "
          f"p99 {np.percentile(grays[0],99):.0f}  "
          f"temporal sigma {np.stack(grays).astype(np.float32).std(0).mean():.2f}")
    ref = np.zeros((h, w), np.uint8)
    for g in grays[: min(3, len(grays))]:
        c = cv2.Canny(g, 25, 70)
        ref = cv2.bitwise_or(ref, cv2.bitwise_or(c, cv2.dilate(c, np.ones((3, 3), np.uint8))))
    print(f"canny reference touches {ref.mean()/2.55:.2f}% of the frame\n")

    header = fmt_header()
    print(header)
    print("-" * len(header))
    results = []
    for deno in args.denoise.split(","):
        dg = [DENOISERS[deno](g) for g in grays]
        for spec in args.frontend.split(","):
            fn, label = parse_frontend(spec)
            fg = [fn(g) for g in dg]
            for floor in [int(x) for x in args.floor.split(",") if x]:
                for shift in [int(x) for x in args.shift.split(",") if x]:
                    for ds in [int(x) for x in args.ds.split(",") if x]:
                        maps = [rtl_edges(g, floor, shift, ds) for g in fg]
                        m = sequence_metrics(maps, ref)
                        m.update(spec=spec, front=label, deno=deno,
                                 floor=floor, shift=shift, ds=ds)
                        results.append(m)
                        print(fmt_row(m))
        print()

    if args.dump:
        os.makedirs(args.dump, exist_ok=True)
        picks = sorted(results, key=lambda r: -r["stable"])[: args.dump_best]
        for i, r in enumerate(picks):
            fn, _ = parse_frontend(r["spec"])
            fg = [fn(g) for g in [DENOISERS[r["deno"]](g) for g in grays]]
            m = rtl_edges(fg[0], r["floor"], r["shift"], r["ds"])
            name = (f"{i:02d}_{r['spec']}_{r['deno']}_f{r['floor']}"
                    f"_s{r['shift']}_d{r['ds']}.png").replace(":", "")
            cv2.imwrite(os.path.join(args.dump, name), (m * 255).astype(np.uint8))
        print(f"saved {len(picks)} maps to {args.dump}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
