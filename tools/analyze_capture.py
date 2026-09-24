#!/usr/bin/env python3
"""Re-compute the on-board Sobel chain in Python from a captured picture.

The point is to stop guessing. A capture stick records the board's HDMI output,
this script takes the *input side* of that picture (the raw grayscale the board
itself got from the camera), replays the exact integer pipeline of
rtl/edge_display_720p.v + rtl/edge_overlay_720p.v on it, and reports numbers
instead of impressions:

  * how much of the frame is edge (edge ratio, in %)
  * how much edge lands in the dark part of the image, which is the complaint
    that started this ("a person in dim light has almost no outline")
  * which bounding box the min/max logic of edge_overlay_720p.v would draw, so a
    box that saturates the whole frame is visible in the numbers
  * the same numbers for candidate front-end enhancements (gamma LUT, per-frame
    mean-gain, histogram equalisation, CLAHE) so the RTL change that actually
    helps can be picked with evidence

The emulation mirrors the RTL on purpose:

  gray       = (77 R + 150 G + 29 B) >> 8           median_filter_3x3_720p.v
  median     = 3x3 median of gray                    median_filter_3x3_720p.v
  magnitude  = |Gx| + |Gy|, 3x3 Sobel on median      edge_display_720p.v
  threshold  = max(median_center >> shift, floor)    edge_display_720p.v
  edge       = magnitude >= threshold                edge_display_720p.v
  despeckle  = centre AND (neighbours >= DS)         edge_overlay_720p.v

Usage:

    python tools/analyze_capture.py --input work/capture/dark_target
    python tools/analyze_capture.py --input clip.avi --dump work/analysis
    python tools/analyze_capture.py --input frame_00.png --sweep

OpenCV's Sobel border mode is not the board's (the board drops the window at the
frame edge), so the outer one-pixel ring is forced to zero before measuring.
"""

from __future__ import annotations

import argparse
import glob
import os
import sys

import cv2
import numpy as np


# --------------------------------------------------------------------------
# The board's integer pipeline
# --------------------------------------------------------------------------

def gray_bt601(bgr: np.ndarray) -> np.ndarray:
    b = bgr[:, :, 0].astype(np.uint16)
    g = bgr[:, :, 1].astype(np.uint16)
    r = bgr[:, :, 2].astype(np.uint16)
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)


def sobel_magnitude(gray: np.ndarray) -> np.ndarray:
    gx = cv2.Sobel(gray, cv2.CV_16S, 1, 0, ksize=3)
    gy = cv2.Sobel(gray, cv2.CV_16S, 0, 1, ksize=3)
    mag = np.abs(gx).astype(np.int32) + np.abs(gy).astype(np.int32)
    mag[0, :] = 0
    mag[-1, :] = 0
    mag[:, 0] = 0
    mag[:, -1] = 0
    return mag


def despeckle(edges: np.ndarray, min_neighbours: int) -> np.ndarray:
    """centre AND (set neighbours >= min_neighbours), as in edge_overlay_720p.v."""
    if min_neighbours <= 0:
        return edges
    kernel = np.ones((3, 3), np.uint8)
    with_self = cv2.filter2D((edges > 0).astype(np.uint8), -1, kernel,
                             borderType=cv2.BORDER_CONSTANT)
    neighbours = with_self.astype(np.int32) - 1
    keep = (edges > 0) & (neighbours >= min_neighbours)
    return (keep.astype(np.uint8) * 255)


def rtl_edges(gray: np.ndarray, floor: int, shift: int, ds: int = 0) -> np.ndarray:
    """Apply median -> Sobel -> adaptive threshold -> optional despeckle."""
    med = cv2.medianBlur(gray, 3)
    mag = sobel_magnitude(med)
    local = med.astype(np.int32) >> shift
    active = np.maximum(local, floor)
    edges = ((mag >= active) & (mag > 0)).astype(np.uint8) * 255
    return despeckle(edges, ds)


# --------------------------------------------------------------------------
# Candidate front-end enhancements (all integer, all cheap in RTL)
# --------------------------------------------------------------------------

def gamma_lut(gamma: float) -> np.ndarray:
    ramp = np.arange(256, dtype=np.float64) / 255.0
    return np.clip(np.round(255.0 * ramp ** gamma), 0, 255).astype(np.uint8)


def apply_gamma(gray: np.ndarray, gamma: float) -> np.ndarray:
    """One 256x8 ROM in RTL."""
    return gamma_lut(gamma)[gray]


def apply_mean_gain(gray: np.ndarray, k: int) -> np.ndarray:
    """out = mean + k * (in - mean), the vip_contrast idea.

    RTL keeps a per-frame accumulator (one adder) and gets the mean with
    shifts only, so the mean is emulated with the same shift approximation
    instead of True division: sum / 921600 ~= (S + S/8 + S/64) >> 20.
    """
    total = int(gray.astype(np.uint32).sum())
    mean = (total + (total >> 3) + (total >> 6)) >> 20
    out = mean + k * (gray.astype(np.int32) - mean)
    return np.clip(out, 0, 255).astype(np.uint8)


def apply_histeq(gray: np.ndarray) -> np.ndarray:
    """Per-frame CDF remap: 256 bins + a 256x8 LUT, one frame of latency."""
    return cv2.equalizeHist(gray)


def apply_clahe(gray: np.ndarray, clip: float = 2.0) -> np.ndarray:
    """Local contrast - the strong reference, but it needs per-tile histograms."""
    return cv2.createCLAHE(clipLimit=clip, tileGridSize=(8, 8)).apply(gray)


CANDIDATES = [
    ("none (board today)", lambda g: g),
    ("gamma 0.8", lambda g: apply_gamma(g, 0.8)),
    ("gamma 0.65", lambda g: apply_gamma(g, 0.65)),
    ("gamma 0.5", lambda g: apply_gamma(g, 0.5)),
    ("mean-gain k=2", lambda g: apply_mean_gain(g, 2)),
    ("mean-gain k=3", lambda g: apply_mean_gain(g, 3)),
    ("histeq", apply_histeq),
    ("clahe 2.0 (reference)", apply_clahe),
]


# --------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------

DARK_LEVEL = 64  # "dark part of the picture", absolute gray level


def dark_mask(gray: np.ndarray) -> np.ndarray:
    return gray < DARK_LEVEL


def bounding_box(edges: np.ndarray) -> tuple[int, int, int, int] | None:
    """What edge_overlay_720p.v's per-frame min/max would latch."""
    ys, xs = np.nonzero(edges)
    if xs.size == 0:
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def edge_metrics(edges: np.ndarray, gray: np.ndarray) -> dict:
    height, width = gray.shape
    active = edges > 0
    dark = dark_mask(gray)
    dark_pixels = int(dark.sum())
    dark_edges = int((active & dark).sum())

    # How many dark areas carry any outline at all: a dark object whose contour
    # survives produces edges inside the dark mask around it.
    box = bounding_box(edges)
    if box:
        x0, y0, x1, y1 = box
        box_area = (x1 - x0 + 1) * (y1 - y0 + 1)
    else:
        box_area = 0

    return {
        "edge_ratio": float(active.sum()) / (height * width) * 100.0,
        "dark_ratio": float(dark_pixels) / (height * width) * 100.0,
        "dark_edge_ratio": (float(dark_edges) / dark_pixels * 100.0) if dark_pixels else 0.0,
        "dark_edges": dark_edges,
        "box": box,
        "box_fraction": float(box_area) / (height * width) * 100.0,
    }


# --------------------------------------------------------------------------
# Input handling
# --------------------------------------------------------------------------

def frame_source(path: str, max_frames: int):
    """Yield BGR frames from a PNG, a folder of PNGs, or a video file."""
    if os.path.isdir(path):
        files = sorted(glob.glob(os.path.join(path, "*.png")))
        if not files:
            raise SystemExit("no PNG files in %s" % path)
        for name in files[:max_frames]:
            frame = cv2.imread(name, cv2.IMREAD_COLOR)
            if frame is not None:
                yield name, frame
        return

    if path.lower().endswith((".png", ".jpg", ".jpeg", ".bmp")):
        frame = cv2.imread(path, cv2.IMREAD_COLOR)
        if frame is None:
            raise SystemExit("cannot read %s" % path)
        yield path, frame
        return

    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise SystemExit("cannot open %s" % path)
    index = 0
    while index < max_frames:
        ok, frame = cap.read()
        if not ok:
            break
        yield "%s#%d" % (os.path.basename(path), index), frame
        index += 1
    cap.release()


def looks_like_split_screen(frame: np.ndarray) -> bool:
    """True when column width/2 is the board's white separator."""
    height, width = frame.shape[:2]
    if width < 8:
        return False
    column = frame[:, width // 2, :]
    return bool((column.min(axis=1) >= 240).mean() > 0.9)


def input_side(frame: np.ndarray, crop: str) -> tuple[np.ndarray, str]:
    """Return the raw grayscale the board processed, and how it was obtained."""
    if crop == "left" or (crop == "auto" and looks_like_split_screen(frame)):
        half = frame.shape[1] // 2
        return gray_bt601(frame[:, :half]), "left half of the split screen"
    return gray_bt601(frame), "whole frame"


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

def contact_sheet(panels: list[tuple[str, np.ndarray]]) -> np.ndarray:
    """Tile (label, image) pairs into one BGR sheet for a quick look."""
    tiles = []
    for label, image in panels:
        tile = cv2.resize(image, (480, 270), interpolation=cv2.INTER_AREA)
        if tile.ndim == 2:
            tile = cv2.cvtColor(tile, cv2.COLOR_GRAY2BGR)
        cv2.putText(tile, label, (8, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.7,
                    (0, 255, 0), 2, cv2.LINE_AA)
        tiles.append(tile)

    while len(tiles) % 2:
        tiles.append(np.zeros_like(tiles[0]))

    rows = [np.hstack(tiles[i:i + 2]) for i in range(0, len(tiles), 2)]
    return np.vstack(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--input", required=True, help="PNG, folder of PNGs, or video")
    parser.add_argument("--crop", choices=("auto", "left", "none"), default="auto",
                        help="auto uses the left half when the frame is a split screen")
    parser.add_argument("--floor", type=int, default=24, help="threshold floor (board default 24)")
    parser.add_argument("--shift", type=int, default=1, help="adaptive weight (board default 1)")
    parser.add_argument("--ds", type=int, default=0, help="despeckle neighbours (0 = off)")
    parser.add_argument("--max-frames", type=int, default=30)
    parser.add_argument("--sweep", action="store_true", help="also sweep the threshold floor")
    parser.add_argument("--dump", default=None, help="write a contact sheet to this folder")
    args = parser.parse_args()

    rows: list[dict] = []
    panels_written = False

    for name, frame in frame_source(args.input, args.max_frames):
        gray, source = input_side(frame, args.crop)

        baseline = rtl_edges(gray, args.floor, args.shift, args.ds)
        metrics = edge_metrics(baseline, gray)
        rows.append(metrics)

        if args.dump and not panels_written:
            panels: list[tuple[str, np.ndarray]] = [
                ("raw gray (board input)", gray),
                ("board chain today", baseline),
            ]
            for label, fn in CANDIDATES[1:]:
                candidate_gray = fn(gray)
                panels.append((label, rtl_edges(candidate_gray, args.floor, args.shift, args.ds)))
            sheet = contact_sheet(panels)
            os.makedirs(args.dump, exist_ok=True)
            out_path = os.path.join(args.dump, "contact_sheet.png")
            cv2.imwrite(out_path, sheet)
            print("wrote %s" % out_path)
            panels_written = True

        print(
            "%-22s  input: %-30s  edge %5.2f%%  dark %5.2f%%  "
            "edges-in-dark %5d (%.2f%% of dark)  box %s (%.1f%% of frame)"
            % (
                name if len(name) <= 22 else "..." + name[-19:],
                source,
                metrics["edge_ratio"],
                metrics["dark_ratio"],
                metrics["dark_edges"],
                metrics["dark_edge_ratio"],
                metrics["box"],
                metrics["box_fraction"],
            )
        )

    if not rows:
        raise SystemExit("no frames analysed")

    def mean_of(key: str) -> float:
        return float(np.mean([row[key] for row in rows]))

    print()
    print("frames analysed      : %d" % len(rows))
    print("edge ratio           : %.2f %%" % mean_of("edge_ratio"))
    print("dark pixels          : %.2f %% of frame (gray < %d)" % (mean_of("dark_ratio"), DARK_LEVEL))
    print("edge pixels in dark  : %.2f %% of the dark area" % mean_of("dark_edge_ratio"))
    print("box area             : %.1f %% of frame" % mean_of("box_fraction"))

    if args.sweep:
        print()
        print("threshold sweep on the first frame (floor, shift=%d, ds=%d)" % (args.shift, args.ds))
        for _, frame in frame_source(args.input, 1):
            gray, _ = input_side(frame, args.crop)
            print("  floor | edge %  | edges in dark")
            for floor in (4, 8, 12, 16, 24, 32, 48, 64, 96):
                edges = rtl_edges(gray, floor, args.shift, args.ds)
                metrics = edge_metrics(edges, gray)
                print("  %5d | %6.2f | %8d" % (floor, metrics["edge_ratio"], metrics["dark_edges"]))

    return 0


if __name__ == "__main__":
    sys.exit(main())
